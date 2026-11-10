// A stateful fake of the Linear GraphQL API for the twelve operations in lib/queries.luau.
//
// Requests are executed by graphql-js against Linear's real SDL (.cache/linear-schema.graphql), so variable coercion,
// validation errors and the shape of every response follow the documents the plugin sends. Resolvers read and mutate an
// in-memory copy of test/fixtures/linear-data.mjs.
//
//   bun test/mock-linear.mjs [--port N]     serve until interrupted, print the endpoint URL
//   import { startMock } from "./mock-linear.mjs"
//
// Extra endpoints: GET /__log (received operations), GET /__state (current data), POST /__reset.
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { buildSchema, GraphQLError, graphql } from "graphql";
import { createSeed, TEST_API_KEY, uuid } from "./fixtures/linear-data.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SCHEMA_PATH = join(root, ".cache/linear-schema.graphql");
const MINUTE = 60_000;
const PRIORITY_LABELS = ["No priority", "Urgent", "High", "Medium", "Low"];

// ─── errors (shapes captured from the live API) ─────────────────────────────

const AUTH_ERROR_BODY = {
	errors: [
		{
			message: "Authentication required, not authenticated",
			extensions: {
				code: "AUTHENTICATION_ERROR",
				statusCode: 401,
				userError: true,
				userPresentableMessage: "You need to authenticate to access this operation.",
			},
		},
	],
};

function notFound(entity) {
	return new GraphQLError(`Entity not found: ${entity}`, {
		extensions: {
			code: "INPUT_ERROR",
			type: "invalid input",
			userError: true,
			userPresentableMessage: `Could not find referenced ${entity}.`,
		},
	});
}

function invalidInput(message) {
	return new GraphQLError("Argument Validation Error", {
		extensions: { code: "INVALID_INPUT", type: "invalid input", userError: true, userPresentableMessage: message },
	});
}

// ─── filters ────────────────────────────────────────────────────────────────

const DURATION = /^([-+])?P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/;

/** DateTimeOrDuration → epoch ms: ISO durations are relative to `now`, anything else is parsed as a date. */
function resolveDate(value, now) {
	const duration = DURATION.exec(value);
	if (duration) {
		const [, sign, y, mo, w, d, h, mi, s] = duration.map((part, i) => (i === 0 || i === 1 ? part : Number(part ?? 0)));
		const days = y * 365 + mo * 30 + w * 7 + d;
		const span = ((days * 24 + h) * 60 + mi) * 60_000 + s * 1000;
		return sign === "-" ? now - span : now + span;
	}
	const parsed = Date.parse(value);
	if (Number.isNaN(parsed)) throw invalidInput(`Invalid date: ${value}`);
	return parsed;
}

/** Applies one comparator object (`{eq, in, gt, null, containsIgnoreCase, ...}`) to a scalar. */
function compare(actual, condition, coerce = (v) => v) {
	for (const [op, raw] of Object.entries(condition)) {
		if (op === "null") {
			if ((actual === null || actual === undefined) !== raw) return false;
			continue;
		}
		const missing = actual === null || actual === undefined;
		const expected = Array.isArray(raw) ? raw.map(coerce) : coerce(raw);
		const text = missing ? "" : String(actual);
		const textExpected = String(expected).toLowerCase();
		switch (op) {
			case "eq":
				if (missing || actual !== expected) return false;
				break;
			case "neq":
				if (!missing && actual === expected) return false;
				break;
			case "in":
				if (missing || !expected.includes(actual)) return false;
				break;
			case "nin":
				if (!missing && expected.includes(actual)) return false;
				break;
			case "lt":
				if (missing || !(actual < expected)) return false;
				break;
			case "lte":
				if (missing || !(actual <= expected)) return false;
				break;
			case "gt":
				if (missing || !(actual > expected)) return false;
				break;
			case "gte":
				if (missing || !(actual >= expected)) return false;
				break;
			case "contains":
				if (!text.includes(String(expected))) return false;
				break;
			case "notContains":
				if (text.includes(String(expected))) return false;
				break;
			case "containsIgnoreCase":
				if (!text.toLowerCase().includes(textExpected)) return false;
				break;
			case "notContainsIgnoreCase":
				if (text.toLowerCase().includes(textExpected)) return false;
				break;
			case "startsWith":
				if (!text.startsWith(String(expected))) return false;
				break;
			case "endsWith":
				if (!text.endsWith(String(expected))) return false;
				break;
			case "eqIgnoreCase":
				if (text.toLowerCase() !== textExpected) return false;
				break;
			case "neqIgnoreCase":
				if (text.toLowerCase() === textExpected) return false;
				break;
			default:
				throw invalidInput(`Unsupported comparator: ${op}`);
		}
	}
	return true;
}

