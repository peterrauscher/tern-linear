--!strict
-- Shared types for tern-linear. This file is the contract between modules:
-- data (linear, credentials, queries), model, text, controller and views.
-- See docs/ARCHITECTURE.md for the semantics behind every field.

local types = {}

-- ─── Linear entities (normalized; never raw GraphQL) ────────────────────────

export type User = {
	id: string,
	name: string,
	displayName: string,
	avatarUrl: string?,
	active: boolean?,
}

export type WorkflowState = {
	id: string,
	name: string,
	-- "triage" | "backlog" | "unstarted" | "started" | "completed" | "canceled" | "duplicate"
	type: string,
	color: string,
	position: number,
}

export type Label = {
	id: string,
	name: string,
	color: string,
	isGroup: boolean?,
}

export type Team = {
	id: string,
	key: string,
	name: string,
	color: string?,
	cyclesEnabled: boolean,
	triageEnabled: boolean,
	-- Team.issueEstimationType: "notUsed" | "exponential" | "fibonacci" | "linear" | "tShirt"
	estimation: string,
	defaultStateId: string?,
	-- Sorted by (type rank, position) — see model.STATE_TYPES.
	states: { WorkflowState },
	-- Group labels (isGroup) are already removed.
	labels: { Label },
	-- Active members only.
	members: { User },
}

export type IssueRef = {
	id: string,
	identifier: string,
	title: string,
	stateType: string,
	stateName: string?,
}

-- One relation row seen from the issue that owns it.
-- direction "outgoing": this issue is the source (`Issue.relations`).
-- direction "incoming": this issue is the target (`Issue.inverseRelations`).
-- type "blocks" + outgoing  => this issue blocks `other`.
-- type "blocks" + incoming  => this issue is blocked by `other`.
export type Relation = {
	id: string,
	type: string,
	direction: "outgoing" | "incoming",
	other: IssueRef,
}

export type Comment = {
	id: string,
	body: string,
	createdAt: string,
	parentId: string?,
	-- nil for bots/integrations; render "Linear" or similar.
	user: User?,
}

export type Issue = {
	id: string,
	identifier: string,
	number: number,
	title: string,
	-- Markdown; only present after a detail fetch (`detailed == true`).
	description: string?,
	-- 0 none, 1 urgent, 2 high, 3 medium, 4 low
	priority: number,
	priorityLabel: string,
	estimate: number?,
	url: string,
	branchName: string,
	createdAt: string,
	updatedAt: string,
	completedAt: string?,
	canceledAt: string?,
	archivedAt: string?,
	-- "YYYY-MM-DD"
	dueDate: string?,
	sortOrder: number,
	state: WorkflowState,
	teamId: string,
	teamKey: string,
	assignee: User?,
	creator: User?,
	labels: { Label },
	project: { id: string, name: string }?,
	cycle: { id: string, number: number, name: string? }?,
	parent: IssueRef?,
	children: { IssueRef },
	relations: { Relation },
	-- Ascending by createdAt; only present after a detail fetch.
	comments: { Comment }?,
	detailed: boolean,
}

export type Viewer = {
	user: User,
	organization: { id: string, name: string, urlKey: string },
}

-- ─── Data layer ─────────────────────────────────────────────────────────────

export type Config = {
	key: string,
	endpoint: string,
}

export type ApiErrorKind = "auth" | "forbidden" | "rate" | "network" | "input" | "notfound" | "server"

export type ApiError = {
	kind: ApiErrorKind,
	-- Human-readable, safe to show (never contains the key).
	message: string,
	-- Present for kind "rate": milliseconds to wait before the next request.
	retryAfterMs: number?,
}

export type Callback<T> = (result: T?, err: ApiError?) -> ()

export type IssuePage = {
	issues: { Issue },
	-- True when MAX_ISSUES was reached and more matched on the server.
	truncated: boolean,
}

export type RateInfo = {
	requestsRemaining: number?,
	requestsLimit: number?,
	complexityRemaining: number?,
	-- Epoch milliseconds.
	resetAt: number?,
}

