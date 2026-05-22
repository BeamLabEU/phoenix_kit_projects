defmodule PhoenixKitProjects.Web.AITranslateFormHelpers do
  @moduledoc """
  Shared form-LV helpers for the AI translate bar wiring on project,
  template, and task forms.

  Extracted because the three form LVs each held an identical copy of
  these helpers. The merge policy now lives directly in the form LVs
  as plain `Map.merge/2` — explicit user-click means AI value always
  wins, and the form UI is locked while a translation is in flight,
  so there's no user-edits-during-job race to mitigate.
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
        show_ai_translation_modal: false,
        # Progress UI state. `nil` until the first dispatch, then
        # `:in_progress` while any lang is in flight, then `:completed`
        # for the brief moment the bar shows 100% before the next
        # dispatch resets the session.
        ai_translation_status: nil,
        ai_translation_progress: 0,
        ai_translation_total: 0
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
  Bump the progress-UI state when a new dispatch starts.

  * `started_count` — number of langs the host just enqueued. For
    single-lang it's `1`; for bulk `*`/`**` the current call sites
    pass `length(in_flight)` from `enqueue_all_missing/2`, which is
    `enqueued + conflicts`. See the forward-looking note below for
    the latent accounting risk that ride-along brings.

  When the previous session was `nil` or `:completed`, this RESETS
  the bar to a fresh `:in_progress` session sized for the new
  dispatch. When the previous session was still `:in_progress`,
  this ADDS to the running total.

  **The additive `:in_progress` branch is forward-looking** — under
  the current UI the dispatch button is `disabled` whenever
  `has_in_flight?(ai_translate)` (see
  `ai_translate_bar.ex#action_disabled?/1`), so a second dispatch
  can't start while jobs are running and the branch is unreachable
  through the modal. Kept so a future host that allows mid-flight
  dispatch (e.g. a queue-style admin UI) gets correct accounting
  without redesigning this helper.

  Caveat for that future host: `enqueue_all_missing/2` reports
  conflict-deduplicated langs alongside newly-enqueued ones in its
  `in_flight` list. A conflict-dedup'd dispatch doesn't get its own
  worker run — it rides along with the **same** job that was
  already in flight, so the broadcast fan-out emits **one**
  `:translation_completed` per actual job, not one per click. If
  `started_count` counts both clicks, `progress` can only reach the
  per-job number → `progress < total` forever. Switch the call site
  to count newly-enqueued langs only (e.g. `length(in_flight -- prev_in_flight)`)
  before enabling mid-flight dispatch.
  """
  @spec bump_translation_started(Phoenix.LiveView.Socket.t(), non_neg_integer()) ::
          Phoenix.LiveView.Socket.t()
  def bump_translation_started(socket, started_count) when started_count > 0 do
    case socket.assigns.ai_translation_status do
      s when s in [nil, :completed] ->
        assign(socket,
          ai_translation_status: :in_progress,
          ai_translation_progress: 0,
          ai_translation_total: started_count
        )

      :in_progress ->
        assign(socket,
          ai_translation_total: socket.assigns.ai_translation_total + started_count
        )
    end
  end

  def bump_translation_started(socket, _zero), do: socket

  @doc """
  Bump the progress-UI state when a translation lifecycle event lands
  (`:translation_completed` or `:translation_failed`). Both terminal
  outcomes advance the bar — the UX is "this job finished, the lang
  is no longer spinning", and failure is communicated separately via
  the flash, not by holding the progress count back.

  Takes the `lang` so the helper can detect duplicate / stale terminal
  events (e.g. the same `:translation_completed` arriving twice on a
  PubSub reconnect, or a stale event from a previous session's
  in-flight set still in transit). When `lang` is no longer in
  `:ai_translate_in_flight`, treat as a no-op: don't double-bump
  progress past `total` and don't flip status back to `:in_progress`
  for a session that already reached `:completed`.

  Also removes `lang` from the in-flight list — caller passes the
  socket BEFORE removal, this helper consolidates the removal +
  progress bump so the two stay in sync.

  Flips status to `:completed` only when the in-flight list goes
  empty as a result of this bump.
  """
  @spec bump_translation_completed(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def bump_translation_completed(socket, lang) when is_binary(lang) do
    in_flight = socket.assigns.ai_translate_in_flight

    if lang in in_flight do
      new_in_flight = in_flight -- [lang]
      next_progress = (socket.assigns.ai_translation_progress || 0) + 1
      next_status = if new_in_flight == [], do: :completed, else: :in_progress

      assign(socket,
        ai_translate_in_flight: new_in_flight,
        ai_translation_progress: next_progress,
        ai_translation_status: next_status
      )
    else
      socket
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
end