/** Evaluates `IssueFilter` JSON against one issue record. */
class IssueMatcher {
	constructor(db, now) {
		this.db = db;
		this.now = now;
	}

	match(issue, filter) {
		for (const [key, condition] of Object.entries(filter ?? {})) {
			if (!this.matchKey(issue, key, condition)) return false;
		}
		return true;
	}

	matchKey(issue, key, condition) {
		const db = this.db;
		const date = (value) => resolveDate(value, this.now);
		switch (key) {
			case "and":
				return condition.every((sub) => this.match(issue, sub));
			case "or":
				return condition.length === 0 || condition.some((sub) => this.match(issue, sub));
			case "id":
				return compare(issue.id, condition);
			case "number":
				return compare(issue.number, condition);
			case "title":
				return compare(issue.title, condition);
			case "description":
				return compare(issue.description, condition);
			case "priority":
				return compare(issue.priority, condition);
			case "estimate":
				return compare(issue.estimate, condition);
			case "dueDate":
				return compare(issue.dueDate, condition);
			case "createdAt":
			case "updatedAt":
			case "completedAt":
			case "canceledAt":
			case "archivedAt":
				return compare(issue[key], condition, date);
			case "assignee":
				return this.matchRelated(db.user(issue.assigneeId), condition, (user, sub) => this.matchUser(user, sub));
			case "creator":
				return this.matchRelated(db.user(issue.creatorId), condition, (user, sub) => this.matchUser(user, sub));
			case "team":
				return this.matchRelated(db.team(issue.teamId), condition, (team, sub) => this.matchTeam(team, sub));
			case "state":
				return this.matchRelated(db.state(issue.stateId), condition, (state, sub) => this.matchState(state, sub));
			case "parent":
				return this.matchRelated(db.issue(issue.parentId), condition, (parent, sub) => this.match(parent, sub));
			case "project":
				return this.matchRelated(db.project(issue.projectId), condition, (project, sub) =>
					this.matchEntries(sub, { id: project.id, name: project.name }),
				);
			case "labels":
				return this.matchLabels(issue, condition);
			case "hasBlockedByRelations":
				return (
					db.state_.relations.some((r) => r.type === "blocks" && r.relatedIssueId === issue.id) === condition.eq
				);
			case "hasBlockingRelations":
				return db.state_.relations.some((r) => r.type === "blocks" && r.issueId === issue.id) === condition.eq;
			default:
				throw invalidInput(`The mock does not support IssueFilter.${key}`);
		}
	}

	/** `{null: bool}` plus nested filters for an optional related entity. */
	matchRelated(entity, condition, matchEntity) {
		const { null: isNull, ...rest } = condition;
		if (isNull !== undefined && (entity === null) !== isNull) return false;
		if (Object.keys(rest).length === 0) return true;
		return entity !== null && matchEntity(entity, rest);
	}

	matchEntries(condition, fields) {
		return Object.entries(condition).every(([key, sub]) => {
			if (!(key in fields)) throw invalidInput(`The mock does not support filtering on ${key}`);
			return compare(fields[key], sub);
		});
	}

	matchUser(user, condition) {
		const { isMe, ...rest } = condition;
		if (isMe !== undefined && (user.id === this.db.state_.viewerId) !== (isMe.eq ?? true)) return false;
		return this.matchEntries(rest, { id: user.id, name: user.name, displayName: user.displayName, email: user.email });
	}

	matchTeam(team, condition) {
		return this.matchEntries(condition, { id: team.id, key: team.key, name: team.name });
	}

	matchState(state, condition) {
		return this.matchEntries(condition, { id: state.id, name: state.name, type: state.type, position: state.position });
	}

	matchLabels(issue, condition) {
		const labels = issue.labelIds.map((id) => this.db.label(id));
		const matches = (label, sub) => this.matchEntries(sub, { id: label.id, name: label.name });
		if (condition.some && !labels.some((label) => matches(label, condition.some))) return false;
		if (condition.every && !labels.every((label) => matches(label, condition.every))) return false;
		if (condition.none && labels.some((label) => matches(label, condition.none))) return false;
		return true;
	}
}

