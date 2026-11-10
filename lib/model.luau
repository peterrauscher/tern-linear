--!strict
-- Pure board logic: grouping, filtering, ordering, server filters, blocked state, dates and form diffs.
-- No `tern.*` access: this module is unit-tested with the stand-alone `luau` CLI.

local types = require("./types")

type Issue = types.Issue
type IssueRef = types.IssueRef
type Prefs = types.Prefs
type Team = types.Team
type WorkflowState = types.WorkflowState
type Form = types.Form

export type Column = {
	id: string,
	title: string,
	stateType: string,
	stateId: string?,
	color: string?,
	issues: { Issue },
}

local model = {}

-- ─── State types and priorities ─────────────────────────────────────────────

local STATE_TYPES: { string } =
	table.freeze({ "triage", "backlog", "unstarted", "started", "completed", "canceled", "duplicate" })
model.STATE_TYPES = STATE_TYPES

local TYPE_TITLES: { [string]: string } = {
	triage = "Triage",
	backlog = "Backlog",
	unstarted = "Todo",
	started = "In Progress",
	completed = "Done",
	canceled = "Canceled",
	duplicate = "Duplicate",
}

local PRIORITIES: { { value: number, label: string } } = {
	{ value = 1, label = "Urgent" },
	{ value = 2, label = "High" },
	{ value = 3, label = "Medium" },
	{ value = 4, label = "Low" },
	{ value = 0, label = "No priority" },
}
model.TYPE_TITLES = TYPE_TITLES
model.PRIORITIES = PRIORITIES

local VIEW_TYPES: { [string]: { string } } = {
	active = table.freeze({ "triage", "unstarted", "started" }),
	backlog = table.freeze({ "backlog" }),
	all = STATE_TYPES,
}

local CLOSED_TYPES: { string } = { "completed", "canceled", "duplicate" }

function model.typeRank(t: string): number
	local rank = table.find(model.STATE_TYPES, t)
	return rank or #model.STATE_TYPES + 1
end

function model.isClosedType(t: string): boolean
	return table.find(CLOSED_TYPES, t) ~= nil
end

function model.viewTypes(view: string): { string }
	return VIEW_TYPES[view] or VIEW_TYPES.active
end

function model.priorityLabel(p: number): string
	for _, entry in model.PRIORITIES do
		if entry.value == p then
			return entry.label
		end
	end
	return "No priority"
end

-- ─── Relations ──────────────────────────────────────────────────────────────

-- Unresolved issues that block `issue` (incoming "blocks" whose other side is not closed).
function model.blockers(issue: Issue): { IssueRef }
	local out: { IssueRef } = {}
	for _, relation in issue.relations do
		if
			relation.type == "blocks"
			and relation.direction == "incoming"
			and not model.isClosedType(relation.other.stateType)
		then
			table.insert(out, relation.other)
		end
	end
	return out
end

function model.isBlocked(issue: Issue): boolean
	return #model.blockers(issue) > 0
end

-- ─── Identifiers ────────────────────────────────────────────────────────────

-- "eng-12" → "ENG", 12
function model.parseIdentifier(s: string): (string?, number?)
	local key, number = string.match(s, "^%s*(%a[%w]*)%-(%d+)%s*$")
	if key == nil or number == nil then
		return nil, nil
	end
	return string.upper(key), tonumber(number)
end

-- ─── Server filter ──────────────────────────────────────────────────────────

local function stateTypeFilter(comparator: string, stateTypes: { string }): any
	return { state = { type = { [comparator] = stateTypes } } }
end

local function viewFilter(view: string): any
	if view == "all" then
		return {
			["or"] = {
				stateTypeFilter("nin", CLOSED_TYPES),
				{ completedAt = { gt = "-P14D" } },
				{ canceledAt = { gt = "-P14D" } },
			},
		}
	end
	return stateTypeFilter("in", model.viewTypes(view))
end

-- Linear IssueFilter as plain tables; non-empty arrays encode as JSON arrays.
function model.serverFilter(prefs: Prefs): any
	local parts: { any } = {}
	if prefs.scope == "mine" then
		table.insert(parts, { assignee = { isMe = { eq = true } } })
	elseif prefs.teamId ~= nil then
		table.insert(parts, { team = { id = { eq = prefs.teamId } } })
	end
	table.insert(parts, viewFilter(prefs.view))
	return { ["and"] = parts }
end

-- ─── Ordering ───────────────────────────────────────────────────────────────

local NO_PRIORITY_RANK = 5

local function priorityRank(p: number): number
	return if p == 0 then NO_PRIORITY_RANK else p
end

local function compare(a: number, b: number): number
	if a < b then
		return -1
	end
	return if a > b then 1 else 0
