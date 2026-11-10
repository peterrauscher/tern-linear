--!strict
-- Linear GraphQL client for the host half: HTTP, auth header, error classification,
-- rate headers, paging and normalization of raw nodes into `types.*`.
-- Every public function is asynchronous and calls its callback exactly once.
-- Neither the key nor any request detail ever reaches a message or a log line.

local queries = require("./queries")
local types = require("./types")

type ApiError = types.ApiError
-- A raw decoded JSON value; normalizers validate it before use.
type Json = any

local linear = {}

local MAX_ISSUES = 250
local ISSUES_PAGE_SIZE = 50
-- Teams carry large nested connections: 5 per page keeps the query far below the 10000 complexity cap.
local TEAMS_PAGE_SIZE = 5
local COMMENTS_PAGE_SIZE = 50
-- Upper bound on follow-up pages of any one listing; guards against a cursor that never ends.
local MAX_PAGES = 40
local REQUEST_TIMEOUT_MS = 20000
local MIN_BACKOFF_MS = 60000

-- Mirrors model.STATE_TYPES; lib/model is not a dependency of the data layer.
local STATE_RANK: { [string]: number } = {
	triage = 1,
	backlog = 2,
	unstarted = 3,
	started = 4,
	completed = 5,
	canceled = 6,
	duplicate = 7,
}
local UNKNOWN_RANK = 99

-- Variables that must encode as JSON arrays even when empty.
local ARRAY_INPUT_KEYS: { [string]: boolean } = {
	labelIds = true,
	addedLabelIds = true,
	removedLabelIds = true,
	subscriberIds = true,
}

local lastRate: types.RateInfo = {}

-- ─── JSON access helpers ────────────────────────────────────────────────────

local function text(v: Json): string?
	return if type(v) == "string" then v else nil
end

local function number(v: Json): number?
	return if type(v) == "number" then v else nil
end

local function nodes(connection: Json): { Json }
	if type(connection) == "table" and type(connection.nodes) == "table" then
		return connection.nodes
	end
	return {}
end

-- ─── Errors ─────────────────────────────────────────────────────────────────

local function failure(kind: types.ApiErrorKind, message: string, retryAfterMs: number?): ApiError
	return { kind = kind, message = message, retryAfterMs = retryAfterMs }
end

local function unexpectedResponse(): ApiError
	return failure("server", "Linear sent a response this plugin could not read.")
end

-- Turns whatever a mapper threw into an ApiError.
local function errorFrom(thrown: Json): ApiError
	if type(thrown) == "table" and type(thrown.kind) == "string" and type(thrown.message) == "string" then
		return thrown
	end
	return unexpectedResponse()
end

local function retryDelayMs(headers: { [string]: string }): number
	local seconds = tonumber(headers["retry-after"])
	if seconds ~= nil and seconds > 0 then
		return math.ceil(seconds * 1000)
	end
	local nowMs = os.time() * 1000
	local soonest: number? = nil
	for _, name in { "x-ratelimit-requests-reset", "x-ratelimit-complexity-reset" } do
		local reset = tonumber(headers[name])
		if reset ~= nil and (soonest == nil or reset < soonest) then
			soonest = reset
		end
	end
	if soonest == nil then
		return MIN_BACKOFF_MS
	end
	return math.max(MIN_BACKOFF_MS, soonest - nowMs)
end

local function rateLimited(headers: { [string]: string }): ApiError
	local delayMs = retryDelayMs(headers)
	local minutes = math.ceil(delayMs / 60000)
	local unit = if minutes == 1 then " minute" else " minutes"
	return failure("rate", "Linear rate limit reached. Pausing for " .. minutes .. unit .. ".", delayMs)
end

local function unreachable(timedOut: boolean): ApiError
	if timedOut then
		return failure("network", "Linear did not respond in time.")
	end
	return failure("network", "Could not reach Linear. Check your connection.")
end

