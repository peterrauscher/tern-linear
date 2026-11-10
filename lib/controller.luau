--!strict
-- The `linear.board` block: state, requests, polling, forms, keys and events.
-- The controller is the only module that mutates `BlockState`; views only read it.
-- Contract: docs/ARCHITECTURE.md (request discipline, actions, select keys, keys).

local credentials = require("./credentials")
local linear = require("./linear")
local model = require("./model")
local text = require("./text")
local types = require("./types")
local view = require("./view")

type BlockState = types.BlockState
type Issue = types.Issue
type Team = types.Team
type ApiError = types.ApiError
type Field = types.Field
type Form = types.Form
type FormField = types.FormField
type FormOption = types.FormOption
type Prefs = types.Prefs
type Patch = { [string]: any }

local POLL_MS = 30000
local FULL_RELOAD_MS = 300000
local NOTICE_MS = 4000
local DETAIL_DEBOUNCE_MS = 250
local DEFAULT_BACKOFF_MS = 60000

local SORT_KEYS: { [string]: boolean } = {
	identifier = true,
	title = true,
	state = true,
	priority = true,
	assignee = true,
	updated = true,
}

-- ─── Run registry ───────────────────────────────────────────────────────────
-- One Run per live block. Pane ids are reused after a restart, so every
-- callback checks that the registry still maps its pane to *its* state.

type Run = {
	state: BlockState,
	cfg: types.Config?,
	poll: TimerHandle?,
	noticeTimer: TimerHandle?,
	detailTimer: TimerHandle?,
	-- Bumped whenever the drawer's detail request is superseded.
	detailToken: number,
	-- What the in-flight foreground request is: only loads may supersede loads.
	fgKind: ("load" | "mutation")?,
	-- tern.now() of the last successful board load.
	lastFullAt: number,
	focusQueued: boolean,
	-- A reload was asked for while another background read was in flight.
	reloadQueued: boolean,
	-- `e` pressed before the detail arrived: open the edit form once it does.
	editAfterLoad: string?,
	-- The viewer and team list loaded; until then polls retry the full load instead of the issues alone.
	metaReady: boolean,
}

local runs: { [number]: Run } = {}

local function runOf(state: BlockState): Run?
	local run = runs[state.cx.pane]
	if run ~= nil and run.state == state then
		return run
	end
	return nil
end

local function cancelTimer(handle: TimerHandle?)
	if handle ~= nil then
		handle:cancel()
	end
end

local function retire(run: Run)
	cancelTimer(run.poll)
	cancelTimer(run.noticeTimer)
	cancelTimer(run.detailTimer)
	run.poll = nil
	run.noticeTimer = nil
	run.detailTimer = nil
	if runs[run.state.cx.pane] == run then
		runs[run.state.cx.pane] = nil
	end
end

local function paneExists(pane: number): boolean
	for _, info in tern.pane.list() do
		if info.pane == pane then
			return true
		end
	end
	return false
end

-- The run of a block that is still on screen; retires runs whose pane is gone.
local function liveRun(state: BlockState): Run?
	local run = runOf(state)
	if run == nil then
		return nil
	end
	if not paneExists(state.cx.pane) then
		retire(run)
		return nil
	end
	return run
end

-- ─── Pure helpers ───────────────────────────────────────────────────────────

local function nowMs(): number
	return os.time() * 1000
end

local function rateMessage(waitMs: number): string
	return string.format("Rate limited by Linear; retrying in %ds", math.ceil(waitMs / 1000))
end

local function isRateMessage(message: string?): boolean
	return message ~= nil and string.find(message, "^Rate limited") ~= nil
end

local function unknownError(): ApiError
	return { kind = "server", message = "Linear returned no data." }
end

local VIEWS: { [string]: "active" | "backlog" | "all" } = { active = "active", backlog = "backlog", all = "all" }
local LAYOUTS: { [string]: "board" | "table" } = { board = "board", table = "table" }
local LINK_MODES: { [string]: "blocked-by" | "blocks" | "related" } = {
	["blocked-by"] = "blocked-by",
	blocks = "blocks",
	related = "related",
}

local function parseView(value: any): ("active" | "backlog" | "all")?
	return if type(value) == "string" then VIEWS[value] else nil
end

local function parseLayout(value: any): ("board" | "table")?
	return if type(value) == "string" then LAYOUTS[value] else nil
end

local function parseLinkMode(value: any): ("blocked-by" | "blocks" | "related")?
	return if type(value) == "string" then LINK_MODES[value] else nil
end

-- Every saved field is checked against its allowed values; anything else falls back.
local function restorePrefs(saved: any): Prefs
	local prefs: Prefs = { scope = "mine", view = "active", layout = "board", sort = "updated", sortAsc = false }
	if type(saved) ~= "table" then
		return prefs
	end
	local data = saved :: { [string]: any }
	if type(data.teamId) == "string" then
		prefs.teamId = data.teamId
		if data.scope == "team" then
			prefs.scope = "team"
		end
	end
	prefs.view = parseView(data.view) or prefs.view
	prefs.layout = parseLayout(data.layout) or prefs.layout
	if type(data.sort) == "string" and SORT_KEYS[data.sort] then
		prefs.sort = data.sort
	end
	if type(data.sortAsc) == "boolean" then
		prefs.sortAsc = data.sortAsc
	end
	return prefs
end

local function newState(cx: BlockCx, prefs: Prefs): BlockState
	return {
		cx = cx,
		phase = "loading",
		keySource = nil,
		setupKey = text.new(""),
		setupError = nil,
		viewer = nil,
		teams = {},
		issues = {},
		truncated = false,
		fetchedAt = nil,
		maxUpdatedAt = nil,
		prefs = prefs,
		query = text.new(""),
		focus = nil,
		selectedId = nil,
		detail = nil,
		detailLoading = false,
		drawerOpen = false,
		comment = text.new(""),
		link = nil,
		form = nil,
		busy = false,
		refreshing = false,
		reloading = false,
		controlEpoch = 0,
		generation = 0,
		error = nil,
		notice = nil,
		backoffUntil = nil,
	}
end

local function findIssue(state: BlockState, id: string): Issue?
	for _, issue in state.issues do
		if issue.id == id then
			return issue
		end
	end
	local detail = state.detail
	if detail ~= nil and detail.id == id then
		return detail
	end
	return nil
end

local function selectedIssue(state: BlockState): Issue?
	local id = state.selectedId
	if id == nil then
		return nil
	end
	return findIssue(state, id)
end

local function teamById(state: BlockState, id: string?): Team?
	if id == nil then
		return nil
	end
	for _, team in state.teams do
		if team.id == id then
			return team
		end
	end
	return nil
end

local function viewerId(state: BlockState): string?
	local viewer = state.viewer
	if viewer == nil then
		return nil
	end
	return viewer.user.id
end

-- The team whose workflow states form the board columns (team scope only).
local function scopeTeam(state: BlockState): Team?
	if state.prefs.scope ~= "team" then
		return nil
	end
	return teamById(state, state.prefs.teamId)
end

local function stringValue(value: any): string?
	if type(value) == "string" then
		return value
	elseif type(value) == "number" then
		return tostring(value)
	end
	return nil
end

-- ─── Focus ──────────────────────────────────────────────────────────────────
-- `state.focus` routes keys; the frame op only moves the native caret. The op
-- is deferred a tick so a field that appears in the same handler is drawn first.

local function focusTarget(state: BlockState): string?
	local focus = state.focus
	if focus == nil then
		return nil
	end
	if focus == "form" then
		local form = state.form
		if form == nil then
			return nil
		end
		local field = form.fields[form.focus]
		if field == nil or field.kind == "choice" then
			return nil
		end
		return view.fieldId("form:" .. field.name)
	end
	return view.fieldId(focus)
end

local function syncFocus(state: BlockState)
	local run = runOf(state)
	if run == nil or run.focusQueued then
		return
	end
	run.focusQueued = true
	tern.timer(0, function()
		local live = liveRun(state)
		if live == nil then
			return
		end
		live.focusQueued = false
		local focusOp: { any } = { "focus", focusTarget(state) or tern.json.null }
		state.cx:frame({ focusOp })
	end)
end

local function setFocus(state: BlockState, name: string?)
	state.focus = name
	syncFocus(state)
