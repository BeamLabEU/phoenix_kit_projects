# Follow-up items from the PR #13 review

PR #13 (`Tighten default prompt template + embedding-contract docs + 5xx
retry`) is already merged. This review surfaced a few items. The
**low-risk, clear-cut** ones were handled on branch
`followup-review-13-fixes`:

- **M1** — `retryable?/1` 5xx allow-list now has direct test coverage.
  `retryable?/1` was made `@doc false` public (it's pure and otherwise
  unreachable in CI, where the AI plugin isn't loaded so `perform/1`
  only ever produces `:ai_not_installed`). New pure-unit tests live in
  `test/phoenix_kit_projects/workers/translate_resource_worker_retryable_test.exs`
  (Level 1, no DB).
- **N1** — fixed the stale `:translation_in_flight?` comment in
  `project_form_live.ex` (the save button is gated on
  `@ai_translate_in_flight != []`).
- **N2** — removed the identity `case` at the end of
  `persist_translation_atomic/4`; `repo.transaction/1` already returns
  the contracted `{:ok, _} | {:error, _}` shape.

The items below need design judgment or a larger change and are left for
a maintainer. Each is self-contained.

---

## L1 — Progress-bar total can overcount (latent; currently unreachable via UI)

**Where**
- `lib/phoenix_kit_projects/translations.ex` — `enqueue_all_missing/2`
  returns `in_flight: enqueued_langs ++ conflict_langs` (~line 354).
- `lib/phoenix_kit_projects/web/{project,template,task}_form_live.ex` —
  the bulk `do_dispatch_ai_translate/4` clause binds that `in_flight`
  list to `enqueued_langs` and calls
  `AITranslateFormHelpers.bump_translation_started(length(enqueued_langs))`.
- `lib/phoenix_kit_projects/web/ai_translate_form_helpers.ex` —
  `bump_translation_started/2` docstring advertises the additive
  "click FR while SQ is mid-flight → bar grows to 2/2" flow.

**Problem**
`ai_translation_total` is bumped by the count of *all* in-flight langs,
including **conflicts** (a job already running for that lang). A conflict
produces **no new** `:translation_completed` broadcast, so if a conflict
lang were ever counted, `ai_translation_progress` could never reach
`ai_translation_total`. The session would still flip to `:completed`
(green bar) when `ai_translate_in_flight` empties — i.e. a green bar
stuck below 100%.

In practice this is **unreachable through the modal**: the Translate
button is `disabled` whenever `has_in_flight?` is true
(`ai_translate_bar.ex` `action_disabled?/1`), so a second dispatch can't
start while jobs are running, and `conflict_langs` is therefore always
empty when dispatched from the UI. The `bump_translation_started/2`
docstring describes a mid-flight additive scenario that the disabled
button actually prevents — so the doc and the additive `:in_progress`
branch are currently misleading/dead.

**Decision needed** — pick one:

1. **Keep the button gated (current behaviour) and correct the docs.**
   Update the `bump_translation_started/2` docstring to drop the
   "click FR while SQ mid-flight" example, and note that the additive
   `:in_progress` branch is forward-looking (only exercised if the
   button is ever allowed to dispatch mid-flight). Lowest effort.
2. **Allow mid-flight additive dispatch** (re-enable the button while
   jobs run) and fix the accounting so it's correct. Then
   `bump_translation_started/2` must be bumped only by langs *newly
   added* to `ai_translate_in_flight`, not by the full returned list:

   ```elixir
   # in each bulk do_dispatch_ai_translate/4 clause
   {:ok, %{in_flight: [_ | _] = now_in_flight, enqueued: n, errors: errors}} ->
     prev = socket.assigns.ai_translate_in_flight
     newly = now_in_flight -- prev          # exclude already-counted langs
     socket
     |> assign(:ai_translate_in_flight, Enum.uniq(prev ++ now_in_flight))
     |> AITranslateFormHelpers.bump_translation_started(length(newly))
     ...
   ```

   Apply to all three form LVs. Note this also interacts with
   cross-session events: a `:translation_started` from another
   admin/tab on the same resource adds to `ai_translate_in_flight`
   without a local `bump_translation_started`, so `progress` can exceed
   `total`; `progress_visible?/1` already hides the bar when
   `total == 0`, but consider clamping `progress` to `total` in
   `bump_translation_completed/2` for safety.

**Acceptance**: dispatching bulk, then (if option 2) a single lang
mid-flight, ends with `progress == total` and a full green bar; option 1
just removes the misleading doc.

---

## L2 — `.dialyzer_ignore.exs` regexes are broader than their rationale

**Where** `.dialyzer_ignore.exs` lines 23, 31–32.

```elixir
~r"lib/phoenix_kit_projects/web/(project|template|task)_form_live\.ex:\d+:\d+:(call|unused_fun)",
~r"lib/phoenix_kit_projects/web/(project|template|task)_form_live\.ex:\d+:guard_fail",
~r"lib/phoenix_kit_projects/workers/translate_resource_worker\.ex:\d+:guard_fail",
```

**Problem**
These ignore **every** `:call` / `:unused_fun` / `:guard_fail` warning in
those files, not just the specific pre-existing ones documented in the
comments. A genuinely new warning of those categories — introduced by a
future change to any of the three form LVs or the worker — would be
silently suppressed.

**Root cause / proper fix**
The `:call` + `:unused_fun` noise comes from `enqueue_all_missing/2`
accepting a `base_params` map without `:target_lang` while the
`enqueue_params` type marks `:target_lang` as required. Introduce a
dedicated type for the bulk path so dialyzer stops flagging the
call sites, then delete the broad ignore:

```elixir
# translations.ex
@typedoc "enqueue_params minus :target_lang — the bulk-dispatch base."
@type base_enqueue_params :: %{
        required(:resource_type) => resource_type(),
        required(:resource_uuid) => String.t(),
        required(:endpoint_uuid) => String.t(),
        required(:prompt_uuid) => String.t(),
        required(:source_lang) => String.t(),
        optional(:actor_uuid) => String.t() | nil
      }