local function describeGraphQlErrors(status: number, headers: { [string]: string }, errors: { Json }): ApiError
	for _, entry in errors do
		local ext: Json = if type(entry) == "table" then entry.extensions else nil
		if type(ext) == "table" and ext.code == "RATELIMITED" then
			return rateLimited(headers)
		end
	end
	local entry: Json = errors[1]
	local ext: Json = if type(entry) == "table" and type(entry.extensions) == "table" then entry.extensions else {}
	local code = text(ext.code) or ""
	local raw = if type(entry) == "table" then text(entry.message) or "" else ""
	local friendly = text(ext.userPresentableMessage) or raw
	if status == 401 or code == "AUTHENTICATION_ERROR" then
		return failure("auth", "Linear rejected the API key. Check that it is valid and has not been revoked.")
	end
	if status == 403 or code == "FORBIDDEN" then
		return failure("forbidden", if friendly ~= "" then friendly else "Your API key is not allowed to do that.")
	end
	if code == "ENTITY_NOT_FOUND" or string.find(raw, "Entity not found", 1, true) ~= nil then
		return failure("notfound", if friendly ~= "" then friendly else "Linear could not find that item.")
	end
	if ext.userError == true or code == "INPUT_ERROR" then
		return failure("input", if friendly ~= "" then friendly else "Linear rejected the request.")
	end
	return failure("server", if raw ~= "" then "Linear error: " .. raw else "Linear returned an error.")
end

-- nil when the response is a success. `errors` wins over the HTTP status, even on HTTP 200.
local function classify(status: number, headers: { [string]: string }, doc: Json): ApiError?
	if type(doc) == "table" and type(doc.errors) == "table" and #doc.errors > 0 then
		return describeGraphQlErrors(status, headers, doc.errors)
	end
	if status == 401 then
		return failure("auth", "Linear rejected the API key. Check that it is valid and has not been revoked.")
	elseif status == 403 then
		return failure("forbidden", "Your API key is not allowed to do that.")
	elseif status == 429 then
		return rateLimited(headers)
	elseif status >= 400 then
		return failure("server", "Linear returned HTTP " .. status .. ".")
	end
	return nil
end

-- ─── Transport ──────────────────────────────────────────────────────────────

local function recordRate(headers: { [string]: string })
	local remaining = tonumber(headers["x-ratelimit-requests-remaining"])
	local limit = tonumber(headers["x-ratelimit-requests-limit"])
	local complexity = tonumber(headers["x-ratelimit-complexity-remaining"])
	local resetAt = tonumber(headers["x-ratelimit-requests-reset"])
	if remaining ~= nil or limit ~= nil or complexity ~= nil or resetAt ~= nil then
		lastRate = {
			requestsRemaining = remaining,
			requestsLimit = limit,
			complexityRemaining = complexity,
			resetAt = resetAt,
		}
	end
end

local function authorization(key: string): string
	if string.sub(key, 1, 10) == "lin_oauth_" then
		return "Bearer " .. key
	end
	return key
end

local function handleResponse(res: FetchResult, cb: (data: Json?, err: ApiError?) -> ())
	recordRate(res.headers)
	if res.error ~= nil or res.status == 0 then
		cb(nil, unreachable(res.timed_out))
		return
	end
	local doc: Json = nil
	local decoded, value = pcall(tern.json.decode, res.body)
	if decoded then
		doc = value
	end
	local err = classify(res.status, res.headers, doc)
	if err ~= nil then
		cb(nil, err)
		return
	end
	if type(doc) ~= "table" or type(doc.data) ~= "table" then
		cb(nil, unexpectedResponse())
		return
	end
	cb(doc.data, nil)
end

local function post(
	cfg: types.Config,
	opName: string,
	query: string,
	variables: { [string]: any }?,
	cb: (data: Json?, err: ApiError?) -> ()
)
	local body: { [string]: any } = { query = query, operationName = opName }
	if variables ~= nil and next(variables) ~= nil then
		body.variables = variables
	end
	local sent = pcall(function()
		tern.fetch(cfg.endpoint, {
			method = "POST",
			headers = { ["Content-Type"] = "application/json", Authorization = authorization(cfg.key) },
			body = tern.json.encode(body),
			timeout_ms = REQUEST_TIMEOUT_MS,
		}, function(res)
			handleResponse(res, cb)
		end)
	end)
	if not sent then
		cb(nil, failure("network", "Could not send the request. Check the Linear API URL and key."))
	end
