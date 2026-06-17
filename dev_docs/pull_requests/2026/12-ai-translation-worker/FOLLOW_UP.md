# Follow-up — PR #12 (AI translation worker + AI translate UI)

**Date:** 2026-05-21
**Reviewer artifact:** `CLAUDE_REVIEW.md` (Claude / Claude Code, Opus 4.7, 2026-05-21)
**Baseline at triage:** `main` post-`a7a01de` (PR #12 merge)

Triage of the Claude review on the merged PR #12 (Oban-backed
`TranslateResourceWorker` + `<.ai_translate_bar>` modal on the project /
template / task form LVs). The review captured 2 MEDIUM, 2 LOW, and 1 NIT, all
non-blocking. Every actionable finding is resolved in this sweep; the larger
`handle_info` dedup is recorded as a deliberate not-fix below.

## Fixed (Batch 1 — 2026-05-21)

- ~~**Finding MEDIUM 1 — Oban `unique` defaulted to a 60s window.**~~ Fixed.
  `lib/phoenix_kit_projects/workers/translate_resource_worker.ex` — added
  `period: :infinity` to the `unique:` config. Oban 2.22's `@unique_defaults`
  sets `period: 60` when omitted, so the documented "one job in flight per
  `(resource_uuid, target_lang)`" invariant only held for translations that
  finished inside a minute; a slower AI call could be duplicated by a second
  enqueue once the original's `inserted_at` aged past 60s (burning tokens
  twice). With `:infinity` the dedup is bounded by the in-flight `states`
  instead of time — a duplicate is rejected as long as the original is still
  `available`/`scheduled`/`executing`/`retryable`, and a fresh job is allowed
  only once the previous reaches a terminal state (re-translating later still
  works). `:infinity` is an explicitly supported `unique_period` value in
  Oban. Moduledoc "## Uniqueness" section updated to explain the choice.

- ~~**Finding MEDIUM 2 — "all"/overwrite scope diverged between DB and the open
  form.**~~ Fixed by threading overwrite intent end-to-end.
  The worker always persisted with `Map.merge/2` (AI wins) while the form
  patched with `merge_blank_fields_only/2` (existing non-blank values win). For
  the `:all` scope ("overwrites existing") that meant the DB was overwritten but
  the open form kept the old values, and a subsequent Save reverted the
  overwrite. Now:
  - `lib/phoenix_kit_projects/translations.ex` — `to_job_args/1` carries a
    normalised boolean `"overwrite"` (defaults `false`); `@type enqueue_params`
    documents the optional key.
  - `lib/phoenix_kit_projects/workers/translate_resource_worker.ex` — reads
    `overwrite` from job args and includes it in both `:translation_completed`
    broadcasts (success + empty short-circuit).
  - `lib/phoenix_kit_projects/web/ai_translate_form_helpers.ex` — new
    `merge_translation_fields/3`: `overwrite? == true` → `Map.merge/2` (AI wins,
    mirrors the DB); `false` → existing `merge_blank_fields_only/2` (edits win).
  - The three form LVs — `do_dispatch_ai_translate(socket, scope, …)` sets
    `overwrite: scope == "**"`; `patch_form_translations/4` applies the
    scope-aware merge using `payload.overwrite`. The `:all` scope now reflects
    in the open form and survives a save; `:missing` / `:current` keep the
    in-flight edit protection. The modal's existing overwrite warning is now
    accurate (no copy change needed).

- ~~**Finding LOW 1 — five Settings/AI lookups ran on both mount passes.**~~
  Fixed. `lib/phoenix_kit_projects/web/ai_translate_form_helpers.ex` — new
  `assign_ai_translate_mount_state/1` runs the DB/plugin-backed lookups
  (default endpoint/prompt UUIDs, endpoint + prompt lists, default-prompt
  existence) only on the **connected** mount; the dead HTTP render gets empty
  defaults. The pure socket state (`ai_translate_in_flight`,
  `ai_translate_scope`, `show_ai_translation_modal`) is assigned
  unconditionally. The three LV mounts now pipe through this single helper
  instead of an inline 11-key `assign/2` — also removes that duplication.

