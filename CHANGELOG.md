# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-10

### Added

- `linear.board` block for Tern, written in pure Luau (host half only; no Node bridge, no background service).
- Board layout with one column per workflow state, and a sortable table layout.
- My issues scope (assigned to you, across teams) and per-team scope; Active, Backlog and All views.
- Search and priority, assignee and label filters.
- Detail drawer with Markdown description, properties, sub-issues, relations and threaded comments.
- Edit title, description, state, priority and assignee; assign to me, mark done, reopen, and move between columns.
- Create issues in a dialog.
- Add and remove blocking and related-issue links by identifier; `Blocked` badge on cards.
- Keyboard-first controls with mouse equivalents.
- Live polling: a change check every 30 seconds, a full reload every 5 minutes, back-off on Linear rate limits.
- In-block setup for a personal API key, with `LINEAR_API_KEY` as an alternative; Sign out for stored keys.
- Remembers layout, view, scope, team and table sort per block.
- Follows the Tern light and dark theme.
- Owner-only key file (`umask 077` on macOS and Linux), `LINEAR_API_URL` restricted to Linear or loopback, and Markdown images and non-http(s) links stripped before display.
- Test suite: unit tests for the pure model and text logic, GraphQL validation against Linear's public schema, a headless end-to-end test against a mock Linear, and a read-only live smoke test.
