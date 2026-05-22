# PR #13 — Follow-up

PR is merged into `main` (merge commit `6907b1c`, version bump landed
in `9f8f947` → 0.5.1). The post-merge review lives at the repo root
as `REVIEW_FOLLOWUP_PR13.md` (placement set by the boss; per
`feedback_reviewer_artifacts.md` it stays where it was put, this
folder simply links to it).

## Pre-existing post-merge fixes (already on `main`)

Landed in `4e5cd10` ("Follow-up review fixes for PR #13: 5xx retry
test + cleanups") immediately after the merge:

- **M1** — `retryable?/1` promoted to `@doc false` `def` + Level-1
  unit tests for the full classification (transient AI atoms, the
  500/502/503/504/522/524/529 allow-list, 501/505 + 4xx discard,
  non-HTTP discard). Pure-function tests live in
  `test/phoenix_kit_projects/workers/translate_resource_worker_retryable_test.exs`
  and need no DB.
- **N1** — fixed stale `:translation_in_flight?` comment in the save
  guard (the assign is `@ai_translate_in_flight != []`).
- **N2** — dropped identity `case` in `persist_translation_atomic/4`;
  `repo.transaction/1` already returns the contracted shape.

## Fixed (Batch 1 — 2026-05-22)

Picked up the four `REVIEW_FOLLOWUP_PR13.md` items the boss left for
a maintainer. Branch `followup-review-pr13-fixes` (local; not yet
pushed):

- **L1 — Progress overcount with conflict_langs (forward-looking).**
  The dispatch button is `disabled` whenever `has_in_flight?` is
  true, so the additive `:in_progress` branch of
  `bump_translation_started/2` is currently unreachable through the
  modal. The previous docstring's "click FR while SQ is mid-flight"
  example was therefore misleading. Rewrote the docstring to:
  - State plainly that the current call sites pass
    `length(in_flight)` (= `enqueued + conflicts`).
  - Document the additive branch as forward-looking (for a future
    queue-style admin UI that allows mid-flight dispatch).
  - Spell out the conflict-accounting caveat for that future host:
    a conflict-dedup'd dispatch rides along with the existing job,
    so the worker emits **one** `:translation_completed` per actual
    job (not per click). Counting conflicts in `started_count`
    would leave `progress < total` forever. The fix (when needed) is
    `length(in_flight -- prev_in_flight)`.

  Code untouched: button-gated UI keeps the issue unreachable today.

- **L2 — Broad dialyzer regexes.** Replaced the file-wide
  `:call|:unused_fun` ignore with a proper spec fix: added
  `base_enqueue_params` type for `enqueue_all_missing/2` (the
  function explicitly drops `:target_lang` and re-adds it per lang,
  so the bulk call sites pass a map without that key). Dialyzer no
  longer flags the call sites; the broad ignore is gone. The
  `:guard_fail` ignore on the LVs is also gone — L3 (next) removed
  the `|| %{}` pattern from those files entirely.

- **L3 — N reloads + N flashes on bulk completion.** Each
  `:translation_completed` previously did a full
  `Projects.get_project/1` (or `get_task/1`). For a 40-lang bulk
  that's 40 sequential reads. Switched to merging from
  `payload.fields` (the worker already broadcasts the translated
  fields). The form's `:project` / `:task` assign still gets
  refreshed for missing-count recompute, but via
  `update_in/3` against the in-memory struct — no DB round-trip.
  Flash behavior unchanged (per-lang flashes overwrite, user sees
  the last one for bulk; "summarised flash" left for a UX iteration).

- **N3 — Broadcast inside `FOR UPDATE` transaction.** Added a
  CONSTRAINT comment at the lock site documenting that
  `persist_translation/3`'s `Projects.update_*` emits a
  `:project_updated` / `:task_updated` PubSub broadcast inside the
  transaction. Today harmless because update is the terminal step;
  flagged so a future maintainer who adds work after the persist
  knows to move the broadcast outside the transaction (or rebind
  `broadcast_*` opts on `update_*`).

Also landed in this batch:

- **Version-bump completion.** The boss's `9f8f947` (release 0.5.1)
  bumped `mix.exs` but missed `PhoenixKitProjects.version/0` which
  is asserted equal to `Mix.Project.config()[:version]` in two
  tests. Updated the hard-coded string to `"0.5.1"` so
  `mix test` is green again.

## Skipped (with rationale)

None. The L1 doc-only resolution and the deferred fail-closed vs
fail-loud question (covered separately in PR #20's FOLLOW_UP)
exhaust the maintainer items.

## Files touched

| File | Change |
| --- | --- |
| `lib/phoenix_kit_projects.ex` | `version/0` "0.5.0" → "0.5.1" (boss's bump missed this) |
| `lib/phoenix_kit_projects/translations.ex` | `+base_enqueue_params` type; `enqueue_all_missing/2` spec uses it |
| `lib/phoenix_kit_projects/web/ai_translate_form_helpers.ex` | `bump_translation_started/2` docstring rewrite (L1) |
| `lib/phoenix_kit_projects/web/project_form_live.ex` | `:translation_completed` merges from `payload.fields` instead of reloading (L3) |
| `lib/phoenix_kit_projects/web/template_form_live.ex` | same as project (L3) |
| `lib/phoenix_kit_projects/web/task_form_live.ex` | same, uses `:task` assign (L3) |
| `lib/phoenix_kit_projects/workers/translate_resource_worker.ex` | CONSTRAINT comment at `FOR UPDATE` lock site (N3) |
| `.dialyzer_ignore.exs` | `:call`/`:unused_fun` ignore removed (L2); LV `:guard_fail` ignore removed (no longer triggered after L3) |

## Verification

- `mix compile --warnings-as-errors` — clean
- `mix format --check-formatted` — clean
- `mix credo --strict` — no issues
- `mix dialyzer` — 0 errors, 20/20 skipped, 0 unnecessary
- `mix test` — 638/638 pass (was 636/638 due to the version-mismatch
  test failures the boss's bump introduced; fixed inline)
- Codex final review — clean. One docstring factual error caught
  on the L1 explanation ("conflict-dedup'd job won't emit a
  `:translation_completed`" was misleading); rewritten to "rides
  along with the same job → one broadcast per actual job, not per
  click."

## Open

None.

## See also

- `/REVIEW_FOLLOWUP_PR13.md` (repo root) — the boss's original
  maintainer-action list. This document records the resolution of
  each L/N item.
