--!strict
-- The `layer` region: issue drawer (details, inline edit form, relations, comments) and the create dialog.
-- Pure: reads the block state, never mutates it. Node ids are `<parent id>.<key or index>`, so every ancestor
-- of a focusable field is keyed and the ids below are constants the controller can focus.

local model = require("./model")
local types = require("./types")

local ui = tern.ui

type Issue = types.Issue
type Team = types.Team
type User = types.User
type IssueRef = types.IssueRef
type Relation = types.Relation
type Comment = types.Comment
type Form = types.Form
type FormField = types.FormField
type LinkDraft = types.LinkDraft
type Field = types.Field
type BlockState = types.BlockState

local detail = {}

-- ─── Node ids ───────────────────────────────────────────────────────────────

-- The drawer and the create dialog never show together (a create form hides the drawer), so both live under
-- one key and the form fields have one id whichever form is open.
local PANEL = "layer.panel"
local COMMENT_ID = PANEL .. ".comments.composer.editor"
local LINK_ID = PANEL .. ".relations.link.row.field.input"
local FORM_FIELD_PATTERN = "^layer%.panel%.form%.field%-([^.]+)%.f%-([^.]+)$"

local function formFieldId(name: string): string
	return PANEL .. ".form.field-" .. name .. ".f-" .. name
end

function detail.fieldId(name: string): string?
	if name == "comment" then
		return COMMENT_ID
	elseif name == "link" then
		return LINK_ID
	elseif name:sub(1, 5) == "form:" and #name > 5 then
		return formFieldId(name:sub(6))
	end
	return nil
end

function detail.fieldName(id: string): string?
	if id == COMMENT_ID then
		return "comment"
	elseif id == LINK_ID then
		return "link"
	end
	local outer, inner = id:match(FORM_FIELD_PATTERN)
	if outer and outer == inner then
		return "form:" .. outer
	end
	return nil
end

-- ─── Small helpers ──────────────────────────────────────────────────────────

local BUSY_REASON = "Working…"
local MIN_DRAWER_COLS = 44
local DRAWER_FRACTION = 0.45

-- Span tokens per workflow state type (see ARCHITECTURE.md, Styling rules).
local STATE_TOKEN: { [string]: string } = {
	triage = "info",
	backlog = "muted",
	unstarted = "",
	started = "warning",
	completed = "success",
	canceled = "muted",
	duplicate = "muted",
}

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function busyReason(state: BlockState): string?
	if state.busy then
		return BUSY_REASON
	end
	return nil
end

local function userLabel(user: User): string
	if user.displayName ~= "" then
		return user.displayName
	end
	return user.name
end

local function isBlank(s: string): boolean
	return s:match("^%s*$") ~= nil
end

local function muted(text: string): Node
	return ui.text({ ui.span(text, "muted") })
end

local function stateDot(stateType: string): Span
	return ui.span("●", STATE_TOKEN[stateType])
end

local function findTeam(teams: { Team }, id: string): Team?
	for _, team in teams do
		if team.id == id then
			return team
		end
	end
	return nil
end

local function currentIssue(state: BlockState): Issue?
	local id = state.selectedId
	local full = state.detail
	if full and full.id == id then
		return full
	end
	for _, issue in state.issues do
		if issue.id == id then
			return issue
		end
	end
	return nil
end

local function drawerSize(cols: number): number
	if cols <= 0 then
		return DRAWER_FRACTION
	end
	return math.min(1, math.max(DRAWER_FRACTION, MIN_DRAWER_COLS / cols))
end

local function loadingLine(): Node
	return ui.node("shimmer", { key = "loading", text = "Loading…" })
end

local function sectionHeading(title: string, count: number?): Node
	local spans = { ui.span(title, "strong") }
	if count ~= nil then
		table.insert(spans, ui.span("  " .. tostring(count), "muted"))
	end
	return with(ui.text(spans), { key = "heading", role = "linear.heading" })
end

-- A text field value as props of an `input`/`editor` node.
local function fieldProps(field: Field, placeholder: string?): { [string]: any }
	return { text = field.text, cursor = field.cursor, anchor = field.anchor, placeholder = placeholder }
end

-- ─── Form fields (shared by the edit form and the create dialog) ────────────

