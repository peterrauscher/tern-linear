// Deterministic seed for the mock Linear server (test/mock-linear.mjs).
//
// Everything is laid out relative to a fixed point in time (`ago(minutes)`), then shifted onto the real clock when the
// seed is created, so relative times in screenshots ("20m", "2d") look natural while ordering stays stable.
//
// Timestamps are stored as epoch milliseconds; the mock serialises them to ISO strings.

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;

const KIND = { user: 1, team: 2, state: 3, label: 4, issue: 5, comment: 6, relation: 7, project: 8, cycle: 9, org: 10 };

/** Stable UUID-shaped ids: the first group names the entity kind, the last one its ordinal. */
export function uuid(kind, ordinal) {
	return `${KIND[kind].toString(16).padStart(8, "0")}-0000-4000-8000-${ordinal.toString(16).padStart(12, "0")}`;
}

export const TEST_API_KEY = "lin_api_test_0123456789abcdef";

const USERS = [
	{ handle: "ada", name: "Ada Lovelace", displayName: "ada", email: "ada@acme.test" },
	{ handle: "grace", name: "Grace Hopper", displayName: "grace", email: "grace@acme.test" },
	{ handle: "linus", name: "Linus Torvalds", displayName: "linus", email: "linus@acme.test" },
	{ handle: "dieter", name: "Dieter Rams", displayName: "dieter", email: "dieter@acme.test" },
];

const STATE_COLORS = {
	Backlog: "#bec2c8",
	Todo: "#e2e2e2",
	"In Progress": "#f2c94c",
	"In Review": "#0f783c",
	Done: "#5e6ad2",
	Canceled: "#95a2b3",
	Duplicate: "#95a2b3",
};

const TEAMS = [
	{
		key: "ENG",
		name: "Engineering",
		color: "#5e6ad2",
		icon: "Code",
		cyclesEnabled: true,
		estimation: "fibonacci",
		defaultState: "Todo",
		states: [
			["Backlog", "backlog"],
			["Todo", "unstarted"],
			["In Progress", "started"],
			["In Review", "started"],
			["Done", "completed"],
			["Canceled", "canceled"],
			["Duplicate", "duplicate"],
		],
		labels: [
			["Bug", "#eb5757"],
			["Feature", "#bb87fc"],
			["Improvement", "#4ea7fc"],
			["Docs", "#26b5ce"],
		],
		members: ["ada", "grace", "linus"],
		nextNumber: 151,
	},
	{
		key: "DES",
		name: "Design",
		color: "#f2994a",
		icon: "Pencil",
		cyclesEnabled: false,
		estimation: "notUsed",
		defaultState: "Backlog",
		states: [
			["Backlog", "backlog"],
			["Todo", "unstarted"],
			["In Progress", "started"],
			["Done", "completed"],
			["Canceled", "canceled"],
		],
		labels: [
			["UI", "#f2994a"],
			["Research", "#5e6ad2"],
		],
		members: ["ada", "dieter"],
		nextNumber: 16,
	},
];

const PROJECTS = [{ name: "Desktop app" }];

