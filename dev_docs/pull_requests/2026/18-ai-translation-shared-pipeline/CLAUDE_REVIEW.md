# Code Review: PR #18 — Migrate AI translation onto the shared core pipeline + quality

**Reviewer:** Claude (Opus 4.8 1M) — review performed with the `elixir`, `phoenix-thinking`, `elixir-thinking`, and `ecto-thinking` skill packs loaded.
**Date:** 2026-06-04
**PR:** https://github.com/BeamLabEU/phoenix_kit_projects/pull/18 (merged)
**State:** MERGED — review + follow-up fixes captured post-merge on `main`.
**Scope:** 444 additions / 3964 deletions across 19 files, 5 commits. Replaces the projects-local AI-translation stack (`Translations` context, `TranslateResourceWorker`, `AITranslateBar`) with core's generic pipeline + the shared modal/glue, plus a Phase 1/2 quality pass.

---

## Overall

Strong PR. ~1000 net lines of duplicated machinery deleted; the surviving project-specific code is two small, well-documented modules — `PhoenixKitProjects.AITranslatable` (the server/DB half) and `PhoenixKitProjects.AITranslateBinding` (the form/changeset half) — cleanly split along the right seam. The `FOR UPDATE` re-read + merge in `put_translation/4` is the correct guard for concurrent per-language jobs, and `fetch/2`'s `is_template` validation closes a real cross-translation hole (a "project" job can't translate a template and broadcast on the wrong topic).

Verified during this review:

- **Compiles clean** via the integration app (the earlier "main blocked on a phoenix_kit release" note is now stale — the core release shipped).
- **All three schemas (`Project`, `Task`, `Assignment`) cast and shape-validate `:translations`** in the changeset that `put_translation/4` routes through, so there is **no silent no-op** for any registered resource type.
- `mix format --check-formatted` clean.

Adapter unit tests are `:integration`-tagged and need Postgres, which is unavailable in this review environment — they were not executed here (the author verified them against a local core). The new tests added below compile.

Findings are split into **FIXED** (applied on this branch as part of this review) and **OPEN** (left for a developer, with enough detail to finish). Nothing blocks.

---

## FIXED (applied during this review)

### F1. `source_value/2` — flattened nested `case`/`if`; shared `present?/1` helper
**File:** `lib/phoenix_kit_projects/ai_translatable.ex`

The nested `case … -> if String.trim(v) != ""` is replaced by a single `present?/1` predicate (non-blank binary), reused by both `source_value/2` and the `source_fields/2` comprehension filter. Same behaviour, less branching, intent stated once. (elixir-thinking: avoid nested `case`.)

### F2. `column_value/2` rescue — documented as intentional, not dead
**File:** `lib/phoenix_kit_projects/ai_translatable.ex`

`String.to_existing_atom/1` can't raise today (fields always come from a schema's `translatable_fields/0`). The `rescue ArgumentError -> nil` is kept but now carries a comment explaining the one future case it guards (a field listed in `translatable_fields/0` without a matching column) and why returning `nil` — skipping the field — is preferable to crashing the Oban job into an infinite retry.

### F3. `AITranslateBinding.has_any_field?/2` — aligned to the same `present?/1` shape
**File:** `lib/phoenix_kit_projects/ai_translate_binding.ex`

Collapsed the inline `case`/`String.trim` to a local `present?/1`, mirroring the adapter so the "non-blank binary" rule reads identically on both sides of the glue. (Modules kept independent by design — see O3.)

### F4. Adapter test coverage for previously-untested paths
**File:** `test/phoenix_kit_projects/ai_translatable_test.exs` (+4 tests)

- `source_fields/2`: blank/whitespace override falls back to the primary column.
- `source_fields/2`: blank source fields are excluded from the result map.
- `put_translation/4`: persists a **task** translation (was project-only).
- `put_translation/4`: row deleted mid-flight rolls back with `:resource_not_found` (the rollback path was untested).

---

## OPEN (for a developer to finish)

### O1. `assignment` AI-translate is only half-wired — **needs a product decision**
**Severity:** MEDIUM (functional gap or intentional asymmetry — confirm which)

`"assignment"` is registered in `PhoenixKitProjects.ai_translatables/0` and fully supported server-side (`AITranslatable.fetch/source_fields/put_translation` handle `%Assignment{}`; `AITranslateBinding.fields_for("assignment")` exists). **But `lib/phoenix_kit_projects/web/assignment_form_live.ex` never calls `FormGlue.assign_ai_translation/4`** — it is the only resource form LV that doesn't. Consequences:

