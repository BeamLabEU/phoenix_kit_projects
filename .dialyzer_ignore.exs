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

  # (`base_enqueue_params` type was introduced in PR `followup-review-pr13-fixes`
  # to give `enqueue_all_missing/2` a correct spec — the previous broad
  # `:call|:unused_fun` ignore is gone with it.)

  # `resource.translations || %{}` defensive fallback in the worker's
  # `translatable_field_map/3`. The schema typespec
  # (`field :translations, :map, default: %{}`) makes `:translations`
  # non-nil to dialyzer, so the fallback never fires in practice. Kept
  # because a future migration / malformed DB read shouldn't crash a
  # mid-translation worker. (The same defensive pattern was removed
  # from the 3 form LVs in PR `followup-review-pr13-fixes` when
  # `:translation_completed` switched from `Projects.get_*/1` reload
  # to in-memory merge from `payload.fields` — `payload.fields` is
  # always a map literal from the worker, never nil.)
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