end

-- Clicking something else leaves a search/comment/link field.
local function blurTextFocus(state: BlockState)
	local focus = state.focus
	if focus == "search" or focus == "comment" or focus == "link" then
		setFocus(state, nil)
	end
end

-- ─── Notice ─────────────────────────────────────────────────────────────────

local function setNotice(state: BlockState, run: Run, message: string)
	state.notice = message
	cancelTimer(run.noticeTimer)
	run.noticeTimer = tern.timer(NOTICE_MS, function()
		local live = liveRun(state)
		if live == nil then
			return
		end
		live.noticeTimer = nil
		if state.notice == message then
			state.notice = nil
			state.cx:render()
		end
	end)
end

-- ─── Selection and drawer ───────────────────────────────────────────────────

local function dropEditForm(state: BlockState)
	local form = state.form
	if form ~= nil and form.kind == "edit" then
		state.form = nil
		if state.focus == "form" then
			setFocus(state, nil)
		end
	end
end

-- The link input and the inline edit form belong to the open drawer.
local function dropDrawerInputs(state: BlockState, run: Run)
	state.link = nil
	run.editAfterLoad = nil
	dropEditForm(state)
	if state.focus == "comment" or state.focus == "link" then
		setFocus(state, nil)
	end
end

local function supersedeDetail(state: BlockState, run: Run)
	run.detailToken += 1
	cancelTimer(run.detailTimer)
	run.detailTimer = nil
	state.detailLoading = false
end

local function closeDrawer(state: BlockState, run: Run)
	state.drawerOpen = false
	supersedeDetail(state, run)
	dropDrawerInputs(state, run)
end

local function clearSelection(state: BlockState, run: Run)
	closeDrawer(state, run)
	state.selectedId = nil
	state.detail = nil
	text.set(state.comment, "")
end

-- ─── Errors and setup ───────────────────────────────────────────────────────

local function resetData(state: BlockState, run: Run)
	state.generation += 1
	state.busy = false
	run.fgKind = nil
	state.reloading = false
	run.metaReady = false
	run.reloadQueued = false
	supersedeDetail(state, run)
	run.editAfterLoad = nil
	state.viewer = nil
	state.teams = {}
	state.issues = {}
	state.truncated = false
	state.fetchedAt = nil
	state.maxUpdatedAt = nil
	state.selectedId = nil
	state.detail = nil
	state.drawerOpen = false
	text.set(state.comment, "")
	state.link = nil
	state.form = nil
	state.error = nil
	state.notice = nil
	state.backoffUntil = nil
end

local function enterSetup(state: BlockState, run: Run, message: string?)
	resetData(state, run)
	run.cfg = nil
	state.keySource = nil
	state.phase = "setup"
	state.setupError = message
	text.set(state.setupKey, "")
	setFocus(state, "setup")
end

-- Routes a failed request: auth → setup, rate → backoff, everything else → inline or banner.
local function fail(state: BlockState, err: ApiError, inline: ((string) -> ())?)
	local run = runOf(state)
	if run == nil then
		return
	end
	if err.kind == "auth" then
		if state.keySource == "env" then
			state.error = "Linear rejected the API key in LINEAR_API_KEY."
		else
			enterSetup(state, run, "Linear rejected the API key.")
		end
		return
	end
	if err.kind == "rate" then
		local waitMs = err.retryAfterMs or DEFAULT_BACKOFF_MS
		state.backoffUntil = nowMs() + waitMs
		local message = rateMessage(waitMs)
		state.error = message
		if inline ~= nil then
			inline(message)
		end
		return
	end
	if inline ~= nil then
		inline(err.message)
	else
		state.error = err.message
	end
end

-- ─── Applying results ───────────────────────────────────────────────────────

local function replaceIssue(list: { Issue }, issue: Issue): boolean
	for index, existing in list do
		if existing.id == issue.id then
			list[index] = issue
			return true
		end
	end
	return false
end

-- A mutation's payload may omit the detail-only fields the drawer already has.
local function mergeDetail(old: Issue, fresh: Issue): Issue
	if fresh.detailed then
		return fresh
	end
	local merged = table.clone(fresh)
	merged.description = old.description
	merged.comments = old.comments
	merged.detailed = old.detailed
	return merged
end

local function applyIssue(state: BlockState, issue: Issue, insertIfNew: boolean)
	if not replaceIssue(state.issues, issue) and insertIfNew then
		table.insert(state.issues, 1, issue)
	end
	local detail = state.detail
	if detail ~= nil and detail.id == issue.id then
		state.detail = mergeDetail(detail, issue)
	end
end

local function commitIssues(state: BlockState, run: Run, page: types.IssuePage)
	state.issues = page.issues
	state.truncated = page.truncated
	state.fetchedAt = os.time()
	local newest: string? = nil
	for _, issue in page.issues do
		if newest == nil or issue.updatedAt > newest then
			newest = issue.updatedAt
		end
	end
	state.maxUpdatedAt = newest
	run.lastFullAt = tern.now()
	local id = state.selectedId
	if id ~= nil and findIssue(state, id) == nil and not state.detailLoading then
		clearSelection(state, run)
	end
end

-- ─── Detail loads ───────────────────────────────────────────────────────────
-- Own flag and token; they never touch `busy`.

local openEditForm: (state: BlockState) -> ()

local function fetchDetail(state: BlockState, run: Run)
	local cfg = run.cfg
	local id = state.selectedId
	if cfg == nil or id == nil then
		return
	end
	run.detailToken += 1
	local token = run.detailToken
	linear.issue(cfg, id, function(issue, err)
		local live = liveRun(state)
		if live == nil or live.detailToken ~= token then
			return
		end
		state.detailLoading = false
		if issue ~= nil then
			state.error = nil
			state.detail = issue
			replaceIssue(state.issues, issue)
			if live.editAfterLoad == id then
				live.editAfterLoad = nil
				openEditForm(state)
			end
		else
			live.editAfterLoad = nil
			local failure = err or unknownError()
			if failure.kind == "notfound" and findIssue(state, id) == nil then
				clearSelection(state, live)
			end
			fail(state, failure, nil)
		end
		state.cx:render()
	end)
end

-- Loads the selected issue's detail now, or after `delayMs` (keyboard navigation).
local function requestDetail(state: BlockState, run: Run, delayMs: number)
	cancelTimer(run.detailTimer)
	run.detailTimer = nil
	local id = state.selectedId
	if id == nil then
		return
	end
	local detail = state.detail
	if detail ~= nil and detail.id ~= id then
		state.detail = nil
		detail = nil
	end
	state.detailLoading = true
	run.detailToken += 1
	if delayMs <= 0 then
		fetchDetail(state, run)
		return
	end
	run.detailTimer = tern.timer(delayMs, function()
		local live = liveRun(state)
		if live == nil then
			return
		end
		live.detailTimer = nil
		if state.selectedId == id and state.drawerOpen then
			fetchDetail(state, live)
		end
	end)
end

local function selectIssue(state: BlockState, run: Run, id: string, open: boolean, delayMs: number)
	local changed = state.selectedId ~= id
	if changed then
		state.selectedId = id
		text.set(state.comment, "")
		dropDrawerInputs(state, run)
		supersedeDetail(state, run)
		local detail = state.detail
		if detail ~= nil and detail.id ~= id then
			state.detail = nil
		end
	end
	local wasOpen = state.drawerOpen
	if open then
		state.drawerOpen = true
	end
	if state.drawerOpen and (changed or not wasOpen or (state.detail == nil and not state.detailLoading)) then
		requestDetail(state, run, delayMs)
	end
end

-- ─── Background reads ───────────────────────────────────────────────────────

local reloadIssues: (state: BlockState, run: Run) -> ()

local function runQueuedReload(state: BlockState, run: Run)
	if run.reloadQueued then
		run.reloadQueued = false
		reloadIssues(state, run)
	end
end

reloadIssues = function(state: BlockState, run: Run)
	local cfg = run.cfg
	if cfg == nil or state.phase ~= "ready" then
		return
	end
	if state.refreshing then
		run.reloadQueued = true
		return
	end
	state.refreshing = true
	local generation = state.generation
	linear.issues(cfg, model.serverFilter(state.prefs), function(page, err)
		local live = liveRun(state)
		if live == nil then
			return
		end
		if state.generation == generation then
			if page ~= nil then
				commitIssues(state, live, page)
				state.error = nil
			elseif err ~= nil then
				fail(state, err, nil)
			end
		end
		state.cx:render()
		runQueuedReload(state, live)
	end)