- ~~**Finding LOW 2 — empty-resource completion flashed "Translated".**~~ Fixed.
  The three form LVs' `:translation_completed` handler now branches on
  `payload.empty`: when true it flashes "Nothing to translate for %{lang} — the
  source has no content yet." and skips the resource reload + form patch
  entirely; otherwise it proceeds with the reload + scope-aware patch.

- ~~**NIT — `get_uuid/1` single-clause.**~~ Fixed.
  `lib/phoenix_kit_projects/workers/translate_resource_worker.ex` — added
  `defp get_uuid(_), do: nil` so a malformed / future struct without `:uuid`
  degrades to a nil uuid in logs/broadcasts instead of crashing the whole job
  with a `FunctionClauseError`.

## Not fixed (deliberate)

- **~150 LOC of duplicated dispatch / `handle_info` wiring across the three
  form LVs.** The PR author flagged this as a post-PR-3 follow-up and the review
  agreed. This sweep lifts two more pieces into the shared helper
  (`merge_translation_fields/3`, `assign_ai_translate_mount_state/1`), but the
  full `handle_info` extraction is left for the larger structural refactor when
  assignment forms join — extracting it now would churn three files for a seam
  that's about to change shape.

## Tests

- `test/phoenix_kit_projects/web/ai_translate_form_helpers_test.exs` — 4 new
  tests pinning `merge_translation_fields/3` (overwrite true vs false, AI-wins
  on non-blank, preserves untouched fields, blank-fill parity).
- `test/phoenix_kit_projects/workers/translate_resource_worker_test.exs` — 1 new
  test asserting the `overwrite` flag propagates to the `:translation_completed`
  broadcast (via the empty-fields path, which is reachable without the AI
  plugin).

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_projects/workers/translate_resource_worker.ex` | `period: :infinity` (MEDIUM 1); read `overwrite` arg + add to completion broadcasts (MEDIUM 2); `get_uuid/1` fallback (NIT); moduledoc |
| `lib/phoenix_kit_projects/translations.ex` | `to_job_args/1` normalises + carries `"overwrite"`; `@type enqueue_params` doc (MEDIUM 2) |
| `lib/phoenix_kit_projects/web/ai_translate_form_helpers.ex` | New `merge_translation_fields/3` (MEDIUM 2) + `assign_ai_translate_mount_state/1` (LOW 1) |
| `lib/phoenix_kit_projects/web/project_form_live.ex` | Mount via helper (LOW 1); `:translation_completed` empty branch + overwrite thread (LOW 2 / MEDIUM 2); `overwrite: scope == "**"` dispatch; `patch_form_translations/4` |
| `lib/phoenix_kit_projects/web/task_form_live.ex` | Same as project_form_live |
| `lib/phoenix_kit_projects/web/template_form_live.ex` | Same as project_form_live |
| `test/phoenix_kit_projects/web/ai_translate_form_helpers_test.exs` | +4 `merge_translation_fields/3` tests |
| `test/phoenix_kit_projects/workers/translate_resource_worker_test.exs` | +1 overwrite-flag broadcast test |

## Verification

- `mix compile --warnings-as-errors` — clean.
- `mix format --check-formatted` — clean.
- `mix credo --strict` on the 6 changed source files — 0 issues.
- Pure-logic suite (`ai_translate_form_helpers_test`, `ai_translate_bar_test`) —
  **68 tests, 0 failures** (was 64; +4 new).
- Verified `period: :infinity` is a valid Oban `unique_period`
  (`oban/lib/oban/validation.ex:70`, `job.ex:29`).

## Resolved post-triage (2026-05-30)

- ~~DB-backed suites (worker, translations, LV tests) not run — no Postgres.~~
  Run with the DB up. The three suites this finding named pass:
  `workers/translate_resource_worker_test.exs` + `translations_test.exs` +
  the three form-LV tests (`project`/`task`/`template`) — **58 tests, 0
  failures**. The additive `overwrite` job-arg / payload key and the
  handler-signature change confirmed non-breaking against the real DB. The
  full module suite is green as well (**737 tests, 0 failures** via the core
  path-override, per `feedback_run_tests_via_parent`).

## Open

None.
