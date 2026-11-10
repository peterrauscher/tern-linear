--!strict
-- The `main` region: setup screen, top bar, filters, board, table, empty and error states.
-- Pure: nothing here mutates state. The drawer and dialogs come from view_detail as the `layer`.

local detail = require("./view_detail")
local model = require("./model")
local types = require("./types")

type BlockState = types.BlockState
type Issue = types.Issue
type Team = types.Team
type Column = model.Column

local ui = tern.ui

local view = {}

-- ─── Node ids ───────────────────────────────────────────────────────────────
-- A node id is `<parent id>.<key>` from the region root. Fields keep these keys on every render.

local KEY_SETUP = "setup"
local KEY_SETUP_KEY = "key"
local KEY_BAR = "bar"
local KEY_SEARCH = "search"

local SETUP_FIELD_ID = `main.{KEY_SETUP}.{KEY_SETUP_KEY}`
local SEARCH_FIELD_ID = `main.{KEY_BAR}.{KEY_SEARCH}`

local KEY_URL = "https://linear.app/settings/account/security"

-- ─── Look-up tables ─────────────────────────────────────────────────────────

-- Linear's state colours cannot be inline, so a state type maps to the nearest tone.
local STATE_TONES: { [string]: string } = {
	triage = "info",
	backlog = "muted",
	unstarted = "neutral",
	started = "warning",
	completed = "success",
	canceled = "muted",
	duplicate = "muted",
}

local PRIORITY_TONES: { [number]: string } = {
	[1] = "error",
	[2] = "warning",
	[3] = "info",
	[4] = "muted",
}

local SORT_COLUMNS: { { key: string, label: string } } = {
	{ key = "identifier", label = "ID" },
	{ key = "title", label = "Title" },
	{ key = "state", label = "State" },
	{ key = "priority", label = "Priority" },
	{ key = "assignee", label = "Assignee" },
	{ key = "updated", label = "Updated" },
}

local VIEWS: { { id: string, label: string } } = {
	{ id = "active", label = "Active" },
	{ id = "backlog", label = "Backlog" },
	{ id = "all", label = "All" },
}

local LAYOUTS: { { id: string, label: string, icon: string } } = {
	{ id = "board", label = "Board", icon = "kanban" },
	{ id = "table", label = "Table", icon = "list" },
}

local MAX_CARD_LABELS = 3
local COLUMN_MIN_WIDTH = "30ch"
-- Pane rows taken by the bar, filter row and column headers; the rest is card space (a row is one
-- 18px line). The bar wraps onto a second line below BAR_WRAP_COLS, and each banner takes three rows.
local BOARD_CHROME_ROWS = 12
local BAR_WRAP_COLS = 120
local BAR_WRAP_ROWS = 3
local BANNER_ROWS = 3
local MIN_COLUMN_LINES = 8

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function with(node: Node, props: { [string]: any }): Node
	local merged: { [string]: any } = node.p or {}
	for name, value in props do
		merged[name] = value
	end
	node.p = merged
	return node
end

local function compact(nodes: { Node? }, count: number): { Node }
	local out: { Node } = {}
	for index = 1, count do
		local node = nodes[index]
		if node ~= nil then
			table.insert(out, node)
		end
	end
	return out
end

local function selectedTeam(state: BlockState): Team?
	if state.prefs.scope ~= "team" then
		return nil
	end
	for _, team in state.teams do
		if team.id == state.prefs.teamId then
			return team
		end
	end
	return nil
end

local function filtersActive(state: BlockState): boolean
	local prefs = state.prefs
	return prefs.priority ~= nil
		or prefs.assignee ~= nil
		or prefs.labelId ~= nil
		or string.match(state.query.text, "%S") ~= nil
end

local function syncedLabel(fetchedAt: number?, now: number): string
	if fetchedAt == nil then
		return "Refresh"
	end
	local iso = os.date("!%Y-%m-%dT%H:%M:%SZ", fetchedAt) :: string
	local relative = model.relativeTime(iso, now)
	if relative == "now" then
		return "Synced just now"
	elseif string.match(relative, "^%d+[mhd]$") ~= nil then
		return `Synced {relative} ago`
	end
	return `Synced {relative}`