end

-- Authoritative reload after a mutation: the board, and the drawer if open.
local function reloadAfterMutation(state: BlockState, run: Run)
	reloadIssues(state, run)
	if state.drawerOpen and state.selectedId ~= nil then
		requestDetail(state, run, 0)
	end
end

-- ─── Foreground requests ────────────────────────────────────────────────────

-- Returns the new generation, or nil when a foreground request already owns `busy`.
-- A load may supersede a load; a mutation never supersedes anything.
local function beginForeground(state: BlockState, run: Run, kind: "load" | "mutation"): number?
	if state.busy and not (kind == "load" and run.fgKind == "load") then
		return nil
	end
	state.busy = true
	state.generation += 1
	run.fgKind = kind
	return state.generation
end

-- Liveness plus "not superseded" check for a foreground completion.
local function current(state: BlockState, generation: number): Run?
	local run = liveRun(state)
	if run ~= nil and state.generation == generation then
		return run
	end
	return nil
end

local function settle(state: BlockState, run: Run)
	state.busy = false
	state.reloading = false
	run.fgKind = nil
end

-- Tern restores a select only when its `value` prop changes, so a pick that was not applied needs a
-- remount (the epoch is part of every select's key) to show the authoritative value again.
local function bumpControls(state: BlockState)
	state.controlEpoch += 1
end

-- A mutation is in flight: form fields must not change under a form that success is about to close.
local function formLocked(state: BlockState, run: Run): boolean
	return state.busy and run.fgKind == "mutation"
end

-- viewer (when unknown) → teams → issues; `issuesOnly` skips straight to the issues.
local function loadAll(state: BlockState, issuesOnly: boolean)
	local run = runOf(state)
	if run == nil then
		return
	end
	local cfg = run.cfg
	if cfg == nil then
		return
	end
	local generation = beginForeground(state, run, "load")
	if generation == nil then
		return
	end
	state.reloading = state.phase == "ready"

	local function failed(err: ApiError?)
		local live = current(state, generation)
		if live == nil then
			return
		end
		settle(state, live)
		if state.phase == "loading" then
			state.phase = "ready"
		end
		fail(state, err or unknownError(), nil)
		state.cx:render()
	end

	local function loadIssues()
		linear.issues(cfg, model.serverFilter(state.prefs), function(page, err)
			local live = current(state, generation)
			if live == nil then
				return
			end
			if page == nil then
				failed(err)
				return
			end
			settle(state, live)
			commitIssues(state, live, page)
			state.phase = "ready"
			state.error = nil
			if state.drawerOpen and state.selectedId ~= nil then
				requestDetail(state, live, 0)
			end
			state.cx:render()
		end)
	end

	local function loadTeams()
		linear.teams(cfg, function(teams, err)
			if current(state, generation) == nil then
				return
			end
			if teams == nil then
				failed(err)
				return
			end
			state.teams = teams
			run.metaReady = true
			if state.prefs.scope == "team" and teamById(state, state.prefs.teamId) == nil then
				state.prefs.scope = "mine"
				state.prefs.teamId = nil
			end
			loadIssues()
		end)
	end

	if issuesOnly then
		loadIssues()
	elseif state.viewer ~= nil then
		loadTeams()
	else
		linear.viewer(cfg, function(viewer, err)
			if current(state, generation) == nil then
				return
			end
			if viewer == nil then
				failed(err)
				return
			end
			state.viewer = viewer
			loadTeams()
		end)
	end
end

-- Runs one foreground mutation. `inline` receives failure text for a dialog or input;
-- without it failures land in the banner.
local function runMutation<T>(
	state: BlockState,
	inline: ((string) -> ())?,
	start: (types.Config, types.Callback<T>, () -> boolean) -> (),
	onSuccess: (T, Run) -> ()
)
	local run = runOf(state)
	if run == nil then
		return
	end
	local cfg = run.cfg
	if cfg == nil then
		return
	end
	local generation = beginForeground(state, run, "mutation")
	if generation == nil then
		return
	end
	-- `start` may chain requests; each hop checks this before it writes anything.
	local function alive(): boolean
		return current(state, generation) ~= nil
	end
	start(cfg, function(result: T?, err: ApiError?)
		local live = current(state, generation)
		if live == nil then
			return
		end
		settle(state, live)
		if result == nil then
			bumpControls(state)
			fail(state, err or unknownError(), inline)
		else
			state.error = nil
			onSuccess(result, live)
		end
		state.cx:render()
	end, alive)
end

-- ─── Polling ────────────────────────────────────────────────────────────────

local function pollAllowed(state: BlockState): boolean
	if state.phase ~= "ready" or state.busy or state.refreshing or state.form ~= nil then
		return false
	end
	local focus = state.focus
	return focus ~= "comment" and focus ~= "form" and focus ~= "link"
end

local function checkForChanges(state: BlockState, run: Run)
	local cfg = run.cfg
	if cfg == nil then
		return
	end
	state.refreshing = true
	local generation = state.generation
	linear.changedSince(cfg, model.serverFilter(state.prefs), state.maxUpdatedAt, function(newest, err)
		local live = liveRun(state)
		if live == nil then
			return
		end
		state.refreshing = false
		if state.generation == generation then
			if err ~= nil then
				fail(state, err, nil)
			else
				state.error = nil
				if newest ~= nil and (state.maxUpdatedAt == nil or newest > state.maxUpdatedAt) then
					reloadIssues(state, live)
				end
			end
		end
		state.cx:render()
		runQueuedReload(state, live)
	end)
end

local function tick(state: BlockState, run: Run)
	if run.cfg == nil then
		return
	end
	local backoff = state.backoffUntil
	if backoff ~= nil then
		local remaining = backoff - nowMs()
		if remaining > 0 then
			if isRateMessage(state.error) then
				state.error = rateMessage(remaining)
				state.cx:render()
			end
			return
		end
		state.backoffUntil = nil
		if isRateMessage(state.error) then
			state.error = nil
			state.cx:render()
		end
	end
	if not pollAllowed(state) then
		return
	end
	if not run.metaReady then
		loadAll(state, false)
		state.cx:render()
		return
	end
	if tern.now() - run.lastFullAt >= FULL_RELOAD_MS then
		reloadIssues(state, run)
	else
		checkForChanges(state, run)
	end
	if state.drawerOpen and state.selectedId ~= nil and not state.detailLoading then
		requestDetail(state, run, 0)
	end
end

-- A re-armed one-shot timer; it ends with the block's pane.
local function schedulePoll(state: BlockState, run: Run)
	run.poll = tern.timer(POLL_MS, function()
		local live = liveRun(state)
		if live == nil then
			return
		end
		schedulePoll(state, live)
		tick(state, live)
	end)
end

-- ─── Issue mutations ────────────────────────────────────────────────────────

local function updateIssue(state: BlockState, issue: Issue, patch: Patch, describe: (Issue) -> string)
	runMutation(state, nil, function(cfg: types.Config, done: types.Callback<Issue>)
		linear.updateIssue(cfg, issue.id, patch, done)
	end, function(updated: Issue, run: Run)
		applyIssue(state, updated, false)
		setNotice(state, run, describe(updated))
		reloadAfterMutation(state, run)
	end)
end

local function describeAssignee(state: BlockState, updated: Issue): string
	local assignee = updated.assignee
	if assignee == nil then
		return "Unassigned"
	end
	if assignee.id == viewerId(state) then
		return "Assigned to you"
	end
	return "Assigned to " .. assignee.displayName
end

local function moveToState(state: BlockState, issue: Issue, target: types.WorkflowState?, missing: string)
	if target == nil then
		state.error = missing
		return
	end
	if target.id == issue.state.id then
		return
	end
	updateIssue(state, issue, { stateId = target.id }, function(updated)
		return "Moved to " .. updated.state.name
	end)
end

local function issueTeam(state: BlockState, issue: Issue): Team?
	local team = teamById(state, issue.teamId)
	if team == nil then
		state.error = "Team " .. issue.teamKey .. " is not available."
	end
	return team
end

local function closeIssue(state: BlockState, issue: Issue)
	local team = issueTeam(state, issue)
	if team ~= nil then
		moveToState(state, issue, model.doneState(team), "Team " .. team.key .. " has no Done state.")
	end
end

local function reopenIssue(state: BlockState, issue: Issue)
	local team = issueTeam(state, issue)
	if team ~= nil then
		moveToState(state, issue, model.todoState(team), "Team " .. team.key .. " has no Todo state.")
	end
end

local function toggleClosed(state: BlockState, issue: Issue)
	if model.isClosedType(issue.state.type) then
		reopenIssue(state, issue)
	else
		closeIssue(state, issue)
	end
end

local function moveAdjacent(state: BlockState, run: Run, issue: Issue, delta: number)
	local team = issueTeam(state, issue)
	if team == nil then
		return
	end
	local target = model.adjacentState(team, issue, delta, state.prefs.view)
	if target == nil then
		setNotice(state, run, if delta < 0 then "Already in the first column" else "Already in the last column")
		return
	end
	moveToState(state, issue, target, "")
end

local function setAssignee(state: BlockState, issue: Issue, userId: string?)
	local assignee: any = if userId == nil then tern.json.null else userId
	updateIssue(state, issue, { assigneeId = assignee }, function(updated)
		return describeAssignee(state, updated)
	end)
end

local function toggleAssignMe(state: BlockState, issue: Issue)
	local me = viewerId(state)
	if me == nil then
		return
	end
	local assignee = issue.assignee
	if assignee ~= nil and assignee.id == me then
		setAssignee(state, issue, nil)
	else
		setAssignee(state, issue, me)
	end
end

local function setPriority(state: BlockState, issue: Issue, priority: number)
	if priority == issue.priority then
		return
	end
	updateIssue(state, issue, { priority = priority }, function(updated)
		return "Priority: " .. updated.priorityLabel
	end)
end

local function submitComment(state: BlockState)
	local id = state.selectedId
	local body = text.trimmed(state.comment)
	if id == nil or body == "" then
		return
	end
	runMutation(state, nil, function(cfg: types.Config, done: types.Callback<types.Comment>)
		linear.createComment(cfg, id, body, done)
	end, function(comment: types.Comment, run: Run)
		if state.selectedId == id then
			if text.trimmed(state.comment) == body then
				text.set(state.comment, "")
			end
			local detail = state.detail
			if detail ~= nil and detail.id == id then
				local comments: { types.Comment } = detail.comments or {}
				local replaced = false
				for index, existing in comments do
					if existing.id == comment.id then
						comments[index] = comment
						replaced = true
						break
					end
				end
				if not replaced then
					table.insert(comments, comment)
				end
				detail.comments = comments
			end
		end
		setNotice(state, run, "Comment added")
		reloadAfterMutation(state, run)
	end)
end

-- ─── Relations ──────────────────────────────────────────────────────────────

local function openLink(state: BlockState, mode: "blocked-by" | "blocks" | "related")
	if state.selectedId == nil or not state.drawerOpen then
		return
	end
	state.link = { mode = mode, field = text.new(""), error = nil }
	setFocus(state, "link")
end

local function cancelLink(state: BlockState)
	state.link = nil
	if state.focus == "link" then
		setFocus(state, nil)
	end
end

local function submitLink(state: BlockState)
	local link = state.link
	local selectedId = state.selectedId
	if link == nil or selectedId == nil then
		return
	end
	local teamKey, number = model.parseIdentifier(link.field.text)
	if teamKey == nil or number == nil then
		link.error = "Enter an issue identifier like ENG-123."
		return
	end
	local identifier = string.format("%s-%d", teamKey, number)
	link.error = nil
	local mode = link.mode
	runMutation(state, function(message: string)
		link.error = message
	end, function(cfg: types.Config, done: types.Callback<boolean>, alive: () -> boolean)
		linear.lookup(cfg, identifier, function(ref, err)
			if not alive() then
				return
			end
			if err ~= nil then
				done(nil, err)
				return
			end
			if ref == nil then
				done(nil, { kind = "notfound", message = "No issue " .. identifier })
				return
			end
			if ref.id == selectedId then
				done(nil, { kind = "input", message = "An issue can't be linked to itself." })
				return
			end
			if mode == "blocked-by" then
				linear.createRelation(cfg, ref.id, selectedId, "blocks", done)
			elseif mode == "blocks" then
				linear.createRelation(cfg, selectedId, ref.id, "blocks", done)
			else
				linear.createRelation(cfg, selectedId, ref.id, "related", done)
			end
		end)
	end, function(_: boolean, run: Run)
		if state.link == link then
			cancelLink(state)
		end
		setNotice(state, run, "Linked " .. identifier)
		reloadAfterMutation(state, run)
	end)
end

local function unlink(state: BlockState, relationId: string)
	runMutation(state, nil, function(cfg: types.Config, done: types.Callback<boolean>)
		linear.deleteRelation(cfg, relationId, done)
	end, function(_: boolean, run: Run)
		setNotice(state, run, "Relation removed")
		reloadAfterMutation(state, run)
	end)
end

-- ─── Credentials ────────────────────────────────────────────────────────────

local function saveKey(state: BlockState)
	local run = runOf(state)
	if run == nil then
		return
	end
	local key = text.trimmed(state.setupKey)
	if not credentials.looksLikeKey(key) then
		state.setupError = "That doesn't look like a Linear API key."
		return
	end
	local endpoint, rejected = credentials.endpoint()
	if endpoint == nil then
		state.setupError = rejected or "LINEAR_API_URL is not an allowed endpoint."
		state.cx:render()
		return
	end
	local generation = beginForeground(state, run, "mutation")
	if generation == nil then
		return
	end
	state.setupError = nil
	local cfg: types.Config = { key = key, endpoint = endpoint }
	linear.viewer(cfg, function(viewer, err)
		local live = current(state, generation)
		if live == nil then
			return
		end
		if viewer == nil then
			settle(state, live)
			if err ~= nil and err.kind == "auth" then
				state.setupError = "Linear rejected the API key."
			else
				state.setupError = if err ~= nil then err.message else "Could not reach Linear."
			end
			state.cx:render()
			return
		end
		-- The foreground request stays alive until the key is on disk.
		credentials.save(key, function(ok: boolean, reason: string?)
			local saving = current(state, generation)
			if saving == nil then
				return
			end
			settle(state, saving)
			if not ok then
				state.setupError = reason or "Could not store the API key."
				state.cx:render()
				return
			end
			saving.cfg = cfg
			state.keySource = "file"
			state.viewer = viewer
			text.set(state.setupKey, "")
			state.phase = "loading"
			setFocus(state, nil)
			loadAll(state, false)
			state.cx:render()
		end)
	end)
end

local function signOut(state: BlockState, run: Run)
	if state.keySource ~= "file" then
		return
	end
	local cleared, reason = credentials.clear()
	if not cleared then
		-- The key is still on disk: stay signed in and say why.
		state.error = reason or "Could not remove the stored API key."
		return
	end
	enterSetup(state, run, nil)
end

-- ─── Forms ──────────────────────────────────────────────────────────────────

local function textField(
	name: string,
	label: string,
	kind: "text" | "multiline",
	value: string,
	placeholder: string?
): FormField
	return {
		name = name,
		label = label,
		kind = kind,
		field = text.new(value),
		baseline = value,
		placeholder = placeholder,
	}
end

local function choiceField(name: string, label: string, options: { FormOption }, value: string): FormField
	return { name = name, label = label, kind = "choice", value = value, options = options, baseline = value }
end

local function fieldNamed(form: Form, name: string): FormField?
	for _, field in form.fields do
		if field.name == name then
			return field
		end
	end
	return nil
end

local function formText(form: Form, name: string): string
	local field = fieldNamed(form, name)
	if field == nil or field.field == nil then
		return ""
	end
	return text.trimmed(field.field)
end

local function formChoice(form: Form, name: string): string
	local field = fieldNamed(form, name)
	if field == nil then
		return ""
	end
	return field.value or ""
end

local function hasOption(options: { FormOption }, value: string): boolean
	for _, option in options do
		if option.value == value then
			return true
		end
	end
	return false
end

local function priorityOptions(): { FormOption }
	local options: { FormOption } = {}
	for _, priority in model.PRIORITIES do
		table.insert(options, { value = tostring(priority.value), label = priority.label })
	end
	return options
end

local function teamOptions(state: BlockState): { FormOption }
	local options: { FormOption } = {}
	for _, team in state.teams do
		table.insert(options, { value = team.id, label = team.name })
	end
	return options
end

-- `present` keeps an issue's current state selectable even if the team list lacks it.
local function stateOptions(team: Team?, present: types.WorkflowState?): { FormOption }
	local options: { FormOption } = {}
	if team ~= nil then
		for _, workflowState in team.states do
			table.insert(options, { value = workflowState.id, label = workflowState.name })
		end
	end
	if present ~= nil and not hasOption(options, present.id) then
		table.insert(options, { value = present.id, label = present.name })
	end
	return options
end

local function assigneeOptions(team: Team?, current: types.User?): { FormOption }
	local options: { FormOption } = { { value = "", label = "Unassigned" } }
	if team ~= nil then
		for _, member in team.members do
			table.insert(options, { value = member.id, label = member.displayName })
		end
	end
	if current ~= nil and not hasOption(options, current.id) then
		table.insert(options, { value = current.id, label = current.displayName })
	end
	return options
end

local function defaultStateId(team: Team): string
	local todo = model.todoState(team)
	if todo ~= nil then
		return todo.id
	end
	if team.defaultStateId ~= nil then
		return team.defaultStateId
	end
	local first = team.states[1]
	return if first ~= nil then first.id else ""
end

local function defaultAssigneeId(state: BlockState, options: { FormOption }): string
	local me = viewerId(state)
	if state.prefs.scope == "mine" and me ~= nil and hasOption(options, me) then
		return me
	end
	return ""
end

local function createTeam(state: BlockState, form: Form): Team?
	local field = fieldNamed(form, "team")
	if field ~= nil then
		return teamById(state, field.value)
	end
	return state.teams[1]
end

-- (Re)points the create form's state and assignee choices at `team`.
local function configureTeamFields(state: BlockState, form: Form, team: Team)
	local stateField = fieldNamed(form, "state")
	if stateField ~= nil then
		stateField.options = stateOptions(team, nil)
		stateField.value = defaultStateId(team)
		stateField.baseline = stateField.value or ""
	end
	local assigneeField = fieldNamed(form, "assignee")
	if assigneeField ~= nil then
		local options = assigneeOptions(team, nil)
		assigneeField.options = options
		local kept = assigneeField.value
		if kept == nil or kept == "" or not hasOption(options, kept) then
			assigneeField.value = defaultAssigneeId(state, options)
		end
		assigneeField.baseline = assigneeField.value or ""
	end
end

local function openCreate(state: BlockState)
	if state.form ~= nil then
		return
	end
	local team = scopeTeam(state) or state.teams[1]
	if team == nil then
		state.error = "No Linear teams are available."
		return
	end
	local fields: { FormField } = {
		textField("title", "Title", "text", "", "Issue title"),
		textField("description", "Description", "multiline", "", "Add a description…"),
	}
	if #state.teams > 1 then
		table.insert(fields, choiceField("team", "Team", teamOptions(state), team.id))
	end
	table.insert(fields, choiceField("state", "State", {}, ""))
	table.insert(fields, choiceField("priority", "Priority", priorityOptions(), "0"))
	table.insert(fields, choiceField("assignee", "Assignee", {}, ""))
	local form: Form = { kind = "create", issueId = nil, fields = fields, focus = 1, error = nil }
	configureTeamFields(state, form, team)
	state.form = form
	setFocus(state, "form")
end

openEditForm = function(state: BlockState)
	local detail = state.detail
	if state.form ~= nil or detail == nil or detail.id ~= state.selectedId then
		return
	end
	local team = teamById(state, detail.teamId)
	local description = detail.description or ""
	local assignee = detail.assignee
	local fields: { FormField } = {
		textField("title", "Title", "text", detail.title, nil),
		textField("description", "Description", "multiline", description, "Add a description…"),
		choiceField("priority", "Priority", priorityOptions(), tostring(detail.priority)),
		choiceField("state", "State", stateOptions(team, detail.state), detail.state.id),
		choiceField(
			"assignee",
			"Assignee",
			assigneeOptions(team, assignee),
			if assignee ~= nil then assignee.id else ""
		),
	}
	state.form = { kind = "edit", issueId = detail.id, fields = fields, focus = 1, error = nil }
	setFocus(state, "form")
end

-- `e`/`edit`: the form needs the full issue, so wait for the detail when it is missing.
local function beginEdit(state: BlockState, run: Run)
	local id = state.selectedId
	if id == nil or state.form ~= nil then
		return
	end
	local issue = selectedIssue(state)
	if issue == nil then
		return
	end
	local wasOpen = state.drawerOpen
	state.drawerOpen = true
	local detail = state.detail
	if detail ~= nil and detail.id == id then
		openEditForm(state)
		return
	end
	run.editAfterLoad = id
	setNotice(state, run, "Loading issue…")
	if not wasOpen or not state.detailLoading then
		requestDetail(state, run, 0)
	end
end

local function closeForm(state: BlockState)
	state.form = nil
	if state.focus == "form" then
		setFocus(state, nil)
	end
end

local function cancelForm(state: BlockState, run: Run)
	run.editAfterLoad = nil
	closeForm(state)
end

local EDIT_PATCH_KEYS: { [string]: string } = {
	title = "title",
	description = "description",
	priority = "priority",
	state = "stateId",
	assignee = "assigneeId",
}

local function editPatch(form: Form): Patch
	local diff = model.formDiff(form)
	local title = formText(form, "title")
	local titleField = fieldNamed(form, "title")
	local titleUnchanged = titleField ~= nil and title == titleField.baseline
	local patch: Patch = {}
	for name, value in diff do
		local key = EDIT_PATCH_KEYS[name]
		if key == nil or (name == "title" and titleUnchanged) then
			continue
		end
		if name == "title" then
			patch[key] = title
		elseif name == "priority" then
			patch[key] = tonumber(value) or 0
		elseif name == "assignee" and value == "" then
			patch[key] = tern.json.null
		else
			patch[key] = value
		end
	end
	return patch
end

local function submitEdit(state: BlockState, form: Form)
	local issueId = form.issueId
	if issueId == nil then
		return
	end
	if formText(form, "title") == "" then
		form.error = "Title is required."
		return
	end
	local patch = editPatch(form)
	if next(patch) == nil then
		closeForm(state)
		return
	end
	form.error = nil
	runMutation(state, function(message: string)
		form.error = message
	end, function(cfg: types.Config, done: types.Callback<Issue>)
		linear.updateIssue(cfg, issueId, patch, done)
	end, function(updated: Issue, run: Run)
		applyIssue(state, updated, false)
		if state.form == form then
			closeForm(state)
		end
		setNotice(state, run, "Saved " .. updated.identifier)
		reloadAfterMutation(state, run)
	end)
end

local function submitCreate(state: BlockState, form: Form)
	local title = formText(form, "title")
	if title == "" then
		form.error = "Title is required."
		return
	end
	local team = createTeam(state, form)
	if team == nil then
		form.error = "Choose a team."
		return
	end
	local input: types.IssueCreateInput = { teamId = team.id, title = title }
	local description = formText(form, "description")
	if description ~= "" then
		input.description = description
	end
	local priority = tonumber(formChoice(form, "priority")) or 0
	if priority > 0 then
		input.priority = priority
	end
	local assigneeId = formChoice(form, "assignee")
	if assigneeId ~= "" then
		input.assigneeId = assigneeId
	end
	local stateId = formChoice(form, "state")
	if stateId ~= "" then
		input.stateId = stateId
	end
	form.error = nil
	runMutation(state, function(message: string)
		form.error = message
	end, function(cfg: types.Config, done: types.Callback<Issue>)
		linear.createIssue(cfg, input, done)
	end, function(created: Issue, run: Run)
		applyIssue(state, created, true)
		if state.form == form then
			closeForm(state)
		end
		setNotice(state, run, "Created " .. created.identifier)
		reloadAfterMutation(state, run)
	end)
end

local function submitForm(state: BlockState)
	local form = state.form
	local run = runOf(state)
	if form == nil or run == nil or formLocked(state, run) then
		return
	end
	if form.kind == "create" then
		submitCreate(state, form)
	else
		submitEdit(state, form)
	end
end

local function setChoice(state: BlockState, form: Form, field: FormField, value: string)
	field.value = value
	if form.kind == "create" and field.name == "team" then
		local team = teamById(state, value)
		if team ~= nil then
			configureTeamFields(state, form, team)
		end
	end
end

local function stepChoice(state: BlockState, form: Form, field: FormField, delta: number)
	local options = field.options
	if options == nil or #options == 0 then
		return
	end
	local index = 1
	for position, option in options do
		if option.value == field.value then
			index = position
			break
		end
	end
	local target = options[math.clamp(index + delta, 1, #options)]
	setChoice(state, form, field, target.value)
end

local function moveFormFocus(state: BlockState, form: Form, delta: number)
	form.focus = (form.focus - 1 + delta) % #form.fields + 1
	setFocus(state, "form")
end

-- ─── Navigation and filters ─────────────────────────────────────────────────

local function visibleIssues(state: BlockState): { Issue }
	return model.visible(state.issues, state.prefs, state.query.text, viewerId(state))
end

-- The order the active layout renders issues in.
local function orderedIssues(state: BlockState): { Issue }
	local visible = visibleIssues(state)
	if state.prefs.layout == "table" then
		return model.sortTable(visible, state.prefs.sort, state.prefs.sortAsc)
	end
	-- Board: the cards' order, column by column (mine scope re-sorts each column by priority).
	local ordered: { Issue } = {}
	for _, column in model.columns(visible, state.prefs, scopeTeam(state)) do
		for _, issue in column.issues do
			table.insert(ordered, issue)
		end
	end
	return ordered
end

local function moveSelection(state: BlockState, run: Run, delta: number): boolean
	local ordered = orderedIssues(state)
	if #ordered == 0 then
		return false
	end
	local index = 0
	for position, issue in ordered do
		if issue.id == state.selectedId then
			index = position
			break
		end
	end
	local target = if index == 0 then 1 else math.clamp(index + delta, 1, #ordered)
	local issue = ordered[target]
	if issue.id ~= state.selectedId then
		selectIssue(state, run, issue.id, false, DETAIL_DEBOUNCE_MS)
	end
	return true
end

-- Board only: first issue of the previous/next non-empty column.
local function moveColumn(state: BlockState, run: Run, delta: number): boolean
	if state.prefs.layout ~= "board" then
		return false
	end
	local columns = model.columns(visibleIssues(state), state.prefs, scopeTeam(state))
	local currentColumn = 0
	for position, column in columns do
		for _, issue in column.issues do
			if issue.id == state.selectedId then
				currentColumn = position
			end
		end
	end
	local step = if currentColumn == 0 then 1 else delta
	local position = if currentColumn == 0 then 1 else currentColumn + delta
	while position >= 1 and position <= #columns do
		local first = columns[position].issues[1]
		if first ~= nil then
			selectIssue(state, run, first.id, false, DETAIL_DEBOUNCE_MS)
			return true
		end
		position += step
	end
	return false
end

-- Client-side filters keyed to a team no longer apply after a scope change.
local function resetScopedFilters(prefs: Prefs)
	prefs.labelId = nil
	if prefs.assignee ~= nil and prefs.assignee ~= "me" and prefs.assignee ~= "none" then
		prefs.assignee = nil
	end
end

-- True when a change to the server filter may start a foreground reload right now.
local function canReload(state: BlockState, run: Run): boolean
	if run.cfg == nil or state.phase ~= "ready" then
		return false
	end
	return not state.busy or run.fgKind == "load"
end

-- Reloads the board in the foreground after the server filter changed.
local function reloadBoard(state: BlockState, run: Run, clearBoard: boolean)
	if clearBoard then
		clearSelection(state, run)
		state.issues = {}
		state.truncated = false
		state.maxUpdatedAt = nil
		resetScopedFilters(state.prefs)
	end
	loadAll(state, true)
end

local function setView(state: BlockState, run: Run, value: any)
	local parsed: ("active" | "backlog" | "all")? = parseView(value)
	if parsed == nil or parsed == state.prefs.view or not canReload(state, run) then
		return
	end
	state.prefs.view = parsed
	reloadBoard(state, run, false)
end

local function setLayout(state: BlockState, value: any)
	local parsed: ("board" | "table")? = parseLayout(value)
	if parsed ~= nil then
		state.prefs.layout = parsed
	end
end

local function setMine(state: BlockState, run: Run)
	if state.prefs.scope == "mine" or not canReload(state, run) then
		return
	end
	state.prefs.scope = "mine"
	reloadBoard(state, run, true)
end

local function setTeam(state: BlockState, run: Run, teamId: string)
	local alreadyThere = state.prefs.scope == "team" and state.prefs.teamId == teamId
	if teamById(state, teamId) == nil or alreadyThere or not canReload(state, run) then
		return
	end
	state.prefs.scope = "team"
	state.prefs.teamId = teamId
	reloadBoard(state, run, true)
end

local function nextTeam(state: BlockState, run: Run): boolean
	local teams = state.teams
	if #teams == 0 then
		return false
	end
	local index = 0
	if state.prefs.scope == "team" then
		for position, team in teams do
			if team.id == state.prefs.teamId then
				index = position
				break
			end
		end
	end
	setTeam(state, run, teams[index % #teams + 1].id)
	return true
end

local function setSort(state: BlockState, key: string)
	if not SORT_KEYS[key] then
		return
	end
	local prefs = state.prefs
	if prefs.sort == key then
		prefs.sortAsc = not prefs.sortAsc
	else
		prefs.sort = key
		prefs.sortAsc = key ~= "updated"
	end
end

local function clearFilters(state: BlockState)
	state.prefs.priority = nil
	state.prefs.assignee = nil
	state.prefs.labelId = nil
	text.set(state.query, "")
end

local function copyText(state: BlockState, run: Run, value: string, label: string)
	state.cx:copy(value)
	setNotice(state, run, "Copied " .. label)
end

-- Only Linear's own pages are opened from an issue's `url`.
local function openIssueUrl(state: BlockState, run: Run, issue: Issue)
	if string.match(issue.url, "^https://linear%.app/") ~= nil then
		state.cx:open(issue.url)
	else
		setNotice(state, run, "Refusing to open a link outside linear.app.")
		state.cx:render()
	end
end

-- ─── Actions ────────────────────────────────────────────────────────────────

type ActionHandler = (BlockState, Run, string?) -> ()

local function withIssue(state: BlockState, id: string?, use: (Issue) -> ())
	if id == nil then
		return
	end
	local issue = findIssue(state, id)
	if issue ~= nil then
		use(issue)
	end
end

local function withSelected(state: BlockState, use: (Issue) -> ())
	local issue = selectedIssue(state)
	if issue ~= nil then
		use(issue)
	end
end

local ACTIONS: { [string]: ActionHandler } = {
	["refresh"] = function(state, _run, _value)
		loadAll(state, false)
	end,
	["layout"] = function(state, _run, value)
		setLayout(state, value)
	end,
	["view"] = function(state, run, value)
		setView(state, run, value)
	end,
	["scope"] = function(state, run, value)
		if value == "mine" then
			setMine(state, run)
		end
	end,
	["team"] = function(state, run, value)
		if value ~= nil then
			setTeam(state, run, value)
		end
	end,
	["sort"] = function(state, _run, value)
		if value ~= nil then
			setSort(state, value)
		end
	end,
	["clear-filters"] = function(state, _run, _value)
		clearFilters(state)
	end,
	["focus-team"] = function(state, run, _value)
		nextTeam(state, run)
	end,
	["select"] = function(state, run, value)
		if value ~= nil then
			selectIssue(state, run, value, true, 0)
		end
	end,
	["close-detail"] = function(state, run, _value)
		closeDrawer(state, run)
	end,
	["open-url"] = function(state, run, value)
		withIssue(state, value, function(issue)
			openIssueUrl(state, run, issue)
		end)
	end,
	["copy-id"] = function(state, run, value)
		withIssue(state, value, function(issue)
			copyText(state, run, issue.identifier, issue.identifier)
		end)
	end,
	["copy-branch"] = function(state, run, value)
		withIssue(state, value, function(issue)
			copyText(state, run, issue.branchName, "branch name")
		end)
	end,
	["set-state"] = function(state, _run, value)
		withSelected(state, function(issue)
			local team = issueTeam(state, issue)
			if team == nil or value == nil then
				return
			end
			for _, workflowState in team.states do
				if workflowState.id == value then
					moveToState(state, issue, workflowState, "")
					return
				end
			end
		end)
	end,
	["assign-me"] = function(state, _run, _value)
		withSelected(state, function(issue)
			toggleAssignMe(state, issue)
		end)
	end,
	["unassign"] = function(state, _run, _value)
		withSelected(state, function(issue)
			if issue.assignee ~= nil then
				setAssignee(state, issue, nil)
			end
		end)
	end,
	["close-issue"] = function(state, _run, _value)
		withSelected(state, function(issue)
			closeIssue(state, issue)
		end)
	end,
	["reopen"] = function(state, _run, _value)
		withSelected(state, function(issue)
			reopenIssue(state, issue)
		end)
	end,
	["edit"] = function(state, run, _value)
		beginEdit(state, run)
	end,
	["create"] = function(state, _run, _value)
		openCreate(state)
	end,
	["submit-form"] = function(state, _run, _value)
		submitForm(state)
	end,
	["cancel-form"] = function(state, run, _value)
		cancelForm(state, run)
	end,
	["submit-comment"] = function(state, _run, _value)
		submitComment(state)
	end,
	["link"] = function(state, _run, value)
		local mode: ("blocked-by" | "blocks" | "related")? = parseLinkMode(value)
		if mode ~= nil then
			openLink(state, mode)
		end
	end,
	["submit-link"] = function(state, _run, _value)
		submitLink(state)
	end,
	["cancel-link"] = function(state, _run, _value)
		cancelLink(state)
	end,
	["unlink"] = function(state, _run, value)
		if value ~= nil then
			unlink(state, value)
		end
	end,
	["save-key"] = function(state, _run, _value)
		saveKey(state)
	end,
	["sign-out"] = function(state, run, _value)
		signOut(state, run)
	end,
}

-- Actions that must not blur the field they were clicked from.
local KEEPS_FOCUS: { [string]: boolean } = {
	["submit-comment"] = true,
	["submit-link"] = true,
	["save-key"] = true,
}

local SETUP_ACTIONS: { [string]: boolean } = { ["save-key"] = true }

-- ─── Select keys ────────────────────────────────────────────────────────────

type SelectHandler = (BlockState, Run, string) -> ()

local function focusFormChoice(state: BlockState, name: string, value: string)
	local form = state.form
	if form == nil then
		return
	end
	for index, field in form.fields do
		if field.name == name and field.kind == "choice" then
			setChoice(state, form, field, value)
			form.focus = index
			setFocus(state, "form")
			return
		end
	end
end

local SELECTS: { [string]: SelectHandler } = {
	["team-select"] = function(state, run, value)
		if value == "mine" then
			setMine(state, run)
		else
			setTeam(state, run, value)
		end
	end,
	["filter-priority"] = function(state, _run, value)
		state.prefs.priority = if value == "" then nil else tonumber(value)
	end,
	["filter-assignee"] = function(state, _run, value)
		state.prefs.assignee = if value == "" then nil else value
	end,
	["filter-label"] = function(state, _run, value)
		state.prefs.labelId = if value == "" then nil else value
	end,
	["state-select"] = function(state, run, value)
		ACTIONS["set-state"](state, run, value)
	end,
	["assignee-select"] = function(state, _run, value)
		withSelected(state, function(issue)
			setAssignee(state, issue, if value == "" then nil else value)
		end)
	end,
	["priority-select"] = function(state, _run, value)
		withSelected(state, function(issue)
			local priority = tonumber(value)
			if priority ~= nil then
				setPriority(state, issue, priority)
			end
		end)
	end,
}

-- ─── Keys ───────────────────────────────────────────────────────────────────

type KeyHandler = (BlockState, Run) -> boolean

local function handleSetupKey(state: BlockState, k: Key): boolean
	if k.name == "enter" then
		saveKey(state)
		return true
	end
	if text.key(state.setupKey, k, false) then
		state.setupError = nil
		return true
	end
	return false
end

local function handleFormKey(state: BlockState, run: Run, k: Key): boolean
	local form = state.form
	if form == nil then
		setFocus(state, nil)
		return true
	end
	if formLocked(state, run) then
		return true
	end
	local field = form.fields[form.focus]
	if field == nil then
		return false
	end
	local name = k.name
	local isChoice = field.kind == "choice"
	local isMultiline = field.kind == "multiline"
	if name == "escape" then
		cancelForm(state, run)
		return true
	elseif name == "tab" then
		moveFormFocus(state, form, if k.shift then -1 else 1)
		return true
	elseif name == "enter" and (not isMultiline or k.ctrl or k.meta) then
		submitForm(state)
		return true
	end
	if isChoice then
		if k.ctrl or k.alt or k.meta then
			return false
		end
		if name == "up" or name == "left" then
			stepChoice(state, form, field, -1)
			return true
		elseif name == "down" or name == "right" then
			stepChoice(state, form, field, 1)
			return true
		end
		return false
	end
	local editable = field.field
	if editable == nil then
		return false
	end
	return text.key(editable, k, field.kind == "multiline")
end

local function handleFieldKey(state: BlockState, run: Run, k: Key): boolean
	local focus = state.focus
	local name = k.name
	if focus == "form" then
		return handleFormKey(state, run, k)
	elseif focus == "search" then
		if name == "escape" or name == "enter" then
			setFocus(state, nil)
			return true
		end
		return text.key(state.query, k, false)
	elseif focus == "comment" then
		if name == "escape" or name == "tab" then
			setFocus(state, nil)
			return true
		elseif name == "enter" and (k.ctrl or k.meta) then
			submitComment(state)
			return true
		end
		return text.key(state.comment, k, true)
	elseif focus == "link" then
		local link = state.link
		if link == nil then
			setFocus(state, nil)
			return true
		elseif name == "escape" then
			cancelLink(state)
			return true
		elseif name == "enter" then
			submitLink(state)
			return true
		end
		return text.key(link.field, k, false)
	end
	return false
end

local function viewKey(value: "active" | "backlog" | "all"): KeyHandler
	return function(state, run)
		setView(state, run, value)
		return true
	end
end

local function selectedAction(use: (BlockState, Run, Issue) -> ()): KeyHandler
	return function(state, run)
		local issue = selectedIssue(state)
		if issue == nil then
			return false
		end
		use(state, run, issue)
		return true
	end
end

local function moveKey(delta: number): KeyHandler
	return function(state, run)
		return moveSelection(state, run, delta)
	end
end

local function columnKey(delta: number): KeyHandler
	return function(state, run)
		return moveColumn(state, run, delta)
	end
end

local function escapeKey(state: BlockState, run: Run): boolean
	if state.form ~= nil then
		cancelForm(state, run)
	elseif state.link ~= nil then
		cancelLink(state)
	elseif state.drawerOpen then
		closeDrawer(state, run)
	elseif state.selectedId ~= nil then
		clearSelection(state, run)
	else
		return false
	end
	return true
end

local KEYS: { [string]: KeyHandler } = {
	["/"] = function(state, _run)
		setFocus(state, "search")
		return true
	end,
	["1"] = viewKey("active"),
	["2"] = viewKey("backlog"),
	["3"] = viewKey("all"),
	["v"] = function(state, _run)
		setLayout(state, if state.prefs.layout == "board" then "table" else "board")
		return true
	end,
	["m"] = function(state, run)
		setMine(state, run)
		return true
	end,
	["t"] = nextTeam,
	["j"] = moveKey(1),
	["down"] = moveKey(1),
	["k"] = moveKey(-1),
	["up"] = moveKey(-1),
	["h"] = columnKey(-1),
	["left"] = columnKey(-1),
	["l"] = columnKey(1),
	["right"] = columnKey(1),
	["enter"] = function(state, run)
		local id = state.selectedId
		if id == nil or state.drawerOpen then
			return false
		end
		selectIssue(state, run, id, true, 0)
		return true
	end,
	["escape"] = escapeKey,
	["n"] = function(state, _run)
		openCreate(state)
		return true
	end,
	["e"] = selectedAction(function(state, run, _issue)
		beginEdit(state, run)
	end),
	["c"] = function(state, _run)
		if not state.drawerOpen or state.form ~= nil then
			return false
		end
		setFocus(state, "comment")
		return true
	end,
	["a"] = selectedAction(function(state, _run, issue)
		toggleAssignMe(state, issue)
	end),
	["x"] = selectedAction(function(state, _run, issue)
		toggleClosed(state, issue)
	end),
	["["] = selectedAction(function(state, run, issue)
		moveAdjacent(state, run, issue, -1)
	end),
	["]"] = selectedAction(function(state, run, issue)
		moveAdjacent(state, run, issue, 1)
	end),
	["o"] = selectedAction(function(state, run, issue)
		openIssueUrl(state, run, issue)
	end),
	["y"] = selectedAction(function(state, run, issue)
		copyText(state, run, issue.identifier, issue.identifier)
	end),
	["r"] = function(state, _run)
		loadAll(state, false)
		return true
	end,
}

local function handleKey(state: BlockState, k: Key, _cx: BlockCx): boolean?
	local run = runOf(state)
	if run == nil then
		return false
	end
	if state.phase == "setup" then
		return handleSetupKey(state, k)
	elseif state.phase ~= "ready" then
		return false
	end
	if state.focus ~= nil then
		return handleFieldKey(state, run, k)
	end
	if k.ctrl or k.alt or k.meta then
		return false
	end
	local handler = KEYS[k.name]
	if handler == nil then
		return false
	end
	return handler(state, run)
end

-- ─── Events ─────────────────────────────────────────────────────────────────

-- Maps a view field name to its focus key, editable text and (form fields) index.
local function resolveField(state: BlockState, name: string): (string?, Field?, number?)
	if name == "search" then
		return "search", state.query, nil
	elseif name == "setup" then
		return "setup", state.setupKey, nil
	elseif name == "comment" then
		return "comment", state.comment, nil
	elseif name == "link" then
		local link = state.link
		if link == nil then
			return nil, nil, nil
		end
		return "link", link.field, nil
	end
	local formField = string.match(name, "^form:(.+)$")
	local form = state.form
	if formField == nil or form == nil then
		return nil, nil, nil
	end
	for index, field in form.fields do
		if field.name == formField then
			return "form", field.field, index
		end
	end
	return nil, nil, nil
end

local function fieldOfEvent(state: BlockState, ev: UiEvent): (string?, Field?, number?)
	local id = ev.id
	if type(id) ~= "string" then
		return nil, nil, nil
	end
	local name = view.fieldName(id)
	if name == nil then
		return nil, nil, nil
	end
	return resolveField(state, name)
end

local function onFocus(state: BlockState, ev: UiEvent)
	local focus, _, index = fieldOfEvent(state, ev)
	if focus == nil then
		return
	end
	local form = state.form
	if index ~= nil and form ~= nil then
		form.focus = index
	end
	setFocus(state, focus)
end

local function onEdit(state: BlockState, run: Run, ev: UiEvent)
	local focus, field, index = fieldOfEvent(state, ev)
	if focus == nil or field == nil then
		return
	end
	if focus == "form" and formLocked(state, run) then
		return
	end
	if not text.applyEdit(field, ev) then
		return
	end
	state.focus = focus
	local form = state.form
	if index ~= nil and form ~= nil then
		form.focus = index
	end
	if focus == "setup" then
		state.setupError = nil
	end
end

-- Selects whose pick may go unapplied (refused, rejected or failed); they remount to the real value.
local REMOUNTING_SELECTS: { [string]: boolean } = {
	["team-select"] = true,
	["state-select"] = true,
	["assignee-select"] = true,
	["priority-select"] = true,
}

-- Select keys carry the control epoch (`state-select-e2`); dispatch is on the key without it.
local function baseKey(key: string): string
	return (string.gsub(key, "%-e%d+$", ""))
end

local function onAction(state: BlockState, run: Run, ev: UiEvent)
	local act = ev.act
	if type(act) ~= "string" then
		return
	end
	local handler = ACTIONS[act]
	if handler == nil then
		return
	end
	if state.phase == "setup" then
		if not SETUP_ACTIONS[act] then
			return
		end
	elseif state.phase ~= "ready" then
		return
	end
	if not KEEPS_FOCUS[act] then
		blurTextFocus(state)
	end
	-- Table button cells and row menus name the row in `item`.
	local value = stringValue(ev.value) or stringValue(ev.item)
	handler(state, run, value)
end

local function onChange(state: BlockState, run: Run, ev: UiEvent)
	local id = ev.id
	local value = stringValue(ev.value)
	if type(id) ~= "string" or value == nil or state.phase ~= "ready" then
		return
	end
	local last = string.match(id, "([^%.]+)$")
	if last == nil then
		return
	end
	local key = baseKey(last)
	local formName = string.match(key, "^f%-(.+)$")
	if formName ~= nil then
		if formLocked(state, run) then
			bumpControls(state)
		else
			focusFormChoice(state, formName, value)
		end
		return
	end
	local handler = SELECTS[key]
	if handler ~= nil then
		blurTextFocus(state)
		local before = state.generation
		handler(state, run, value)
		if state.generation == before and REMOUNTING_SELECTS[key] then
			bumpControls(state)
		end
	end
end

-- Table row events: `select` highlights (and follows an open drawer), `activate` opens.
local function onRow(state: BlockState, run: Run, ev: UiEvent, open: boolean)
	local item = ev.item
	if type(item) ~= "string" or state.phase ~= "ready" or findIssue(state, item) == nil then
		return
	end
	blurTextFocus(state)
	selectIssue(state, run, item, open, 0)
end

local function handleEvent(state: BlockState, ev: UiEvent, _cx: BlockCx)
	local run = runOf(state)
	if run == nil then
		return
	end
	local kind = ev.ev
	if kind == "focus" then
		onFocus(state, ev)
	elseif kind == "edit" then
		onEdit(state, run, ev)
	elseif kind == "action" then
		onAction(state, run, ev)
	elseif kind == "change" then
		onChange(state, run, ev)
	elseif kind == "select" then
		onRow(state, run, ev, state.drawerOpen)
	elseif kind == "activate" then
		onRow(state, run, ev, true)
	end
end

-- ─── Block definition ───────────────────────────────────────────────────────

local function startRun(state: BlockState, run: Run)
	local cfg, rejected = credentials.resolve()
	if cfg == nil then
		enterSetup(state, run, rejected)
	else
		run.cfg = cfg
		state.keySource = credentials.source()
		state.phase = "loading"
		loadAll(state, false)
	end
	schedulePoll(state, run)
end

local function register(state: BlockState): Run
	local previous = runs[state.cx.pane]
	if previous ~= nil then
		retire(previous)
	end
	local run: Run = {
		state = state,
		cfg = nil,
		poll = nil,
		noticeTimer = nil,
		detailTimer = nil,
		detailToken = 0,
		fgKind = nil,
		lastFullAt = tern.now(),
		focusQueued = false,
		reloadQueued = false,
		editAfterLoad = nil,
		metaReady = false,
	}
	runs[state.cx.pane] = run
	return run
end

local function blockTitle(state: BlockState): string
	if state.phase ~= "ready" then
		return "Linear"
	end
	local team = scopeTeam(state)
	if team ~= nil then
		return "Linear · " .. team.key
	end
	return "Linear · My issues"
end

local featureList: { "edit" | "undo" } = { "edit" }

local def: BlockDef<BlockState> = {
	font = "sans",
	features = featureList,
	init = function(cx, _args, saved)
		local state = newState(cx, restorePrefs(saved))
		startRun(state, register(state))
		return state
	end,
	view = function(state, cx)
		return view.render(state, cx)
	end,
	title = blockTitle,
	key = handleKey,
	event = handleEvent,
	save = function(state)
		local prefs = state.prefs
		return {
			sort = prefs.sort,
			sortAsc = prefs.sortAsc,
			scope = prefs.scope,
			teamId = prefs.teamId,
			view = prefs.view,
			layout = prefs.layout,
		}
	end,
}

local controller = { def = def }

return controller