// ─── data access and views ──────────────────────────────────────────────────

const IDENTIFIER = /^([A-Za-z][A-Za-z0-9]*)-(\d+)$/;

function slugify(title) {
	return title
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, "-")
		.replace(/^-+|-+$/g, "")
		.slice(0, 50)
		.replace(/-+$/, "");
}

function connection(items, { first, after } = {}) {
	const start = after ? Number(after) : 0;
	const nodes = items.slice(start, start + (first ?? 50));
	const end = start + nodes.length;
	return {
		nodes,
		edges: nodes.map((node, i) => ({ cursor: String(start + i + 1), node })),
		pageInfo: {
			hasNextPage: end < items.length,
			hasPreviousPage: start > 0,
			startCursor: nodes.length > 0 ? String(start + 1) : null,
			endCursor: nodes.length > 0 ? String(end) : null,
		},
	};
}

const iso = (ms) => (ms === null || ms === undefined ? null : new Date(ms).toISOString());

class Database {
	constructor(now) {
		this.state_ = createSeed(now);
		this.lastTick = now;
	}

	/** Monotonic clock so every mutation produces a strictly newer `updatedAt`. */
	tick() {
		this.lastTick = Math.max(Date.now(), this.lastTick + 1);
		return this.lastTick;
	}

	user(id) {
		return this.state_.users.find((u) => u.id === id) ?? null;
	}
	team(id) {
		return this.state_.teams.find((t) => t.id === id) ?? null;
	}
	state(id) {
		for (const team of this.state_.teams) {
			const state = team.states.find((s) => s.id === id);
			if (state) return state;
		}
		return null;
	}
	label(id) {
		for (const team of this.state_.teams) {
			const label = team.labels.find((l) => l.id === id);
			if (label) return label;
		}
		return null;
	}
	project(id) {
		return this.state_.projects.find((p) => p.id === id) ?? null;
	}
	issue(id) {
		return id ? (this.state_.issues.find((i) => i.id === id) ?? null) : null;
	}
	identifier(issue) {
		return `${this.team(issue.teamId).key}-${issue.number}`;
	}

	/** Resolves a UUID or an `ENG-12` identifier (case-insensitive). */
	findIssue(idOrIdentifier) {
		const byId = this.issue(idOrIdentifier);
		if (byId) return byId;
		const parts = IDENTIFIER.exec(idOrIdentifier ?? "");
		if (!parts) return null;
		const team = this.state_.teams.find((t) => t.key === parts[1].toUpperCase());
		if (!team) return null;
		return this.state_.issues.find((i) => i.teamId === team.id && i.number === Number(parts[2])) ?? null;
	}

	requireIssue(idOrIdentifier) {
		const issue = this.findIssue(idOrIdentifier);
		if (!issue) throw notFound("Issue");
		return issue;
	}

	// views: plain objects (functions take connection arguments) that graphql-js resolves lazily

	userView(user) {
		return user && { ...user };
	}

	stateView(state) {
		return state && { ...state };
	}

	cycleView(id) {
		const cycle = this.state_.teams.map((t) => t.activeCycle).find((c) => c?.id === id);
		return cycle ? { ...cycle, startsAt: iso(cycle.startsAt), endsAt: iso(cycle.endsAt) } : null;
	}

	teamView(team) {
		return {
			...team,
			defaultIssueState: { id: team.defaultStateId },
			activeCycle: team.activeCycle ? this.cycleView(team.activeCycle.id) : null,
			states: (args) => connection(team.states.map((s) => this.stateView(s)), args),
			labels: (args) => connection(team.labels.map((l) => ({ ...l })), args),
			members: (args) => connection(team.memberIds.map((id) => this.userView(this.user(id))), args),
		};
	}

	commentView(comment) {
		return {
			...comment,
			createdAt: iso(comment.createdAt),
			updatedAt: iso(comment.updatedAt),
			user: this.userView(this.user(comment.userId)),
		};
	}

	relationView(relation) {
		return {
			id: relation.id,
			type: relation.type,
			issue: this.issueView(this.issue(relation.issueId)),
			relatedIssue: this.issueView(this.issue(relation.relatedIssueId)),
		};
	}