end

local function pluralIssues(count: number): string
	return if count == 1 then "1 issue" else `{count} issues`
end

-- ─── Setup and loading ──────────────────────────────────────────────────────

local function setupCard(state: BlockState): Node
	local failure = state.setupError
	local createSpans: { Span | string } = {
		"Create a personal API key at ",
		ui.link(KEY_URL, KEY_URL),
		". It needs Read, Create/update issues and Create comments permissions, or Full access.",
	}
	local children = compact({
		ui.node("text", {
			key = "head",
			spans = { ui.span("Connect Linear", "strong") },
			mark = "heading",
		}),
		ui.node("text", { key = "create", spans = createSpans }),
		ui.node("text", {
			key = "storage",
			spans = {
				ui.span(
					"The key is saved in the plugin data folder in a file created owner-only (umask 077). "
						.. "LINEAR_API_KEY in Tern's environment works too.",
					"muted"
				),
			},
		}),
		ui.node("input", {
			key = KEY_SETUP_KEY,
			role = "linear.setup-key",
			text = state.setupKey.text,
			cursor = state.setupKey.cursor,
			anchor = state.setupKey.anchor,
			placeholder = "lin_api_…",
			secret = true,
			mono = true,
			variant = "field",
		}),
		if failure ~= nil
			then ui.node("text", {
				key = "error",
				role = "linear.setup-error",
				tone = "error",
				spans = { ui.span(failure, "error") },
			})
			else nil,
		ui.button("Connect", {
			key = "save",
			role = "linear.setup-save",
			variant = "primary",
			keys = { "enter" },
			busy = state.busy,
			actions = { click = "save-key" },
		}),
	}, 6)
	return ui.node("col", { key = KEY_SETUP, role = "linear.setup", gap = "md", max = { w = "60ch" } }, children)
end

local function loadingNode(): Node
	return ui.node("spinner", {
		key = "loading",
		role = "linear.loading",
		style = "braille",
		label = "Loading Linear…",
	})
end

-- Stands in for the board while a foreground load runs over an already-ready screen.
local function reloadingNode(): Node
	return ui.node("row", { key = "content", role = "linear.reloading", gap = "sm" }, {
		ui.node("spinner", { key = "spinner", style = "braille" }),
		ui.node("text", { key = "label", spans = { ui.span("Loading issues…", "muted") } }),
	})
end

-- ─── Top bar ────────────────────────────────────────────────────────────────

local function scopeSelect(state: BlockState): Node
	local options: { { value: string, label: string } } = { { value = "mine", label = "My issues" } }
	for _, team in state.teams do
		table.insert(options, { value = team.id, label = `{team.key} · {team.name}` })
	end
	local prefs = state.prefs
	local value = if prefs.scope == "team" and prefs.teamId ~= nil then prefs.teamId else "mine"
	return ui.node("select", {
		key = detail.controlKey("team-select", state.controlEpoch),
		role = "linear.team-select",
		value = value,
		options = options,
		variant = "field",
		disabled = if state.busy then true else nil,
		aria = "Scope",
	})
end

local function viewSwitcher(state: BlockState): Node
	local buttons: { Node } = {}
	for _, entry in VIEWS do
		table.insert(
			buttons,
			ui.button(entry.label, {
				key = `view-{entry.id}`,
				role = `linear.view-{entry.id}`,
				on = state.prefs.view == entry.id,
				actions = { click = `view={entry.id}` },
			})
		)
	end
	return ui.node("buttons", { key = "views" }, buttons)
end

local function layoutSwitcher(state: BlockState): Node
	local buttons: { Node } = {}
	for _, entry in LAYOUTS do
		table.insert(
			buttons,
			ui.button(entry.label, {
				key = `layout-{entry.id}`,
				role = `linear.layout-{entry.id}`,
				icon = entry.icon,
				on = state.prefs.layout == entry.id,
				actions = { click = `layout={entry.id}` },
			})
		)
	end
	return ui.node("buttons", { key = "layouts" }, buttons)
