# FOLLOW_UP — PR #35: Public portal review queue

Triaged 2026-09-11 against current `main`. Reviewers: Claude
(`CLAUDE_REVIEW.md`) and Pincer (`PINCER_REVIEW.md`).

## Fixed (pre-existing)

Everything the review marked ✅ during the round: the merged tree not compiling
against its declared core, `AssignmentFormLive` having no authorization gate,
`confirm_start_project` having a feature gate and no permission gate, team and
department grants evaporating without `phoenix_kit_staff`, pending submissions
being out of the lists but in the numbers, and `suggest_public_slug/1` using
`:rand`.

Also since resolved:

- ~~**IMPROVEMENT-HIGH — `Features.gates/1` costs ~15+ queries per call.**~~
  Fixed. `features.ex:203-209` now takes one `context/1` and reduces over
  `@task_gates` in memory.

## Fixed since (re-verified 2026-10-29)

- ~~**IMPROVEMENT-MEDIUM — `list_projects_for/2` loads everything to build a
  uuid list.**~~ `maybe_scope_to_viewer/2` now calls
  `Members.accessible_project_uuids/1` (`projects.ex:920-926`,
  `members.ex:154`). `8ae601f`.
- ~~**BUG-MEDIUM — anonymous portal submissions write to the site-wide task
  library.**~~ The portal creates its task with `"ad_hoc" => true`
  (`portal.ex:1522`), and the library reads exclude ad-hoc tasks by default
  (`projects.ex:134`, `:302-312`). `82db490`. Residual LOW: `create_task`
  still broadcasts `:task_created` and advances `next_task_position/0` for each
  portal submission (`projects.ex:251-254`). This is listed under Open.
- ~~**BUG-LOW — portal attachments never reach the project's Files tab.**~~
  `place_in_project_folder/3` files each upload under a "portal submissions"
  subfolder of the project folder (`portal.ex:713-726`). `b4caccc`.
- ~~**IMPROVEMENT-MEDIUM — AGENTS.md contradicts the code in three
  load-bearing places.**~~ `528bb8e` rewrote AGENTS.md. It now documents the
  module-owned chain (`AGENTS.md:651-656`), says the forms re-check writes and
  that `Authz.can?/5` governs events (`:503-507`, `:577`), and has the current
  layout tree (`:370-385`).

## Still live (re-verified 2026-10-29)

- **BUG-MEDIUM — the permission interceptor can't see sub-project tasks.**
  The write hole is closed in `6ef11b2` (the tasks-deadlines branch, whose
  make_idle / make_ready / next-up / board_move went through it too):
  `child_task_allowed?/5` (`web/project_show_live.ex`) asks a displayed
  sub-project task's OWN project, with the task as the record, so a right
  held in the parent no longer writes there
  (`hub_permission_enforcement_test.exs`, "a sub-project's task shown on the
  parent's page"). Residual, still live: the parent check still runs first
  with a `nil` record, so a child-only rule that would let someone act (e.g.
  the assignee of the child task, refused by the parent's floor) is refused
  — fail-closed, not a leak. Fix if wanted: skip the parent check for a
  displayed child task and ask only its own project.
- **NITPICK — per-IP portal rate buckets are keyed per project.**
  `portal.ex:1453-1454` (`"pkp_portal:m:#{project_uuid}:#{bucket}"`), while the
  doc at `:70` says "per peer".
- **NITPICK — residual of the AGENTS.md finding:** `mix.exs:20` still has
  `plt_add_apps: [:phoenix_kit, :phoenix_kit_staff]` although staff is
  optional.
- **NITPICK — residual of the task-library finding:** a portal submission's
  ad-hoc task still broadcasts `:task_created` and takes a library position
  (`projects.ex:251-254`).

## Files touched

None in this triage.

## Verification

`mix precommit` clean; 1511 tests, 0 failures (2026-09-11).

## Open

Still live — awaiting Max's decision: the four items under "Still live" above.
The interceptor is the one that matters. The fix is to resolve the record the
way `scoped_assignment/2` does and to authorize it against the record's own
project.