const ISSUES = [
	{
		team: "ENG",
		number: 142,
		title: "Crash when opening large workspace",
		description: [
			"## What happens",
			"",
			"Opening a workspace with more than **5,000 files** crashes the app during indexing.",
			"",
			"## Steps to reproduce",
			"",
			"1. Clone the `monorepo-large` fixture",
			"2. Open it from the launcher",
			"3. Wait for the indexer to pass 90%",
			"",
			"```",
			"thread 'indexer' panicked at 'index out of bounds: the len is 4096 but the index is 4096'",
			"```",
			"",
			"> Seems related to the chunk size change in the storage layer.",
		].join("\n"),
		priority: 1,
		state: "In Progress",
		assignee: "ada",
		creator: "grace",
		labels: ["Bug"],
		estimate: 5,
		project: 0,
		cycle: true,
		created: 3 * DAY,
		updated: 20 * MINUTE,
	},
	{
		team: "ENG",
		number: 131,
		title: "Revamp board interactions",
		description: "Umbrella for the interaction work on the issue board: **key bindings**, drag and drop, and selection.",
		priority: 3,
		state: "In Progress",
		assignee: "grace",
		creator: "grace",
		labels: ["Feature"],
		estimate: 8,
		project: 0,
		cycle: true,
		created: 12 * DAY,
		updated: 26 * 60 * MINUTE,
	},
	{
		team: "ENG",
		number: 138,
		title: "Add keyboard shortcuts to board",
		description: [
			"Power users want to move through the board without touching the mouse.",
			"",
			"- `j` / `k` move the selection",
			"- `Enter` opens the detail drawer",
			"- `[` and `]` move the issue between columns",
			"",
			"See the [shortcut sheet](https://example.com/shortcuts) for the full list.",
		].join("\n"),
		priority: 2,
		state: "In Review",
		assignee: "ada",
		creator: "grace",
		labels: ["Feature", "Improvement"],
		estimate: 3,
		parent: 131,
		project: 0,
		cycle: true,
		created: 9 * DAY,
		updated: 45 * MINUTE,
	},
	{
		team: "ENG",
		number: 139,
		title: "Drag cards between board columns",
		description: "Moving a card to another column should change its status. Optimistic UI is not required.",
		priority: 2,
		state: "Todo",
		creator: "linus",
		labels: ["Feature"],
		estimate: 8,
		parent: 131,
		project: 0,
		created: 9 * DAY,
		updated: 10 * 60 * MINUTE,
	},
	{
		team: "ENG",
		number: 145,
		title: "Fix flaky sync test on CI",
		description: "`sync_roundtrip` fails roughly one run in twenty with a timeout. Likely a race in the test harness.",
		priority: 4,
		state: "Todo",
		assignee: "ada",
		creator: "linus",
		labels: ["Bug"],
		estimate: 2,
		cycle: true,
		created: 6 * DAY,
		updated: 5 * 60 * MINUTE,
	},
	{
		team: "ENG",
		number: 146,
		title: "Ship v2 export format",
		description: "Export documents in the new format.\n\nBlocked until the storage migration lands.",
		priority: 3,
		state: "Todo",
		assignee: "ada",
		creator: "grace",
		labels: ["Feature"],
		estimate: 5,
		project: 0,
		created: 5 * DAY,
		updated: 130 * MINUTE,
	},
	{
		team: "ENG",
		number: 140,
		title: "Migrate storage layer to SQLite",
		description: "Replace the JSON file store with SQLite.\n\n### Plan\n\n1. Schema\n2. Migrations\n3. Switch reads\n4. Switch writes",
		priority: 2,
		state: "In Progress",
		assignee: "linus",
		creator: "linus",
		labels: ["Improvement"],
		estimate: 13,
		project: 0,
		cycle: true,
		created: 14 * DAY,
		updated: 70 * MINUTE,
	},
	{
		team: "ENG",
		number: 133,
		title: "Define webhook retry policy",
		description: "Retries use exponential backoff with jitter, capped at one hour.",
		priority: 3,
		state: "Done",
		assignee: "grace",
		creator: "grace",
		labels: ["Docs"],
		created: 10 * DAY,
		updated: 2 * DAY,
		completed: 2 * DAY,
	},
	{
		team: "ENG",
		number: 147,
		title: "Document webhook retry policy",
		description: "Write the public docs for the retry behaviour decided in ENG-133.",
		priority: 4,
		state: "Backlog",
		assignee: "ada",
		creator: "grace",
		labels: ["Docs"],
		created: 4 * DAY,
		updated: 50 * 60 * MINUTE,
	},
	{
		team: "ENG",
		number: 137,
		title: "Upgrade build tooling to Node 22",
		description: "Bump the toolchain and fix the fallout in CI.",
		priority: 3,
		state: "Done",
		assignee: "ada",
		creator: "ada",
		labels: ["Improvement"],
		estimate: 2,
		created: 11 * DAY,
		updated: 5 * DAY,
		completed: 5 * DAY,
	},
	{
		team: "ENG",
		number: 129,
		title: "Support legacy import format",
		description: "Decided not to pursue: fewer than 1% of users still have the old format.",
		priority: 0,
		state: "Canceled",
		assignee: "linus",
		creator: "grace",
		created: 20 * DAY,
		updated: 6 * DAY,
		canceled: 6 * DAY,
	},
	{
		team: "ENG",
		number: 98,
		title: "Set up error reporting",
		description: "Wire the crash reporter into release builds.",
		priority: 2,
		state: "Done",
		assignee: "grace",
		creator: "grace",
		labels: ["Improvement"],
		created: 60 * DAY,
		updated: 40 * DAY,
		completed: 40 * DAY,
	},
	{
		team: "ENG",
		number: 150,
		title: "Evaluate Tauri for the desktop shell",
		description: "Spike: measure start-up time and memory against the current shell.",
		priority: 0,
		state: "Backlog",
		creator: "linus",
		labels: ["Improvement"],
		created: 2 * DAY,
		updated: 4 * 24 * 60 * MINUTE,
	},
	{
		team: "DES",
		number: 12,
		title: "Redesign empty states",
		description: "Every list needs a friendly empty state with a clear next step.\n\n- [x] Inbox\n- [ ] Projects\n- [ ] Search results",
		priority: 3,
		state: "In Progress",
		assignee: "ada",
		creator: "dieter",
		labels: ["UI"],
		created: 8 * DAY,
		updated: 90 * MINUTE,
	},
	{
		team: "DES",
		number: 15,
		title: "Audit icon set for consistency",
		description: "Stroke widths and corner radii differ across the set. Produce a list of offenders.",
		priority: 4,
		state: "Todo",
		assignee: "ada",
		creator: "dieter",
		labels: ["UI", "Research"],
		created: 3 * DAY,
		updated: 400 * MINUTE,
	},
	{
		team: "DES",
		number: 9,
		title: "Explore dark theme palette",
		description: "Try three candidate palettes and compare contrast ratios.",
		priority: 0,
		state: "Backlog",
		assignee: "ada",
		creator: "ada",
		labels: ["Research"],
		created: 16 * DAY,
		updated: 5000 * MINUTE,
	},
	{
		team: "DES",
		number: 11,
		title: "Refresh onboarding illustrations",
		description: "New illustrations for the three onboarding steps.",
		priority: 3,
		state: "Done",
		assignee: "dieter",
		creator: "dieter",
		labels: ["UI"],
		created: 13 * DAY,
		updated: 3 * DAY,
		completed: 3 * DAY,
	},
];

