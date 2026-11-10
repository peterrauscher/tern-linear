--!strict
-- Unit tests for lib/model.luau: filtering, ordering, columns, server filters, dates. Run with the `luau` CLI.

local model = require("../../lib/model")
local types = require("../../lib/types")

local failures = 0

local function check(name: string, condition: boolean)
	if condition then
		print("ok   " .. name)
	else
		failures += 1
		print("FAIL " .. name)
	end
end

local function ids(issues: { types.Issue }): string
	local out: { string } = {}
	for _, issue in issues do
		table.insert(out, issue.identifier)
	end
	return table.concat(out, " ")
end

local function state(id: string, name: string, stateType: string, position: number): types.WorkflowState
	return { id = id, name = name, type = stateType, color = "#888888", position = position }
end

local BACKLOG = state("s-backlog", "Backlog", "backlog", 0)
local TODO = state("s-todo", "Todo", "unstarted", 0)
local DOING = state("s-doing", "In Progress", "started", 0)
local REVIEW = state("s-review", "In Review", "started", 1)
local DONE = state("s-done", "Done", "completed", 0)
local CANCELED = state("s-canceled", "Canceled", "canceled", 0)
local DUPLICATE = state("s-dup", "Duplicate", "duplicate", 1)

local team: types.Team = {
	id = "t-eng",
	key = "ENG",
	name = "Engineering",
	color = nil,
	cyclesEnabled = false,
	triageEnabled = false,
	estimation = "notUsed",
	defaultStateId = nil,
	states = { BACKLOG, TODO, DOING, REVIEW, DONE, CANCELED, DUPLICATE },
	labels = {},
	members = {},
}

local function user(id: string, name: string): types.User
	return { id = id, name = name, displayName = name, avatarUrl = nil, active = true }
end

local ME = user("u-me", "Peter Pan")
local ANA = user("u-ana", "Ana")

type IssueOverrides = {
	number: number?,
	title: string?,
	state: types.WorkflowState?,
	priority: number?,
	sortOrder: number?,
	teamKey: string?,
	assignee: types.User?,
	labels: { types.Label }?,
	relations: { types.Relation }?,
	updatedAt: string?,
}

local function issue(id: string, overrides: IssueOverrides?): types.Issue
	local o: IssueOverrides = overrides or {}
	local teamKey = o.teamKey or "ENG"
	local number = o.number or 1
	return {
		id = id,
		identifier = `{teamKey}-{number}`,
		number = number,
		title = o.title or "Untitled",
		description = nil,
		priority = o.priority or 0,
		priorityLabel = "",
		estimate = nil,
		url = "https://linear.app/x",
		branchName = "branch",
		createdAt = "2025-01-01T00:00:00.000Z",
		updatedAt = o.updatedAt or "2025-01-01T00:00:00.000Z",
		completedAt = nil,
		canceledAt = nil,
		archivedAt = nil,
		dueDate = nil,
		sortOrder = o.sortOrder or 0,
		state = o.state or TODO,
		teamId = "t-" .. string.lower(teamKey),
		teamKey = teamKey,
		assignee = o.assignee,
		creator = nil,
		labels = o.labels or {},
		project = nil,
		cycle = nil,
		parent = nil,
		children = {},
		relations = o.relations or {},
		comments = nil,
		detailed = false,
	}
end

local function prefs(overrides: { [string]: any }?): types.Prefs
	local p: { [string]: any } = {
		scope = "team",
		teamId = "t-eng",
		view = "active",
		layout = "board",
		sort = "identifier",
		sortAsc = true,
	}
	for key, value in overrides or {} do
		p[key] = value
	end
	return p :: any
end

local function ref(id: string, stateType: string): types.IssueRef
	return { id = id, identifier = id, title = id, stateType = stateType, stateName = nil }
end

-- ─── blocked ────────────────────────────────────────────────────────────────

local blockedByOpen = issue(
	"a",
	{ relations = { { id = "r1", type = "blocks", direction = "incoming", other = ref("open", "started") } } }
)
local blockedByDone = issue(
	"b",
	{ relations = { { id = "r2", type = "blocks", direction = "incoming", other = ref("done", "completed") } } }
)
local blocking =
	issue("c", { relations = { { id = "r3", type = "blocks", direction = "outgoing", other = ref("x", "started") } } })
local related =
	issue("d", { relations = { { id = "r4", type = "related", direction = "incoming", other = ref("y", "started") } } })

check("an open incoming blocker blocks", model.isBlocked(blockedByOpen))
check("a resolved blocker does not block", not model.isBlocked(blockedByDone))
check("blocking someone else is not blocked", not model.isBlocked(blocking))
check("a plain relation is not a blocker", not model.isBlocked(related))
check(
	"blockers lists the open blockers only",
	#model.blockers(blockedByOpen) == 1 and #model.blockers(blockedByDone) == 0
)

