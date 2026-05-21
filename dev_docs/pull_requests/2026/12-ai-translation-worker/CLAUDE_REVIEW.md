# PR #12 Review — AI Translation Worker + AI Translate UI on Form LVs

**Reviewer:** Claude (Claude Code, Opus 4.7)
**Date:** 2026-05-21
**PR:** [BeamLabEU/phoenix_kit_projects#12](https://github.com/BeamLabEU/phoenix_kit_projects/pull/12) (merged, `a7a01de`)
**Baseline:** `main` post-merge (`a7a01de`); PR head `4372e7a`
**Method:** Reviewed via the Elixir thinking skills (oban-thinking, phoenix-thinking).

---

## Executive Summary

A genuinely strong PR. The Oban worker follows the deterministic-vs-transient
retry discipline (`{:discard, _}` for non-retryable failures so retries don't
burn AI tokens), respects the JSON-serialization rule (string-keyed `perform/1`
args), sanitizes failure reasons before logging / activity-metadata writes, and
scopes its PubSub fan-out to per-resource topics rather than `topic_all`. The
form LVs patch only the `translations` field of the live changeset via
`Ecto.Changeset.put_change/3` so an in-flight job can't clobber unsaved edits.

**Build status (at review):** pure-logic suite green (64 tests). DB-backed
suites (worker, context, LV) could not run in the review sandbox — no Postgres.
PR reports full suite 563/0, `mix format` + `mix credo --strict` clean.

Two behavioral findings (both MEDIUM) and three minor findings. None are crashes
on the happy path; all are addressed in the follow-up sweep — see `FOLLOWUP.md`.

---

## Findings

### MEDIUM 1 — Oban `unique` has no `period`, so it defaults to 60s

`translate_resource_worker.ex` declares the unique constraint with `keys` and
`states` but **no `:period`**:

```elixir
unique: [
  keys: [:resource_uuid, :target_lang],
  states: [:available, :scheduled, :executing, :retryable]
]
```

Oban 2.22's `@unique_defaults` (`oban/lib/oban/job.ex:235`) sets `period: 60`.
So the documented invariant "one job in flight per `(resource_uuid,
target_lang)`" only holds for jobs that finish within 60 seconds. A multi-field
AI translation can easily exceed that; once the original job's `inserted_at` is
>60s old, a second enqueue is no longer treated as a duplicate and a concurrent
job runs — burning tokens twice.

The UI's `in_flight` set masks this for a single live socket, but
`ai_translate_in_flight` resets to `[]` on every (re)mount and isn't shared
across tabs/users, so on a reconnect or a second tab Oban's unique window is the
only backstop — and 60s is too short for this workload.

**Fix:** add `period: :infinity` (keep the in-flight `states`). Verified Oban
accepts `:infinity` (`@type unique_period :: Period.t() | :infinity`).

### MEDIUM 2 — "All / overwrite" scope diverges between DB and the open form

Two merge policies meet at the `:all` scope:

- Worker persists with `Map.merge(target_map, translated_fields)` — **AI wins**.
- Form patches with `merge_blank_fields_only/2` — **only fills blanks**.

So when a user picks **"All non-primary languages (overwrites existing)"** with
the form open: the DB row is overwritten, but the form keeps the old non-blank
values, and a subsequent **Save pushes the old values back**, undoing the
overwrite. The `:missing` / `:current` scopes are fine (the target was blank);
this is isolated to the explicitly-destructive scope — which is the one place
the divergence is most surprising.

**Fix:** thread an `overwrite` flag through `enqueue` → job args → broadcast →
form so the `:all` scope overwrites in the form too (mirrors the worker), while
`:missing` / `:current` keep the blank-only edit protection.

### LOW 1 — New Settings/AI lookups run in `mount` (called twice)

The mount adds five runtime lookups (`get_default_ai_endpoint_uuid`,
`get_default_ai_prompt_uuid`, `list_ai_endpoints`, `list_ai_prompts`,
`default_translation_prompt_exists?`). `mount/3` runs on both the dead HTTP
render and the WS connect, so each fires twice. These values are only needed
once the modal is interactive (connected).

**Fix:** gate the lookups behind `connected?/1`; dead render gets empty defaults.

### LOW 2 — Empty-resource completion flashes "Translated"

When the source has no translatable content the worker short-circuits to
`:translation_completed` with `empty: true`, and the form still flashes
`"Translated to %{lang}."`. Also reloads the resource on every completion.

**Fix:** branch on `payload.empty` and flash an accurate message; skip the
reload/patch in the empty case.

### NIT — `get_uuid/1` single-clause

`defp get_uuid(%{uuid: uuid})` has no fallback — a resource lacking `:uuid`
would `FunctionClauseError`. All current schemas carry `uuid`, so it's a latent
sharp edge only. **Fix:** add a `get_uuid(_) -> nil` fallback.

### NOT FIXED (deliberate) — ~150 LOC duplicated across the three form LVs

The author flagged this as a post-PR-3 follow-up. The dispatch / `handle_info`
wiring is near-identical in all three form LVs. The follow-up lifts two more
pieces into the shared helper (`merge_translation_fields/3`, the mount-state
assigner) but leaves the full `handle_info` dedup for the larger structural
refactor when assignment forms join.

---

## Recommendation

Merge-ready as shipped (it was merged). The two MEDIUM findings are worth a
fast-follow because they affect token spend (MEDIUM 1) and the correctness of
the explicit overwrite action (MEDIUM 2). All findings resolved in `FOLLOWUP.md`.