local function formOptions(field: FormField): { { value: string, label: string } }
	local options = {}
	local source: { types.FormOption } = field.options or {}
	for _, option in source do
		table.insert(options, { value = option.value, label = option.label })
	end
	return options
end

local function formControl(field: FormField): Node
	local props: { [string]: any } = { key = "f-" .. field.name, role = "linear.field-" .. field.name }
	if field.kind == "choice" then
		props.value = field.value or ""
		props.options = formOptions(field)
		props.placeholder = field.placeholder
		props.variant = "field"
		return ui.node("select", props)
	end
	local text = fieldProps(field.field or { text = "", cursor = 0 }, field.placeholder)
	for k, v in text do
		props[k] = v
	end
	props.variant = "field"
	if field.kind == "multiline" then
		props.maxLines = 10
		return ui.node("editor", props)
	end
	return ui.node("input", props)
end

local function formField(field: FormField): Node
	return with(
		ui.col({
			with(muted(field.label), { key = "label" }),
			formControl(field),
		}),
		{ key = "field-" .. field.name, role = "linear.form-field", gap = "xs" }
	)
end

local function formError(form: Form): Node?
	if form.error == nil then
		return nil
	end
	return with(ui.text({ ui.span(form.error, "error") }), { key = "error", role = "linear.form-error" })
end

local function formBody(form: Form, extra: { Node }): Node
	local children: { Node } = {}
	for _, field in form.fields do
		table.insert(children, formField(field))
	end
	local err = formError(form)
	if err then
		table.insert(children, err)
	end
	for _, node in extra do
		table.insert(children, node)
	end
	return ui.col(children)
end

local function cancelFormButton(key: string, state: BlockState): Node
	return ui.button("Cancel", {
		key = key,
		role = "linear.form-cancel",
		size = "sm",
		disabled = busyReason(state),
		actions = { click = "cancel-form" },
	})
end

local function submitFormButton(key: string, label: string, state: BlockState, size: "md" | "sm"): Node
	return ui.button(label, {
		key = key,
		role = "linear.form-submit",
		variant = "primary",
		size = size,
		keys = { "⌘", "enter" },
		busy = state.busy,
		actions = { click = "submit-form" },
	})
end

-- ─── Create dialog ──────────────────────────────────────────────────────────

local function dialog(state: BlockState, form: Form): Node
	local body = with(formBody(form, {}), { key = "form", role = "linear.dialog-form" })
	local foot = with(
		ui.row({
			cancelFormButton("cancel", state),
			submitFormButton("submit", "Create issue", state, "md"),
		}),
		{ key = "foot", justify = "end" }
	)
	return ui.node("overlay", {
		key = "panel",
		role = "linear.dialog",
		modal = true,
		size = "md",
		head = "New issue",
		foot = PANEL .. ".foot",
	}, { body, foot })
end

-- ─── Drawer: header, actions, properties ────────────────────────────────────

local function headerSection(issue: Issue): Node
	local parts = { issue.teamKey }
	local now = os.time()
	table.insert(parts, "created " .. model.relativeTime(issue.createdAt, now))
	table.insert(parts, "updated " .. model.relativeTime(issue.updatedAt, now))
	if issue.creator then
		table.insert(parts, "by " .. userLabel(issue.creator))
	end
	return with(
		ui.col({
			with(ui.text({ ui.span(issue.title, "strong") }), { key = "title", role = "linear.title" }),
			with(muted(table.concat(parts, "  ·  ")), { key = "meta", role = "linear.meta" }),
		}),
		{ key = "header", role = "linear.header", gap = "xs" }
	)
end

local function iconButton(key: string, icon: string, title: string, action: string): Node
	return ui.button("", {
		key = key,
		icon = icon,
		size = "sm",
		variant = "quiet",
		title = title,
		actions = { click = action },
	})
end

local function closeButton(): Node
	return ui.button("", {
		key = "close",
		icon = "x",
		size = "sm",
		variant = "quiet",
		title = "Close",
		keys = { "esc" },
		actions = { click = "close-detail" },
	})
end

