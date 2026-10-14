# Follow-up — PR #51 (2026-10-14)

How each finding in this folder's reviews was resolved. Reviews:
`ZAI_REVIEW.md` (zai on the repo, six numbered questions — `REVIEW_BRIEF.md`),
`CLAUDE_REVIEW.md` (the sweep's three re-validation agents and my own pass).
Codex was briefed with the same questions but could not reach its service
all night (it loops on "Reconnecting… waiting for network", even for a
one-word probe). Grok was started on the same brief, read-only and sandboxed;
it had not answered when this was written.

## Fixed

- ~~Removing a parent's line cascade-deletes a subtask whose line stays~~
  (zai 1-A, my pass) — `delete_rows` moves kept lines out from under a row
  before deleting it. Test: "a parent's line removed while its subtask's
  line stays: the subtask survives".
- ~~`parent_uuid` castable from the form~~ (agent 1) — not cast any more;
  written only by `Outline.move/3` / `write_order/2`; a clone sets it after
  insert. Test: "the database refuses a parent in another project, and the
  form cannot set one"; the clone test.
- ~~The form's "Sits under" skips rights, the feature flag and sub-project
  parents~~ (agent 1) — `maybe_move` needs `:edit_tasks` and the Subtasks
  feature; `Outline.move/3` refuses a sub-project parent (`:subproject`); a
  typed line indented under a sub-project row sits beside it. Test:
  "nothing goes under a sub-project row".
- ~~A held subtask escapes the cascade-delete check~~ (zai 4-A, agent 1) —
  `Outline.rows_below/1` reads every review status. Test: "a held subtask
  counts: the delete needs cascade and reports it".
- ~~The form's Status select and Subtasks box never recompute the
  project~~ (zai 2-A) and ~~a reopen there keeps the completion stamps~~
  (zai 2-B) — `update_assignment_form/3` stamps or clears `completed_at`,
  `completed_by_uuid`, `progress_pct` on a status change, settles, and
  recomputes; the Subtasks box recomputes. Test: "ticking the last task
  there completes the project; reopening clears the stamps".
- ~~Two ticks race; a move/sync/restore never settles the tree~~ (zai 2-C,
  agent 3) — `Outline.settle/3` runs under the project lock;
  `Outline.settle_tree/2` brings every parent in line after a move, a saved
  list, a restore or a batch. Test: "moving the last open subtask out ticks
  the parent it leaves".
- ~~Malformed lines crash the LiveView~~ (agent 1/2) — skipped. Tests:
  "malformed lines are skipped, never a crash" (and Unicode, 500 chars,
  depth strings/negatives/nil), "too many lines, or a project that is
  gone", the page test with `["foo", 42]`.
- ~~A new line arrives ticked without `:update_status`~~ (agent 1) —
  `allow_done:`. Test: "a new line arrives ticked only when ticking is
  allowed".
- ~~History gaps~~ (agent 2) — every outline event and the form's subtask
  acts log on success and on failure; a batch counts every new task. Test:
  the activity assertion in the page test.
- ~~No `phx-disable-with` on Restore / Delete / Add a task~~ (agent 1).
- ~~A board drag leaves a card's subtasks behind~~ (zai 2-D) — the drop is
  written through `keep_outline/2` like the list's.
- ~~The V23 replay re-runs the renumbering walk~~ (zai 3-A) — only when the
  conversion converted something.
- ~~Paste across a sub-project line mutates then aborts~~ (zai 5-A), ~~an
  unsaved line jumps to the top~~ (zai 5-B), ~~`known` grows forever~~
  (zai 5-C), ~~the dead `ask()`~~ (agent 2) — fixed in the hook.
- ~~Missing specs, unused `descendant_count/1`, public `lines/1`~~ (agent 3).

## Answered, not changed

- zai 1-C — an unlisted subtask woven after the row that preceded it can sit
  inside a sibling's branch by position; `parent_uuid` is right and
  `walk/1` draws it right, and the next write of the list restores the
  order. Rare (it needs another person's new subtask to arrive during a
  sync); left.
- zai 3-B — the parent trigger reports "in another project" for a child
  inserted before its parent in one multi-row INSERT. No path does that
  (sync and batch insert parentless and set parents by UPDATE).
- zai 3-D — `down_v23` promotes subtasks to the top level and deletes held
  rows; a one-way conversion, as the migration's comment says.
- zai 5-D — undo is local: a task deleted elsewhere comes back as a new one
  if undone. Written up in AGENTS.md as a known limit (with the two-browser
  case).
- Autosave is last-write-wins against a concurrent API edit of non-text
  fields (zai, Part B) — unchanged by this PR; noted.
- `Ledger.totals_for_branches/1` has no caller in lib (agent 3) — a tested
  public helper for a parent's own + below time; kept.
