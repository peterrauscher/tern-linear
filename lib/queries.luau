--!strict
-- GraphQL documents for tern-linear: one named operation per string, operation name == key.
-- test/validate-queries.mjs extracts every `queries.<Name> = [[...]]` and validates it against Linear's SDL.
-- Every nested connection carries an explicit `first`: Linear's default of 50 multiplies query complexity.
-- Issues, IssueCreate and IssueUpdate share one node selection so a mutation result can be spliced into the board.

local queries = {}

queries.Viewer = [[query Viewer {
  viewer { id name displayName avatarUrl organization { id name urlKey } }
}]]

-- Nested connections are capped (states 40, labels 100, members 100); each carries pageInfo so
-- linear.teams can follow up with TeamMore for any team that overflows.
queries.Teams = [[query Teams($first: Int = 5, $after: String) {
  teams(first: $first, after: $after) {
    nodes {
      id key name color
      cyclesEnabled triageEnabled issueEstimationType
      defaultIssueState { id }
      states(first: 40) { nodes { id name type color position } pageInfo { hasNextPage endCursor } }
      labels(first: 100) { nodes { id name color isGroup } pageInfo { hasNextPage endCursor } }
      members(first: 100) { nodes { id name displayName avatarUrl active } pageInfo { hasNextPage endCursor } }
    }
    pageInfo { hasNextPage endCursor }
  }
}]]

queries.TeamMore = [[query TeamMore($id: String!, $statesAfter: String, $labelsAfter: String, $membersAfter: String) {
  team(id: $id) {
    id
    states(first: 40, after: $statesAfter) { nodes { id name type color position } pageInfo { hasNextPage endCursor } }
    labels(first: 100, after: $labelsAfter) { nodes { id name color isGroup } pageInfo { hasNextPage endCursor } }
    members(first: 100, after: $membersAfter) { nodes { id name displayName avatarUrl active } pageInfo { hasNextPage endCursor } }
  }
}]]

queries.Issues =
	[[query Issues($filter: IssueFilter, $first: Int = 50, $after: String, $orderBy: PaginationOrderBy = updatedAt, $includeArchived: Boolean = false) {
  issues(filter: $filter, first: $first, after: $after, orderBy: $orderBy, includeArchived: $includeArchived) {
    nodes {
      id identifier number title priority priorityLabel estimate url branchName
      createdAt updatedAt completedAt canceledAt archivedAt dueDate sortOrder
      state { id name type color position }
      team { id key }
      assignee { id name displayName avatarUrl }
      labels(first: 10) { nodes { id name color } }
      project { id name }
      cycle { id number name }
      parent { id identifier title state { name type } }
      children(first: 10) { nodes { id identifier title state { name type } } }
      relations(first: 5) { nodes { id type relatedIssue { id identifier title state { name type } } } }
      inverseRelations(first: 10) { nodes { id type issue { id identifier title state { name type } } } }
    }
    pageInfo { hasNextPage endCursor }
  }
}]]

queries.Issue = [[query Issue($id: String!, $commentsFirst: Int = 50, $commentsAfter: String) {
  issue(id: $id) {
    id identifier number title description priority priorityLabel estimate url branchName
    createdAt updatedAt completedAt canceledAt archivedAt dueDate sortOrder
    state { id name type color position }
    team { id key }
    creator { id name displayName avatarUrl }
    assignee { id name displayName avatarUrl }
    labels(first: 25) { nodes { id name color } }
    project { id name }
    cycle { id number name }
    parent { id identifier title state { name type } }
    children(first: 50) { nodes { id identifier title state { name type } } }
    relations(first: 25) { nodes { id type relatedIssue { id identifier title state { name type } } } }
    inverseRelations(first: 25) { nodes { id type issue { id identifier title state { name type } } } }
    comments(first: $commentsFirst, after: $commentsAfter, orderBy: createdAt) {
      nodes { id body createdAt parentId user { id name displayName avatarUrl } }
      pageInfo { hasNextPage endCursor }
    }
  }
}]]

queries.IssueCreate = [[mutation IssueCreate($input: IssueCreateInput!) {
  issueCreate(input: $input) {
    success
    issue {
      id identifier number title priority priorityLabel estimate url branchName
      createdAt updatedAt completedAt canceledAt archivedAt dueDate sortOrder
      state { id name type color position }
      team { id key }
      assignee { id name displayName avatarUrl }
      labels(first: 10) { nodes { id name color } }
      project { id name }
      cycle { id number name }
      parent { id identifier title state { name type } }
      children(first: 10) { nodes { id identifier title state { name type } } }
      relations(first: 5) { nodes { id type relatedIssue { id identifier title state { name type } } } }
      inverseRelations(first: 10) { nodes { id type issue { id identifier title state { name type } } } }
    }
  }
}]]

queries.IssueUpdate = [[mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) {
  issueUpdate(id: $id, input: $input) {
    success
    issue {
      id identifier number title priority priorityLabel estimate url branchName
      createdAt updatedAt completedAt canceledAt archivedAt dueDate sortOrder
      state { id name type color position }
      team { id key }
      assignee { id name displayName avatarUrl }
      labels(first: 10) { nodes { id name color } }
      project { id name }
      cycle { id number name }
      parent { id identifier title state { name type } }
      children(first: 10) { nodes { id identifier title state { name type } } }
      relations(first: 5) { nodes { id type relatedIssue { id identifier title state { name type } } } }
      inverseRelations(first: 10) { nodes { id type issue { id identifier title state { name type } } } }
    }
  }
}]]

queries.CommentCreate = [[mutation CommentCreate($input: CommentCreateInput!) {
  commentCreate(input: $input) {
    success
    comment { id body createdAt parentId user { id name displayName avatarUrl } }
  }
}]]

queries.IssueRelationCreate = [[mutation IssueRelationCreate($input: IssueRelationCreateInput!) {
  issueRelationCreate(input: $input) {
    success
    issueRelation { id type }
  }
}]]

queries.IssueRelationDelete = [[mutation IssueRelationDelete($id: String!) {
  issueRelationDelete(id: $id) { success entityId }
}]]

-- Resolves "ENG-123" (or a UUID): Query.issue(id: String!) accepts both forms.
queries.IssueLookup = [[query IssueLookup($id: String!) {
  issue(id: $id) { id identifier title state { name type } }
}]]

-- Cheap change detection: the most recently updated issue under the board's scope filter.
queries.IssuesChanged = [[query IssuesChanged($filter: IssueFilter, $includeArchived: Boolean = false) {
  issues(filter: $filter, first: 1, orderBy: updatedAt, includeArchived: $includeArchived) {
    nodes { id updatedAt }
  }
}]]

return queries