local function actionRow(state: BlockState, issue: Issue, editing: boolean): Node
	local reason = busyReason(state)
	local viewer = state.viewer
	local mine = viewer ~= nil and issue.assignee ~= nil and issue.assignee.id == viewer.user.id
	local buttons: { Node } = {}

	if mine then
		table.insert(
			buttons,
			ui.button("Unassign", {
				key = "assign",
				role = "linear.unassign",
				size = "sm",
				disabled = reason,
				actions = { click = "unassign" },
			})
		)
	else
		table.insert(
			buttons,
			ui.button("Assign to me", {
				key = "assign",
				role = "linear.assign-me",
				size = "sm",
				disabled = reason,
				actions = { click = "assign-me" },
			})
		)
	end

	if model.isClosedType(issue.state.type) then
		table.insert(
			buttons,
			ui.button("Reopen", {
				key = "close",
				role = "linear.reopen",
				size = "sm",
				disabled = reason,
				actions = { click = "reopen" },
			})
		)
	else
		table.insert(
			buttons,
			ui.button("Mark done", {
				key = "close",
				role = "linear.close-issue",
				size = "sm",
				disabled = reason,
				actions = { click = "close-issue" },
			})
		)
	end

	local editReason: string? = reason
	if editReason == nil and editing then
		editReason = "Already editing"
	elseif editReason == nil and not issue.detailed then
		editReason = "Loading…"
	end
	table.insert(
		buttons,
		ui.button("Edit", {
			key = "edit",
			role = "linear.edit",
			size = "sm",
			keys = { "e" },
			disabled = editReason,
			actions = { click = "edit" },
		})
	)
	table.insert(
		buttons,
		ui.button("Open in Linear", {
			key = "open",
			role = "linear.open-url",
			size = "sm",
			keys = { "o" },
			actions = { click = "open-url=" .. issue.id },
		})
	)
	table.insert(buttons, iconButton("copy-id", "copy", "Copy identifier", "copy-id=" .. issue.id))
	table.insert(buttons, iconButton("copy-branch", "branch", "Copy branch name", "copy-branch=" .. issue.id))

	return with(ui.row(buttons), { key = "actions", role = "linear.actions", wrap = true })
end

local function propRow(key: string, label: string, value: Node): Node
	return ui.node("row", { key = "prop-" .. key, role = "linear.prop", gap = "sm" }, {
		with(muted(label), { key = "label" }),
		value,
	})
end

local function stateOptions(team: Team?, current: types.WorkflowState): { { value: string, label: string } }
	local options = {}
	local found = false
	local states: { types.WorkflowState } = if team then team.states else {}
	for _, st in states do
		table.insert(options, { value = st.id, label = st.name })
		found = found or st.id == current.id
	end
	if not found then
		table.insert(options, 1, { value = current.id, label = current.name })
	end
	return options
end

local function assigneeOptions(team: Team?, current: User?): { { value: string, label: string } }
	local options = { { value = "", label = "Unassigned" } }
	local found = current == nil
	local members: { User } = if team then team.members else {}
	for _, member in members do
		table.insert(options, { value = member.id, label = userLabel(member) })
		found = found or (current ~= nil and member.id == current.id)
	end
	if not found and current then
		table.insert(options, { value = current.id, label = userLabel(current) })
	end
	return options
end

local function priorityOptions(): { { value: string, label: string } }
	local options = {}
	for _, p in model.PRIORITIES do
		table.insert(options, { value = tostring(p.value), label = p.label })
	end
	return options
end

local function labelChips(issue: Issue): Node
	local chips: { Node } = {}
	for _, label in issue.labels do
		table.insert(chips, with(ui.badge(label.name, "neutral"), { key = label.id }))
	end
	return ui.node("row", { key = "value", role = "linear.labels", gap = "xs", wrap = true }, chips)
end

local function cycleLabel(cycle: { id: string, number: number, name: string? }): string
	if cycle.name ~= nil and cycle.name ~= "" then
		return cycle.name
	end
	return "Cycle " .. tostring(cycle.number)
end

local function parentSpans(parent: IssueRef): { Span | string }
	return { ui.span(parent.identifier, "muted"), "  " .. parent.title }
end