end

-- One request whose `data` is mapped to a result. A throwing mapper becomes an error; `cb` runs outside pcall.
local function run(
	cfg: types.Config,
	opName: string,
	query: string,
	variables: { [string]: any }?,
	map: (data: Json) -> any,
	cb: (result: any, err: ApiError?) -> ()
)
	post(cfg, opName, query, variables, function(data, err)
		if err ~= nil then
			cb(nil, err)
			return
		end
		local ok, result = pcall(map, data)
		if not ok then
			cb(nil, errorFrom(result))
			return
		end
		cb(result, nil)
	end)
end

type PageSpec = {
	opName: string,
	query: string,
	variables: { [string]: any },
	-- Name of the cursor variable in `query`.
	afterKey: string,
}

-- Fetches pages sequentially. `onPage` consumes a page's data and returns the connection's raw
-- `pageInfo` (nil stops early). `done` runs once, with an error or nil.
local function eachPage(cfg: types.Config, spec: PageSpec, onPage: (data: Json) -> Json, done: (err: ApiError?) -> ())
	local pages = 0
	local function step()
		post(cfg, spec.opName, spec.query, spec.variables, function(data, err)
			if err ~= nil then
				done(err)
				return
			end
			local ok, info = pcall(onPage, data)
			if not ok then
				done(errorFrom(info))
				return
			end
			pages += 1
			local cursor: string? = nil
			if type(info) == "table" and info.hasNextPage == true and pages < MAX_PAGES then
				cursor = text(info.endCursor)
			end
			if cursor == nil then
				done(nil)
				return
			end
			spec.variables[spec.afterKey] = cursor
			step()
		end)
	end
	step()
end

-- ─── Normalizers ────────────────────────────────────────────────────────────

local function normalizeUser(raw: Json): types.User?
	if type(raw) ~= "table" then
		return nil
	end
	local id = text(raw.id)
	local name = text(raw.name)
	if id == nil or name == nil then
		return nil
	end
	return {
		id = id,
		name = name,
		displayName = text(raw.displayName) or name,
		avatarUrl = text(raw.avatarUrl),
		active = if type(raw.active) == "boolean" then raw.active else nil,
	}
end

local function normalizeState(raw: Json): types.WorkflowState?
	if type(raw) ~= "table" then
		return nil
	end
	local id = text(raw.id)
	local name = text(raw.name)
	local stateType = text(raw.type)
	if id == nil or name == nil or stateType == nil then
		return nil
	end
	return {
		id = id,
		name = name,
		type = stateType,
		color = text(raw.color) or "",
		position = number(raw.position) or 0,
	}
end

local function normalizeLabel(raw: Json): types.Label?
	if type(raw) ~= "table" then
		return nil
	end
	local id = text(raw.id)
	local name = text(raw.name)
	if id == nil or name == nil then
		return nil
	end
	return {
		id = id,
		name = name,
		color = text(raw.color) or "",
		isGroup = if type(raw.isGroup) == "boolean" then raw.isGroup else nil,
	}
end

local function normalizeRef(raw: Json): types.IssueRef?
	if type(raw) ~= "table" then
		return nil
	end
	local id = text(raw.id)
	local identifier = text(raw.identifier)
	if id == nil or identifier == nil then
		return nil
	end
	local state: Json = if type(raw.state) == "table" then raw.state else {}
	return {
		id = id,
		identifier = identifier,
		title = text(raw.title) or "",
		stateType = text(state.type) or "backlog",
		stateName = text(state.name),
	}
end

local function normalizeComment(raw: Json): types.Comment?
	if type(raw) ~= "table" then
		return nil
	end
	local id = text(raw.id)
	local createdAt = text(raw.createdAt)
	if id == nil or createdAt == nil then
		return nil
	end
	return {
		id = id,
		body = text(raw.body) or "",
		createdAt = createdAt,
		parentId = text(raw.parentId),
		user = normalizeUser(raw.user),
	}
