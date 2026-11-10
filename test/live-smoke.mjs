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
const present = (selector, timeout) => waitFor(() => exists(selector), { what: `${selector} to appear`, timeout });
const absent = (selector) => waitFor(async () => !(await exists(selector)), { what: `${selector} to disappear` });
const backspaces = async (count) => {
	for (let i = 0; i < count; i += 1) await t.key("Backspace");
};

async function closeDrawer() {
	for (let attempt = 0; attempt < 4 && (await exists(role("drawer"))); attempt += 1) await t.key("Escape");
	await absent(role("drawer"));
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

async function scenario() {
	await runner.step("board-loads", async (label) => {
		await t.openBlock();
		await waitFor(async () => IDENTIFIER.test(await t.text(role("board"))) || (await exists(role("empty"))), {
			what: "the board to load",
			timeout: 45_000,
		});
		if (await exists(role("setup"))) throw new Error("the plugin shows the setup screen; the API key was not picked up");
		if (await exists(role("error"))) throw new Error(`error banner: ${(await t.text(role("error"))).slice(0, 300)}`);
		await runner.shot(label);
	});

	await runner.step("table-view", async (label) => {
		await t.key("3");
		await t.key("v");
		await present(role("table"));
		await waitFor(async () => IDENTIFIER.test(await t.text(role("table"))), { what: "issue identifiers in the table" });
		await runner.shot(label);
		await t.key("v");
		await present(role("board"));
	});

	await runner.step("detail-drawer", async (label) => {
		await t.click(role("card"));
		await present(role("drawer"));
		await t.expect("Comments");
		await runner.shot(label);
		await closeDrawer();
	});

	if (!write) return;

	await runner.step("create-issue", async (label) => {
		const title = `[tern-linear smoke] ${new Date().toISOString()}`;
		created = { title };
		await t.key("t");
		await t.key("3");
		await t.key("n");
		await present(role("dialog"));
		await t.type(title);
		await t.key("Ctrl+Enter");
		await absent(role("dialog"));
		const notice = await waitFor(
			async () => {
				const text = await t.text(role("notice"));
				return text.includes("Created") ? text : null;
			},
			{ what: "the Created notice", timeout: 30_000 },
		);
		created.identifier = IDENTIFIER.exec(notice)?.[0] ?? "(identifier not shown)";
		await runner.shot(label);
	});

	await runner.step("comment-and-complete", async (label) => {
		const { title } = created;
		const needle = title.slice("[tern-linear smoke] ".length);
		await search(needle);
		await waitFor(() => exists(role("card")), { what: "the created issue on the board", timeout: 30_000 });
		await t.click(role("card"));
		await present(role("drawer"));
		await t.key("c");
		await t.type("Posted by the tern-linear live smoke test.");
		await t.key("Ctrl+Enter");
		await t.expect("Posted by the tern-linear live smoke test.");
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