end

local function searchField(state: BlockState): Node
	return ui.node("input", {
		key = KEY_SEARCH,
		role = "linear.search",
		text = state.query.text,
		cursor = state.query.cursor,
		anchor = state.query.anchor,
		placeholder = "Search issues",
		icon = "search",
		keys = { "/" },
		variant = "field",
		grow = 1,
		min = { w = "16ch" },
		max = { w = "40ch" },
	})
end

local function refreshButton(state: BlockState, now: number): Node
	return ui.button(syncedLabel(state.fetchedAt, now), {
		key = "refresh",
		role = "linear.refresh",
		icon = "repeat",
		keys = { "r" },
		busy = state.refreshing or state.busy,
		actions = { click = "refresh" },
	})
end

local function barActions(state: BlockState, now: number): Node
	local children = compact({
		refreshButton(state, now),
		ui.button("New issue", {
			key = "new",
			role = "linear.new",
			variant = "primary",
			icon = "plus",
			keys = { "n" },
			actions = { click = "create" },
		}),
		if state.keySource == "file"
			then ui.button("Sign out", {
				key = "sign-out",
				role = "linear.sign-out",
				variant = "quiet",
				actions = { click = "sign-out" },
			})
			else nil,
	}, 3)
	return ui.node("row", { key = "actions", role = "linear.bar-actions", gap = "sm" }, children)
end

local function topBar(state: BlockState, now: number): Node
	local children = compact({
		scopeSelect(state),
		viewSwitcher(state),
		searchField(state),
		layoutSwitcher(state),
		barActions(state, now),
	}, 5)
	return ui.node("row", { key = KEY_BAR, role = "linear.bar", gap = "sm", wrap = true }, children)
end

-- ─── Filter row ─────────────────────────────────────────────────────────────

local function prioritySelect(state: BlockState): Node
	local options: { { value: string, label: string } } = { { value = "", label = "Any priority" } }
	for _, entry in model.PRIORITIES do
		table.insert(options, { value = tostring(entry.value), label = entry.label })
	end
	local priority = state.prefs.priority
	return ui.node("select", {
		key = "filter-priority",
		role = "linear.filter-priority",
		value = if priority ~= nil then tostring(priority) else "",
		options = options,
		variant = "quiet",
		aria = "Priority filter",
	})
end

local function assigneeSelect(state: BlockState, team: Team?): Node
	local options: { { value: string, label: string } } = {
		{ value = "", label = "Any assignee" },
		{ value = "me", label = "Me" },
		{ value = "none", label = "Unassigned" },
	}
	local viewerId = if state.viewer ~= nil then state.viewer.user.id else nil
	if team ~= nil then
		for _, member in team.members do
			if member.id ~= viewerId then
				table.insert(options, { value = member.id, label = member.displayName })
			end
		end
	end
	return ui.node("select", {
		key = "filter-assignee",
		role = "linear.filter-assignee",
		value = state.prefs.assignee or "",
		options = options,
		variant = "quiet",
		aria = "Assignee filter",
	})
end

-- Team scope lists the team's labels; "my issues" has no single team, so it lists the labels in use.
local function availableLabels(state: BlockState, team: Team?): { types.Label }
	if team ~= nil then
		return team.labels
	end
	local seen: { [string]: boolean } = {}
	local labels: { types.Label } = {}
	for _, issue in state.issues do
		for _, label in issue.labels do
			if not seen[label.id] then
				seen[label.id] = true
				table.insert(labels, label)
			end
		end
	end
	table.sort(labels, function(a, b)
		return string.lower(a.name) < string.lower(b.name)
	end)
	return labels
end

local function labelSelect(state: BlockState, team: Team?): Node
	local options: { { value: string, label: string } } = { { value = "", label = "Any label" } }
	for _, label in availableLabels(state, team) do
		table.insert(options, { value = label.id, label = label.name })
	end
	return ui.node("select", {
		key = "filter-label",
		role = "linear.filter-label",
		value = state.prefs.labelId or "",
		options = options,
		variant = "quiet",
		aria = "Label filter",
	})