end

local function appendRelations(
	out: { types.Relation },
	connection: Json,
	direction: "outgoing" | "incoming",
	otherKey: string
)
	for _, node in nodes(connection) do
		local id = text(node.id)
		local relationType = text(node.type)
		local other = normalizeRef(node[otherKey])
		if id ~= nil and relationType ~= nil and other ~= nil then
			table.insert(out, { id = id, type = relationType, direction = direction, other = other })
		end
	end
end

local function normalizeIssue(raw: Json, detailed: boolean): types.Issue
	local state = normalizeState(raw.state)
	local team: Json = raw.team
	local id = text(raw.id)
	local identifier = text(raw.identifier)
	if state == nil or type(team) ~= "table" or id == nil or identifier == nil then
		error("malformed issue")
	end

	local labels: { types.Label } = {}
	for _, node in nodes(raw.labels) do
		local label = normalizeLabel(node)
		if label ~= nil then
			table.insert(labels, label)
		end
	end
	local children: { types.IssueRef } = {}
	for _, node in nodes(raw.children) do
		local child = normalizeRef(node)
		if child ~= nil then
			table.insert(children, child)
		end
	end
	local relations: { types.Relation } = {}
	appendRelations(relations, raw.relations, "outgoing", "relatedIssue")
	appendRelations(relations, raw.inverseRelations, "incoming", "issue")

	local project: { id: string, name: string }? = nil
	if type(raw.project) == "table" and text(raw.project.id) ~= nil and text(raw.project.name) ~= nil then
		project = { id = raw.project.id, name = raw.project.name }
	end
	local cycle: { id: string, number: number, name: string? }? = nil
	if type(raw.cycle) == "table" and text(raw.cycle.id) ~= nil and number(raw.cycle.number) ~= nil then
		cycle = { id = raw.cycle.id, number = raw.cycle.number, name = text(raw.cycle.name) }
	end

	return {
		id = id,
		identifier = identifier,
		number = number(raw.number) or 0,
		title = text(raw.title) or "",
		description = text(raw.description),
		priority = number(raw.priority) or 0,
		priorityLabel = text(raw.priorityLabel) or "No priority",
		estimate = number(raw.estimate),
		url = text(raw.url) or "",
		branchName = text(raw.branchName) or "",
		createdAt = text(raw.createdAt) or "",
		updatedAt = text(raw.updatedAt) or "",
		completedAt = text(raw.completedAt),
		canceledAt = text(raw.canceledAt),
		archivedAt = text(raw.archivedAt),
		dueDate = text(raw.dueDate),
		sortOrder = number(raw.sortOrder) or 0,
		state = state,
		teamId = text(team.id) or "",
		teamKey = text(team.key) or "",
		assignee = normalizeUser(raw.assignee),
		creator = normalizeUser(raw.creator),
		labels = labels,
		project = project,
		cycle = cycle,
		parent = normalizeRef(raw.parent),
		children = children,
		relations = relations,
		comments = nil,
		detailed = detailed,
	}
end

local function stateOrder(a: types.WorkflowState, b: types.WorkflowState): boolean
	local rankA = STATE_RANK[a.type] or UNKNOWN_RANK
	local rankB = STATE_RANK[b.type] or UNKNOWN_RANK
	if rankA ~= rankB then
		return rankA < rankB
	end
	if a.position ~= b.position then
		return a.position < b.position
	end
	return a.id < b.id
end

-- ─── Teams ──────────────────────────────────────────────────────────────────

-- Cursors of a team's nested connections that overflowed their caps in `Teams`.
type Overflow = { team: types.Team, states: string?, labels: string?, members: string? }

local function overflowCursor(connection: Json): string?
	if
		type(connection) == "table"
		and type(connection.pageInfo) == "table"
		and connection.pageInfo.hasNextPage == true
	then
		return text(connection.pageInfo.endCursor)
	end
	return nil