	issueView(issue) {
		const team = this.team(issue.teamId);
		const identifier = this.identifier(issue);
		const slug = slugify(issue.title);
		const creator = this.user(issue.creatorId);
		const viewer = this.user(this.state_.viewerId);
		const relatedTo = (field) => this.state_.relations.filter((r) => r[field] === issue.id);
		return {
			...issue,
			identifier,
			priorityLabel: PRIORITY_LABELS[issue.priority] ?? "No priority",
			url: `https://linear.app/${this.state_.organization.urlKey}/issue/${identifier}/${slug}`,
			branchName: `${viewer.displayName}/${identifier.toLowerCase()}-${slug}`,
			createdAt: iso(issue.createdAt),
			updatedAt: iso(issue.updatedAt),
			completedAt: iso(issue.completedAt),
			canceledAt: iso(issue.canceledAt),
			archivedAt: iso(issue.archivedAt),
			state: this.stateView(this.state(issue.stateId)),
			team: this.teamView(team),
			creator: this.userView(creator),
			assignee: this.userView(this.user(issue.assigneeId)),
			labels: (args) => connection(issue.labelIds.map((id) => ({ ...this.label(id) })), args),
			project: this.project(issue.projectId),
			cycle: this.cycleView(issue.cycleId),
			parent: issue.parentId ? this.issueView(this.issue(issue.parentId)) : null,
			subscribers: (args) => connection([this.userView(viewer)], args),
			children: (args) =>
				connection(
					this.state_.issues.filter((i) => i.parentId === issue.id).map((i) => this.issueView(i)),
					args,
				),
			relations: (args) => connection(relatedTo("issueId").map((r) => this.relationView(r)), args),
			inverseRelations: (args) => connection(relatedTo("relatedIssueId").map((r) => this.relationView(r)), args),
			// Linear documents no direction for `comments`; newest first keeps clients honest about sorting.
			comments: (args) =>
				connection(
					this.state_.comments
						.filter((c) => c.issueId === issue.id)
						.sort((a, b) => b.createdAt - a.createdAt)
						.map((c) => this.commentView(c)),
					args,
				),
		};
	}
}

// ─── resolvers ──────────────────────────────────────────────────────────────