end

local function filterRow(state: BlockState, team: Team?, visibleCount: number): Node
	local summary: { Span | string } = { ui.span(pluralIssues(visibleCount), "muted") }
	if state.truncated then
		table.insert(summary, ui.span(`  ·  Showing first {#state.issues}`, "warning"))
	end
	local children = compact({
		prioritySelect(state),
		assigneeSelect(state, team),
		labelSelect(state, team),
		if filtersActive(state)
			then ui.button("Clear filters", {
				key = "clear-filters",
				role = "linear.clear-filters",
				variant = "quiet",
				icon = "funnel-x",
				actions = { click = "clear-filters" },
			})
			else nil,
		ui.node("row", { key = "spacer", grow = 1 }),
		-- Counts of a list that is being replaced would be wrong.
		if state.reloading then nil else ui.node("text", { key = "count", role = "linear.count", spans = summary }),
	}, 6)
	return ui.node("row", { key = "filters", role = "linear.filters", gap = "sm", wrap = true }, children)
end

-- ─── Banners ────────────────────────────────────────────────────────────────

local function banner(key: string, role: string, tone: string, icon: string, message: string): Node
	return ui.node("row", { key = key, role = role, tone = tone, gap = "sm" }, {
		ui.node("icon", { key = "icon", name = icon, tone = tone }),
		ui.node("text", { key = "text", spans = { message }, grow = 1 }),
	})
end

-- ─── Board ──────────────────────────────────────────────────────────────────

local function stateDot(stateType: string): Node
	return ui.node("text", {
		key = "dot",
		role = "linear.state-dot",
		tone = STATE_TONES[stateType] or "muted",
		mark = stateType,
		spans = { "\u{00A0}" },
	})
end

local function labelChips(issue: Issue): { Node }
	local chips: { Node } = {}
	for index, label in issue.labels do
		if index > MAX_CARD_LABELS then
			local more = ui.badge(`+{#issue.labels - MAX_CARD_LABELS}`, "muted")
			table.insert(chips, with(more, { key = "more", mark = "label" }))
			break
		end
		table.insert(chips, with(ui.badge(label.name, "neutral"), { key = `label-{label.id}`, mark = "label" }))
	end
	return chips
end

local function cardHead(issue: Issue): Node
	local priorityTone = PRIORITY_TONES[issue.priority]
	local blocked = model.isBlocked(issue)
	local children = compact({
		ui.node("text", { key = "id", spans = { ui.span(issue.identifier, "mono muted") } }),
		ui.node("row", { key = "spacer", grow = 1 }),
		if blocked then with(ui.badge("Blocked", "error"), { key = "blocked", mark = "blocked" }) else nil,
		if priorityTone ~= nil
			then with(ui.badge(model.priorityLabel(issue.priority), priorityTone), {
				key = "priority",
				mark = `priority-{issue.priority}`,
			})
			else nil,
	}, 4)
	return ui.node("row", { key = "head", gap = "xs" }, children)
end

local function cardFoot(issue: Issue): Node?
	local chips = labelChips(issue)
	local assignee = issue.assignee
	if #chips == 0 and assignee == nil then
		return nil
	end
	local children: { Node } = {}
	children[1] = ui.node("row", { key = "labels", gap = "xs", wrap = true, grow = 1 }, chips)
	if assignee ~= nil then
		table.insert(
			children,
			ui.node("text", {
				key = "assignee",
				role = "linear.card-assignee",
				title = assignee.name,
				spans = { ui.span(assignee.displayName, "muted") },
				max = { w = "14ch" },
			})
		)
	end
	return ui.node("row", { key = "foot", gap = "sm", align = "start" }, children)
end

local function issueCard(issue: Issue, selectedId: string?): Node
	local children = compact({
		cardHead(issue),
		ui.node("text", { key = "title", role = "linear.card-title", max = { h = "2lines" }, spans = { issue.title } }),
		cardFoot(issue),
	}, 3)
	return ui.node("col", {
		key = issue.id,
		role = "linear.card",
		gap = "xs",
		mark = if issue.id == selectedId then "selected" else nil,
		actions = { click = `select={issue.id}` },
	}, children)