export type IssueCreateInput = {
	teamId: string,
	title: string,
	description: string?,
	priority: number?,
	assigneeId: string?,
	stateId: string?,
	labelIds: { string }?,
	parentId: string?,
}

-- ─── Text fields (lib/text.luau) ────────────────────────────────────────────

-- A controlled text field. Offsets are UTF-16 code units (Tern's contract).
export type Field = {
	text: string,
	cursor: number,
	anchor: number?,
}

-- ─── Board preferences (persisted by `save`) ────────────────────────────────

export type Prefs = {
	-- "mine": issues assigned to the viewer across teams; "team": every issue of `teamId`.
	scope: "mine" | "team",
	teamId: string?,
	-- "active": triage/unstarted/started; "backlog": backlog; "all": everything,
	-- closed ones only when closed in the last 14 days.
	view: "active" | "backlog" | "all",
	layout: "board" | "table",
	-- Table sort column: "identifier" | "title" | "state" | "priority" | "assignee" | "updated"
	sort: string,
	sortAsc: boolean,
	-- Client-side filters; nil means "any".
	priority: number?,
	-- "me" | "none" | <user id>
	assignee: string?,
	labelId: string?,
}

-- ─── Forms ──────────────────────────────────────────────────────────────────

export type FormOption = { value: string, label: string }

export type FormField = {
	-- Stable name: "title" | "description" | "team" | "state" | "priority" | "assignee" | "labels" | "estimate"
	name: string,
	label: string,
	kind: "text" | "multiline" | "choice",
	-- text / multiline fields
	field: Field?,
	-- choice fields; "" means none
	value: string?,
	options: { FormOption }?,
	-- Value when the form opened; edit submits only fields that differ.
	baseline: string,
	placeholder: string?,
}

export type Form = {
	kind: "create" | "edit",
	-- edit: the issue being edited
	issueId: string?,
	fields: { FormField },
	-- Index into `fields` that owns the keyboard.
	focus: number,
	error: string?,
}

-- Inline "link issue" input inside the drawer.
export type LinkDraft = {
	-- "blocked-by": the selected issue is blocked by the typed one.
	-- "blocks": the selected issue blocks the typed one.
	-- "related": plain relation.
	mode: "blocked-by" | "blocks" | "related",
	field: Field,
	error: string?,
}

-- ─── Block state (lib/controller.luau owns all mutation) ────────────────────

export type BlockState = {
	cx: BlockCx,
	-- "setup": no key yet; "loading": first load in flight; "ready": data shown.
	phase: "setup" | "loading" | "ready",
	keySource: ("env" | "file")?,
	setupKey: Field,
	setupError: string?,

	viewer: Viewer?,
	teams: { Team },
	issues: { Issue },
	truncated: boolean,
	-- Epoch seconds of the last successful board load.
	fetchedAt: number?,
	-- Greatest updatedAt seen in the current scope (ISO string, server clock).
	maxUpdatedAt: string?,

	prefs: Prefs,
	query: Field,
	-- Which field owns the keyboard: nil | "search" | "setup" | "comment" | "link" | "form"
	focus: string?,

	selectedId: string?,
	-- Full issue for the drawer; nil until loaded.
	detail: Issue?,
	detailLoading: boolean,
	-- Drawer open (selectedId set and user opened details).
	drawerOpen: boolean,
	comment: Field,
	link: LinkDraft?,
	form: Form?,

	-- A foreground request is in flight: actions that mutate are disabled.
	busy: boolean,
	-- A background read is in flight: never gates input.
	refreshing: boolean,
	-- A foreground load started over an already-ready board; the issue list is not authoritative yet.
	reloading: boolean,
	-- Bumped when a select must remount to show the authoritative value (it is part of the select's key).
	controlEpoch: number,
	generation: number,
	error: string?,
	-- Transient success/info line (e.g. "Created ENG-12").
	notice: string?,
	-- Epoch ms until which background polling is paused (rate limit backoff).
	backoffUntil: number?,
}

return types