function buildRoot(db, now) {
	const matcher = new IssueMatcher(db, now());

	const settle = (issue) => {
		const state = db.state(issue.stateId);
		issue.completedAt = state.type === "completed" ? (issue.completedAt ?? db.tick()) : null;
		issue.canceledAt = state.type === "canceled" || state.type === "duplicate" ? (issue.canceledAt ?? db.tick()) : null;
	};

	const requireTeam = (id) => {
		const team = db.state_.teams.find((t) => t.id === id || t.key === id);
		if (!team) throw notFound("Team");
		return team;
	};

	const resolveRef = (ref, entity) => {
		if (ref === null || ref === undefined) return null;
		const issue = db.findIssue(ref);
		if (!issue) throw notFound(entity);
		return issue.id;
	};

	return {
		viewer: () => ({
			...db.userView(db.user(db.state_.viewerId)),
			organization: { ...db.state_.organization },
		}),

		teams: (args) => connection(db.state_.teams.map((t) => db.teamView(t)), args),

		team: ({ id }) => db.teamView(requireTeam(id)),

		issues: ({ filter, first, after, orderBy, includeArchived }) => {
			matcher.now = now();
			const key = orderBy === "updatedAt" ? "updatedAt" : "createdAt";
			const matching = db.state_.issues
				.filter((issue) => includeArchived || issue.archivedAt === null)
				.filter((issue) => matcher.match(issue, filter))
				.sort((a, b) => b[key] - a[key] || b.number - a.number);
			return connection(
				matching.map((issue) => db.issueView(issue)),
				{ first, after },
			);
		},

		issue: ({ id }) => db.issueView(db.requireIssue(id)),

		issueCreate: ({ input }) => {
			const team = requireTeam(input.teamId);
			if (!input.title || input.title.trim() === "") throw invalidInput("title must be longer than or equal to 1 characters");
			const state = db.state(input.stateId ?? team.defaultStateId);
			if (!state || !team.states.includes(state)) throw notFound("WorkflowState");
			const assignee = input.assigneeId ? db.user(input.assigneeId) : null;
			if (input.assigneeId && !assignee) throw notFound("User");
			const now_ = db.tick();
			const issue = {
				id: uuid("issue", ++db.state_.sequence.issue),
				teamId: team.id,
				number: team.nextNumber++,
				title: input.title,
				description: input.description ?? null,
				priority: input.priority ?? 0,
				estimate: input.estimate ?? null,
				stateId: state.id,
				assigneeId: assignee?.id ?? null,
				creatorId: db.state_.viewerId,
				labelIds: input.labelIds ?? [],
				parentId: resolveRef(input.parentId, "Issue"),
				projectId: input.projectId ?? null,
				cycleId: input.cycleId ?? null,
				dueDate: input.dueDate ?? null,
				sortOrder: -now_,
				createdAt: now_,
				updatedAt: now_,
				completedAt: null,
				canceledAt: null,
				archivedAt: null,
			};
			settle(issue);
			db.state_.issues.push(issue);
			return { success: true, issue: db.issueView(issue) };
		},

		issueUpdate: ({ id, input }) => {
			const issue = db.requireIssue(id);
			const team = db.team(issue.teamId);
			const has = (key) => Object.hasOwn(input, key);
			if (has("title") && (input.title ?? "").trim() === "") throw invalidInput("title must be longer than or equal to 1 characters");
			if (has("stateId")) {
				const state = db.state(input.stateId);
				if (!state || !team.states.includes(state)) throw notFound("WorkflowState");
				if (state.id !== issue.stateId) {
					issue.stateId = state.id;
					issue.completedAt = null;
					issue.canceledAt = null;
					settle(issue);
				}
			}
			if (has("assigneeId")) {
				if (input.assigneeId !== null && !db.user(input.assigneeId)) throw notFound("User");
				issue.assigneeId = input.assigneeId;
			}
			for (const key of ["title", "description", "priority", "estimate", "dueDate", "projectId", "cycleId"]) {
				if (has(key)) issue[key] = input[key];
			}
			if (has("parentId")) issue.parentId = resolveRef(input.parentId, "Issue");
			if (has("labelIds")) issue.labelIds = [...input.labelIds];
			if (has("addedLabelIds")) {
				for (const labelId of input.addedLabelIds) if (!issue.labelIds.includes(labelId)) issue.labelIds.push(labelId);
			}
			if (has("removedLabelIds")) issue.labelIds = issue.labelIds.filter((l) => !input.removedLabelIds.includes(l));
			issue.updatedAt = db.tick();
			return { success: true, issue: db.issueView(issue) };
		},

		commentCreate: ({ input }) => {
			const issue = db.requireIssue(input.issueId);
			if (!input.body || input.body.trim() === "") throw invalidInput("body must be longer than or equal to 1 characters");
			const at = db.tick();
			const comment = {
				id: uuid("comment", ++db.state_.sequence.comment),
				issueId: issue.id,
				userId: db.state_.viewerId,
				body: input.body,
				createdAt: at,
				updatedAt: at,
				parentId: input.parentId ?? null,
			};
			db.state_.comments.push(comment);
			issue.updatedAt = at;
			return { success: true, comment: db.commentView(comment) };
		},

		issueRelationCreate: ({ input }) => {
			const issue = db.requireIssue(input.issueId);
			const related = db.requireIssue(input.relatedIssueId);
			const relation = {
				id: uuid("relation", ++db.state_.sequence.relation),
				type: input.type,
				issueId: issue.id,
				relatedIssueId: related.id,
			};
			db.state_.relations.push(relation);
			issue.updatedAt = related.updatedAt = db.tick();
			return { success: true, issueRelation: db.relationView(relation) };
		},

		issueRelationDelete: ({ id }) => {
			const index = db.state_.relations.findIndex((r) => r.id === id);
			if (index < 0) throw notFound("IssueRelation");
			const [relation] = db.state_.relations.splice(index, 1);
			const at = db.tick();
			for (const issueId of [relation.issueId, relation.relatedIssueId]) db.issue(issueId).updatedAt = at;
			return { success: true, entityId: id };
		},
	};
}

// ─── server ─────────────────────────────────────────────────────────────────

function loadSchema() {
	if (!existsSync(SCHEMA_PATH)) {
		const fetched = spawnSync("sh", [join(root, "scripts/fetch-tools.sh")], { stdio: "inherit" });
		if (fetched.status !== 0 || !existsSync(SCHEMA_PATH)) {
			throw new Error(`mock-linear: cannot obtain ${SCHEMA_PATH}; run scripts/fetch-tools.sh`);
		}
	}
	return buildSchema(readFileSync(SCHEMA_PATH, "utf8"));
}

