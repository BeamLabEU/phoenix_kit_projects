defmodule PhoenixKitProjects.Web.Components.FormParts do
  @moduledoc """
  The building blocks of the module's edit popups, lifted out of the task
  popup (the newest, the design the others follow — the boss, 2026-10-30:
  "the lack of tabs, the user assignment thing being different in basically
  every pop-up"):

    * `form_header/1` — where the record sits and what is happening to it
      on one line, and under it the record's name as it is being typed;
    * `form_tabs/1` — the tab strip over the panes of one form; every pane
      stays in the form and is only hidden, so a switch loses nothing
      typed and a save posts all of them; a tab holding an error carries a
      dot;
    * `form_pane/1` — one of those panes;
    * `words_block/1` — the language tabs (with the AI translate button)
      over the translatable fields, and only those: the wrapper re-mounts
      on a language switch;
    * `status_choices/1` — the status as a row of coloured choices, one
      press each.

  The assignee picker, the time pickers and the amount-of-time input are
  components of their own (`AssigneePicker`, `TimeInput`,
  `DurationInput`).
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitWeb.Components.Core.NavTabs
  import PhoenixKitWeb.Components.MultilangForm, only: [multilang_fields_wrapper: 1]
  import PhoenixKitAI.Components.AITranslate, only: [ai_multilang_tabs: 1]

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitProjects.Web.Components.AssignmentStatusBadge

  # ── Header ─────────────────────────────────────────────────────────

  @doc """
  The popup's header, one row (the boss, 2026-10-31: compact, the same in
  every popup): `:context` first (the record's ref pill, a back arrow),
  then the title, which the form keeps up to date as the name is typed —
  an emptied name shows a muted "Untitled" rather than the last text —
  then `:badge` (a status), `:actions` and the close button when
  `close_event` is set. `mode` ("Editing", "Add task") is said to screen
  readers and in the title's tooltip only; the title already says it.
  """
  attr(:id, :string, required: true)
  attr(:title_id, :string, default: nil)
  attr(:title, :string, required: true)
  attr(:mode, :string, default: nil)

  attr(:untitled, :string,
    default: nil,
    doc: "shown, muted, while the name is empty (default: \"Untitled\")"
  )

  attr(:close_event, :string, default: nil)

  attr(:close_confirm, :any,
    default: nil,
    doc: "a question asked before closing (unsaved changes)"
  )

  attr(:close_label, :string, default: nil)
  slot(:context)
  slot(:actions)
  slot(:badge)

  def form_header(assigns) do
    assigns = assign(assigns, :untitled?, String.trim(assigns.title || "") == "")

    ~H"""
    <%!-- Without its own ✕ the header sits in a popup whose ✕ is pinned at
         the top right: leave it that room. --%>
    <header id={@id} class={["flex items-center gap-2 min-w-0 shrink-0", !@close_event && "pr-8"]}>
      {render_slot(@context)}
      <h2
        id={@title_id || "#{@id}-title"}
        title={@mode}
        class={[
          "flex-1 min-w-0 text-lg font-semibold leading-tight break-words",
          @untitled? && "text-base-content/40 italic font-normal"
        ]}
      >
        <span :if={@mode} class="sr-only">{@mode}:</span>
        {if @untitled?, do: @untitled || gettext("Untitled"), else: @title}
      </h2>
      {render_slot(@badge)}
      {render_slot(@actions)}
      <button
        :if={@close_event}
        type="button"
        phx-click={@close_event}
        data-confirm={@close_confirm}
        class="btn btn-ghost btn-sm btn-square shrink-0"
        aria-label={@close_label || gettext("Close")}
      >
        <.icon name="hero-x-mark" class="w-5 h-5" />
      </button>
    </header>
    """
  end

  # ── Tabs ───────────────────────────────────────────────────────────

  # Each pane's icon, the same wherever the pane appears.
  defp pane_icon("task"), do: "hero-clipboard-document-list"
  defp pane_icon("project"), do: "hero-folder"
  defp pane_icon("subproject"), do: "hero-folder"
  defp pane_icon("planning"), do: "hero-calendar-days"
  defp pane_icon("schedule"), do: "hero-calendar-days"
  defp pane_icon("connections"), do: "hero-link"
  defp pane_icon("more"), do: "hero-paper-clip"
  defp pane_icon("settings"), do: "hero-cog-6-tooth"
  defp pane_icon(_), do: nil

  @doc """
  The tab strip of a form's panes: `panes` is `[{id, label}]`, `active` the
  open one, `errors` the panes holding an error (a `MapSet`). Each tab sends
  `event` with `pane`. Nothing is drawn for fewer than two panes. Tab ids
  are `<prefix>-tab-<pane>`, pane ids `<prefix>-pane-<pane>`.

  Tabs never jump (the panel, 2026-10-31): in a drawer (`PopupHost`) the
  form is a column — header, this strip, then the open pane as the one
  scroll area — so the strip sits outside what scrolls, and a switch to a
  shorter tab moves nothing. The `PkpTabScroll` hook takes the newly
  opened pane to its top, and does nothing on any other update.
  """
  attr(:id, :string, required: true)
  attr(:prefix, :string, required: true)
  attr(:panes, :list, required: true)
  attr(:active, :string, required: true)
  attr(:errors, :any, default: MapSet.new())
  attr(:event, :string, default: "set_form_pane")

  def form_tabs(assigns) do
    ~H"""
    <%!-- The module's one tab look, the project page's (core `NavTabs`,
         boxed, an icon each — the boss, 2026-11-02: these read as another
         kind of tab, with more air above and under them). --%>
    <div
      :if={match?([_, _ | _], @panes)}
      role="tablist"
      class={NavTabs.tablist_class(:boxed, "shrink-0 self-start max-w-full overflow-x-auto")}
      id={@id}
      phx-hook="PkpTabScroll"
      data-pkp-tabs
      data-active={@active}
    >
      <button
        :for={{pane, label} <- @panes}
        type="button"
        role="tab"
        id={"#{@prefix}-tab-#{pane}"}
        aria-selected={to_string(@active == pane)}
        aria-controls={"#{@prefix}-pane-#{pane}"}
        phx-click={@event}
        phx-value-pane={pane}
        class={NavTabs.tab_class(@active == pane, "whitespace-nowrap")}
      >
        <.icon :if={pane_icon(pane)} name={pane_icon(pane)} class="w-4 h-4 shrink-0" />
        {label}
        <span
          :if={MapSet.member?(@errors, pane)}
          class="inline-block w-2 h-2 rounded-full bg-error"
          title={gettext("Something here needs fixing")}
          data-pane-error={pane}
        ></span>
      </button>
    </div>
    """
  end

  @doc "One pane of a tabbed form: hidden, never removed, while another is open."
  attr(:prefix, :string, required: true)
  attr(:pane, :string, required: true)
  attr(:active, :string, required: true)
  attr(:class, :any, default: "flex flex-col gap-4")
  slot(:inner_block, required: true)

  def form_pane(assigns) do
    ~H"""
    <section
      id={"#{@prefix}-pane-#{@pane}"}
      role="tabpanel"
      aria-labelledby={"#{@prefix}-tab-#{@pane}"}
      class={[@class, @active != @pane && "hidden"]}
    >
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  Which pane to show: `wanted` when it is one of `panes`, else the first.
  """
  @spec open_pane([{String.t(), String.t()}], String.t() | nil) :: String.t()
  def open_pane([{first, _} | _] = panes, wanted) do
    if Enum.any?(panes, &(elem(&1, 0) == wanted)), do: wanted, else: first
  end

  def open_pane([], wanted), do: wanted || ""

  @doc """
  The panes holding an error the form shows: `pane_of` maps a field (atom)
  to its pane, `changesets` are the forms' sources. Only a changeset with an
  action shows its errors.
  """
  @spec error_panes([Ecto.Changeset.t() | nil], %{atom() => String.t()}) :: MapSet.t()
  def error_panes(changesets, pane_of) do
    for %Ecto.Changeset{action: action, errors: errors} <- changesets,
        action != nil,
        {field, _} <- errors,
        pane = Map.get(pane_of, field),
        pane != nil,
        into: MapSet.new(),
        do: pane
  end

  # ── The words, per language ───────────────────────────────────────

  @doc """
  The language tabs (the AI translate button in their row) over the
  translatable fields — which go in the inner block, and nothing else:
  the wrapper re-mounts on a language switch. Framed when there is more
  than one language. `:skeleton` mirrors the fields while a switch loads.
  """
  attr(:id, :string, required: true)
  attr(:multilang_enabled, :boolean, required: true)
  attr(:language_tabs, :list, required: true)
  attr(:current_lang, :string, required: true)
  attr(:ai_translate, :any, default: nil)
  slot(:skeleton)
  slot(:inner_block, required: true)

  def words_block(assigns) do
    assigns =
      assign(assigns,
        translated?: assigns.multilang_enabled and match?([_, _ | _], assigns.language_tabs),
        language_tabs: native_tabs(assigns.language_tabs)
      )

    ~H"""
    <%!-- Tight under the language row (the boss, 2026-11-02: a large gap
         between the languages and the title field); core's switcher keeps
         a margin of its own, taken off here. --%>
    <div id={@id} class={["flex flex-col gap-2", @translated? && "rounded-box border border-base-300 p-3"]}>
      <.ai_multilang_tabs
        :if={@multilang_enabled}
        multilang_enabled={@multilang_enabled}
        language_tabs={@language_tabs}
        current_lang={@current_lang}
        class="[&>div:last-child]:mb-0"
        ai_row_class="flex items-center gap-3 -mt-3"
        ai_translate={@ai_translate}
      />
      <.multilang_fields_wrapper
        multilang_enabled={@multilang_enabled}
        current_lang={@current_lang}
        skeleton_class="space-y-2"
        fields_class="flex flex-col gap-3"
      >
        <:skeleton>
          <%= if @skeleton != [] do %>
            {render_slot(@skeleton)}
          <% else %>
            <div class="space-y-2 mb-3">
              <div class="bg-base-content/15 rounded h-4 w-20 animate-pulse"></div>
              <div class="bg-base-content/15 rounded h-10 w-full animate-pulse"></div>
            </div>
            <div class="space-y-2">
              <div class="bg-base-content/15 rounded h-4 w-24 animate-pulse"></div>
              <div class="bg-base-content/15 rounded h-16 w-full animate-pulse"></div>
            </div>
          <% end %>
        </:skeleton>
        {render_slot(@inner_block)}
      </.multilang_fields_wrapper>
    </div>
    """
  end

  @doc """
  The language tabs named in their own languages — "Eesti", "Русский" —
  instead of core's English names ("Estonian", "Russian"), which read as
  English on every page that is not (the walk-through, 2026-10-31). The
  native name comes from core's static language catalogue
  (`Languages.get_available_language_by_code/1`, held in memory); a
  language it does not know keeps the name it came with.
  """
  @spec native_tabs([map()]) :: [map()]
  def native_tabs(tabs) when is_list(tabs) do
    bases = tabs |> Enum.map(&base_code/1) |> Enum.frequencies()
    Enum.map(tabs, &native_tab(&1, bases))
  end

  def native_tabs(tabs), do: tabs

  # The region is named only when two variants of one language are on
  # together ("English (US)" beside "English (UK)"); a site with one
  # English says "English" (the boss, 2026-10-31).
  defp native_tab(%{code: code} = tab, bases) when is_binary(code) do
    base = base_code(tab)
    lone? = Map.get(bases, base, 0) == 1 and base != code

    case (lone? && native_name(base)) || native_name(code) do
      name when is_binary(name) and name != "" ->
        Map.put(tab, :name, if(lone?, do: strip_region(name), else: name))

      _ ->
        if lone? and is_binary(tab[:name]),
          do: Map.put(tab, :name, strip_region(tab.name)),
          else: tab
    end
  end

  defp native_tab(tab, _bases), do: tab

  defp base_code(%{code: code}) when is_binary(code),
    do: code |> String.split(["-", "_"], parts: 2) |> hd() |> String.downcase()

  defp base_code(_), do: nil

  defp strip_region(name), do: String.replace(name, ~r/\s*\([^)]*\)\s*$/u, "")

  defp native_name(code) do
    case Languages.get_available_language_by_code(code) do
      %{native: native} -> native
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ── Status ─────────────────────────────────────────────────────────

  @doc """
  The status as the list's own coloured badges, one press each — a radio
  group, so the choice posts with the form. `options` is `[{label, value}]`.
  """
  attr(:id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:value, :string, required: true)
  attr(:options, :list, required: true)
  attr(:label, :string, default: nil)

  def status_choices(assigns) do
    ~H"""
    <fieldset id={@id}>
      <legend class="text-sm font-semibold mb-1.5">{@label || gettext("Status")}</legend>
      <div class="flex flex-wrap gap-1.5">
        <label
          :for={{label, value} <- @options}
          id={"#{@id}-#{value}"}
          class={status_choice_class(value, @value == value)}
        >
          <input type="radio" name={@name} value={value} checked={@value == value} class="sr-only" />
          {label}
        </label>
      </div>
    </fieldset>
    """
  end

  # The chosen one filled, the others outlined in their own colour.
  defp status_choice_class(status, true) do
    [
      "badge badge-lg h-auto py-1.5 px-3 gap-1 cursor-pointer select-none font-semibold",
      "ring-2 ring-base-content/20 focus-within:outline focus-within:outline-2 focus-within:outline-offset-2",
      AssignmentStatusBadge.badge_class(status)
    ]
  end

  defp status_choice_class(status, false) do
    [
      "badge badge-lg badge-outline h-auto py-1.5 px-3 gap-1 cursor-pointer select-none",
      "opacity-80 hover:opacity-100 focus-within:outline focus-within:outline-2 focus-within:outline-offset-2",
      AssignmentStatusBadge.outline_class(status)
    ]
  end
end
