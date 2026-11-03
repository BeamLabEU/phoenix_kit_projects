# Follow-up — PR #59

2026-10-30: all findings in `CODEX_REVIEW.md` are fixed.

- Staff-record confirmation rechecks both the form's write right and the
  current assignment permission/feature. It creates nothing after revocation
  or a tighter assignment floor.
- Real-time corrections lock and read the current assignment before validation
  and update, preventing stale corrections from restoring an invalid finish.
- Time-page deadline affordances use grouped extension/feature reads and one
  role lookup for the viewer. `batched_time_board_test.exs` pins query-count
  independence and parity with the individual permission/feature rules.
- The calendar fixture puts its five-workday schedule inside the first month,
  avoiding a month-boundary-dependent smoke failure.

## Validation

The eight new regression tests across PRs #58/#59 were run against the
original production code at `5ea8d52`: **eight failures**, each corresponding
to a new regression. The original Time-page lookup made **9 queries for one
project and 45 for five**.

With the fixes restored, the complete suite passed: **2,390 tests, zero
failures** (`mix test --max-cases 6`). This includes API, LiveView, context,
batch-query, and migration tests.

The shared database entered recovery after a workspace disk-quota failure.
Verification therefore used a disposable local PostgreSQL 18 server, an
isolated test database, and build output under `/tmp`. Test commands used
`MIX_ENV=test`, `MIX_BUILD_PATH=/tmp/phoenix-kit-projects-review-build/test`,
`PGHOST=127.0.0.1`, `PGUSER=projects_review`,
`PGDATABASE=phoenix_kit_projects_review_local`, `PGPOOL=8`, and
`ERL_FLAGS='+S 6:6'`.

The normal **`MIX_ENV=dev mix precommit` gate passed** using the same
temporary build path: warnings-as-errors compilation, unused-lock and Hex
audit checks, formatting, strict Credo, and Dialyzer. No new warning
suppressions were added. The gate is run in `dev` because this repository's
Dialyzer configuration does not include ExUnit for the test-support modules.

## Claude's review (2026-11-03)

Findings in `CLAUDE_REVIEW.md`, reviewed after #60 had reworked much of this code:

- **Fixed, with a test that fails when the fix is reverted:**
  - HIGH: the sub-project rights bypass through another spelling of a task's uuid, plus `save_duration`,
    `detach_subproject` and `save_work_entry`.
  - HIGH: the assignee picker's lists read for someone who may not assign.
  - MEDIUM: task-view intents run by every viewer's page on a shared host topic.
  - MEDIUM: the weekend-counting walk-back.
  - MEDIUM: one assignee's row taking others' logged time.
  - NITPICK: the Time page's week start.
- **Left, with the reason on record:**
  - which accounts an assigner may pick from (they still see every account and its email);
  - the Time page's one-segment multi-day plan;
  - its per-minute reload;
  - deadlines read while Dates is off.

Validation: one run covers both PRs, see `../60-boss-review-lists/FOLLOW_UP.md`.