end

local function appendStates(team: types.Team, connection: Json)
	for _, node in nodes(connection) do
		local state = normalizeState(node)
		if state ~= nil then
			table.insert(team.states, state)
		end
	end
end

local function appendLabels(team: types.Team, connection: Json)
	for _, node in nodes(connection) do
		local label = normalizeLabel(node)
		if label ~= nil and label.isGroup ~= true then
			table.insert(team.labels, label)
		end
	end
end

local function appendMembers(team: types.Team, connection: Json)
	for _, node in nodes(connection) do
		local user = normalizeUser(node)
		if user ~= nil and user.active ~= false then
			table.insert(team.members, user)
		end
	end
end

local function normalizeTeam(raw: Json): (types.Team?, Overflow?)
	local id = text(raw.id)
	local key = text(raw.key)
	if id == nil or key == nil then
		return nil, nil
	end
	local team: types.Team = {
		id = id,
		key = key,
		name = text(raw.name) or key,
		color = text(raw.color),
		cyclesEnabled = raw.cyclesEnabled == true,
		triageEnabled = raw.triageEnabled == true,
		estimation = text(raw.issueEstimationType) or "notUsed",
		defaultStateId = if type(raw.defaultIssueState) == "table" then text(raw.defaultIssueState.id) else nil,
		states = {},
		labels = {},
		members = {},
	}
	appendStates(team, raw.states)
	appendLabels(team, raw.labels)
	appendMembers(team, raw.members)
	local overflow: Overflow = {
		team = team,
		states = overflowCursor(raw.states),
		labels = overflowCursor(raw.labels),
		members = overflowCursor(raw.members),
	}
	if overflow.states == nil and overflow.labels == nil and overflow.members == nil then
		return team, nil
	end
	return team, overflow
end

-- Pages one team's overflowing connections through TeamMore until all are complete.
local function completeTeam(cfg: types.Config, overflow: Overflow, done: (err: ApiError?) -> ())
	local rounds = 0
	local function step()
		if (overflow.states == nil and overflow.labels == nil and overflow.members == nil) or rounds >= MAX_PAGES then
			done(nil)
			return
		end
		rounds += 1
		local variables: { [string]: any } = {
			id = overflow.team.id,
			statesAfter = overflow.states,
			labelsAfter = overflow.labels,
			membersAfter = overflow.members,
		}
		post(cfg, "TeamMore", queries.TeamMore, variables, function(data, err)
			if err ~= nil then
				done(err)
				return
			end
			local ok, thrown = pcall(function()
				local raw: Json = data.team
				local team = overflow.team
				if overflow.states ~= nil then
					appendStates(team, raw.states)
					overflow.states = overflowCursor(raw.states)
				end
				if overflow.labels ~= nil then
					appendLabels(team, raw.labels)
					overflow.labels = overflowCursor(raw.labels)
				end
				if overflow.members ~= nil then
					appendMembers(team, raw.members)
					overflow.members = overflowCursor(raw.members)
				end
			end)
			if not ok then
				done(errorFrom(thrown))
				return
			end
			step()
		end)
	end
	step()
end

function linear.teams(cfg: types.Config, cb: types.Callback<{ types.Team }>)
	local teams: { types.Team } = {}
	local overflowing: { Overflow } = {}

	local function finish()
		for _, team in teams do
			table.sort(team.states, stateOrder)
		end
		cb(teams, nil)
	end

	local function completeFrom(index: number)
		local overflow = overflowing[index]
		if overflow == nil then
			finish()
			return
		end
		completeTeam(cfg, overflow, function(err)
			if err ~= nil then
				cb(nil, err)
				return
			end
			completeFrom(index + 1)
		end)
	end

	eachPage(cfg, {
		opName = "Teams",
		query = queries.Teams,
		variables = { first = TEAMS_PAGE_SIZE },
		afterKey = "after",
	}, function(data)
		local connection: Json = data.teams
		for _, node in nodes(connection) do
			local team, overflow = normalizeTeam(node)
			if team ~= nil then
				table.insert(teams, team)
			end
			if overflow ~= nil then
				table.insert(overflowing, overflow)
			end
		end
		return connection.pageInfo
	end, function(err)
		if err ~= nil then
			cb(nil, err)
			return
		end
		completeFrom(1)
	end)
