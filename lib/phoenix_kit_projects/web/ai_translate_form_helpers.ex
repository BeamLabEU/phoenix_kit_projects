defmodule PhoenixKitProjects.Web.AITranslateFormHelpers do
  @moduledoc """
  Shared form-LV helpers for the AI translate bar wiring on project,
  template, and task forms.

  Extracted because the three form LVs each held an identical copy of
  these helpers. Beyond dedup, lifting them out makes the
  `merge_blank_fields_only/2` policy directly unit-testable — the
  user-edits-win contract is load-bearing for the form UX (a
  translation that lands mid-edit must not silently clobber what the
  user typed).
  """

  import Phoenix.Component, only: [assign: 2]

  alias PhoenixKitProjects.Translations

  @doc """
  Assigns the AI-translate bar's initial mount state onto `socket`.

  The DB/plugin-backed lookups (default endpoint/prompt UUIDs, the
  endpoint + prompt lists, default-prompt existence) only run on the
  **connected** mount. `mount/3` fires twice — once for the dead HTTP
  render and again on the WS upgrade — and these values are only needed
  once the modal is interactive, so the dead render gets empty defaults
  and we avoid five duplicate Settings/plugin round-trips per mount.
  """
  @spec assign_ai_translate_mount_state(Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  def assign_ai_translate_mount_state(socket) do
    socket =
      assign(socket,
        ai_translate_in_flight: [],
        ai_translate_scope: :missing,
        show_ai_translation_modal: false
      )

    if Phoenix.LiveView.connected?(socket) do
      assign(socket,
        ai_selected_endpoint_uuid: Translations.get_default_ai_endpoint_uuid(),
        ai_selected_prompt_uuid: Translations.get_default_ai_prompt_uuid(),
        ai_endpoints: Translations.list_ai_endpoints(),
        ai_prompts: Translations.list_ai_prompts(),
        ai_default_prompt_exists: Translations.default_translation_prompt_exists?()
      )
    else
      assign(socket,
        ai_selected_endpoint_uuid: nil,
        ai_selected_prompt_uuid: nil,
        ai_endpoints: [],
        ai_prompts: [],
        ai_default_prompt_exists: false
      )
    end
  end

  @doc """
  Computes the `missing` list for the language switcher's
  `ai_translate.missing` slot.

  A language is "missing" when it's in the host's enabled-language
  list, isn't the primary language, and doesn't have **any non-blank
  translatable field** for that language code yet.

  The non-blank rule matters: `%{"es" => %{}}` and
  `%{"es" => %{"name" => ""}}` both still count as missing — the
  user hasn't actually translated anything yet, just opened the tab.
  Treating an empty map as "translated" would hide the sparkle the
  user is looking for.
  """
  @spec missing_languages([map()], String.t(), map() | nil, [atom() | String.t()]) ::
          [String.t()]
  def missing_languages(language_tabs, primary_language, translations, translatable_fields) do
    enabled = Enum.map(language_tabs || [], & &1.code)
    have = translations || %{}

    Enum.reject(enabled, fn lang ->
      lang == primary_language or has_any_translation?(have, lang, translatable_fields)
    end)
  end

  @doc """
  Does the resource have at least one non-blank translatable field
  for `lang`?
  """
  @spec has_any_translation?(map(), String.t(), [atom() | String.t()]) :: boolean()
  def has_any_translation?(translations, lang, translatable_fields) do
    case Map.get(translations, lang) do
      m when is_map(m) ->
        Enum.any?(translatable_fields, fn field ->
          case Map.get(m, field) do
            v when is_binary(v) -> String.trim(v) != ""
            _ -> false
          end
        end)

      _ ->
        false
    end
  end

  @doc """
  Merges the AI's translated `new_lang_map` into the existing
  `current_lang_map`, with **user-typed values winning over AI
  output**.

  A field is updated by the AI only when the current value is
  blank (`nil`, `""`, or whitespace-only). If the user switched to
  the target language during the Oban job and typed something in
  e.g. `name`, the AI's translated name will NOT overwrite it.

  This is the policy fix from PR #12's final codex review — an
  unconditional `Map.merge/2` would silently clobber edits the user
  made between dispatching the translation and the job completing.
  """
  @spec merge_blank_fields_only(map(), map()) :: map()
  def merge_blank_fields_only(current_lang_map, new_lang_map)
      when is_map(current_lang_map) and is_map(new_lang_map) do
    Enum.reduce(new_lang_map, current_lang_map, fn {field, ai_value}, acc ->
      if blank?(Map.get(acc, field)) do
        Map.put(acc, field, ai_value)
      else
        acc
      end
    end)
  end

  @doc """
  Merges AI output into the form's current lang map according to the
  job's scope.

  * `overwrite? == true` (the "all" scope) — AI output wins via plain
    `Map.merge/2`, mirroring the worker's persisted merge so the open
    form reflects exactly what was written to the DB. Without this, an
    "overwrite all" translation would update the DB but leave the open
    form showing the old values, and a subsequent save would silently
    revert the overwrite.
  * `overwrite? == false` (missing-only / single-lang) — defers to
    `merge_blank_fields_only/2` so edits the user made while the job
    ran are preserved.
  """
  @spec merge_translation_fields(map(), map(), boolean()) :: map()
  def merge_translation_fields(current_lang_map, new_lang_map, true)
      when is_map(current_lang_map) and is_map(new_lang_map) do
    Map.merge(current_lang_map, new_lang_map)
  end

  def merge_translation_fields(current_lang_map, new_lang_map, _overwrite?) do
    merge_blank_fields_only(current_lang_map, new_lang_map)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: false
end
