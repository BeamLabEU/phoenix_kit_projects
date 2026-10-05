# Codex review of the unreleased changes and ca85176 — 2026-10-05

This is a commit-keyed release audit, not a new PR folder. Reviewed
`ca85176d32490105986a4e5c1d712c1e2255c81c`, its parent, the PR #48 review
documents, and the unreleased scope since `v0.28.0`. Existing reviews were
left intact. This review makes no production-code changes.

The fixes are useful, but I would address findings 1–3 before publishing.
Passing the existing gate and suite does not cover these cases.

## Findings

### 1. BUG - HIGH: reservation takeover can duplicate live work and overwrite its response

Introduced by `ca85176`. `ApiKeys.take_over_stale/2` treats any status-0
reservation older than 120 seconds as abandoned. It does not establish that
the original request stopped. A blocked database call or slow extension
provider can still be alive after that interval. A retry then executes the
same mutation a second time.

There is also no reservation owner/generation in `run_reserved/2` or
`release/1`: both match only the API key and idempotency string. The original
request can overwrite its successor's stored response, or delete the
successor's reservation on an error. The atomic takeover only serializes
the retries competing to take over; it does not exclude the original owner.

Evidence: `lib/phoenix_kit_projects/api_keys.ex:411`, `:436`, `:457`.
The accompanying reproduction keeps the first callback alive, ages its
reservation to simulate elapsed time, runs a second callback successfully,
then resumes the first. Both execute, and a subsequent replay returns the
first callback's response instead of the second's.

Recommendation: serialize execution across the whole mutation, or use a
lease with enforced ownership and cancellation/fencing of the old worker.
An owner token on finalization/release prevents response corruption but
alone does not prevent duplicate side effects. A longer timeout alone does
not resolve this race. Until safe recovery exists, retaining `in_progress`
and using deliberate recovery is safer than reclaiming live work by age.

### 2. BUG - MEDIUM: a rejected checklist PATCH still persists text changes

Existing in PR #48 and incompletely fixed by `ca85176`.
`TasksController.do_update/3` writes the task content before applying the
assignment changeset. `check_checklist/1` checks only that the value is a
list; the 50-item limit is enforced later by `Assignment.normalize_checklist/1`.

Reproduction: create a task titled `Before`, then PATCH `title: After`
alongside 51 valid checklist items. The API returns 422, but a subsequent
read shows `After`. The failed request also skips the normal wording stamp
and assignment-updated activity record. The new regression covers an
overlong `waiting_on`, which is now checked early; it does not prove general
PATCH atomicity.

Evidence: `lib/phoenix_kit_projects/web/api/tasks_controller.ex:202`, `:476`;
`lib/phoenix_kit_projects/schemas/assignment.ex:241`.

Recommendation: validate the complete task and assignment changesets
before writing, and commit the PATCH's related writes in one transaction.
Publish broadcasts and success activity only after that transaction commits.

### 3. BUG - MEDIUM: accepted durations can break the parent rollup silently

Existing conversion limitation, not resolved by the new API numeric bound.
The API accepts `estimated_duration: 1000000000` with unit `hours` because
it caps the raw integer. A child project's parent assignment stores its
total duration in minutes, which becomes 60,000,000,000 and exceeds int4.
Other units and the sum of several assignments can produce the same issue.

Reproduction: create this task under a child project, then start it. The API
returns 200 and the task moves to `in_progress`. The parent linking row
remains at its old duration (0 in the reproduction) and old status.
Calling `Projects.recompute_project_completion/1` directly raises
`DBConnection.EncodeError`; the API's `sync_project_completion/1` rescues
that error without logging it. This is stale rollup data, not a reproduced
HTTP 500 on the start endpoint.

Evidence: `lib/phoenix_kit_projects/web/api/tasks_controller.ex:918`, `:780`;
`lib/phoenix_kit_projects/projects.ex:2485`.

Recommendation: enforce bounds on normalized totals as well as raw inputs,
or widen rollup storage with a migration. Account for multiple assignments.
Do not silently report success when the required rollup failed.

### 4. BUG - MEDIUM: generated ledger correction docs advertise the wrong scopes

Introduced by the scope correction in `ca85176`. PATCH and DELETE
`/entries/{id}` now require `usage:write` for token/cost entries and
`time:write` for time entries. Their authoritative `Docs.endpoints/0` rows
still say only `scope: time:write`. Both `llms.txt` and OpenAPI derive from
this table, so an agent following the advertised contract cannot correct
usage with the documented scope.

Evidence: `lib/phoenix_kit_projects/web/api/docs.ex:981`, `:1017`;
`lib/phoenix_kit_projects/web/api/ledger_controller.ex:201`.

Recommendation: describe both scopes and the condition by entry kind in
the endpoint table and generated contract. Add a contract check alongside
the existing functional scope regression.

## Assessment of Claude's work

The template type check, project settings sanitization and fresh-settings
fold, comments target restriction, edit-floor entries, timestamp preservation,
row-specific ledger scope, malformed-ref handling, sub-project transition
restriction, description synchronization, pending-submission rejection, and
personal-account liveness/revocation are supported by the committed code.

The corrected redirect claim and the decision to preserve claims across
reopening agree with the implementation and existing contract. I did not
independently repeat the reported old-code run yielding 16 failing tests;
the current regression files do run successfully.

The four new LiveView tests use the default site-admin scope. They cover
the template type boundary, fresh settings, redirect input narrowing, and
cross-project comments targets. They do not exercise a denied
`manage_modules` save or the new redirect/adopt edit-floor denial. Add
ordinary-member tests with explicit restrictive floors for those claims.

The open issues already recorded in `SONNET_REVIEW.md` remain. In
particular, the claim race and sub-project completion permission gap are
behavioral concerns, rather than merely form polish. Request fingerprinting,
idempotency retention, and the crash window between a committed mutation
and storing its response also remain design work.

## Validation and release state

- `mix precommit`: exit 0, including compilation, formatting, Hex retired
  dependency audit, Credo, and Dialyzer. Dialyzer reported seven errors, all
  covered by existing ignores; no unnecessary ignores.
- `mix test`: 1712 tests, 0 failures; database-backed tests ran.
- Claude's three regression files: 24 tests, 0 failures.
- Accompanying `REPRO_TEST.exs`: three tests confirm findings 1–3 against
  this commit. These tests assert the defects, so they should fail after
  the defects are fixed. Run with `mix test
  dev_docs/pull_requests/2026/ca85176-release-audit/REPRO_TEST.exs`.
- Companion `elixir:*` thinking skills referenced by `pr-review-release`
  were unavailable in this environment; source review was performed directly.
- Local version and latest Hex release are `0.28.0`, published October 1,
  2026 (verified through `https://hex.pm/api/packages/phoenix_kit_projects`).
  PR #48 and `ca85176` are unreleased. The local tracking ref for upstream
  was at `f75d62b`; no remote fetch was used to claim current remote HEAD.
- A later release needs a version bump and CHANGELOG entry covering the
  API, fixes, schema V17–V20 and core floor `>= 2.49.0 and < 3.0.0`.
  No version bump, push, publication, or tag was performed by this audit.