// `issue` blocks `related`: ENG-140 is still open, ENG-133 is done.
const RELATIONS = [
	{ type: "blocks", issue: "ENG-140", related: "ENG-146" },
	{ type: "blocks", issue: "ENG-133", related: "ENG-147" },
	{ type: "related", issue: "ENG-142", related: "ENG-145" },
];

// [issue, author, age in ms, body, parent index within COMMENTS or null]
const COMMENTS = [
	[
		"ENG-142",
		"grace",
		2 * DAY,
		"I can reproduce this on the `monorepo-large` fixture. It always dies at the same file.",
		null,
	],
	[
		"ENG-142",
		"ada",
		2 * DAY - 90 * MINUTE,
		"Found it: the indexer allocates fixed 4096-entry chunks. I'll make them grow.",
		null,
	],
	["ENG-142", "linus", 2 * DAY - 120 * MINUTE, "Careful, the storage layer assumes that size. Let's talk before merging.", 0],
	["ENG-142", "ada", 3 * 60 * MINUTE, "Fix is up for review. Adds a regression test with 10,000 files.", null],
	["ENG-138", "grace", 5 * DAY, "Can we also support arrow keys for people who don't use vim bindings?", null],
	["ENG-138", "ada", 5 * DAY - 40 * MINUTE, "Yes, they map to the same actions. Added to the checklist.", null],
	["ENG-138", "grace", 3 * 60 * MINUTE, "Looks great. One nit on the `Escape` behaviour inside the search field.", null],
];

