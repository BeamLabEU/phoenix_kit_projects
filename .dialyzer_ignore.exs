[
  # Gettext.Backend generated code triggers opaque-type warnings from
  # Expo.PluralForms — known false positive in gettext ≥ 0.26.
  ~r"lib/phoenix_kit_projects/gettext\.ex:1:call_without_opaque",

  # `PhoenixKitAI` is an optional plugin — present only when the host
  # depends on `:phoenix_kit_ai`. The compiler is silenced via
  # `@compile {:no_warn_undefined, ...}` at the call sites in
  # `translations.ex`. Dialyzer still flags these as `unknown_function`
  # since the dep isn't present in this project's _build. Same pattern
  # core uses for `PhoenixKitAI.ask_with_prompt/4` in
  # `lib/modules/ai/translation.ex`.
  {"lib/phoenix_kit_projects/translations.ex", :unknown_function},

  # `enqueue_all_missing/2` accepts a `base_params` map without
  # `:target_lang` (drops the key explicitly and re-adds per lang
  # in the loop). The `enqueue_params` type requires `:target_lang`,
  # so dialyzer sees every bulk-dispatch call site as failing — and
  # marks `maybe_flash_partial_errors/2` unused because the path
  # supposedly never reaches it. Functionally correct; the spec
  # just needs a separate `base_enqueue_params` type for the bulk
  # path, queued for a separate cleanup PR.
  ~r"lib/phoenix_kit_projects/web/(project|template|task)_form_live\.ex:\d+:\d+:(call|unused_fun)",

  # `reloaded.translations || %{}` defensive fallback. The schema
  # typespec (`field :translations, :map, default: %{}`) makes
  # `:translations` non-nil to dialyzer, so the fallback never
  # fires in practice. Kept across 3 LVs + the worker because a
  # future migration / malformed DB read shouldn't crash a
  # mid-translation render.
  ~r"lib/phoenix_kit_projects/web/(project|template|task)_form_live\.ex:\d+:guard_fail",
  ~r"lib/phoenix_kit_projects/workers/translate_resource_worker\.ex:\d+:guard_fail",

  # `sanitize_reason({:persist_error, _})` clause —
  # `handle_translation_failure/4` is currently only called from
  # the AI-error branch (the persist branch uses its own path),
  # so dialyzer sees the pattern as unreachable. Keeping the
  # clause for forward-compat if a future caller routes a persist
  # error through this helper.
  ~r"lib/phoenix_kit_projects/workers/translate_resource_worker\.ex:\d+:\d+:pattern_match",

  # `defp get_uuid(_), do: nil` defensive catch-all. Every loaded
  # resource carries a `:uuid`, so dialyzer marks the clause
  # unreachable. Kept so a future schema (or malformed struct)
  # without uuid degrades to nil in logs/broadcasts rather than
  # crashing the worker with `FunctionClauseError`.
  ~r"lib/phoenix_kit_projects/workers/translate_resource_worker\.ex:\d+:\d+:pattern_match_cov"
]
