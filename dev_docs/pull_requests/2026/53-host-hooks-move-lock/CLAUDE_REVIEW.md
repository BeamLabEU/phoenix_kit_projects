# Claude (Sonnet 5.5) review — PR #53, after the merge (2026-10-16)

PR #53 (`timujinne/feat/host-hooks`, merge `36e5ac8`): three host hooks —
`Projects.key_taken?/1`; `{:projects, :assignment_status_changed, …}` broadcast
from every status-changing path (including the rows `Outline.settle` cascades
over, announced after the project lock commits); and the
`config :phoenix_kit_projects, move_lock:` hook (`MoveLock`) enforced in
`ProjectMove.run/4`, the Move dialog, the «Project to nest» picker and
`detach_subproject`.

## Verified, no change needed

- **`from` is real.** `update_tracking_status/2` locks the row `FOR NO KEY UPDATE`
  and reads the status inside the writing transaction, only when the changeset
  touches `:status`; otherwise it uses the struct's. `settle_outline` now also
  receives that DB value instead of a possibly stale struct's. No caller wraps
  these functions in its own transaction, so the assignment lock (tracking txn)
  and the project lock (`settle_outline`) are never held together by one
  transaction — no new lock-ordering deadlock.
- **The event buffer cannot leak or mute a later lock.** `with_project_lock/2`
  saves the outer buffer, restores it on any throw/error/exit, drops the inner
  changes on a rollback, and hands them to the outer lock when nested (newest
  first, reversed on announce). Outside a lock `note_status_changes/3` announces
  at once and never creates the key.
- **No reload storms.** Every subscriber of `projects:all` or a project topic now
  either ignores `:assignment_status_changed` (Overview, ProjectsLive, Show,
  Gantt, Calendar), has a catch-all no-op (Modules, Members, Files, Hours), or
  matches an explicit event list (Events, Whiteboards, Portal). `TasksLive` and
  `TemplatesLive` reload on any message but subscribe to `projects:tasks` /
  `projects:templates`, which this event never reaches.
- **`MoveLock` fails open, as documented.** Raise, exit, throw, a non-map, a struct
  (the `for` over it raises and is rescued) and malformed config all yield `%{}`;
  entries for uuids not in the list or with a blank/non-string reason are
  dropped. The hook is asked once per page load (`ProjectsLive`,
  `ProjectShowLive`) and per event, never per row.
- **`ProjectMove.run/4`'s `with … else`.** `allowed? || {:error, :forbidden}` and
  `nil <- MoveLock.reason/1` fall into the two `else` clauses correctly; the inner
  `with` is not subject to them.
- **`child_project` is preloaded** by `list_assignments/1`
  (`@assignment_preloads`), so `load_move_locks/2` never hands the hook a
  `NotLoaded`.
- **`key_taken?/1`** normalises like `Refs.normalize_key/1`; blank/non-string is
  `false`. Its registry read is schemaless like the other registry reads
  (`project_by_key/1`, `former_keys/1`, `suggest_key`), so it behaves the same under
  a table prefix as they do.
- The three new integration files (44 tests) pass against the test database.

## Fixed

- **NITPICK — misplaced comment.** In `ProjectsLive` the new
  `:assignment_status_changed` clause was inserted between the reload clause and
  the comment describing it ("Any change anywhere… share one reload"), so the
  comment sat on the no-op clause. Gave the no-op its own comment and put the
  burst-coalescing one back on the reload clause. Comment-only.

## Noted, not changed

- **NITPICK:** the registry reads (`phoenix_kit_project_keys`) are unprefixed while
  the task-interaction join table goes through `with_table_prefix/1`. Pre-existing
  and consistent across all registry readers; `key_taken?/1` follows its
  neighbours. Worth one sweep if a prefixed install ever uses keys.
- **NITPICK:** `key_taken?/1` checks `projects.key` as well as the registry. The V22
  trigger registers every key a project holds, so the second read is redundant
  today; it is a cheap belt-and-braces and documented as such.
- **By design:** the lock guards the project being moved, not the target parent or
  its descendants; `Projects.move_project/2` and `link_subproject/2` stay
  policy-free (host tools). A cascade of N rows is N+1 messages on `projects:all`.

## Gate

`mix precommit` is green (compile `--warnings-as-errors`, format, credo
`--strict`, dialyzer) when built against the local core checkout
(`PHOENIX_KIT_PATH=../phoenix_kit`). Against the Hex-locked `phoenix_kit 2.62.2` the
compile step fails with 15 warnings from `project_hours_live.ex` (PR #51: its
`SearchPicker` uses `chosen` / `clear_label` / `clear_event`, which that release lacks —
"needs core #933"). Not caused by #52 or #53; it clears once the core release carrying
#933 is published and the lock moves to it.