-- ─── server filter ──────────────────────────────────────────────────────────

local mineFilter: any = model.serverFilter(prefs({ scope = "mine", teamId = nil, view = "backlog" }))
check("mine scope filters on the viewer", mineFilter["and"][1].assignee.isMe.eq == true)
check(
	"backlog view filters the backlog type",
	mineFilter["and"][2].state.type["in"][1] == "backlog" and #mineFilter["and"][2].state.type["in"] == 1
)

local teamFilter: any = model.serverFilter(prefs({ view = "active" }))
check("team scope filters on the team id", teamFilter["and"][1].team.id.eq == "t-eng")
local activeTypes: { string } = teamFilter["and"][2].state.type["in"]
check("active view is triage, unstarted and started", table.concat(activeTypes, ",") == "triage,unstarted,started")

local allFilter: any = model.serverFilter(prefs({ view = "all" }))
local either: any = allFilter["and"][2]["or"]
check("all view keeps open issues", table.concat(either[1].state.type.nin, ",") == "completed,canceled,duplicate")
check(
	"all view keeps recently closed issues",
	either[2].completedAt.gt == "-P14D" and either[3].canceledAt.gt == "-P14D"
)

-- ─── visible: filtering and board order ─────────────────────────────────────

local urgent = issue("i1", { number = 1, state = DOING, priority = 1, title = "Urgent fix", assignee = ME })
local low = issue("i2", { number = 2, state = DOING, priority = 4, sortOrder = 5 })
local none = issue("i3", { number = 3, state = DOING, priority = 0, sortOrder = 1 })
local highLater = issue("i4", { number = 4, state = DOING, priority = 2, sortOrder = 9, title = "Search ПРИВЕТ" })
local highEarlier = issue("i5", {
	number = 5,
	state = DOING,
	priority = 2,
	sortOrder = 2,
	labels = { { id = "l-bug", name = "Bug", color = "#f00", isGroup = nil } },
})
local inReview = issue("i6", { number = 6, state = REVIEW, priority = 1, assignee = ANA })
local inTodo = issue("i7", { number = 7, state = TODO, priority = 3 })
local inBacklog = issue("i8", { number = 8, state = BACKLOG, priority = 1 })

local pool = { inReview, none, highLater, inBacklog, urgent, low, inTodo, highEarlier, urgent }

check(
	"visible orders by column, priority, sortOrder and drops duplicates",
	ids(model.visible(pool, prefs(), "", nil)) == "ENG-8 ENG-7 ENG-1 ENG-5 ENG-4 ENG-2 ENG-3 ENG-6"
)
check(
	"query matches titles case-insensitively, Cyrillic included",
	ids(model.visible(pool, prefs(), "urgent", nil)) == "ENG-1"
)
check("query matches the identifier", ids(model.visible(pool, prefs(), "eng-5", nil)) == "ENG-5")
check("query matches label names", ids(model.visible(pool, prefs(), "BUG", nil)) == "ENG-5")
check("query matches the assignee", ids(model.visible(pool, prefs(), "ana", nil)) == "ENG-6")
check("priority filter", ids(model.visible(pool, prefs({ priority = 2 }), "", nil)) == "ENG-5 ENG-4")
check("assignee filter me", ids(model.visible(pool, prefs({ assignee = "me" }), "", "u-me")) == "ENG-1")
check(
	"assignee filter me without a viewer matches nothing",
	ids(model.visible(pool, prefs({ assignee = "me" }), "", nil)) == ""
)
check(
	"assignee filter none",
	ids(model.visible(pool, prefs({ assignee = "none" }), "", nil)) == "ENG-8 ENG-7 ENG-5 ENG-4 ENG-2 ENG-3"
)
check("assignee filter by id", ids(model.visible(pool, prefs({ assignee = "u-ana" }), "", nil)) == "ENG-6")
check("label filter", ids(model.visible(pool, prefs({ labelId = "l-bug" }), "", nil)) == "ENG-5")

-- ─── columns ────────────────────────────────────────────────────────────────

local teamAll = prefs({ view = "all" })
local columns = model.columns(model.visible(pool, teamAll, "", nil), teamAll, team)
local titles: { string } = {}
for _, column in columns do
	table.insert(titles, `{column.title}:{#column.issues}`)
end
check(
	"team columns follow the team's states, empty ones included",
	table.concat(titles, ",") == "Backlog:1,Todo:1,In Progress:5,In Review:1,Done:0,Canceled:0,Duplicate:0"
)
check(
	"team columns carry state ids",
	columns[3].id == "s-doing" and columns[3].stateId == "s-doing" and columns[3].stateType == "started"
)