end

local function compareText(a: string, b: string): number
	local left, right = string.lower(a), string.lower(b)
	if left < right then
		return -1
	end
	return if left > right then 1 else 0
end

local function compareIdentifier(a: Issue, b: Issue): number
	local byTeam = compareText(a.teamKey, b.teamKey)
	if byTeam ~= 0 then
		return byTeam
	end
	return compare(a.number, b.number)
end

local function compareState(a: Issue, b: Issue): number
	local byType = compare(model.typeRank(a.state.type), model.typeRank(b.state.type))
	if byType ~= 0 then
		return byType
	end
	local byPosition = compare(a.state.position, b.state.position)
	return if byPosition ~= 0 then byPosition else compareText(a.state.name, b.state.name)
end

-- Priority (1..4, then none), then manual sort order, then identifier.
local function compareCard(a: Issue, b: Issue): number
	local byPriority = compare(priorityRank(a.priority), priorityRank(b.priority))
	if byPriority ~= 0 then
		return byPriority
	end
	local bySortOrder = compare(a.sortOrder, b.sortOrder)
	return if bySortOrder ~= 0 then bySortOrder else compareIdentifier(a, b)
end

local function compareBoard(a: Issue, b: Issue): number
	local byState = compareState(a, b)
	return if byState ~= 0 then byState else compareCard(a, b)
end

local function lessWith(compareIssues: (Issue, Issue) -> number): (Issue, Issue) -> boolean
	return function(a: Issue, b: Issue): boolean
		local c = compareIssues(a, b)
		if c ~= 0 then
			return c < 0
		end
		return a.id < b.id
	end
end

-- ─── Dates ──────────────────────────────────────────────────────────────────

local SECONDS_PER_DAY = 86400
local MONTH_NAMES = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's days_from_civil).
local function daysFromCivil(year: number, month: number, day: number): number
	local y = if month <= 2 then year - 1 else year
	local era = y // 400
	local yearOfEra = y - era * 400
	local monthIndex = (month + 9) % 12
	local dayOfYear = (153 * monthIndex + 2) // 5 + day - 1
	local dayOfEra = yearOfEra * 365 + yearOfEra // 4 - yearOfEra // 100 + dayOfYear
	return era * 146097 + dayOfEra - 719468
end