@spec enqueue_all_missing(base_enqueue_params(), [String.t()]) :: ...
```

For the `:guard_fail` entries (`reloaded.translations || %{}` where the
schema typespec makes `:translations` non-nil), either drop the defensive
`|| %{}` (and trust the schema default) or, if keeping it for
forward-compat, narrow the ignore to the exact lines rather than a
file-wide `:\d+:guard_fail`.

**Acceptance**: `mix dialyzer` stays green after removing/narrowing the
three broad entries; the only remaining worker/LV ignores are the
specifically-documented `pattern_match` / `pattern_match_cov` ones.

---

## L3 — Bulk completion does N full reloads + N overwriting flashes

**Where**
`lib/phoenix_kit_projects/web/{project,template,task}_form_live.ex` —
the `:translation_completed` `handle_info`.

```elixir
case Projects.get_project(uuid) do
  ...
  reloaded ->
    new_translation = Map.get(reloaded.translations || %{}, lang, %{})
    socket |> assign(:project, reloaded) |> patch_form_translations(lang, new_translation) ...
```

**Problem**
For a bulk dispatch of N languages, each `:translation_completed` event
triggers a **full** `Projects.get_project/1` reload and a per-lang
`put_flash(:info, "Translated to X.")`. With ~40 enabled languages that's
40 sequential full-resource reads on the LV process and 40 flashes that
collapse to a single visible message. Functionally correct (events are
spaced by AI completion timing), but wasteful.

**Recommended fix**
The worker already broadcasts the translated fields in the payload:

```elixir
# translate_resource_worker.ex
broadcast(:translation_completed, resource, type, params, fields: translated_fields)
```

Merge from `payload.fields` instead of re-querying:

```elixir
def handle_info({:projects, :translation_completed,
      %{resource_uuid: uuid, target_lang: lang} = payload}, socket)
    when uuid == socket.assigns.project.uuid do
  socket = AITranslateFormHelpers.bump_translation_completed(socket, lang)

  cond do
    Map.get(payload, :empty, false) -> {:noreply, put_flash(socket, :info, ...)}
    true ->
      new_translation = Map.get(payload, :fields, %{})
      {:noreply,
       socket
       |> patch_form_translations(lang, new_translation)
       |> put_flash(:info, gettext("Translated to %{lang}.", lang: String.upcase(lang)))}
  end
end
```

Notes:
- `payload.fields` carries only the freshly-translated fields for `lang`,
  which is exactly what `patch_form_translations/3` merges — no reload
  needed. The form's `socket.assigns.project` no longer gets refreshed,
  so if anything downstream relies on `assigns.project.translations`
  being current for the *missing-count* recomputation, update that too
  (e.g. merge the new lang into `assigns.project.translations` in-memory).
- For bulk, consider debouncing the flash (e.g. only flash the final
  completion, or switch to a single "Translated N languages" summary
  when `ai_translate_in_flight` empties) so the user isn't shown a
  flicker of per-lang messages.

**Acceptance**: a 40-lang bulk completes with zero `Projects.get_project/1`
calls in the completion path and at most one flash per logical batch;
the form shows all translated langs without a page refresh.

---

## N3 — `:project_updated` is broadcast inside the `FOR UPDATE` transaction

**Where**
`lib/phoenix_kit_projects/workers/translate_resource_worker.ex`
`persist_translation_atomic/4` calls `persist_translation/3` →
`Projects.update_project/2`, which runs `repo().update()` **and**
`ProjectsPubSub.broadcast_project(:project_updated, ...)` — all inside
the `repo.transaction` that holds the row lock.

**Problem (low risk today)**
The broadcast fires before the transaction commits. A subscriber that
reacts by reading the row back would see the *pre-commit* (locked) state.
Today this is harmless because `update` is the terminal step in the
transaction (no rollback can follow a successful update), and the
payload carries `name`/`is_template` from the changeset rather than
requiring a re-read. But it's a latent footgun if the transaction body
ever grows a step after the update.

**Options**
- Leave as-is and add a one-line comment at the lock site noting that
  `update_project/2` broadcasts inside the transaction and must remain
  the final step.
- Or thread an `opts` flag so the worker's persist path skips the
  in-context `broadcast_project` and re-broadcasts after
  `repo.transaction` returns `{:ok, _}` (cleaner, more code).

**Acceptance**: either a comment documenting the constraint, or the
broadcast moved to after commit.
