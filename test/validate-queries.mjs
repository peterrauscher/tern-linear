// Validates every GraphQL document in lib/queries.luau against Linear's public SDL.
//   bun test/validate-queries.mjs [path/to/queries.luau]
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { buildSchema, Kind, parse, validate } from "graphql";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const queriesPath = resolve(process.argv[2] ?? join(root, "lib/queries.luau"));
const schemaPath = join(root, ".cache/linear-schema.graphql");
const EXPECTED = [
	"Viewer",
	"Teams",
	"TeamMore",
	"Issues",
	"Issue",
	"IssueCreate",
	"IssueUpdate",
	"CommentCreate",
	"IssueRelationCreate",
	"IssueRelationDelete",
	"IssueLookup",
	"IssuesChanged",
];

/** Extracts `queries.<Name> = [==[ ... ]==]` long strings from Luau source. */
export function extractQueries(source) {
	const found = [];
	const pattern = /queries\.(\w+)\s*=\s*\[(=*)\[([\s\S]*?)\]\2\]/g;
	for (const match of source.matchAll(pattern)) found.push({ key: match[1], text: match[3] });
	return found;
}

function ensureSchema() {
	if (existsSync(schemaPath)) return;
	const fetched = spawnSync("sh", [join(root, "scripts/fetch-tools.sh")], { stdio: "inherit" });
	if (fetched.status !== 0 || !existsSync(schemaPath)) {
		console.error("cannot obtain .cache/linear-schema.graphql");
		process.exit(1);
	}
}

function main() {
	if (!existsSync(queriesPath)) {
		console.error(`missing ${queriesPath}`);
		process.exit(1);
	}
	ensureSchema();
	const schema = buildSchema(readFileSync(schemaPath, "utf8"));
	const queries = extractQueries(readFileSync(queriesPath, "utf8"));
	let errors = 0;
	const fail = (message) => {
		errors += 1;
		console.log(`FAIL ${message}`);
	};

	for (const { key, text } of queries) {
		let document;
		try {
			document = parse(text);
		} catch (error) {
			fail(`${key}: ${error.message}`);
			continue;
		}
		const operations = document.definitions.filter((d) => d.kind === Kind.OPERATION_DEFINITION);
		if (operations.length !== 1 || document.definitions.length !== 1) {
			fail(`${key}: a document must hold exactly one operation`);
			continue;
		}
		const name = operations[0].name?.value;
		if (name !== key) {
			fail(`${key}: operation is named "${name}", expected "${key}"`);
			continue;
		}
		const problems = validate(schema, document);
		if (problems.length === 0) {
			console.log(`ok ${key}`);
			continue;
		}
		for (const problem of problems) fail(`${key}: ${problem.message}`);
	}

	const keys = queries.map((q) => q.key);
	for (const name of EXPECTED) if (!keys.includes(name)) fail(`missing operation ${name}`);
	for (const key of new Set(keys.filter((k, i) => keys.indexOf(k) !== i))) fail(`duplicate operation ${key}`);
	if (queries.length < EXPECTED.length) fail(`found ${queries.length} operations, expected at least ${EXPECTED.length}`);

	console.log(`\n${queries.length} operations, ${errors} errors`);
	process.exit(errors === 0 ? 0 : 1);
}

if (import.meta.main) main();
