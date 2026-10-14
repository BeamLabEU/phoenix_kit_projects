# Claude's review — the quality sweep's re-validation (2026-10-14)

Scope: `git diff 7fa7cc2..HEAD -- lib priv/static` (the 30 commits since the
last code review: the task form, Hours, the projects list, and tasks under
tasks with the typed list). Three read-only reviewers, run with the sweep
playbook's C12 prompts, plus my own pass (C12.5).

## Agent 1 — security, error handling, async UX

- MEDIUM — `parent_uuid` was in `Assignment`'s castable fields: a forged
  `assignment[parent_uuid]` on the form's save set a parent with no lock, no
  settle, and could name a sub-project or held row.
- MEDIUM — the form's "Sits under" (`maybe_move`) did not re-check
  `:edit_tasks`, the Subtasks feature, or a sub-project parent.
- MEDIUM — `DELETE /tasks/{id}` counted subtasks from accepted rows only; a
  held subtask under the target was cascaded away without `cascade=true` or
  the policy check.
- LOW — a typed line could arrive ticked from someone without
  `:update_status`; `outline_purge` checked delete rights only.
- LOW — no `phx-disable-with` on Restore, Delete (held), Add a task.
- LOW — `outline_sync` / `outline_paste` with lines that are not maps, or
  text that is not a string, raised and took the LiveView down.
- Clean: secrets, SQL injection (migration interpolation is the prefix),
  SSRF, path injection, log leaks, `:action` on validate, XSS in the hook.

## Agent 2 — translations, activity, tests

- The hook's `ask()` read `data-yes` / `data-no` nobody set — and was never
  called (dead code).
- Activity gaps: the card face's add / rename / move / drop / restore, the
  form's subtask add / toggle / move, and failures of sync / restore /
  purge wrote no history.
- Missing tests: malformed lines, depth as a string / negative / nil, text
  over 500, Unicode, too many lines, other-project ids, activity rows.

## Agent 3 — PubSub, cleanliness, public API

- `settle_placed` only reopened ancestors: a move taking the last open
  subtask out never ticked the parent it left; `sync` never settled at all.
- Races: `Outline.settle` read the shape and wrote with no lock (two people
  ticking the last two subtasks could both miss the parent); `restore` and
  the after-lock `settle_placed` likewise.
- Missing `@spec` on `OutlineList`'s public functions; `descendant_count/1`
  unused; `lines/1` public for no reason.
- Clean: broadcasts after commit, minimal payloads, handle_info catch-alls,
  no `Task.start`, no IO/TODO/commented code.

## My pass

- CRITICAL (found while reading `remove_rows`, before zai reported the
  same): removing a parent's line while keeping its subtask's line deleted
  the subtask through `ON DELETE CASCADE` — the delete ran before the new
  nesting was written.
- The history line for a typed batch counted only lines carrying a browser
  key, so a batch without them logged nothing (found by the new test).
- A cloned subtask lost its parent once `parent_uuid` stopped being cast.
