# PR #25 follow-up — Drop the Gantt dependency sort (gantt 0.3.0)

Triaged 2026-07-17 as part of the quality sweep. All findings from
`CLAUDE_REVIEW.md` were already resolved in the review/release pass itself
(the 0.14.0 release commit); re-verified against current code.

## Fixed (pre-existing)

- ~~R1 — `@version`/CHANGELOG contradiction with the published 0.13.0~~ —
  fixed at review: bumped to 0.14.0 with an explicit reversal CHANGELOG
  entry. Long since superseded by later releases.
- ~~#2 — rewritten test asserted order but not the connector claim~~ — fixed
  at review; re-verified live at
  `test/phoenix_kit_projects/web/project_gantt_live_test.exs:138-140`
  (`lg-connector` + `data-from-id`/`data-to-id` under a backward order).

## Skipped (with rationale)

- The inverse conflict-marker assertion (backward order carries the "flags
  it honestly" marker class) stays out: gantt 0.3.x exposes no stable marker
  hook, and pinning a dep-internal class is brittle. Trigger to revisit: a
  0.3.x+ release documenting a marker hook.

## Files touched

| File | Change |
|------|--------|
| _none this pass_ | review fixes were already merged |

## Verification

- Findings re-verified by inspection 2026-07-17; the connector assertions
  run green in the current suite (`project_gantt_live_test.exs`).

## Open

None.
