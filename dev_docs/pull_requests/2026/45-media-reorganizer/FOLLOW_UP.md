# Follow-up Items for PR #45

Triage of `CLAUDE_REVIEW.md` against the current code on `main`
(2026-10-01). The review's fixes landed in `0d2f1b8` (0.26.0). Since then
PR #46 (`78db856`) replaced the ~1100-line planner with a 31-line
declaration fed to core's `Storage.Reorganizer.ResourceSource`
(`media_reorganizer.ex`), so none of the planning code the findings refer to
exists in this repo any more.

## Fixed (pre-existing)

- ~~**IMPROVEMENT - MEDIUM — A stray copy next to an ambiguous match went
  unreported**~~ — fixed in `0d2f1b8`; the planner is now core's. Core's
  `resolve_entry` keeps the non-matched copies as `stray` on the ambiguous
  branches (core `reorganizer/resource_source.ex:501-508`).
- ~~**NITPICK — Dead `"name (N)"` noop clause and a vacuous test**~~ —
  removed in `0d2f1b8`; `suffixed_variant?/2` no longer exists anywhere in
  this repo.
- ~~**NITPICK — Stale "core does not ship the engine" comments**~~ — the
  comments are gone, and the review's own follow-up is done:
  `media_reorganizer/0` now carries `@impl PhoenixKit.Module`
  (`lib/phoenix_kit_projects.ex:298-299`) on the `>= 2.38.0` core floor.
- ~~**NITPICK — DataCase test outside `integration/`**~~ — now
  `test/phoenix_kit_projects/integration/media_reorganizer_test.exs`.
- ~~**NITPICK — An uppercase legacy folder name is detected but never acted
  on**~~ — N/A in this repo: candidate detection moved to core's
  `ResourceSource` (the downcase is at core `resource_source.ex:1016`). The
  review left it as is; if it matters it is a core item.
- ~~**NITPICK — `:hook_nil` does not name the parent**~~ — N/A in this repo:
  the report is built by core's `hook_nil_action/2`
  (`resource_source.ex:909-`). The review left it as is; if it matters it is a
  core item.

## Files touched

None — documentation only.

## Verification

- Read `lib/phoenix_kit_projects/media_reorganizer.ex` (31 lines, a spec map
  only) and `media_reorganizer/0` in `lib/phoenix_kit_projects.ex`.
- `git log -- lib/phoenix_kit_projects/media_reorganizer.ex` and
  `git log -S suffixed_variant?` for the fix and replacement commits.
- Grepped core's `lib/modules/storage/reorganizer/resource_source.ex` in the
  workspace checkout for the stray, `hook_nil` and downcase handling.

## Open

None.
