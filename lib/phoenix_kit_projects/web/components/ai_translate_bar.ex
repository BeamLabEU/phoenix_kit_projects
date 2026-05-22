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
        primary_lang: "en",             # source for translations + disables :current on primary
        primary_lang_name: "English"    # friendly label; falls back to upcased code, then a generic string
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

  ## Host embedding contract — render placement matters

  The modal contains its own `<form phx-change>` elements for the
  endpoint / prompt selectors. HTML forbids nested `<form>` and the
  browser silently flattens them, which makes the selectors' change
  events fire against the *outer* form's `phx-change` handler.
  Render the modal **outside** your outer form, after `</.form>`:

      <.form for={@form} phx-change="validate" phx-submit="save" ...>
        <.ai_translate_button ai_translate={...} />
        <%!-- rest of the form fields here --%>
      </.form>

      <%!-- Modal AFTER the form close, not inside it. --%>
      <.ai_translate_modal ai_translate={...} />

  Both components accept the same `ai_translate` map, so a host can
  compute it once per render and pass it to both.

  ### LiveComponent hosts

  If the host renders the button from inside a `Phoenix.LiveComponent`
  (e.g. a translation tab strip rendered via `<.live_component>`),
  the modal's selector events still need to land on the parent
  LiveView — modal placement at the LV root is the simplest path.
  Embed the modal at the LV's outer render template, not inside the
  LiveComponent's HEEx, and have the LiveComponent emit a
  `send(self(), {:ai_translate, ...})` (or call the host event via
  `phx-target={@myself}` on the button only) so the modal's PubSub
  / `handle_event` consumers stay on the LV process.

  If the modal MUST render from inside a LiveComponent (rare —
  e.g. embedded analytics panel that wants the picker self-contained),
  pass `phx-target={@myself}` on every `<.form>` / event-emitting
  element inside the modal so the LiveComponent receives the events
  instead of routing them up. The current `<.ai_translate_modal>`
  does not plumb a target attr; in that case render a thin wrapper
  inside the LiveComponent and replicate the modal markup.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKitWeb.Components.Core.Icon

  attr(:ai_translate, :map,
    default: nil,
    doc: "Configuration map — see moduledoc for the full shape."
  )

  @doc """
  Compact trigger button. Shows a small spinner glyph while any
  translation is in flight (no count, no missing badge — the
  sibling `<.ai_translate_progress>` carries the per-session status,
  and the modal's scope picker shows the missing count if the user
  needs it).

  Hidden when `ai_translate.enabled != true` or the toggle event is
  blank. Stays visible after all langs are translated so the user can
  re-translate at any time.
  """
  def ai_translate_button(assigns) do
    ~H"""
    <%= if button_visible?(@ai_translate) do %>
      <button
        type="button"
        class="btn btn-ghost btn-xs gap-2"
        phx-click={toggle_event_name(@ai_translate)}
        aria-haspopup="dialog"
        aria-expanded={if modal_open?(@ai_translate), do: "true", else: "false"}
      >
        <Icon.icon name="hero-language" class="w-4 h-4 text-primary" />
        <span>{gettext("AI Translate")}</span>
        <%= if has_in_flight?(@ai_translate) do %>
          <span class="loading loading-spinner loading-xs"></span>
        <% end %>
      </button>
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
                "Source: %{lang}. Each translation runs as a background job — you can keep editing while it finishes.",
                lang: source_lang_label(@ai_translate)
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

            <%!-- Action button. `phx-disable-with` covers the small
                 window between click and the LV's first re-render, so
                 a double-click during a slow round-trip can't queue
                 two dispatches before the modal closes. --%>
            <div class="flex flex-wrap gap-3">
              <button
                type="button"
                class={[
                  "btn btn-primary btn-sm gap-1",
                  action_disabled?(@ai_translate) && "btn-disabled"
                ]}
                phx-click={event_name(@ai_translate)}
                phx-value-lang={scope_target(@ai_translate)}
                phx-disable-with={gettext("Starting…")}
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

  attr(:ai_translate, :map,
    required: true,
    doc:
      "Same `ai_translate` config map the button + modal accept. Reads `:translation_status`, `:translation_progress`, and `:translation_total` keys for the bar fill state."
  )

  attr(:wrapper_class, :string, default: "flex-1 min-w-0")
  attr(:class, :string, default: "progress h-2 w-full block")

  @doc """
  Slim inline progress bar — designed to sit on the same row as
  `<.ai_translate_button>`. No text, no counter, no language list:
  the bar's fill level is the only signal. Color flips to
  `progress-success` when the session reaches `:completed`.

  The wrapper is `flex-1 min-w-0` so the bar fills the remaining
  horizontal space in its parent flex container without bleeding past
  it; the inner `<progress>` is `w-full` so its daisyUI default
  `width: 100%` resolves against the wrapper, not the row.

  Renders nothing until the host has dispatched at least one
  translation in the session (`translation_status` flips to
  `:in_progress`). The bar persists in the `:completed` state until
  the next dispatch resets it.
  """
  def ai_translate_progress(assigns) do
    ~H"""
    <%= if progress_visible?(@ai_translate) do %>
      <div class={@wrapper_class}>
        <progress
          class={[
            @class,
            translation_status(@ai_translate) == :completed && "progress-success",
            translation_status(@ai_translate) != :completed && "progress-primary"
          ]}
          value={translation_progress(@ai_translate)}
          max={max(translation_total(@ai_translate), 1)}
        >
        </progress>
      </div>
    <% end %>
    """
  end

  # ─── Visibility / state helpers ────────────────────────────────

  defp button_visible?(cfg) when is_map(cfg) do
    enabled?(cfg) and toggle_event_name(cfg) != nil
  end

  defp button_visible?(_), do: false

  defp modal_renderable?(cfg) when is_map(cfg) do
    enabled?(cfg) and toggle_event_name(cfg) != nil
  end

  defp modal_renderable?(_), do: false

  defp modal_open?(cfg), do: get(cfg, :modal_open) == true

  defp enabled?(cfg), do: get(cfg, :enabled) == true

  defp actionable_missing(cfg) do
    missing = normalized_missing(cfg)
    in_flight = normalized_in_flight(cfg)
    Enum.reject(missing, &(&1 in in_flight))
  end

  defp has_in_flight?(cfg), do: normalized_in_flight(cfg) != []

  defp translation_status(cfg) when is_map(cfg), do: get(cfg, :translation_status)
  defp translation_status(_), do: nil

  defp translation_progress(cfg) when is_map(cfg), do: get(cfg, :translation_progress) || 0
  defp translation_progress(_), do: 0

  defp translation_total(cfg) when is_map(cfg), do: get(cfg, :translation_total) || 0
  defp translation_total(_), do: 0

  defp progress_visible?(cfg) when is_map(cfg) do
    enabled?(cfg) and translation_status(cfg) in [:in_progress, :completed] and
      translation_total(cfg) > 0
  end

  defp progress_visible?(_), do: false

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

  # Friendly label for the source (primary) language. Prefers
  # `primary_lang_name` (host can resolve "en-US" → "English (United
  # States)") and falls back to the uppercased code when the host
  # didn't pass a name. Last resort: "the primary language".
  defp source_lang_label(cfg) do
    name = get(cfg, :primary_lang_name)
    code = get(cfg, :primary_lang)

    cond do
      is_binary(name) and String.trim(name) != "" -> name
      is_binary(code) and String.trim(code) != "" -> String.upcase(code)
      true -> gettext("the primary language")
    end
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