end

-- ─── Reads ──────────────────────────────────────────────────────────────────

function linear.viewer(cfg: types.Config, cb: types.Callback<types.Viewer>)
	run(cfg, "Viewer", queries.Viewer, nil, function(data: Json): types.Viewer
		local raw: Json = data.viewer
		local user = normalizeUser(raw)
		local org: Json = raw.organization
		local orgId = text(org.id)
		local orgName = text(org.name)
		local urlKey = text(org.urlKey)
		if user == nil or orgId == nil or orgName == nil or urlKey == nil then
			error("malformed viewer")
		end
		return { user = user, organization = { id = orgId, name = orgName, urlKey = urlKey } }
	end, cb)
end

-- An empty filter table would encode as a JSON array, which Linear rejects.
local function usableFilter(filter: Json): Json
	if type(filter) == "table" and next(filter) == nil then
		return nil
	end
	return filter
end

function linear.issues(cfg: types.Config, filter: any, cb: types.Callback<types.IssuePage>)
	local issues: { types.Issue } = {}
	local seen: { [string]: boolean } = {}
	local truncated = false

	eachPage(cfg, {
		opName = "Issues",
		query = queries.Issues,
		variables = { filter = usableFilter(filter), first = ISSUES_PAGE_SIZE },
		afterKey = "after",
	}, function(data)
		local connection: Json = data.issues
		for _, node in nodes(connection) do
			local issue = normalizeIssue(node, false)
			if not seen[issue.id] then
				seen[issue.id] = true
				table.insert(issues, issue)
			end
		end
		if #issues >= MAX_ISSUES then
			while #issues > MAX_ISSUES do
				table.remove(issues)
			end
			truncated = type(connection.pageInfo) == "table" and connection.pageInfo.hasNextPage == true
			return nil
		end
		return connection.pageInfo
	end, function(err)
		if err ~= nil then
			cb(nil, err)
			return
		end
		cb({ issues = issues, truncated = truncated }, nil)
	end)
end

function linear.changedSince(cfg: types.Config, filter: any, sinceIso: string?, cb: types.Callback<string?>)
	local scope = usableFilter(filter)
	local combined: Json = scope
	if sinceIso ~= nil then
		local newer = { updatedAt = { gt = sinceIso } }
		combined = if scope == nil then newer else { ["and"] = { scope, newer } }
	end
	run(cfg, "IssuesChanged", queries.IssuesChanged, { filter = combined }, function(data: Json): string?
		local newest: Json = nodes(data.issues)[1]
		return if type(newest) == "table" then text(newest.updatedAt) else nil
	end, cb)
end

local function sortComments(comments: { types.Comment }): { types.Comment }
	local order: { [types.Comment]: number } = {}
	for index, comment in comments do
		order[comment] = index
	end
	table.sort(comments, function(a: types.Comment, b: types.Comment): boolean
		if a.createdAt ~= b.createdAt then
			return a.createdAt < b.createdAt
		end
		return (order[a] or 0) < (order[b] or 0)
	end)
	return comments
end

function linear.issue(cfg: types.Config, id: string, cb: types.Callback<types.Issue>)
	local issue: types.Issue? = nil
	local comments: { types.Comment } = {}

	eachPage(cfg, {
		opName = "Issue",
		query = queries.Issue,
		variables = { id = id, commentsFirst = COMMENTS_PAGE_SIZE },
		afterKey = "commentsAfter",
	}, function(data)
		local raw: Json = data.issue
		if issue == nil then
			issue = normalizeIssue(raw, true)
		end
		local connection: Json = raw.comments
		for _, node in nodes(connection) do
			local comment = normalizeComment(node)
			if comment ~= nil then
				table.insert(comments, comment)
			end
		end
		return if type(connection) == "table" then connection.pageInfo else nil
	end, function(err)
		local loaded = issue
		if err ~= nil or loaded == nil then
			cb(nil, err or unexpectedResponse())
			return
		end
		loaded.comments = sortComments(comments)
		cb(loaded, nil)
	end)
