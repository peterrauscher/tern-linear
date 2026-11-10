// Headless Tern driver: loads this plugin as a fixture into an isolated `tern serve` and exposes its control commands.
//
//   const t = await startTern({ env: { LINEAR_API_URL: mock.url, LINEAR_API_KEY: "..." }, out: "e2e-artifacts/shots" });
//   await t.ctl('palette "New Linear block"');
//   await t.expect("Connect Linear");
//   await t.shot("01-setup");
//   await t.stop();
//
// Every instance gets its own config, log and work directories, so it never touches the user's Tern.
import { copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

export const BLOCK_SELECTOR = "[data-surface='plugin.linear.board']";
const PACKAGE_ENTRIES = ["plugin.toml", "host.luau", "lib", "styles", "LICENSE"];
const INHERITED_PREFIXES = ["TERN_", "STENCIL_", "LINEAR_"];
const CTL_TIMEOUT_MS = 45_000;
const STARTUP_TIMEOUT_MS = 20_000;

/** Quotes text as one argument for the scenario parser (`\"`, `\\`, `\n`, `\t` escapes). */
export function quote(text) {
	const escaped = text
		.replaceAll("\\", "\\\\")
		.replaceAll('"', '\\"')
		.replaceAll("\n", "\\n")
		.replaceAll("\t", "\\t");
	return `"${escaped}"`;
}

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

/**
 * Starts `tern serve` with the plugin at `pluginDir` loaded as a fixture.
 * @param {object} [options]
 * @param {Record<string, string>} [options.env]   extra environment (LINEAR_API_URL, LINEAR_API_KEY, ...)
 * @param {string} [options.out]                   directory for `shot` output (default `<tmp>/shots`)
 * @param {string} [options.pluginDir]             package root (default: this repository)
 * @param {boolean} [options.keep]                 keep the temporary directory after `stop()`
 * @param {string} [options.size]                  viewport, e.g. "1600 1000"
 */
export async function startTern({ env = {}, out, pluginDir = repoRoot, keep = false, size } = {}) {
	const root = mkdtempSync("/tmp/tern-linear-");
	const fixtureRoot = join(root, "fx/crates/tern");
	const target = join(root, "fx/crates/plugins/fixtures/linear");
	const outDir = resolve(out ?? join(root, "shots"));
	const logDir = join(root, "logs");
	const work = join(root, "work");
	const socket = join(root, "ctl.sock");

	mkdirSync(join(fixtureRoot, "goldens/fixtures"), { recursive: true });
	mkdirSync(target, { recursive: true });
	for (const dir of [join(root, "config"), logDir, work, outDir]) mkdirSync(dir, { recursive: true });
	for (const entry of PACKAGE_ENTRIES) {
		const from = join(pluginDir, entry);
		if (existsSync(from)) cpSync(from, join(target, entry), { recursive: true });
	}

	const childEnv = Object.fromEntries(
		Object.entries(process.env).filter(([key]) => !INHERITED_PREFIXES.some((prefix) => key.startsWith(prefix))),
	);
	Object.assign(childEnv, {
		TERN_CONFIG_DIR: join(root, "config"),
		STENCIL_LOG_DIR: logDir,
		STENCIL_FIXTURE_ROOT: fixtureRoot,
		STENCIL_LOG: "warn,stencil=info,tern::plugin=debug",
		...env,
	});

	const server = Bun.spawn(["tern", "serve", "--control", socket, "--out", outDir], {
		cwd: work,
		env: childEnv,
		stdout: "ignore",
		stderr: "ignore",
	});

	/** Sends one control line; resolves to the parsed JSON reply. */
	async function ctl(line, { allowFail = false, timeoutMs = CTL_TIMEOUT_MS } = {}) {
		const proc = Bun.spawn(["tern", "ctl", "--control", socket, line], {
			cwd: work,
			env: childEnv,
			stdout: "pipe",
			stderr: "pipe",
		});
		const timer = setTimeout(() => proc.kill(), timeoutMs);
		const [stdout, stderr] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
		await proc.exited;
		clearTimeout(timer);
		const first = stdout.trim().split("\n")[0] ?? "";
		let reply;
		try {
			reply = JSON.parse(first);
		} catch {
			reply = { ok: false, error: first || stderr.trim().slice(0, 400) || "no reply (timeout?)" };
		}
		if (!reply.ok && !allowFail) throw new Error(`tern ctl \`${line}\` failed: ${reply.error ?? first}`);
		return reply;
	}

	const deadline = Date.now() + STARTUP_TIMEOUT_MS;
	while (!existsSync(socket)) {
		if (Date.now() > deadline || server.exitCode !== null) {
			server.kill();
			throw new Error("tern serve did not open its control socket");
		}
		await sleep(100);
	}

	let stopped = false;
	const instance = {
		root,
		out: outDir,
		ctl,

		/** `plugins expect`: only sees the start of the surface text; prefer `waitFor` for anything else. */
		expect: (text) => ctl(`plugins expect ${quote(text)}`),

		/** Advances app time (headless runs have no wall clock: overlays slide in only as time passes). */
		wait: (ms) => ctl(`wait ${ms}`),

		/** Takes a screenshot into `<out>/serve/<name>.png` after letting animations finish; resolves to that path. */
		async shot(name) {
			await ctl("wait 900");
			const reply = await ctl(`shot ${name}`);
			if (!reply.png || !existsSync(reply.png)) throw new Error(`shot ${name}: no PNG in reply ${JSON.stringify(reply)}`);
			return reply.png;
		},

		/** `tree SELECTOR`; the control command takes the selector unquoted. */
		tree: (selector) => ctl(`tree ${selector}`),

		/**
		 * Visible text of `selector` and everything below it, one string per line. `tree` caps each node's text at
		 * 200 characters, so descendants are listed separately to see the whole content.
		 */
		async text(selector = BLOCK_SELECTOR) {
			const lines = [];
			for (const query of [selector, `${selector} *`]) {
				for (const node of (await instance.tree(query)).nodes ?? []) if (node.text) lines.push(node.text);
			}
			return lines.join("\n");
		},

		/** Polls (advancing app time by 150 ms per round) until the text under `selector` contains `text`. */
		async waitFor(selector, text, { timeout = 15_000 } = {}) {
			let seen = "";
			try {
				await waitFor(
					async () => {
						await ctl("wait 150");
						seen = await instance.text(selector);
						return seen.includes(text);
					},
					{ timeout, interval: 0, what: `${JSON.stringify(text)} under ${selector}` },
				);
			} catch (error) {
				throw new Error(`${error.message}; the text there is: ${seen.slice(0, 600)}`);
			}
		},

		/** Polls until no text under `selector` contains `text` (an absent selector counts as empty). */
		gone: (selector, text, { timeout = 15_000 } = {}) =>
			waitFor(
				async () => {
					await ctl("wait 150");
					return !(await instance.text(selector)).includes(text);
				},
				{ timeout, interval: 0, what: `${JSON.stringify(text)} to disappear from ${selector}` },
			),

		/** Opens a new Linear block from the palette and, by default, zooms its pane to fill the window. */
		async openBlock({ zoom = true } = {}) {
			await ctl('palette "New Linear block"');
			await ctl("key Enter");
			if (zoom) await ctl("zoom");
		},

		key: (combo) => ctl(`key ${combo}`),
		type: (text) => ctl(`type ${quote(text)}`),
		click: (selector) => ctl(`click ${quote(selector)}`),

		/** Warnings, errors and the plugin's own log lines (`tern::plugin`) written since the start. */
		logs() {
			const lines = [];
			for (const name of readdirSync(logDir).sort()) {
				if (!name.endsWith(".log")) continue;
				for (const line of readFileSync(join(logDir, name), "utf8").split("\n")) {
					if (/ (WARN|ERROR) |tern::plugin/.test(line)) lines.push(line.slice(0, 800));
				}
			}
			return lines;
		},

		async stop() {
			if (stopped) return;
			stopped = true;
			await ctl("quit", { allowFail: true, timeoutMs: 10_000 }).catch(() => {});
			const exited = await Promise.race([server.exited, sleep(10_000).then(() => null)]);
			if (exited === null) server.kill();
			if (!keep) rmSync(root, { recursive: true, force: true, maxRetries: 3 });
		},
	};

	try {
		await ctl("ready");
		if (size) await ctl(`size ${size}`);
		await ctl("plugins fixtures");
	} catch (error) {
		await instance.stop();
		throw error;
	}
	return instance;
}

// ─── scenario helpers shared by test/e2e.mjs and test/live-smoke.mjs ────────

/** Plugin log lines that always fail a run. */
const FATAL_LOG =
	/plugin handler failed|plugin style sheet has errors|plugin hook exceeded its budget|plugin failed to load|plugin window entry failed to load|not a usable plugin/;

/** Polls `check` until it returns a truthy value; rejects with `what` after `timeout` ms. */
export async function waitFor(check, { what, timeout = 15_000, interval = 150 } = {}) {
	const deadline = Date.now() + timeout;
	for (;;) {
		const value = await check();
		if (value) return value;
		if (Date.now() > deadline) throw new Error(`timed out after ${timeout / 1000}s waiting for ${what ?? "condition"}`);
		await sleep(interval);
	}
}

/**
 * Numbered steps with a screenshot per step and a JSON report.
 * The first failing step takes a `-FAILED` screenshot, writes the report and rethrows.
 */
export function createRunner(initial, { dir, shotsDir = join(dir, "shots"), title }) {
	mkdirSync(shotsDir, { recursive: true });
	const startedAt = Date.now();
	const report = { title, passed: false, steps: [], shots: [], logs: [], durationMs: 0 };
	let number = 0;
	let t = initial;

	const runner = {
		report,
		shotsDir,

		/** Continues the same report with another Tern instance (e.g. a fresh one for README shots). */
		attach(next) {
			t = next;
		},

		/** Screenshot copied to `<shotsDir>/<name>.png`. */
		async shot(name) {
			const target = join(shotsDir, `${name}.png`);
			copyFileSync(await t.shot(name), target);
			report.shots.push(target);
			return target;
		},

		/** Runs `fn`; `fn` receives the step label and returns nothing. */
		async step(name, fn) {
			number += 1;
			const label = `${String(number).padStart(2, "0")}-${name}`;
			const entry = { step: number, name, ok: false, ms: 0 };
			report.steps.push(entry);
			const began = Date.now();
			try {
				await fn(label);
				const fatal = t.logs().filter((line) => FATAL_LOG.test(line));
				if (fatal.length > 0) throw new Error(`plugin log reported a failure:\n${fatal.join("\n")}`);
				entry.ok = true;
				console.log(`ok   ${label} (${Date.now() - began} ms)`);
			} catch (error) {
				entry.error = error instanceof Error ? error.message : String(error);
				console.log(`FAIL ${label}: ${entry.error}`);
				try {
					entry.shot = await runner.shot(`${label}-FAILED`);
					entry.visibleText = (await t.text()).slice(0, 4000);
				} catch {
					// the failure itself may be the reason nothing can be captured
				}
				throw error;
			} finally {
				entry.ms = Date.now() - began;
			}
		},

		/** Writes `<dir>/report.json`; `extra` is merged into the report. */
		finish(passed, extra = {}) {
			report.passed = passed;
			report.durationMs = Date.now() - startedAt;
			report.logs = t.logs();
			Object.assign(report, extra);
			writeFileSync(join(dir, "report.json"), `${JSON.stringify(report, null, 2)}\n`);
		},
	};
	return runner;
}