-- Inverse of daysFromCivil: (year, month, day).
local function civilFromDays(days: number): (number, number, number)
	local z = days + 719468
	local era = z // 146097
	local dayOfEra = z - era * 146097
	local yearOfEra = (dayOfEra - dayOfEra // 1460 + dayOfEra // 36524 - dayOfEra // 146096) // 365
	local dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra // 4 - yearOfEra // 100)
	local monthIndex = (5 * dayOfYear + 2) // 153
	local day = dayOfYear - (153 * monthIndex + 2) // 5 + 1
	local month = if monthIndex < 10 then monthIndex + 3 else monthIndex - 9
	local year = yearOfEra + era * 400
	return (if month <= 2 then year + 1 else year), month, day
end

-- Seconds east of UTC for "Z", "", "+HH:MM", "-HHMM"; nil when malformed.
local function parseOffset(s: string): number?
	if s == "" or s == "Z" or s == "z" then
		return 0
	end
	local sign, hours, minutes = string.match(s, "^([+-])(%d%d):?(%d%d)$")
	if sign == nil or hours == nil or minutes == nil then
		return nil
	end
	local seconds = (tonumber(hours) :: number) * 3600 + (tonumber(minutes) :: number) * 60
	return if sign == "-" then -seconds else seconds
end

local function validDate(month: number, day: number): boolean
	return month >= 1 and month <= 12 and day >= 1 and day <= 31
end

-- "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM:SS(.fff)?(Z|±HH:MM)" → UTC epoch seconds.
function model.epoch(iso: string): number?
	local y, mo, d = string.match(iso, "^(%d%d%d%d)-(%d%d)-(%d%d)$")
	if y ~= nil and mo ~= nil and d ~= nil then
		local year, month, day = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
		if not validDate(month, day) then
			return nil
		end
		return daysFromCivil(year, month, day) * SECONDS_PER_DAY
	end

	local ty, tmo, td, hh, mm, ss, fraction, zone =
		string.match(iso, "^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(%.?%d*)(.*)$")
	if
		ty == nil
		or tmo == nil
		or td == nil
		or hh == nil
		or mm == nil
		or ss == nil
		or fraction == nil
		or zone == nil
	then
		return nil
	end
	local offset = parseOffset(zone)
	local year, month, day = tonumber(ty) :: number, tonumber(tmo) :: number, tonumber(td) :: number
	local hour, minute, second = tonumber(hh) :: number, tonumber(mm) :: number, tonumber(ss) :: number
	local malformedFraction = fraction ~= "" and string.sub(fraction, 1, 1) ~= "."
	if offset == nil or malformedFraction or not validDate(month, day) or hour > 23 or minute > 59 or second > 60 then
		return nil
	end
	local fractional = if #fraction > 1 then tonumber("0" .. fraction) or 0 else 0
	local localSeconds = daysFromCivil(year, month, day) * SECONDS_PER_DAY + hour * 3600 + minute * 60 + second
	return localSeconds - offset + fractional
end

-- "now", "5m", "3h", "2d", else "Mar 4" (with the year when it is not the current one).
function model.relativeTime(iso: string, now: number): string
	local at = model.epoch(iso)
	if at == nil then
		return ""
	end
	local elapsed = now - at
	if elapsed < 60 then
		return "now"
	elseif elapsed < 3600 then
		return `{elapsed // 60}m`
	elseif elapsed < SECONDS_PER_DAY then
		return `{elapsed // 3600}h`
	end
	local days = elapsed // SECONDS_PER_DAY
	if days <= 30 then
		return `{days}d`
	end
	local year, month, day = civilFromDays(at // SECONDS_PER_DAY)
	local currentYear = civilFromDays(now // SECONDS_PER_DAY)
	local label = `{MONTH_NAMES[month]} {day}`
	return if year == currentYear then label else `{label}, {year}`
end

-- ─── Filtering ──────────────────────────────────────────────────────────────

local function searchHaystack(issue: Issue): string
	local parts: { string } = { issue.identifier, issue.title }
	for _, label in issue.labels do
		table.insert(parts, label.name)
	end
	local assignee = issue.assignee
	if assignee ~= nil then
		table.insert(parts, assignee.name)
		table.insert(parts, assignee.displayName)
	end
	return string.lower(table.concat(parts, "\n"))
end

local function matchesQuery(issue: Issue, needle: string, key: string?, number: number?): boolean
	if key ~= nil and number ~= nil and string.upper(issue.teamKey) == key and issue.number == number then
		return true
	end
	return string.find(searchHaystack(issue), needle, 1, true) ~= nil
end

local function matchesAssignee(issue: Issue, wanted: string, viewerId: string?): boolean
	local assignee = issue.assignee
	if wanted == "none" then
		return assignee == nil
	end
	local id = if wanted == "me" then viewerId else wanted
	return assignee ~= nil and id ~= nil and assignee.id == id
end

local function hasLabel(issue: Issue, labelId: string): boolean
	for _, label in issue.labels do
		if label.id == labelId then
			return true
		end
	end
	return false
end

function model.visible(issues: { Issue }, prefs: Prefs, query: string, viewerId: string?): { Issue }
	local needle = string.lower(string.match(query, "^%s*(.-)%s*$") :: string)
	local key, number = model.parseIdentifier(needle)
	local seen: { [string]: boolean } = {}
	local out: { Issue } = {}
	for _, issue in issues do
		local keep = not seen[issue.id]
			and (needle == "" or matchesQuery(issue, needle, key, number))
			and (prefs.priority == nil or issue.priority == prefs.priority)
			and (prefs.assignee == nil or matchesAssignee(issue, prefs.assignee, viewerId))
			and (prefs.labelId == nil or hasLabel(issue, prefs.labelId))
		if keep then
			table.insert(out, issue)
		end
		seen[issue.id] = true
	end
	table.sort(out, lessWith(compareBoard))
	return out
end

-- ─── Columns ────────────────────────────────────────────────────────────────

local function inList(list: { string }, value: string): boolean
	return table.find(list, value) ~= nil
end

local function teamColumns(visible: { Issue }, team: Team, stateTypes: { string }): { Column }
	local columns: { Column } = {}
	local byState: { [string]: Column } = {}
	for _, state in team.states do
		if inList(stateTypes, state.type) then
			local column: Column = {
				id = state.id,
				title = state.name,
				stateType = state.type,
				stateId = state.id,
				color = state.color,
				issues = {},
			}
			table.insert(columns, column)
			byState[state.id] = column
		end
	end
	for _, issue in visible do
		local column = byState[issue.state.id]
		if column ~= nil then
			table.insert(column.issues, issue)
		end
	end
	return columns
end

-- Duplicate is a flavour of canceled on a "my issues" board.
local function mineColumnType(stateType: string): string
	return if stateType == "duplicate" then "canceled" else stateType
end

local function mineColumns(visible: { Issue }, stateTypes: { string }): { Column }
	local columns: { Column } = {}
	local byType: { [string]: Column } = {}
	for _, stateType in stateTypes do
		if stateType ~= "duplicate" then
			local column: Column = {
				id = stateType,
				title = model.TYPE_TITLES[stateType] or stateType,
				stateType = stateType,
				stateId = nil,
				color = nil,
				issues = {},
			}
			table.insert(columns, column)
			byType[stateType] = column
		end
	end
	for _, issue in visible do
		local column = byType[mineColumnType(issue.state.type)]
		if column ~= nil then
			table.insert(column.issues, issue)
		end
	end
	-- Issues of one type come from several teams whose state positions differ; order cards by priority only.
	for _, column in columns do
		table.sort(column.issues, lessWith(compareCard))
	end
	return columns
end

function model.columns(visible: { Issue }, prefs: Prefs, team: Team?): { Column }
	local stateTypes = model.viewTypes(prefs.view)
	if prefs.scope == "team" and team ~= nil then
		return teamColumns(visible, team, stateTypes)
	end
	return mineColumns(visible, stateTypes)
end

-- ─── Table sorting ──────────────────────────────────────────────────────────

local function compareTitle(a: Issue, b: Issue): number
	return compareText(a.title, b.title)
end

local function comparePriority(a: Issue, b: Issue): number
	return compare(priorityRank(a.priority), priorityRank(b.priority))
end

-- Unassigned issues sort after every named assignee.
local function compareAssignee(a: Issue, b: Issue): number
	local left, right = a.assignee, b.assignee
	if left == nil or right == nil then
		return compare(if left == nil then 1 else 0, if right == nil then 1 else 0)
	end
	return compareText(left.name, right.name)
end

local function compareUpdated(a: Issue, b: Issue): number
	return compare(model.epoch(a.updatedAt) or 0, model.epoch(b.updatedAt) or 0)
end

local TABLE_COMPARATORS: { [string]: (Issue, Issue) -> number } = {
	identifier = compareIdentifier,
	title = compareTitle,
	state = compareState,
	priority = comparePriority,
	assignee = compareAssignee,
	updated = compareUpdated,
}

function model.sortTable(visible: { Issue }, key: string, asc: boolean): { Issue }
	local base = TABLE_COMPARATORS[key] or compareIdentifier
	local out = table.clone(visible)
	table.sort(
		out,
		lessWith(function(a: Issue, b: Issue): number
			local c = base(a, b)
			if c == 0 then
				return compareIdentifier(a, b)
			end
			return if asc then c else -c
		end)
	)
	return out
end

-- ─── Workflow states ────────────────────────────────────────────────────────

function model.stateFor(team: Team, stateType: string): WorkflowState?
	local best: WorkflowState? = nil
	for _, state in team.states do
		if state.type == stateType and (best == nil or state.position < best.position) then
			best = state
		end
	end
	return best
end

function model.doneState(team: Team): WorkflowState?
	return model.stateFor(team, "completed")
end

function model.todoState(team: Team): WorkflowState?
	return model.stateFor(team, "unstarted")
end

function model.startedState(team: Team): WorkflowState?
	return model.stateFor(team, "started")
end

local function filterStates(states: { WorkflowState }, keep: (WorkflowState) -> boolean): { WorkflowState }
	local out: { WorkflowState } = {}
	for _, state in states do
		if keep(state) then
			table.insert(out, state)
		end
	end
	return out
end

local function indexOfState(states: { WorkflowState }, id: string): number?
	for index, state in states do
		if state.id == id then
			return index
		end
	end
	return nil
end

-- The state one column before (delta < 0) or after (delta > 0) the issue's, or nil at the edge.
-- Columns are the team's states of the view's types; an issue outside the view steps through every
-- non-duplicate state instead.
function model.adjacentState(team: Team, issue: Issue, delta: number, view: string): WorkflowState?
	local stateTypes = model.viewTypes(view)
	local candidates = filterStates(team.states, function(state: WorkflowState): boolean
		return inList(stateTypes, state.type)
	end)
	local current = indexOfState(candidates, issue.state.id)
	if current == nil then
		candidates = filterStates(team.states, function(state: WorkflowState): boolean
			return state.type ~= "duplicate" or state.id == issue.state.id
		end)
		current = indexOfState(candidates, issue.state.id)
	end
	if current == nil then
		return nil
	end
	return candidates[current + delta]
end

-- ─── Forms ──────────────────────────────────────────────────────────────────

-- name → current value, for every field that differs from its baseline.
function model.formDiff(form: Form): { [string]: string }
	local changed: { [string]: string } = {}
	for _, field in form.fields do
		local current = ""
		if field.kind == "choice" then
			current = field.value or ""
		elseif field.field ~= nil then
			current = field.field.text
		end
		if current ~= field.baseline then
			changed[field.name] = current
		end
	end
	return changed
end

return model
