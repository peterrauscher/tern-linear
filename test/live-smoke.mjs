// Smoke test against the real Linear API (no mock).
//   bun test/live-smoke.mjs            read-only: board, table, detail drawer
//   bun test/live-smoke.mjs --write    also creates, comments on and completes one issue
//
// The key comes from LINEAR_API_KEY, else ~/.config/tern-linear-dev/api-key. It is never printed or written to the report.
// Screenshots and the report go to e2e-artifacts/live/.
import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createRunner, repoRoot, startTern, waitFor } from "./harness.mjs";

const write = process.argv.includes("--write");
const artifacts = join(repoRoot, "e2e-artifacts/live");
const ternOut = join(artifacts, "tern-out");
const IDENTIFIER = /\b[A-Z][A-Z0-9]*-\d+\b/;

function readKey() {
	const fromEnv = process.env.LINEAR_API_KEY?.trim();
	if (fromEnv) return fromEnv;
	const file = join(homedir(), ".config/tern-linear-dev/api-key");
	if (existsSync(file)) return readFileSync(file, "utf8").trim();
	console.error("live-smoke: set LINEAR_API_KEY or create ~/.config/tern-linear-dev/api-key");
	process.exit(2);
}

rmSync(artifacts, { recursive: true, force: true });
mkdirSync(artifacts, { recursive: true });

// Never point the plugin at the mock: LINEAR_API_URL is stripped from the child environment by the harness.
const t = await startTern({ env: { LINEAR_API_KEY: readKey() }, out: ternOut, size: "1440 900" });
const runner = createRunner(t, { dir: artifacts, title: write ? "tern-linear live smoke (write)" : "tern-linear live smoke" });

const role = (name) => `[data-role='linear.${name}']`;
const exists = async (selector) => ((await t.tree(selector)).nodes ?? []).length > 0;
// Polling advances app time (`wait 150`): headless Tern only animates and renders as time passes.
const present = (selector, timeout) =>
	waitFor(async () => (await t.wait(150), exists(selector)), { what: `${selector} to appear`, timeout, interval: 0 });
const absent = (selector) =>
	waitFor(async () => (await t.wait(150), !(await exists(selector))), { what: `${selector} to disappear`, interval: 0 });
const backspaces = async (count) => {
	for (let i = 0; i < count; i += 1) await t.key("Backspace");
};

async function closeDrawer() {
	for (let attempt = 0; attempt < 4 && (await exists(role("drawer"))); attempt += 1) await t.key("Escape");
	await absent(role("drawer"));
}

/** Number of cards once it has not changed for `quietMs` (and, while it is 0, for at least `emptyMs`). */
async function cardCountSettled({ quietMs = 2500, emptyMs = 6000, timeout = 45_000 } = {}) {
	const began = Date.now();
	let count = -1;
	let since = began;
	for (;;) {
		await t.wait(150);
		const now = Date.now();
		const current = ((await t.tree(role("card"))).nodes ?? []).length;
		if (current !== count) {
			count = current;
			since = now;
		}
		if (now - since >= quietMs && (count > 0 || now - began >= emptyMs)) return count;
		if (now - began > timeout) throw new Error("the board never settled");
	}
}

async function search(query) {
	await t.key("/");
	await t.type(query);
	await t.key("Escape");
}

async function clearSearch(length) {
	await t.key("/");
	await backspaces(length);
	await t.key("Escape");
}

let created;
let hasIssues = false;
const report = runner.report;

async function scenario() {
	await runner.step("board-loads", async (label) => {
		await t.openBlock();
		// Loaded = the loading screen is gone and something else (board, empty state, setup or error) shows.
		await waitFor(
			async () => {
				await t.wait(150);
				if (await exists(role("loading"))) return false;
				return (await exists(role("board"))) || (await exists(role("empty"))) || (await exists(role("setup"))) || (await exists(role("error")));
			},
			{ what: "the board to load", timeout: 45_000, interval: 0 },
		);
		if (await exists(role("setup"))) throw new Error("the plugin shows the setup screen; the API key was not picked up");
		if (await exists(role("error"))) throw new Error(`error banner: ${(await t.text(role("error"))).slice(0, 300)}`);
		await runner.shot(label);
	});

	// "My issues / Active" can be legitimately empty, so look at everything in the first team. Switching scope
	// reloads from the network and the empty state shows meanwhile, so wait until the card count stops changing.
	await runner.step("team-scope-all-view", async (label) => {
		await t.key("t");
		await cardCountSettled();
		await t.key("3");
		const count = await cardCountSettled();
		hasIssues = count > 0;
		if (hasIssues) {
			const cards = await t.text(role("card"));
			if (!IDENTIFIER.test(cards)) throw new Error(`cards show no issue identifier: ${cards.slice(0, 200)}`);
			console.log(`note: ${count} cards in the first team's All view`);
		} else {
			console.log("note: the workspace has no issues in the first team's All view; table and drawer steps are skipped");
			report.skipped = "no issues in the first team";
		}
		await runner.shot(label);
	});

	if (hasIssues) {
		await runner.step("table-view", async (label) => {
			await t.key("v");
			await present(role("table"));
			await waitFor(async () => (await t.wait(150), IDENTIFIER.test(await t.text(role("table")))), {
				what: "issue identifiers in the table",
				interval: 0,
			});
			await runner.shot(label);
			await t.key("v");
			await present(role("board"));
		});

		await runner.step("detail-drawer", async (label) => {
			await t.click(role("card"));
			await present(role("drawer"));
			await t.waitFor(role("drawer"), "Comments");
			await runner.shot(label);
			await closeDrawer();
		});
	}

	if (!write) return;

	await runner.step("create-issue", async (label) => {
		const title = `[tern-linear smoke] ${new Date().toISOString()}`;
		created = { title };
		await t.key("n");
		await present(role("dialog"));
		await t.type(title);
		await t.key("Ctrl+Enter");
		await absent(role("dialog"));
		await t.waitFor(role("notice"), "Created", { timeout: 30_000 });
		const notice = await t.text(role("notice"));
		created.identifier = IDENTIFIER.exec(notice)?.[0] ?? "(identifier not shown)";
		await runner.shot(label);
	});

	await runner.step("comment-and-complete", async (label) => {
		const { title } = created;
		const needle = title.slice("[tern-linear smoke] ".length);
		await search(needle);
		await t.waitFor(role("card"), needle, { timeout: 30_000 });
		await t.click(role("card"));
		await present(role("drawer"));
		await t.key("c");
		await t.type("Posted by the tern-linear live smoke test.");
		await t.key("Ctrl+Enter");
		await t.waitFor(role("drawer"), "Posted by the tern-linear live smoke test.");
		await t.key("x");
		await present(role("reopen"));
		await runner.shot(label);
		await closeDrawer();
		await clearSearch(needle.length);
	});
}

let failure;
try {
	await scenario();
} catch (error) {
	failure = error;
}
runner.finish(failure === undefined, created ? { createdIssue: created.identifier ?? created.title } : {});
await t.stop();
rmSync(ternOut, { recursive: true, force: true });

if (failure) {
	console.error(`\nlive smoke FAILED: ${failure instanceof Error ? failure.message : failure}`);
} else {
	console.log("\nlive smoke passed");
	if (created) console.log(`created and completed: ${created.identifier} (${created.title})`);
}
console.log(`artifacts: ${artifacts}`);
process.exit(failure ? 1 : 0);