- The assignment form supports **manual** multilang editing of `:description` but has **no AI-translate button** (project/task/template all got one).
- `AITranslateBinding.existing_translation_langs("assignment", …)` / `apply_translation("assignment", …)` are unreachable from the UI — nothing routes through them.
- The server-side `assignment` path is reachable only via a host-driven enqueue.

**Decision needed:** is assignment intentionally server-only (host-driven), or was the form wiring missed?

- **If it should have the button:** mirror `project_form_live.ex` —
  1. add `alias PhoenixKitWeb.Components.AITranslate.FormGlue`;
  2. in `mount`, append `|> assign_ai_translate()` where `assign_ai_translate/1` calls `FormGlue.assign_ai_translation(socket, "assignment", resource_or_nil, PhoenixKitProjects.AITranslateBinding)` (resource is the assignment on `:edit`, `nil` on `:new`);
  3. add the six thin `ai_*` `handle_event` delegators and the one `{:ai_translation, _, _}` `handle_info` (verbatim from `project_form_live.ex`);
  4. gate `save` on `socket.assigns.ai_in_flight == []`;
  5. render the shared button/modal in the template (single-field: `:description` only).
  6. Browser-verify edit→translate→persist, and the `:new` "save first" flash.
- **If it's intentionally server-only:** drop `assignment` from `ai_translatables/0` **or** add a one-line `@moduledoc` note in both `AITranslatable` and `AITranslateBinding` stating that `assignment` is enqueue-only (no form UI), so the unreachable binding branch doesn't read as a bug.

### O2. Translation write *suppresses* the resource broadcast instead of *deferring it to post-commit*
**Severity:** LOW (design / depends on requirements)

`put_translation/4` passes `broadcast: false` because the context updater's `:*_updated` event would otherwise fire **pre-commit** (inside the `FOR UPDATE` transaction) and look like a user edit. Correct diagnosis. But suppressing entirely means any subscriber **not** on core's per-resource AI topic — e.g. a project/task **show** or **list** LV — never learns about the translation write and won't refresh until reload.

The fuller fix: emit the broadcast **after** `repo.transaction/1` returns `{:ok, _}` (post-commit, from the adapter), so legitimate viewers refresh without the pre-commit race. Acceptable as-is because the form LVs rely on core's `:translation_completed`; only worth doing if a non-form view needs live translation updates. If left as-is, no action — `broadcast: false` is the intended behaviour and is documented inline.

### O3. Minor duplication between the adapter and the binding
**Severity:** LOW (intentional layering — note only)

`AITranslatable` and `AITranslateBinding` each carry their own `fields_for/1`, `present?/1`, and the identical lang-map merge (`Map.put(map, lang, Map.merge(existing, fields))`). They sit on different layers (DB persist vs form changeset), so the split is deliberate; F1/F3 already made the predicate read identically. A future cleanup could lift the merge + `present?` into a tiny shared `PhoenixKitProjects.Translations.Util` if a third caller appears. Not worth a shared module for two callers today.

### O4. `put_translation/4` concurrency is untested (the reason the transaction exists)
**Severity:** LOW (test gap — hard to write reliably)

F4 added the rollback path, but the **concurrent** `FOR UPDATE` merge — two per-language jobs persisting at once without dropping each other's siblings — is still only exercised sequentially. A real concurrency test needs two processes racing on the row lock inside the Ecto sandbox (e.g. `Task.async` with shared-connection mode, or a `pg_advisory`/checkout dance), which is fiddly and easy to make flaky. Left for a developer who wants to pin the lock semantics; the sequential "keeps sibling fields" test is a partial proxy.

### O5. No `assignment` adapter fixture/tests
**Severity:** LOW (test gap)

There is no `fixture_assignment` in `test/support/data_case.ex` (an assignment needs a project + task linkage), so the adapter's `assignment` `source_fields`/`put_translation` paths are untested. If O1 lands as "wire the form", add a `fixture_assignment/1` and the matching adapter tests at the same time.

---

## Status summary

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| F1 | Flatten `source_value/2`, add `present?/1` | style | ✅ Fixed |
| F2 | Document `column_value/2` rescue intent | minor | ✅ Fixed |
| F3 | Align binding `has_any_field?/2` | minor | ✅ Fixed |
| F4 | Tests: blank-skip, task persist, not-found rollback | test gap | ✅ Fixed |
| O1 | `assignment` AI-translate half-wired | medium | ⏳ Needs decision |
| O2 | Broadcast suppressed vs. post-commit | low | ⏳ Open (design) |
| O3 | Adapter/binding duplication | low | ⏳ Note only |
| O4 | Concurrency test for `put_translation/4` | low | ⏳ Open |
| O5 | No `assignment` fixture/tests | low | ⏳ Open (with O1) |