local activeColumns = model.columns(model.visible(pool, prefs(), "", nil), prefs(), team)
check(
	"active view hides backlog and closed columns",
	#activeColumns == 3 and activeColumns[1].title == "Todo" and activeColumns[3].title == "In Review"
)

local mine = prefs({ scope = "mine", teamId = nil, view = "all" })
local otherTeam =
	issue("o1", { teamKey = "OPS", number = 9, state = state("s-ops-doing", "Doing", "started", 3), priority = 1 })
local dupIssue = issue("o2", { teamKey = "OPS", number = 10, state = DUPLICATE })
local mineColumns = model.columns(model.visible({ low, otherTeam, dupIssue, urgent }, mine, "", nil), mine, nil)
local mineTitles: { string } = {}
for _, column in mineColumns do
	table.insert(mineTitles, `{column.title}:{#column.issues}`)
end
check(
	"mine columns are one per state type with duplicate folded into canceled",
	table.concat(mineTitles, ",") == "Triage:0,Backlog:0,Todo:0,In Progress:3,Done:0,Canceled:1"
)
check(
	"mine columns have no state id",
	mineColumns[4].stateId == nil and mineColumns[4].id == "started" and mineColumns[5].title == "Done"
)
check("mine columns order cards by priority across teams", ids(mineColumns[4].issues) == "ENG-1 OPS-9 ENG-2")

local emptyBoard = model.columns({}, prefs({ view = "backlog" }), team)
check(
	"an empty board keeps its shape",
	#emptyBoard == 1 and emptyBoard[1].title == "Backlog" and #emptyBoard[1].issues == 0
)

-- ─── table sorting ──────────────────────────────────────────────────────────

local rows = {
	issue("t1", {
		teamKey = "ENG",
		number = 10,
		title = "beta",
		priority = 0,
		assignee = ANA,
		state = DONE,
		updatedAt = "2025-03-01T00:00:00Z",
	}),
	issue(
		"t2",
		{ teamKey = "ENG", number = 2, title = "Alpha", priority = 2, state = TODO, updatedAt = "2025-05-01T00:00:00Z" }
	),
	issue("t3", {
		teamKey = "API",
		number = 7,
		title = "gamma",
		priority = 1,
		assignee = ME,
		state = DOING,
		updatedAt = "2025-04-01T00:00:00Z",
	}),
}

check(
	"sort by identifier compares team key then number",
	ids(model.sortTable(rows, "identifier", true)) == "API-7 ENG-2 ENG-10"
)
check("sort by identifier descending", ids(model.sortTable(rows, "identifier", false)) == "ENG-10 ENG-2 API-7")
check("sort by title ignores case", ids(model.sortTable(rows, "title", true)) == "ENG-2 ENG-10 API-7")
check("sort by state follows type rank", ids(model.sortTable(rows, "state", true)) == "ENG-2 API-7 ENG-10")
check(
	"sort by priority puts urgent first and none last",
	ids(model.sortTable(rows, "priority", true)) == "API-7 ENG-2 ENG-10"
)
check("sort by assignee puts unassigned last", ids(model.sortTable(rows, "assignee", true)) == "ENG-10 API-7 ENG-2")
check(
	"sort by updated is newest first when descending",
	ids(model.sortTable(rows, "updated", false)) == "ENG-2 API-7 ENG-10"
)
check("sorting does not mutate its input", ids(rows) == "ENG-10 ENG-2 API-7")

-- ─── workflow states ────────────────────────────────────────────────────────

check(
	"stateFor picks the lowest position of a type",
	(model.stateFor(team, "started") :: types.WorkflowState).id == "s-doing"
)
check(
	"done, todo and started helpers",
	(model.doneState(team) :: types.WorkflowState).id == "s-done"
		and (model.todoState(team) :: types.WorkflowState).id == "s-todo"
		and (model.startedState(team) :: types.WorkflowState).id == "s-doing"
)

local doing = issue("m1", { state = DOING })
check(
	"adjacentState steps forward inside the view",
	(model.adjacentState(team, doing, 1, "active") :: types.WorkflowState).id == "s-review"
)
check(
	"adjacentState steps backward inside the view",
	(model.adjacentState(team, doing, -1, "active") :: types.WorkflowState).id == "s-todo"
)
check(
	"adjacentState stops at the last column",
	model.adjacentState(team, issue("m2", { state = REVIEW }), 1, "active") == nil
)
check(
	"adjacentState stops at the first column",
	model.adjacentState(team, issue("m3", { state = TODO }), -1, "active") == nil
)
check(
	"adjacentState outside the view walks every state",
	(model.adjacentState(team, issue("m4", { state = DONE }), 1, "active") :: types.WorkflowState).id == "s-canceled"
)
check(
	"adjacentState from a closed state skips duplicate",
	model.adjacentState(team, issue("m5", { state = CANCELED }), 1, "active") == nil
)
check(
	"adjacentState in the all view reaches the duplicate state",
	(model.adjacentState(team, issue("m6", { state = CANCELED }), 1, "all") :: types.WorkflowState).id == "s-dup"
)

