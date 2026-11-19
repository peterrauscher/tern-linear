--!strict
-- The `main` region: setup screen, top bar, filters, board, table, project board, empty and error states.
-- Pure: nothing here mutates state. The drawer and dialogs come from view_detail as the `layer`.

local detail = require("./view_detail")
local model = require("./model")
local types = require("./types")

type BlockState = types.BlockState
type Issue = types.Issue
type Project = types.Project
type Team = types.Team
type Column = model.Column
type ProjectColumn = model.ProjectColumn

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

-- Project statuses map to tones the same way; planned and paused have no issue-state counterpart.
local PROJECT_STATUS_TONES: { [string]: string } = {
	backlog = "muted",
	planned = "neutral",
	started = "warning",
	paused = "info",
	completed = "success",
	canceled = "muted",
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
local MAX_CARD_TEAMS = 2
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

local function projectFiltersActive(state: BlockState): boolean
	local prefs = state.prefs
	return prefs.projectTeamId ~= nil or prefs.projectLead ~= nil or string.match(state.query.text, "%S") ~= nil
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

local function pluralProjects(count: number): string
	return if count == 1 then "1 project" else `{count} projects`
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
local function reloadingNode(projects: boolean): Node
	local label = if projects then "Loading projects…" else "Loading issues…"
	return ui.node("row", { key = "content", role = "linear.reloading", gap = "sm" }, {
		ui.node("spinner", { key = "spinner", style = "braille" }),
		ui.node("text", { key = "label", spans = { ui.span(label, "muted") } }),
	})
end

-- ─── Top bar ────────────────────────────────────────────────────────────────

local function scopeSelect(state: BlockState): Node
	local options: { { value: string, label: string } } = {
		{ value = "mine", label = "My issues" },
		{ value = "projects", label = "Projects" },
	}
	for _, team in state.teams do
		table.insert(options, { value = team.id, label = `{team.key} · {team.name}` })
	end
	local prefs = state.prefs
	local value = "mine"
	if prefs.scope == "projects" then
		value = "projects"
	elseif prefs.scope == "team" and prefs.teamId ~= nil then
		value = prefs.teamId
	end
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
		placeholder = if state.prefs.scope == "projects" then "Search projects" else "Search issues",
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
		if state.prefs.scope == "projects" then nil else layoutSwitcher(state),
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

-- The scope's controls, then "Clear filters" while any filter is on, and the count of what is shown.
local function filterBar(state: BlockState, controls: { Node }, active: boolean, summary: { Span | string }): Node
	local children: { Node } = {}
	for _, control in controls do
		table.insert(children, control)
	end
	if active then
		local clear = ui.button("Clear filters", {
			key = "clear-filters",
			role = "linear.clear-filters",
			variant = "quiet",
			icon = "funnel-x",
			actions = { click = "clear-filters" },
		})
		table.insert(children, clear)
	end
	table.insert(children, ui.node("row", { key = "spacer", grow = 1 }))
	-- Counts of a list that is being replaced would be wrong.
	if not state.reloading then
		table.insert(children, ui.node("text", { key = "count", role = "linear.count", spans = summary }))
	end
	return ui.node("row", { key = "filters", role = "linear.filters", gap = "sm", wrap = true }, children)
end

local function filterRow(state: BlockState, team: Team?, visibleCount: number): Node
	local summary: { Span | string } = { ui.span(pluralIssues(visibleCount), "muted") }
	if state.truncated then
		table.insert(summary, ui.span(`  ·  Showing first {#state.issues}`, "warning"))
	end
	local controls = { prioritySelect(state), assigneeSelect(state, team), labelSelect(state, team) }
	return filterBar(state, controls, filtersActive(state), summary)
end

local function projectTeamSelect(state: BlockState): Node
	local options: { { value: string, label: string } } = { { value = "", label = "Any team" } }
	for _, team in state.teams do
		table.insert(options, { value = team.id, label = `{team.key} · {team.name}` })
	end
	return ui.node("select", {
		key = "filter-project-team",
		role = "linear.filter-team",
		value = state.prefs.projectTeamId or "",
		options = options,
		variant = "quiet",
		aria = "Team filter",
	})
end

-- Everyone who can lead a project: team members and the leads of the loaded projects, without the viewer.
local function projectLeads(state: BlockState, viewerId: string?): { types.User }
	local seen: { [string]: boolean } = {}
	local leads: { types.User } = {}
	local function add(user: types.User)
		if user.id ~= viewerId and not seen[user.id] then
			seen[user.id] = true
			table.insert(leads, user)
		end
	end
	for _, team in state.teams do
		for _, member in team.members do
			add(member)
		end
	end
	for _, project in state.projects do
		if project.lead ~= nil then
			add(project.lead)
		end
	end
	table.sort(leads, function(a, b)
		local nameA, nameB = string.lower(a.displayName), string.lower(b.displayName)
		if nameA ~= nameB then
			return nameA < nameB
		end
		return a.id < b.id
	end)
	return leads
end

local function projectLeadSelect(state: BlockState, viewerId: string?): Node
	local options: { { value: string, label: string } } = {
		{ value = "", label = "Any lead" },
		{ value = "me", label = "Me" },
		{ value = "none", label = "No lead" },
	}
	for _, user in projectLeads(state, viewerId) do
		table.insert(options, { value = user.id, label = user.displayName })
	end
	return ui.node("select", {
		key = "filter-project-lead",
		role = "linear.filter-lead",
		value = state.prefs.projectLead or "",
		options = options,
		variant = "quiet",
		aria = "Lead filter",
	})
end

local function projectFilterRow(state: BlockState, viewerId: string?, visibleCount: number): Node
	local summary: { Span | string } = { ui.span(pluralProjects(visibleCount), "muted") }
	if state.truncated then
		table.insert(summary, ui.span(`  ·  Showing first {#state.projects}`, "warning"))
	end
	local controls = { projectTeamSelect(state), projectLeadSelect(state, viewerId) }
	return filterBar(state, controls, projectFiltersActive(state), summary)
end

-- ─── Banners ────────────────────────────────────────────────────────────────

local function banner(key: string, role: string, tone: string, icon: string, message: string): Node
	return ui.node("row", { key = key, role = role, tone = tone, gap = "sm" }, {
		ui.node("icon", { key = "icon", name = icon, tone = tone }),
		ui.node("text", { key = "text", spans = { message }, grow = 1 }),
	})
end

-- ─── Board ──────────────────────────────────────────────────────────────────

local function stateDot(stateType: string, tones: { [string]: string }): Node
	return ui.node("text", {
		key = "dot",
		role = "linear.state-dot",
		tone = tones[stateType] or "muted",
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

type ColumnParts = {
	id: string,
	stateType: string,
	title: string,
	dot: Node,
	cards: { Node },
	-- Placeholder text of a column without cards.
	empty: string,
}

-- One column: a head (state dot, title, count) above a scroll of cards, or a placeholder when it has none.
local function statusColumn(parts: ColumnParts, lines: number): Node
	local cards = parts.cards
	local count = #cards
	if count == 0 then
		table.insert(
			cards,
			ui.node("text", { key = "none", role = "linear.column-empty", spans = { ui.span(parts.empty, "dim") } })
		)
	end
	local head = ui.node("row", { key = "head", role = "linear.column-head", gap = "sm" }, {
		parts.dot,
		ui.node("text", { key = "title", spans = { ui.span(parts.title, "strong") } }),
		ui.node("text", { key = "count", spans = { ui.span(tostring(count), "muted") } }),
	})
	return ui.node("col", {
		key = parts.id,
		role = "linear.column",
		mark = parts.stateType,
		gap = "sm",
		grow = 1,
		basis = 0,
		min = { w = COLUMN_MIN_WIDTH },
	}, {
		head,
		ui.node("scroll", { key = "cards", gap = "sm", max = { h = `{lines}lines` } }, cards),
	})
end

local function boardColumn(column: Column, selectedId: string?, lines: number): Node
	local cards: { Node } = {}
	for _, issue in column.issues do
		table.insert(cards, issueCard(issue, selectedId))
	end
	return statusColumn({
		id = column.id,
		stateType = column.stateType,
		title = column.title,
		dot = stateDot(column.stateType, STATE_TONES),
		cards = cards,
		empty = "No issues",
	}, lines)
end

-- The team keys of a project, as many as fit a card with the rest counted; the tooltip names every team.
local function projectTeams(project: Project): Node?
	local teams = project.teams
	if #teams == 0 then
		return nil
	end
	local keys: { string } = {}
	local names: { string } = {}
	for index, team in teams do
		table.insert(names, team.name)
		if index <= MAX_CARD_TEAMS then
			table.insert(keys, team.key)
		end
	end
	local label = table.concat(keys, " · ")
	if #teams > MAX_CARD_TEAMS then
		label ..= ` +{#teams - MAX_CARD_TEAMS}`
	end
	return ui.node("text", {
		key = "teams",
		title = table.concat(names, ", "),
		spans = { ui.span(label, "mono muted") },
	})
end

local function projectCardHead(project: Project): Node
	local priorityTone = PRIORITY_TONES[project.priority]
	local health = detail.healthBadge(project.health)
	local children = compact({
		projectTeams(project),
		ui.node("row", { key = "spacer", grow = 1 }),
		if health ~= nil then with(health, { key = "health" }) else nil,
		if priorityTone ~= nil
			then with(ui.badge(model.priorityLabel(project.priority), priorityTone), {
				key = "priority",
				mark = `priority-{project.priority}`,
			})
			else nil,
	}, 4)
	return ui.node("row", { key = "head", gap = "xs" }, children)
end

local function projectSummary(project: Project): Node?
	if string.match(project.description, "%S") == nil then
		return nil
	end
	return ui.node("text", {
		key = "summary",
		role = "linear.project-summary",
		max = { h = "2lines" },
		spans = { ui.span(project.description, "muted") },
	})
end

local function targetDate(project: Project): Node?
	local date = project.targetDate
	if date == nil then
		return nil
	end
	return ui.node("text", { key = "target", mark = "target", spans = { ui.span(`Target {date}`, "muted") } })
end

-- Tern's progress bar with the percentage as its label; closed projects take their status tone, open ones the accent.
local function projectProgress(project: Project): Node
	local statusType = project.status.type
	local percent = model.progressPercent(project.progress)
	local tone = if model.isClosedProjectType(statusType) then PROJECT_STATUS_TONES[statusType] else nil
	local bar = with(ui.progress(project.progress, { ui.span(`{percent}%`, "mono muted") }), {
		key = "bar",
		role = "linear.project-progress",
		tone = tone,
		grow = 1,
	})
	return ui.node("row", { key = "progress", gap = "sm", wrap = true }, compact({ bar, targetDate(project) }, 2))
end

local function projectLead(project: Project): Node?
	local lead = project.lead
	if lead == nil then
		return nil
	end
	return ui.node("text", {
		key = "lead",
		role = "linear.card-assignee",
		title = lead.name,
		spans = { ui.span(lead.displayName, "muted") },
	})
end

local function projectCard(project: Project, selectedId: string?): Node
	local children = compact({
		projectCardHead(project),
		ui.node("text", {
			key = "title",
			role = "linear.card-title",
			max = { h = "2lines" },
			spans = { ui.span(project.name, "strong") },
		}),
		projectSummary(project),
		projectProgress(project),
		projectLead(project),
	}, 5)
	return ui.node("col", {
		key = project.id,
		role = "linear.project-card",
		gap = "xs",
		mark = if project.id == selectedId then "selected" else nil,
		actions = { click = `select={project.id}` },
	}, children)
end

local function projectColumn(column: ProjectColumn, selectedId: string?, lines: number): Node
	local cards: { Node } = {}
	for _, project in column.projects do
		table.insert(cards, projectCard(project, selectedId))
	end
	return statusColumn({
		id = column.id,
		stateType = column.statusType,
		title = column.title,
		dot = stateDot(column.statusType, PROJECT_STATUS_TONES),
		cards = cards,
		empty = "No projects",
	}, lines)
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

local function columnLines(state: BlockState, cx: BlockCx): number
	return math.max(MIN_COLUMN_LINES, cx.rows - chromeRows(state, cx))
end

local function board(state: BlockState, cx: BlockCx, visible: { Issue }, team: Team?): Node
	local columns = model.columns(visible, state.prefs, team)
	local lines = columnLines(state, cx)
	local children: { Node } = {}
	for _, column in columns do
		table.insert(children, boardColumn(column, state.selectedId, lines))
	end
	return ui.node("row", { key = "content", role = "linear.board", gap = "md", align = "start" }, children)
end

local function projectBoard(state: BlockState, cx: BlockCx, visible: { Project }): Node
	local columns = model.projectColumns(visible, state.prefs.view)
	local lines = columnLines(state, cx)
	local children: { Node } = {}
	for _, column in columns do
		table.insert(children, projectColumn(column, state.returnProjectId or state.selectedId, lines))
	end
	return ui.node("row", { key = "content", role = "linear.projects-board", gap = "md", align = "start" }, children)
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
	local prefs = state.prefs
	local projects = prefs.scope == "projects"
	local filtered = if projects then projectFiltersActive(state) else filtersActive(state)
	local noun = if projects then "projects" else "issues"
	local nodes: { Node } = {
		ui.node("empty", {
			key = "content",
			role = "linear.empty",
			variant = "center",
			icon = if filtered then "funnel-x" else "inbox",
			title = if filtered then `No matching {noun}` else `No {noun} in this view`,
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
	elseif projects then
		if prefs.view ~= "all" then
			table.insert(
				buttons,
				ui.button("All", { key = "empty-all", role = "linear.empty-all", actions = { click = "view=all" } })
			)
		end
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
		return { reloadingNode(false) }
	end
	if #visible == 0 then
		return emptyState(state)
	end
	if state.prefs.layout == "table" then
		return { sortBar(state), issueTable(state, visible, now) }
	end
	return { board(state, cx, visible, team) }
end

local function projectContent(state: BlockState, cx: BlockCx, visible: { Project }): { Node }
	if state.reloading then
		return { reloadingNode(true) }
	end
	if #visible == 0 then
		return emptyState(state)
	end
	return { projectBoard(state, cx, visible) }
end

local function readyChildren(state: BlockState, cx: BlockCx): { Node }
	local now = os.time()
	local viewerId = if state.viewer ~= nil then state.viewer.user.id else nil
	local filters: Node
	local body: { Node }
	if state.prefs.scope == "projects" then
		local visible = model.visibleProjects(state.projects, state.prefs, state.query.text, viewerId)
		filters = projectFilterRow(state, viewerId, #visible)
		body = projectContent(state, cx, visible)
	else
		local team = selectedTeam(state)
		local visible = model.visible(state.issues, state.prefs, state.query.text, viewerId)
		filters = filterRow(state, team, #visible)
		body = content(state, cx, visible, team, now)
	end
	local failure = state.error
	local notice = state.notice
	local children = compact({
		topBar(state, now),
		filters,
		if failure ~= nil then banner("error", "linear.error", "error", "x-circle", failure) else nil,
		if notice ~= nil then banner("notice", "linear.notice", "success", "check", notice) else nil,
	}, 4)
	for _, node in body do
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