/** Plain-JSON snapshot of the data the tests assert on. */
function snapshot(db) {
	const s = db.state_;
	return {
		viewerId: s.viewerId,
		users: s.users.map(({ id, name, displayName }) => ({ id, name, displayName })),
		teams: s.teams.map((t) => ({
			id: t.id,
			key: t.key,
			states: t.states.map(({ id, name, type }) => ({ id, name, type })),
		})),
		issues: s.issues.map((i) => ({
			id: i.id,
			identifier: db.identifier(i),
			title: i.title,
			description: i.description,
			priority: i.priority,
			state: db.state(i.stateId).name,
			stateId: i.stateId,
			stateType: db.state(i.stateId).type,
			assigneeId: i.assigneeId,
			updatedAt: iso(i.updatedAt),
			completedAt: iso(i.completedAt),
			canceledAt: iso(i.canceledAt),
		})),
		comments: s.comments.map((c) => ({
			id: c.id,
			issue: db.identifier(db.issue(c.issueId)),
			body: c.body,
			parentId: c.parentId,
			userId: c.userId,
		})),
		relations: s.relations.map((r) => ({
			id: r.id,
			type: r.type,
			issue: db.identifier(db.issue(r.issueId)),
			related: db.identifier(db.issue(r.relatedIssueId)),
		})),
	};
}

const json = (body, init = {}) =>
	new Response(JSON.stringify(body), { ...init, headers: { "content-type": "application/json", ...init.headers } });

/**
 * Starts the mock on 127.0.0.1. `port: 0` picks a free port.
 * Returns `{ url, port, log, state(), reset(), stop() }`; `url` is the GraphQL endpoint.
 */
export async function startMock({ port = 0, apiKey = TEST_API_KEY } = {}) {
	const schema = loadSchema();
	let db = new Database(Date.now());
	let root_ = buildRoot(db, Date.now);
	let log = [];
	let requestsRemaining = 2500;

	const reset = () => {
		db = new Database(Date.now());
		root_ = buildRoot(db, Date.now);
		log = [];
		requestsRemaining = 2500;
	};

	const rateHeaders = () => ({
		"x-ratelimit-requests-limit": "2500",
		"x-ratelimit-requests-remaining": String(requestsRemaining),
		"x-ratelimit-requests-reset": String(Date.now() + 60 * MINUTE),
		"x-ratelimit-complexity-limit": "3000000",
		"x-ratelimit-complexity-remaining": "2999000",
		"x-complexity": "10",
	});

	async function handleGraphql(request) {
		if (request.headers.get("authorization") !== apiKey) {
			log.push({ operationName: null, variables: null, status: 401 });
			return json(AUTH_ERROR_BODY, { status: 401 });
		}
		let body;
		try {
			body = await request.json();
		} catch {
			return json({ errors: [{ message: "Body must be JSON" }] }, { status: 400 });
		}
		const { query, variables, operationName } = body ?? {};
		log.push({ operationName: operationName ?? null, variables: variables ?? null, status: 200 });
		requestsRemaining = Math.max(0, requestsRemaining - 1);
		const result = await graphql({
			schema,
			source: query ?? "",
			rootValue: root_,
			variableValues: variables ?? undefined,
			operationName: operationName ?? undefined,
		});
		const status = result.data === undefined ? 400 : 200;
		return json(result, { status, headers: rateHeaders() });
	}

	const server = Bun.serve({
		port,
		hostname: "127.0.0.1",
		async fetch(request) {
			const { pathname } = new URL(request.url);
			if (pathname === "/graphql" && request.method === "POST") return handleGraphql(request);
			if (pathname === "/__log" && request.method === "GET") return json(log);
			if (pathname === "/__state" && request.method === "GET") return json(snapshot(db));
			if (pathname === "/__reset" && request.method === "POST") {
				reset();
				return json({ ok: true });
			}
			return json({ errors: [{ message: "Not found" }] }, { status: 404 });
		},
	});

	return {
		url: `http://127.0.0.1:${server.port}/graphql`,
		port: server.port,
		apiKey,
		get log() {
			return log;
		},
		state: () => snapshot(db),
		reset,
		stop: () => server.stop(true),
	};
}

if (import.meta.main) {
	const portFlag = process.argv.indexOf("--port");
	const mock = await startMock({ port: portFlag >= 0 ? Number(process.argv[portFlag + 1]) : 0 });
	console.log(`mock-linear: ${mock.url}`);
	console.log(`mock-linear: Authorization: ${mock.apiKey}`);
}