local function propertiesSection(state: BlockState, issue: Issue, team: Team?): Node
	local disabled: boolean? = if state.busy then true else nil
	local rows: { Node } = {
		propRow(
			"state",
			"State",
			ui.node("select", {
				key = "state-select",
				role = "linear.state-select",
				value = issue.state.id,
				options = stateOptions(team, issue.state),
				variant = "quiet",
				disabled = disabled,
			})
		),
		propRow(
			"assignee",
			"Assignee",
			ui.node("select", {
				key = "assignee-select",
				role = "linear.assignee-select",
				value = if issue.assignee then issue.assignee.id else "",
				options = assigneeOptions(team, issue.assignee),
				variant = "quiet",
				disabled = disabled,
			})
		),
		propRow(
			"priority",
			"Priority",
			ui.node("select", {
				key = "priority-select",
				role = "linear.priority-select",
				value = tostring(issue.priority),
				options = priorityOptions(),
				variant = "quiet",
				disabled = disabled,
			})
		),
	}
	if #issue.labels > 0 then
		table.insert(rows, propRow("labels", "Labels", labelChips(issue)))
	end
	if issue.project then
		table.insert(rows, propRow("project", "Project", with(ui.text(issue.project.name), { key = "value" })))
	end
	if issue.cycle then
		table.insert(rows, propRow("cycle", "Cycle", with(ui.text(cycleLabel(issue.cycle)), { key = "value" })))
	end
	if issue.estimate ~= nil then
		table.insert(rows, propRow("estimate", "Estimate", with(ui.text(tostring(issue.estimate)), { key = "value" })))
	end
	if issue.dueDate ~= nil then
		table.insert(rows, propRow("due", "Due", with(ui.text(issue.dueDate), { key = "value" })))
	end
	if issue.parent then
		local parent = issue.parent
		table.insert(
			rows,
			propRow(
				"parent",
				"Parent",
				with(ui.text(parentSpans(parent)), {
					key = "value",
					role = "linear.parent",
					actions = { click = "select=" .. parent.id },
				})
			)
		)
	end
	return with(ui.col(rows), { key = "props", role = "linear.props", gap = "xs" })
end

-- ─── Drawer: edit form, description, sub-issues ─────────────────────────────

local function editForm(state: BlockState, form: Form): Node
	local buttons = with(
		ui.row({
			submitFormButton("submit", "Save", state, "sm"),
			cancelFormButton("cancel", state),
		}),
		{ key = "buttons" }
	)
	return with(formBody(form, { buttons }), { key = "form", role = "linear.edit-form" })
end

local function descriptionSection(state: BlockState, issue: Issue): Node?
	if not issue.detailed then
		if state.detailLoading then
			return with(ui.col({ loadingLine() }), { key = "description", role = "linear.description-loading" })
		end
		return nil
	end
	local text = issue.description
	if text == nil or isBlank(text) then
		return with(muted("No description"), { key = "description", role = "linear.description-empty" })
	end
	return with(ui.md(text), { key = "description", role = "linear.description" })
end

local function issueLine(ref: IssueRef): Node
	local spans: { Span | string } =
		{ stateDot(ref.stateType), "  ", ui.span(ref.identifier, "muted"), "  " .. ref.title }
	return ui.text(spans)
end

