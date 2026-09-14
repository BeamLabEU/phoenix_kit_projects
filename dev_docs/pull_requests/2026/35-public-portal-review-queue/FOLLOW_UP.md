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

## Still live (surfaced, not changed in this triage)

- **IMPROVEMENT-MEDIUM — `list_projects_for/2` loads everything to build a uuid
  list.** Confirmed unchanged: `projects.ex:889-896`'s `maybe_scope_to_viewer/2`
  calls `Members.accessible_projects/1`, which materialises full `%Project{}`
  structs for every accessible project and then keeps only `&1.uuid`. The
  narrowing is genuinely in SQL (`where p.uuid in ^uuids`); the uuid set is not.

  **This got hotter in the PR that accompanies this triage.** The new
  `phoenix_kit_dashboard_viewer_context/2` calls `list_projects_for(scope,
  limit: 2)`; the `LIMIT 2` bounds the outer query but `maybe_scope_to_viewer/2`
  runs first and loads every accessible project regardless. Fix shape is
  unchanged from the review: a `Members.accessible_project_uuids/1` selecting
  `p.uuid` only.
- **BUG-MEDIUM — anonymous portal submissions write to the site-wide task
  library.** Unchanged.
- **BUG-MEDIUM — the permission interceptor can't see sub-project tasks.**
  Unchanged.
- **BUG-LOW — portal attachments never reach the project's Files tab.**
  Unchanged.
- **NITPICK — per-IP portal rate buckets are keyed per project.** Unchanged.
- **IMPROVEMENT-MEDIUM — AGENTS.md contradicts the code in three load-bearing
  places.** Unchanged.

## Files touched

None in this triage.

## Verification

`mix precommit` clean; 1511 tests, 0 failures (2026-09-11).

## Open

The six items above. The `accessible_project_uuids/1` one is the one this
PR's own work makes more expensive, and is the first candidate.
