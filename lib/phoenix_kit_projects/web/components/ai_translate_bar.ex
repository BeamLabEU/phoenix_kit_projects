defmodule PhoenixKitProjects.Web.Components.AITranslateBar do
  @moduledoc """
  AI-translation affordance for project / template / task forms.

  Provides two surfaces:

    * `<.ai_translate_button>` — a single compact button rendered
      above the multilang tabs. Click toggles the modal below. Shows
      a "(N missing)" badge so the user knows there's something to
      do. Spinner badge while any job is in-flight.

    * `<.ai_translate_modal>` — a daisyUI dialog modal containing
      endpoint + prompt selectors, a "Generate Default Prompt"
      button when none is provisioned, in-flight status, and two
      action buttons:

        - "Translate Missing Only" — enqueues a job per missing lang
        - "Translate to Current Language" — enqueues a single job
          for the active tab's language (when not on the primary)

  This is the publishing-style replacement for the earlier
  40-button inline bar, which became unusable on apps with many
  enabled languages.

  ## Host contract

  Pass `ai_translate: %{...}`:

      %{
        enabled: true,                  # boolean — gates render
        event: "translate_lang",        # phx-click event name
        toggle_event: "toggle_ai",      # opens/closes the modal
        select_endpoint_event: "...",   # endpoint dropdown change
        select_prompt_event: "...",     # prompt dropdown change
        select_scope_event: "...",      # scope radio change
        generate_prompt_event: "...",   # generate-default-prompt
        missing: ["es", "de"],          # langs still to translate
        all_langs: ["es", "de", "fr"],  # every non-primary enabled lang
        in_flight: ["es"],              # jobs running now
        modal_open: false,              # is the modal visible?
        endpoints: [{uuid, name}, ...], # AI endpoints list
        prompts: [{uuid, name}, ...],   # AI prompts list
        selected_endpoint_uuid: "...",  # current endpoint choice
        selected_prompt_uuid: "...",    # current prompt choice
        scope: :missing,                # :missing | :all | :current
        default_prompt_exists: true,    # hides the generate-button
        current_lang: "es",             # active multilang tab
        primary_lang: "en"              # to disable "current" scope on primary
      }

  ## Action contract

  The modal renders a single "Translate" button driven by `scope`:

    - `:missing` (default) — bulk: `phx-value-lang="*"`. Worker
      only enqueues langs without translations.
    - `:all` — bulk with overwrite warning: `phx-value-lang="**"`.
      Enqueues every non-primary lang (existing translations get
      overwritten on completion via the host's same-target merge).
    - `:current` — single lang: `phx-value-lang=<current_lang>`.

  Host's `handle_event(@ai_translate.event, %{"lang" => lang}, socket)`
  branches on the value: `"*"` → missing-only path; `"**"` → all
  path; concrete code → single-lang path.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKitWeb.Components.Core.Icon

  attr(:ai_translate, :map,
    default: nil,
    doc: "Configuration map — see moduledoc for the full shape."
  )

  attr(:class, :string, default: "flex items-center gap-2 px-4 py-2 border-b border-base-200")

  @doc """
  Compact trigger button. Shows a missing-count badge and a spinner
  badge while any translation is in flight.

  Hidden entirely when `ai_translate.enabled != true`, the toggle
  event is blank, or there's nothing to translate AND nothing in
  flight.
  """
  def ai_translate_button(assigns) do
    ~H"""
    <%= if button_visible?(@ai_translate) do %>
      <div class={@class}>
        <button
          type="button"
          class="btn btn-ghost btn-xs gap-2"
          phx-click={toggle_event_name(@ai_translate)}
          aria-haspopup="dialog"
          aria-expanded={if modal_open?(@ai_translate), do: "true", else: "false"}
        >
          <Icon.icon name="hero-language" class="w-4 h-4 text-primary" />
          <span>{gettext("AI Translate")}</span>

          <%= cond do %>
            <% has_in_flight?(@ai_translate) -> %>
              <span class="badge badge-sm badge-primary gap-1">
                <span class="loading loading-spinner loading-xs"></span>
                {length(normalized_in_flight(@ai_translate))}
              </span>
            <% missing_count(@ai_translate) > 0 -> %>
              <span class="badge badge-sm badge-ghost">
                {gettext("%{count} missing", count: missing_count(@ai_translate))}
              </span>
            <% true -> %>
            <% end %>
        </button>
      </div>
    <% end %>
    """
  end

  @doc """
  Modal dialog with endpoint/prompt selectors + action buttons.

  Renders nothing when `ai_translate.enabled != true` — the gate
  matches `ai_translate_button/1` so a host can always render both
  components and only the relevant one shows.
  """
  def ai_translate_modal(assigns) do
    ~H"""
    <%= if modal_renderable?(@ai_translate) do %>
      <dialog
        id="ai-translation-modal"
        class={["modal", modal_open?(@ai_translate) && "modal-open"]}
      >
        <div class="modal-box max-w-lg">
          <div class="flex items-center justify-between mb-4">
            <h3 class="font-bold text-lg flex items-center gap-2">
              <Icon.icon name="hero-language" class="w-5 h-5 text-primary" />
              {gettext("AI Translation")}
            </h3>
            <button
              type="button"
              class="btn btn-sm btn-circle btn-ghost"
              phx-click={toggle_event_name(@ai_translate)}
              aria-label={gettext("Close")}
            >
              <Icon.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>

          <div class="space-y-4">
            <p class="text-sm text-base-content/70">
              {gettext(
                "Automatically translate this resource to other languages using AI. The translation will be queued as a background job."
              )}
            </p>

            <%!-- Endpoint Selection --%>
            <div class="space-y-1">
              <form phx-change={get(@ai_translate, :select_endpoint_event)}>
                <label class="select select-sm w-full">
                  <select name="endpoint_uuid">
                    <option value="">{gettext("Select an endpoint...")}</option>
                    <%= for {id, name} <- ai_endpoints(@ai_translate) do %>
                      <option
                        value={id}
                        selected={get(@ai_translate, :selected_endpoint_uuid) == id}
                      >
                        {name}
                      </option>
                    <% end %>
                  </select>
                </label>
              </form>
            </div>

            <%!-- Prompt Selection --%>
            <div class="space-y-1">
              <form phx-change={get(@ai_translate, :select_prompt_event)}>
                <label class="select select-sm w-full">
                  <select name="prompt_uuid">
                    <option value="">{gettext("Select a prompt...")}</option>
                    <%= for {id, name} <- ai_prompts(@ai_translate) do %>
                      <option
                        value={id}
                        selected={get(@ai_translate, :selected_prompt_uuid) == id}
                      >
                        {name}
                      </option>
                    <% end %>
                  </select>
                </label>
              </form>
              <%= unless get(@ai_translate, :default_prompt_exists) == true do %>
                <button
                  type="button"
                  class="btn btn-outline btn-xs gap-1"
                  phx-click={get(@ai_translate, :generate_prompt_event)}
                >
                  <Icon.icon name="hero-sparkles" class="w-3 h-3" />
                  {gettext("Generate Default Prompt")}
                </button>
              <% end %>
            </div>

            <%!-- Status: in-flight translation list --%>
            <%= if has_in_flight?(@ai_translate) do %>
              <div class="alert alert-info py-2 text-xs gap-2">
                <span class="loading loading-spinner loading-xs"></span>
                <span>
                  {gettext("Translating to %{langs}…",
                    langs:
                      @ai_translate
                      |> normalized_in_flight()
                      |> Enum.map_join(", ", &String.upcase/1)
                  )}
                </span>
              </div>
            <% end %>

            <%!-- Scope picker — what to translate.
                 Each option is a `phx-click` (not a `phx-change` form)
                 because Phoenix LV's form-event handler refuses to
                 dispatch when the modal sits outside the host's
                 root form (the dialog-inside-wrapper structure
                 confuses the form-ownership lookup). Using
                 plain click events sidesteps that entirely. --%>
            <fieldset class="space-y-2">
              <legend class="text-sm font-medium">{gettext("Translate")}</legend>

              <%= for {value, label, disabled} <- scope_options(@ai_translate) do %>
                <label class={[
                  "flex items-start gap-2 cursor-pointer p-2 rounded hover:bg-base-200",
                  disabled && "opacity-50 cursor-not-allowed pointer-events-none"
                ]}>
                  <input
                    type="radio"
                    name="scope"
                    value={value}
                    class="radio radio-sm radio-primary mt-0.5"
                    checked={Atom.to_string(current_scope(@ai_translate)) == value}
                    disabled={disabled}
                    phx-click={if disabled, do: nil, else: get(@ai_translate, :select_scope_event)}
                    phx-value-scope={value}
                  />
                  <span class="text-sm leading-tight">{label}</span>
                </label>
              <% end %>
            </fieldset>

            <%!-- Overwrite warning when scope = :all --%>
            <%= if current_scope(@ai_translate) == :all do %>
              <div class="alert alert-warning py-2 text-xs gap-2">
                <Icon.icon name="hero-exclamation-triangle" class="w-4 h-4 shrink-0" />
                <span>
                  {gettext(
                    "Existing translations in every non-primary language will be overwritten on completion."
                  )}
                </span>
              </div>
            <% end %>

            <%!-- Action button --%>
            <div class="flex flex-wrap gap-3">
              <button
                type="button"
                class={[
                  "btn btn-primary btn-sm gap-1",
                  action_disabled?(@ai_translate) && "btn-disabled"
                ]}
                phx-click={event_name(@ai_translate)}
                phx-value-lang={scope_target(@ai_translate)}
                disabled={action_disabled?(@ai_translate)}
              >
                <Icon.icon name="hero-sparkles" class="w-4 h-4" />
                {action_label(@ai_translate)}
              </button>
            </div>
          </div>
        </div>
        <div class="modal-backdrop" phx-click={toggle_event_name(@ai_translate)}></div>
      </dialog>
    <% end %>
    """
  end

  # ─── Backward-compatible alias ─────────────────────────────────
  # Older host pages embed `<.ai_translate_bar>` directly. Forward
  # to the new button surface so they keep rendering — the original
  # 40-button bar is gone, replaced by this compact trigger.
  @doc false
  def ai_translate_bar(assigns), do: ai_translate_button(assigns)

  # ─── Visibility / state helpers ────────────────────────────────

  defp button_visible?(cfg) when is_map(cfg) do
    enabled?(cfg) and toggle_event_name(cfg) != nil and
      (missing_count(cfg) > 0 or has_in_flight?(cfg))
  end

  defp button_visible?(_), do: false

  defp modal_renderable?(cfg) when is_map(cfg) do
    enabled?(cfg) and toggle_event_name(cfg) != nil
  end

  defp modal_renderable?(_), do: false

  defp modal_open?(cfg), do: get(cfg, :modal_open) == true

  defp enabled?(cfg), do: get(cfg, :enabled) == true

  defp missing_count(cfg), do: length(actionable_missing(cfg))

  defp actionable_missing(cfg) do
    missing = normalized_missing(cfg)
    in_flight = normalized_in_flight(cfg)
    Enum.reject(missing, &(&1 in in_flight))
  end

  defp has_in_flight?(cfg), do: normalized_in_flight(cfg) != []

  defp normalized_missing(cfg) do
    cfg
    |> get(:missing)
    |> List.wrap()
    |> Enum.map(&to_lang/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalized_in_flight(cfg) do
    cfg
    |> get(:in_flight)
    |> List.wrap()
    |> Enum.map(&to_lang/1)
    |> Enum.reject(&is_nil/1)
  end

  defp to_lang(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      v -> v
    end
  end

  defp to_lang(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp to_lang(_), do: nil

  defp ai_endpoints(cfg), do: cfg |> get(:endpoints) |> List.wrap()
  defp ai_prompts(cfg), do: cfg |> get(:prompts) |> List.wrap()

  # ─── Scope picker ──────────────────────────────────────────────

  @doc false
  # Public for testing — list of `{value, label, disabled}` tuples
  # for the radio options. Order is missing → all → current.
  def scope_options_for_test(cfg), do: scope_options(cfg)

  defp scope_options(cfg) do
    missing_count = length(actionable_missing(cfg))
    all_count = length(all_target_langs(cfg))
    current = get(cfg, :current_lang)
    current_disabled = not current_scope_available?(cfg)

    [
      {
        "missing",
        gettext("Missing only (%{count} %{plural})",
          count: missing_count,
          plural: ngettext_plural(missing_count, "language", "languages")
        ),
        # Missing scope disabled when no missing langs left to translate.
        missing_count == 0
      },
      {
        "all",
        gettext("All non-primary languages (%{count}, overwrites existing)",
          count: all_count
        ),
        # All scope disabled when there are zero target langs (one-language app).
        all_count == 0
      },
      {"current",
       gettext("Current tab only (%{lang})",
         lang: if(is_binary(current), do: String.upcase(current), else: "—")
       ), current_disabled}
    ]
  end

  defp current_scope_available?(cfg) do
    current = get(cfg, :current_lang)
    primary = get(cfg, :primary_lang)
    is_binary(current) and current != "" and current != primary
  end

  defp all_target_langs(cfg) do
    primary = get(cfg, :primary_lang)

    cfg
    |> get(:all_langs)
    |> List.wrap()
    |> Enum.map(&to_lang/1)
    |> Enum.reject(&(is_nil(&1) or &1 == primary))
  end

  # ─── Selected scope + derived action surface ───────────────────

  defp current_scope(cfg) do
    case get(cfg, :scope) do
      :missing -> :missing
      :all -> :all
      :current -> :current
      "missing" -> :missing
      "all" -> :all
      "current" -> :current
      _ -> :missing
    end
  end

  defp scope_target(cfg) do
    case current_scope(cfg) do
      :missing -> "*"
      :all -> "**"
      :current -> get(cfg, :current_lang) || ""
    end
  end

  defp action_label(cfg) do
    case current_scope(cfg) do
      :missing ->
        gettext("Translate %{n} missing", n: length(actionable_missing(cfg)))

      :all ->
        gettext("Translate all %{n} languages", n: length(all_target_langs(cfg)))

      :current ->
        gettext("Translate to %{lang}",
          lang: String.upcase(get(cfg, :current_lang) || "")
        )
    end
  end

  # The action button is disabled when:
  #   * no endpoint or no prompt selected
  #   * any translation is currently running (prevents double-click + helps
  #     visually communicate that the system is busy)
  #   * the chosen scope has nothing to translate (e.g. :missing with 0
  #     missing, :current on the primary tab)
  defp action_disabled?(cfg) do
    blank?(get(cfg, :selected_endpoint_uuid)) or
      blank?(get(cfg, :selected_prompt_uuid)) or
      has_in_flight?(cfg) or
      scope_empty?(cfg)
  end

  defp scope_empty?(cfg) do
    case current_scope(cfg) do
      :missing -> actionable_missing(cfg) == []
      :all -> all_target_langs(cfg) == []
      :current -> not current_scope_available?(cfg)
    end
  end

  defp ngettext_plural(1, sing, _plur), do: sing
  defp ngettext_plural(_, _sing, plur), do: plur

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: false

  defp event_name(cfg), do: trimmed_event(cfg, :event)
  defp toggle_event_name(cfg), do: trimmed_event(cfg, :toggle_event)

  defp trimmed_event(cfg, key) do
    case get(cfg, key) do
      ev when is_binary(ev) -> if String.trim(ev) == "", do: nil, else: ev
      _ -> nil
    end
  end

  defp get(cfg, key) when is_map(cfg) and is_atom(key) do
    case Map.fetch(cfg, key) do
      {:ok, v} -> v
      :error -> Map.get(cfg, Atom.to_string(key))
    end
  end

  defp get(_, _), do: nil
end