end

function linear.lookup(cfg: types.Config, identifier: string, cb: types.Callback<types.IssueRef?>)
	local variables: { [string]: any } = { id = string.upper(identifier) }
	run(cfg, "IssueLookup", queries.IssueLookup, variables, function(data: Json): types.IssueRef?
		return normalizeRef(data.issue)
	end, function(ref, err)
		if err ~= nil and err.kind == "notfound" then
			cb(nil, nil)
			return
		end
		cb(ref, err)
	end)
end

-- ─── Mutations ──────────────────────────────────────────────────────────────

-- Copies a mutation input, tagging list values so they encode as JSON arrays; `tern.json.null` passes through.
local function withArrays(input: { [string]: any }): { [string]: any }
	local copy: { [string]: any } = {}
	for key, value in input do
		if ARRAY_INPUT_KEYS[key] and type(value) == "table" then
			local items = {}
			for index, item in ipairs(value) do
				items[index] = item
			end
			copy[key] = tern.json.array(items)
		else
			copy[key] = value
		end
	end
	return copy
end

-- The mutation payload under `key`, once it reports `success`.
local function successfulPayload(data: Json, key: string): Json
	local payload: Json = data[key]
	if type(payload) ~= "table" then
		error("missing payload")
	end
	if payload.success ~= true then
		error(failure("server", "Linear did not apply the change."))
	end
	return payload
end

local function issueFromPayload(data: Json, key: string): types.Issue
	local payload = successfulPayload(data, key)
	if type(payload.issue) ~= "table" then
		error(failure("server", "Linear did not return the updated issue."))
	end
	return normalizeIssue(payload.issue, false)
end

function linear.createIssue(cfg: types.Config, input: types.IssueCreateInput, cb: types.Callback<types.Issue>)
	local variables: { [string]: any } = { input = withArrays(input :: any) }
	run(cfg, "IssueCreate", queries.IssueCreate, variables, function(data: Json): types.Issue
		return issueFromPayload(data, "issueCreate")
	end, cb)
end

function linear.updateIssue(cfg: types.Config, id: string, patch: { [string]: any }, cb: types.Callback<types.Issue>)
	local variables: { [string]: any } = { id = id, input = withArrays(patch) }
	run(cfg, "IssueUpdate", queries.IssueUpdate, variables, function(data: Json): types.Issue
		return issueFromPayload(data, "issueUpdate")
	end, cb)
end

function linear.createComment(cfg: types.Config, issueId: string, body: string, cb: types.Callback<types.Comment>)
	local variables: { [string]: any } = { input = { issueId = issueId, body = body } }
	run(cfg, "CommentCreate", queries.CommentCreate, variables, function(data: Json): types.Comment
		local comment = normalizeComment(successfulPayload(data, "commentCreate").comment)
		if comment == nil then
			error(failure("server", "Linear did not return the new comment."))
		end
		return comment
	end, cb)
end

function linear.createRelation(
	cfg: types.Config,
	issueId: string,
	relatedIssueId: string,
	kind: string,
	cb: types.Callback<boolean>
)
	local variables: { [string]: any } = { input = { issueId = issueId, relatedIssueId = relatedIssueId, type = kind } }
	run(cfg, "IssueRelationCreate", queries.IssueRelationCreate, variables, function(data: Json): boolean
		successfulPayload(data, "issueRelationCreate")
		return true
	end, cb)
end

function linear.deleteRelation(cfg: types.Config, relationId: string, cb: types.Callback<boolean>)
	run(cfg, "IssueRelationDelete", queries.IssueRelationDelete, { id = relationId }, function(data: Json): boolean
		successfulPayload(data, "issueRelationDelete")
		return true
	end, cb)
end

function linear.rate(): types.RateInfo
	return lastRate
end

return linear