-- ─── dates ──────────────────────────────────────────────────────────────────

check("epoch of the Unix epoch", model.epoch("1970-01-01T00:00:00Z") == 0)
check("epoch of a known timestamp", model.epoch("2024-03-04T05:06:07Z") == 1709528767)
check("epoch keeps fractional seconds", model.epoch("2024-03-04T05:06:07.250Z") == 1709528767.25)
check("epoch applies a positive offset", model.epoch("2024-03-04T07:06:07+02:00") == 1709528767)
check("epoch applies a negative offset", model.epoch("2024-03-03T23:36:07-05:30") == 1709528767)
check(
	"epoch handles leap days",
	(model.epoch("2024-03-01T00:00:00Z") :: number) - (model.epoch("2024-02-28T00:00:00Z") :: number) == 2 * 86400
)
check("epoch of a bare date", model.epoch("2024-03-04") == 1709510400)
check("epoch rejects garbage", model.epoch("yesterday") == nil and model.epoch("2024-13-01T00:00:00Z") == nil)

local now = model.epoch("2025-06-15T12:00:00Z") :: number
check("relativeTime under a minute is now", model.relativeTime("2025-06-15T11:59:01Z", now) == "now")
check("relativeTime at a minute", model.relativeTime("2025-06-15T11:59:00Z", now) == "1m")
check("relativeTime in minutes", model.relativeTime("2025-06-15T11:55:00Z", now) == "5m")
check("relativeTime at an hour", model.relativeTime("2025-06-15T11:00:00Z", now) == "1h")
check("relativeTime in hours", model.relativeTime("2025-06-15T09:00:00Z", now) == "3h")
check("relativeTime at a day", model.relativeTime("2025-06-14T12:00:00Z", now) == "1d")
check("relativeTime in days", model.relativeTime("2025-06-13T12:00:00Z", now) == "2d")
check("relativeTime keeps days through 30", model.relativeTime("2025-05-16T12:00:00Z", now) == "30d")
check("relativeTime switches to a date after 30 days", model.relativeTime("2025-05-15T12:00:00Z", now) == "May 15")
check("relativeTime adds the year for earlier years", model.relativeTime("2024-03-04T08:00:00Z", now) == "Mar 4, 2024")
check("relativeTime of the future is now", model.relativeTime("2025-06-16T12:00:00Z", now) == "now")

-- ─── identifiers and priorities ─────────────────────────────────────────────

local key, number = model.parseIdentifier("eng-12")
check("parseIdentifier uppercases the team key", key == "ENG" and number == 12)
check("parseIdentifier rejects free text", model.parseIdentifier("fix login") == nil)
check("priorityLabel", model.priorityLabel(1) == "Urgent" and model.priorityLabel(0) == "No priority")
check("typeRank follows STATE_TYPES", model.typeRank("triage") == 1 and model.typeRank("duplicate") == 7)

-- ─── form diff ──────────────────────────────────────────────────────────────

local form: types.Form = {
	kind = "edit",
	issueId = "a",
	focus = 1,
	error = nil,
	fields = {
		{
			name = "title",
			label = "Title",
			kind = "text",
			field = { text = "New title", cursor = 9, anchor = nil },
			value = nil,
			options = nil,
			baseline = "Old title",
			placeholder = nil,
		},
		{
			name = "description",
			label = "Description",
			kind = "multiline",
			field = { text = "same", cursor = 4, anchor = nil },
			value = nil,
			options = nil,
			baseline = "same",
			placeholder = nil,
		},
		{
			name = "priority",
			label = "Priority",
			kind = "choice",
			field = nil,
			value = "2",
			options = {},
			baseline = "0",
			placeholder = nil,
		},
		{
			name = "assignee",
			label = "Assignee",
			kind = "choice",
			field = nil,
			value = "",
			options = {},
			baseline = "",
			placeholder = nil,
		},
	},
}
local diff = model.formDiff(form)
check(
	"formDiff returns only changed fields",
	diff.title == "New title" and diff.priority == "2" and diff.description == nil and diff.assignee == nil
)

if failures > 0 then
	error(`{failures} model test(s) failed`)
end
print("model tests passed")