end

local function boardColumn(column: Column, selectedId: string?, lines: number): Node
	local cards: { Node } = {}
	for _, issue in column.issues do
		table.insert(cards, issueCard(issue, selectedId))
	end
	if #cards == 0 then
		table.insert(
			cards,
			ui.node("text", { key = "none", role = "linear.column-empty", spans = { ui.span("No issues", "dim") } })
		)
	end
	local head = ui.node("row", { key = "head", role = "linear.column-head", gap = "sm" }, {
		stateDot(column.stateType),
		ui.node("text", { key = "title", spans = { ui.span(column.title, "strong") } }),
		ui.node("text", { key = "count", spans = { ui.span(tostring(#column.issues), "muted") } }),
	})
	return ui.node("col", {
		key = column.id,
		role = "linear.column",
		mark = column.stateType,
		gap = "sm",
		grow = 1,
		basis = 0,
		min = { w = COLUMN_MIN_WIDTH },
	}, {
		head,
		ui.node("scroll", { key = "cards", gap = "sm", max = { h = `{lines}lines` } }, cards),
	})
end

local function chromeRows(state: BlockState, cx: BlockCx): number
	local rows = BOARD_CHROME_ROWS
	if cx.cols < BAR_WRAP_COLS then
		rows += BAR_WRAP_ROWS
	end
	if state.error ~= nil then
		rows += BANNER_ROWS
	end
	if state.notice ~= nil then
		rows += BANNER_ROWS
	end
	return rows
end

local function board(state: BlockState, cx: BlockCx, visible: { Issue }, team: Team?): Node
	local columns = model.columns(visible, state.prefs, team)
	local lines = math.max(MIN_COLUMN_LINES, cx.rows - chromeRows(state, cx))
	local children: { Node } = {}
	for _, column in columns do
		table.insert(children, boardColumn(column, state.selectedId, lines))
	end
	return ui.node("row", { key = "content", role = "linear.board", gap = "md", align = "start" }, children)
end

-- ─── Table ──────────────────────────────────────────────────────────────────

local TABLE_COLUMNS: { Col } = {
	{ id = "id", head = "ID", mono = true, priority = 8 },
	{ id = "title", head = "Title", grow = 1, priority = 9 },
	{ id = "state", head = "State", priority = 6 },
	{ id = "priority", head = "Priority", priority = 5 },
	{ id = "assignee", head = "Assignee", priority = 3 },
	{ id = "updated", head = "Updated", align = "end", priority = 2 },
}

local function priorityCell(issue: Issue): Cell
	local tone = PRIORITY_TONES[issue.priority]
	if tone == nil then
		return ""
	end
	return { badge = { text = model.priorityLabel(issue.priority), tone = tone } }
end

local function tableRow(issue: Issue, now: number): TableRow
	local assignee = issue.assignee
	return {
		id = issue.id,
		cells = {
			issue.identifier,
			issue.title,
			{ text = issue.state.name, dot = STATE_TONES[issue.state.type] or "muted" },
			priorityCell(issue),
			if assignee ~= nil then assignee.displayName else "",
			model.relativeTime(issue.updatedAt, now),
		},
	}
end

local function sortBar(state: BlockState): Node
	local children: { Node } = { ui.node("text", { key = "label", spans = { ui.span("Sort", "muted") } }) }
	for _, entry in SORT_COLUMNS do
		local active = state.prefs.sort == entry.key
		local arrow = if not active then "" elseif state.prefs.sortAsc then " ↑" else " ↓"
		table.insert(
			children,
			ui.button(entry.label .. arrow, {
				key = `sort-{entry.key}`,
				role = `linear.sort-{entry.key}`,
				variant = "quiet",
				size = "sm",
				on = active,
				actions = { click = `sort={entry.key}` },
			})
		)
	end
	return ui.node("row", { key = "sort", role = "linear.sort", gap = "xs", wrap = true }, children)
end

local function issueTable(state: BlockState, visible: { Issue }, now: number): Node
	local sorted = model.sortTable(visible, state.prefs.sort, state.prefs.sortAsc)
	local rows: { TableRow } = {}
	for _, issue in sorted do
		table.insert(rows, tableRow(issue, now))
	end
	local node = ui.table(TABLE_COLUMNS, rows, { selectable = true, selected = state.selectedId })
	return with(node, { key = "table", role = "linear.table" })
end

-- ─── Content ────────────────────────────────────────────────────────────────

local function emptyState(state: BlockState): { Node }
	local filtered = filtersActive(state)
	local prefs = state.prefs
	local nodes: { Node } = {
		ui.node("empty", {
			key = "content",
			role = "linear.empty",
			variant = "center",
			icon = if filtered then "funnel-x" else "inbox",
			title = if filtered then "No matching issues" else "No issues in this view",
		}),
	}
	local buttons: { Node } = {}
	if filtered then
		table.insert(
			buttons,
			ui.button("Clear filters", {
				key = "empty-clear-filters",
				role = "linear.empty-clear-filters",
				icon = "funnel-x",
				actions = { click = "clear-filters" },
			})
		)
	elseif prefs.scope == "mine" and prefs.view == "active" then
		table.insert(
			nodes,
			ui.node("text", {
				key = "empty-hint",
				role = "linear.empty-hint",
				spans = { ui.span("Nothing assigned to you is active.", "muted") },
			})
		)
		table.insert(
			buttons,
			ui.button("All", { key = "empty-all", role = "linear.empty-all", actions = { click = "view=all" } })
		)
		if #state.teams > 0 then
			table.insert(
				buttons,
				ui.button("Choose team", {
					key = "empty-team",
					role = "linear.empty-team",
					actions = { click = "focus-team" },
				})
			)
		end
	end
	if #buttons > 0 then
		table.insert(
			nodes,
			ui.node("row", { key = "empty-actions", role = "linear.empty-actions", gap = "sm" }, buttons)
		)
	end
	return nodes
end

local function content(state: BlockState, cx: BlockCx, visible: { Issue }, team: Team?, now: number): { Node }
	if state.reloading then
		return { reloadingNode() }
	end
	if #visible == 0 then
		return emptyState(state)
	end
	if state.prefs.layout == "table" then
		return { sortBar(state), issueTable(state, visible, now) }
	end
	return { board(state, cx, visible, team) }
end

local function readyChildren(state: BlockState, cx: BlockCx): { Node }
	local now = os.time()
	local team = selectedTeam(state)
	local viewerId = if state.viewer ~= nil then state.viewer.user.id else nil
	local visible = model.visible(state.issues, state.prefs, state.query.text, viewerId)
	local failure = state.error
	local notice = state.notice
	local children = compact({
		topBar(state, now),
		filterRow(state, team, #visible),
		if failure ~= nil then banner("error", "linear.error", "error", "x-circle", failure) else nil,
		if notice ~= nil then banner("notice", "linear.notice", "success", "check", notice) else nil,
	}, 4)
	for _, node in content(state, cx, visible, team, now) do
		table.insert(children, node)
	end
	return children
end

-- ─── Public API ─────────────────────────────────────────────────────────────

function view.render(state: BlockState, cx: BlockCx): BlockView
	local children: { Node }
	if state.phase == "setup" then
		children = { setupCard(state) }
	elseif state.phase == "loading" then
		children = { loadingNode() }
	else
		children = readyChildren(state, cx)
	end
	return {
		main = ui.node("col", { role = "linear.app", gap = "md" }, children),
		layer = detail.layer(state, cx),
	}
end

function view.fieldId(name: string): string
	if name == "search" then
		return SEARCH_FIELD_ID
	elseif name == "setup" then
		return SETUP_FIELD_ID
	end
	return detail.fieldId(name) or ""
end

function view.fieldName(id: string): string?
	if id == SEARCH_FIELD_ID then
		return "search"
	elseif id == SETUP_FIELD_ID then
		return "setup"
	end
	return detail.fieldName(id)
end

return view