local function childrenSection(issue: Issue): Node?
	if #issue.children == 0 then
		return nil
	end
	local rows: { Node } = { sectionHeading("Sub-issues", #issue.children) }
	for _, child in issue.children do
		table.insert(
			rows,
			with(issueLine(child), {
				key = child.id,
				role = "linear.child",
				actions = { click = "select=" .. child.id },
			})
		)
	end
	return with(ui.col(rows), { key = "children", role = "linear.children", gap = "xs" })
end

-- ─── Drawer: relations ──────────────────────────────────────────────────────

local LINK_MODE_LABEL: { [string]: string } = {
	["blocked-by"] = "Blocked by",
	blocks = "Blocks",
	related = "Related to",
}

local function relationTypeNote(rel: Relation): string?
	if rel.type == "duplicate" then
		return if rel.direction == "outgoing" then "Duplicate of" else "Duplicated by"
	elseif rel.type == "similar" then
		return "Similar"
	end
	return nil
end

local function relationRow(state: BlockState, rel: Relation): Node
	local open: { Node } = {}
	local note = relationTypeNote(rel)
	if note then
		table.insert(open, with(muted(note), { key = "note" }))
	end
	table.insert(open, with(issueLine(rel.other), { key = "issue" }))
	return ui.node("row", { key = rel.id, role = "linear.relation", gap = "sm" }, {
		ui.node("row", {
			key = "open",
			role = "linear.relation-open",
			gap = "sm",
			grow = 1,
			actions = { click = "select=" .. rel.other.id },
		}, open),
		ui.button("", {
			key = "unlink",
			icon = "x",
			size = "sm",
			variant = "quiet",
			title = "Remove relation",
			disabled = busyReason(state),
			actions = { click = "unlink=" .. rel.id },
		}),
	})
end

local function relationGroup(state: BlockState, key: string, title: string, rels: { Relation }): Node?
	if #rels == 0 then
		return nil
	end
	local rows: { Node } = { with(muted(title), { key = "title", role = "linear.relation-group-title" }) }
	for _, rel in rels do
		table.insert(rows, relationRow(state, rel))
	end
	return with(ui.col(rows), { key = key, role = "linear.relation-group", gap = "xs" })
end

local function linkButton(state: BlockState, key: string, label: string, mode: string): Node
	return ui.button(label, {
		key = key,
		size = "sm",
		on = state.link ~= nil and state.link.mode == mode,
		disabled = busyReason(state),
		actions = { click = "link=" .. mode },
	})
end

local function linkDraft(state: BlockState, draft: LinkDraft): Node
	local input = ui.node("input", {
		key = "input",
		role = "linear.link-input",
		text = draft.field.text,
		cursor = draft.field.cursor,
		anchor = draft.field.anchor,
		placeholder = "ENG-123",
		variant = "field",
	})
	local row = ui.row({
		ui.node("col", { key = "field", grow = 1 }, { input }),
		ui.button("Link", {
			key = "submit",
			role = "linear.link-submit",
			size = "sm",
			variant = "primary",
			busy = state.busy,
			actions = { click = "submit-link" },
		}),
		ui.button("Cancel", {
			key = "cancel",
			role = "linear.link-cancel",
			size = "sm",
			disabled = busyReason(state),
			actions = { click = "cancel-link" },
		}),
	})
	local children: { Node } = {
		with(muted(LINK_MODE_LABEL[draft.mode]), { key = "mode", role = "linear.link-mode" }),
		with(row, { key = "row" }),
	}
	if draft.error then
		table.insert(
			children,
			with(ui.text({ ui.span(draft.error, "error") }), { key = "error", role = "linear.link-error" })
		)
	end
	return with(ui.col(children), { key = "link", role = "linear.link" })
end

local function relationsSection(state: BlockState, issue: Issue): Node
	local blockedBy: { Relation } = {}
	local blocks: { Relation } = {}
	local related: { Relation } = {}
	for _, rel in issue.relations do
		if rel.type == "blocks" and rel.direction == "incoming" then
			table.insert(blockedBy, rel)
		elseif rel.type == "blocks" then
			table.insert(blocks, rel)
		else
			table.insert(related, rel)
		end
	end

	local children: { Node } = { sectionHeading("Relations", #issue.relations) }
	local groups: { Node? } = {
		relationGroup(state, "blocked-by", "Blocked by", blockedBy),
		relationGroup(state, "blocks", "Blocks", blocks),
		relationGroup(state, "related", "Related", related),
	}
	for i = 1, 3 do
		local group = groups[i]
		if group then
			table.insert(children, group)
		end
	end
	if #issue.relations == 0 then
		table.insert(children, with(muted("No relations"), { key = "none" }))
	end
	table.insert(
		children,
		with(
			ui.row({
				linkButton(state, "add-blocker", "Add blocker", "blocked-by"),
				linkButton(state, "add-blocks", "Blocks…", "blocks"),
				linkButton(state, "add-related", "Relate…", "related"),
			}),
			{ key = "add", wrap = true }
		)
	)
	if state.link then
		table.insert(children, linkDraft(state, state.link))
	end
	return with(ui.col(children), { key = "relations", role = "linear.relations" })
end

-- ─── Drawer: comments ───────────────────────────────────────────────────────

local function commentNode(comment: Comment, replies: { [string]: { Comment } }, now: number): Node
	local author = if comment.user then userLabel(comment.user) else "Linear"
	local head = ui.row({
		with(ui.text({ ui.span(author, "strong") }), { key = "author" }),
		with(muted(model.relativeTime(comment.createdAt, now)), { key = "time" }),
	})
	local children: { Node } = {
		with(head, { key = "head", role = "linear.comment-head" }),
		with(ui.md(comment.body), { key = "body", role = "linear.comment-body" }),
	}
	local own = replies[comment.id]
	if own then
		local thread: { Node } = {}
		for _, reply in own do
			table.insert(thread, commentNode(reply, replies, now))
		end
		table.insert(children, with(ui.col(thread), { key = "replies", role = "linear.replies" }))
	end
	return with(ui.col(children), { key = comment.id, role = "linear.comment", gap = "xs" })
end

-- Roots are comments without a parent (or whose parent is missing); replies hang under their parent.
local function commentThreads(comments: { Comment }, now: number): { Node }
	local known: { [string]: boolean } = {}
	for _, comment in comments do
		known[comment.id] = true
	end
	local roots: { Comment } = {}
	local replies: { [string]: { Comment } } = {}
	for _, comment in comments do
		local parentId = comment.parentId
		if parentId ~= nil and known[parentId] then
			local siblings = replies[parentId] or {}
			table.insert(siblings, comment)
			replies[parentId] = siblings
		else
			table.insert(roots, comment)
		end
	end
	local nodes: { Node } = {}
	for _, root in roots do
		table.insert(nodes, commentNode(root, replies, now))
	end
	return nodes
end

local function composer(state: BlockState): Node
	local draftEmpty = isBlank(state.comment.text)
	local disabled: (boolean | string)? = busyReason(state)
	if disabled == nil and draftEmpty then
		disabled = true
	end
	local editorProps = fieldProps(state.comment, "Leave a comment…")
	editorProps.key = "editor"
	editorProps.role = "linear.comment-editor"
	editorProps.maxLines = 8
	editorProps.variant = "field"
	return with(
		ui.col({
			ui.node("editor", editorProps),
			with(
				ui.row({
					ui.button("Comment", {
						key = "submit",
						role = "linear.comment-submit",
						size = "sm",
						keys = { "⌘", "enter" },
						disabled = disabled,
						actions = { click = "submit-comment" },
					}),
				}),
				{ key = "actions", justify = "end" }
			),
		}),
		{ key = "composer", role = "linear.composer" }
	)
end

local function commentsSection(state: BlockState, issue: Issue): Node
	local children: { Node }
	if issue.comments ~= nil then
		children = { sectionHeading("Comments", #issue.comments) }
		for _, node in commentThreads(issue.comments, os.time()) do
			table.insert(children, node)
		end
	else
		children = { sectionHeading("Comments", nil) }
		if state.detailLoading then
			table.insert(children, loadingLine())
		end
	end
	table.insert(children, composer(state))
	return with(ui.col(children), { key = "comments", role = "linear.comments" })
end

-- ─── Drawer ─────────────────────────────────────────────────────────────────

local function drawer(state: BlockState, cx: BlockCx, issue: Issue): Node
	local team = findTeam(state.teams, issue.teamId)
	local form = state.form
	local editing = form ~= nil and form.kind == "edit" and form.issueId == issue.id

	local children: { Node } = { closeButton() }
	if form ~= nil and editing then
		table.insert(children, editForm(state, form))
	else
		table.insert(children, headerSection(issue))
	end
	table.insert(children, actionRow(state, issue, editing))
	table.insert(children, propertiesSection(state, issue, team))
	if not editing then
		local description = descriptionSection(state, issue)
		if description then
			table.insert(children, description)
		end
	end
	local subIssues = childrenSection(issue)
	if subIssues then
		table.insert(children, subIssues)
	end
	table.insert(children, relationsSection(state, issue))
	table.insert(children, commentsSection(state, issue))

	return ui.node("overlay", {
		key = "panel",
		role = "linear.drawer",
		side = "right",
		size = drawerSize(cx.cols),
		head = issue.identifier,
		meta = issue.state.name,
		["end"] = PANEL .. ".close",
	}, children)
end

-- ─── Layer ──────────────────────────────────────────────────────────────────

function detail.layer(state: BlockState, cx: BlockCx): Node?
	local panel: Node?
	local form = state.form
	if form ~= nil and form.kind == "create" then
		panel = dialog(state, form)
	elseif state.drawerOpen and state.selectedId ~= nil then
		local issue = currentIssue(state)
		if issue then
			panel = drawer(state, cx, issue)
		end
	end
	if panel == nil then
		return nil
	end
	return ui.col({ panel })
end

return detail