function build(now) {
	const ago = (ms) => now - ms;
	const users = USERS.map((u, i) => ({ id: uuid("user", i + 1), avatarUrl: null, active: true, ...u }));
	const userByHandle = new Map(users.map((u) => [u.handle, u]));
	const organization = { id: uuid("org", 1), name: "Acme", urlKey: "acme" };
	const projects = PROJECTS.map((p, i) => ({ id: uuid("project", i + 1), name: p.name }));

	let stateOrdinal = 0;
	let labelOrdinal = 0;
	const teams = TEAMS.map((t, i) => {
		const id = uuid("team", i + 1);
		const states = t.states.map(([name, type], position) => ({
			id: uuid("state", ++stateOrdinal),
			name,
			type,
			color: STATE_COLORS[name] ?? "#95a2b3",
			position,
		}));
		const labels = t.labels.map(([name, color]) => ({ id: uuid("label", ++labelOrdinal), name, color, isGroup: false }));
		const cycle = t.cyclesEnabled
			? {
					id: uuid("cycle", i + 1),
					number: 12,
					name: null,
					startsAt: ago(3 * DAY),
					endsAt: now + 11 * DAY,
				}
			: null;
		return {
			id,
			key: t.key,
			name: t.name,
			color: t.color,
			icon: t.icon,
			cyclesEnabled: t.cyclesEnabled,
			triageEnabled: false,
			issueEstimationType: t.estimation,
			issueEstimationAllowZero: false,
			issueEstimationExtended: false,
			defaultIssueEstimate: 0,
			defaultStateId: states.find((s) => s.name === t.defaultState).id,
			activeCycle: cycle,
			states,
			labels,
			memberIds: t.members.map((handle) => userByHandle.get(handle).id),
			nextNumber: t.nextNumber,
		};
	});
	const teamByKey = new Map(teams.map((t) => [t.key, t]));

	const issues = ISSUES.map((spec, i) => {
		const team = teamByKey.get(spec.team);
		const state = team.states.find((s) => s.name === spec.state);
		return {
			id: uuid("issue", i + 1),
			teamId: team.id,
			number: spec.number,
			title: spec.title,
			description: spec.description,
			priority: spec.priority,
			estimate: spec.estimate ?? null,
			stateId: state.id,
			assigneeId: spec.assignee ? userByHandle.get(spec.assignee).id : null,
			creatorId: userByHandle.get(spec.creator).id,
			labelIds: (spec.labels ?? []).map((name) => team.labels.find((l) => l.name === name).id),
			parentNumber: spec.parent ?? null,
			projectId: spec.project === undefined ? null : projects[spec.project].id,
			cycleId: spec.cycle ? team.activeCycle.id : null,
			dueDate: null,
			sortOrder: -spec.number * 100,
			createdAt: ago(spec.created),
			updatedAt: ago(spec.updated),
			completedAt: spec.completed === undefined ? null : ago(spec.completed),
			canceledAt: spec.canceled === undefined ? null : ago(spec.canceled),
			archivedAt: null,
		};
	});
	const issueByIdentifier = (identifier) => {
		const [key, number] = identifier.split("-");
		const team = teamByKey.get(key);
		return issues.find((issue) => issue.teamId === team.id && issue.number === Number(number));
	};
	for (const issue of issues) {
		if (issue.parentNumber === null) {
			issue.parentId = null;
			continue;
		}
		const team = teams.find((t) => t.id === issue.teamId);
		issue.parentId = issueByIdentifier(`${team.key}-${issue.parentNumber}`).id;
	}
	for (const issue of issues) delete issue.parentNumber;

	const relations = RELATIONS.map((r, i) => ({
		id: uuid("relation", i + 1),
		type: r.type,
		issueId: issueByIdentifier(r.issue).id,
		relatedIssueId: issueByIdentifier(r.related).id,
	}));

	const comments = COMMENTS.map(([identifier, author, age, body, parentIndex], i) => ({
		id: uuid("comment", i + 1),
		issueId: issueByIdentifier(identifier).id,
		userId: userByHandle.get(author).id,
		body,
		createdAt: ago(age),
		updatedAt: ago(age),
		parentId: parentIndex === null ? null : uuid("comment", parentIndex + 1),
	}));

	return {
		viewerId: users[0].id,
		organization,
		users,
		projects,
		teams,
		issues,
		relations,
		comments,
		sequence: { issue: issues.length, comment: comments.length, relation: relations.length },
	};
}

/** A fresh, independent copy of the seed, anchored to `now` (epoch ms). */
export function createSeed(now = Date.now()) {
	return build(now);
}
