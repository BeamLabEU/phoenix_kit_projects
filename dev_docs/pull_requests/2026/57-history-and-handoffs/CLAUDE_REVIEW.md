# Claude review — PR #57: History, hand-off notices and comment notices

Reviewer: Claude (Sonnet 5.5). Scope: `History`, `Handoffs`, `Notices`,
`CommentNotices`, `PubSub.after_commit/1`, `Activity.log/2`'s decoration,
`L10n`'s viewer zone, `ProjectHistoryLive`. Four panel rounds had already
fixed the larger items (see `FOLLOW_UP.md`); this is an independent read.

Gate before the change: `mix test` 2158 tests, 0 failures; `mix format` clean.

## Findings

### IMPROVEMENT - MEDIUM — `History.list(project, task: uuid)` trusted the uuid (fixed)

`:task` narrowed every source to that uuid without checking the task is in
the project: activity by `resource_uuid`, the ledger-correction branch by
`metadata.assignment_uuid` (any project), comments and time by task uuid.
A caller passing another project's task would have read that task's lines
under a project it may view. The only caller (the task drawer) passes the
edited assignment's own uuid, so nothing leaked today; the function is public
and the next caller would not have known. Now a task not in the project's
index answers an empty history. Test added to `handoffs_test.exs`.

### NITPICK — `ProjectHistoryLive.load/1` swallows every error (not changed)

A failed read renders "Nothing has happened here yet." with a warning in the
log. Deliberate (a tab must not crash the page); the empty state is slightly
misleading for a DB error. Left.

### Checked, no change

- **Embeddability**: `ProjectHistoryLive` exports no `handle_params/3`; the
  failed-mount fallback never reads `reload_ref`, and the `handle_info` guard
  on `project: %Project{}` keeps `:reload` from running without a project.
- **`PubSub.after_commit/1`**: nested ordering (`held ++ outer`), rollback
  dropping, and exception restore are right; the "must be the outermost
  transaction" limit is documented and nothing violates it.
- **Notice fan-out loops**: `Notices.notify` rows carry `notice: true` and a
  `target_uuid`, so `tell_assignees/2` never re-fans them out.
- **Timestamps**: `Entry` is `utc_datetime_usec`, `WorkEntry` `utc_datetime`,
  so `DateTime.to_unix/1` in `History`'s sort is safe for every source.
- **Process-dictionary state** (`Actor`, viewer zone, handoff batch, deferred
  broadcasts) is per LiveView/API process and reset where a process is reused
  (`Api.Auth`).

### Known and left (already on the record in `FOLLOW_UP.md`)

- Per-recipient `Auth.get_user` + `Authz.can?` in `Notices` (writes only).
- `Activity.log/2` does one extra read per assignment row lacking
  `project_uuid` in its metadata (`with_project_uuid/1`); same reason.
- Comment excerpts are stored permanently in notice rows; `scrub_comment/1`
  removes them on delete.

## Fix summary

`lib/phoenix_kit_projects/history.ex` (task-scope guard),
`test/phoenix_kit_projects/integration/handoffs_test.exs` (regression).
