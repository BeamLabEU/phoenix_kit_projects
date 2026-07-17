defmodule PhoenixKitProjects.Web.Components.AssigneeFilterPanel do
  @moduledoc """
  `<.assignee_filter_panel>` — the Filters funnel button (badged with the
  active-filter count) plus its client-side popup panel: person typeahead,
  Me/Unassigned quick-adders, active chips, Personal-only and Overdue-only
  refinements, and Clear.

  Pure UI over `Web.AssigneeFilter`'s assigns/events: the events land on the
  parent LiveView, which forwards them through `AssigneeFilter.update/3` (see
  that module's usage note). The panel opens/closes entirely client-side —
  `JS.toggle` on the button (LV JS commands stick across patches, so toggling
  a control inside doesn't collapse it) with `phx-click-away` on the shared
  wrapper for outside-click dismiss. Pass a unique `id` per page so two
  panels (e.g. the Overview and an embedded project calendar) can't collide.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.SearchPicker, only: [search_picker: 1]

  alias Phoenix.LiveView.JS
  alias PhoenixKitProjects.CalendarDisplay
  alias PhoenixKitProjects.Web.AssigneeFilter

  attr(:id, :string, required: true, doc: "unique prefix for the panel/picker DOM ids")
  attr(:assignee_selected, :list, required: true)
  attr(:include_unassigned?, :boolean, required: true)
  attr(:unassigned_count, :integer, required: true)
  attr(:assignee_direct_only?, :boolean, required: true)
  attr(:overdue_only?, :boolean, required: true)
  attr(:me_scope, :any, required: true)

  def assignee_filter_panel(assigns) do
    assigns = assign(assigns, :active_count, AssigneeFilter.active_count(assigns))

    ~H"""
    <div class="relative" phx-click-away={JS.hide(to: "##{@id}-panel")}>
      <button
        type="button"
        class="btn btn-sm btn-ghost border-base-300 gap-1.5 tooltip"
        data-tip={gettext("Filters")}
        aria-label={gettext("Filters")}
        phx-click={JS.toggle(to: "##{@id}-panel")}
      >
        <.icon name="hero-funnel" class="w-4 h-4" />
        {gettext("Filters")}
        <span :if={@active_count > 0} class="badge badge-xs badge-primary">
          {@active_count}
        </span>
      </button>

      <div
        id={"#{@id}-panel"}
        class="hidden absolute left-0 top-full mt-2 z-30 w-80 max-w-[90vw] card bg-base-100 border border-base-200 shadow-lg"
      >
        <div class="card-body p-4 gap-3">
          <div class="flex items-center justify-between">
            <span class="text-sm font-semibold">{gettext("Filters")}</span>
            <%!-- One tap back to the unfiltered everything-view; only exists
                 while something is filtered. --%>
            <button
              :if={@active_count > 0}
              type="button"
              class={["btn btn-xs btn-ghost", CalendarDisplay.loading_class()]}
              phx-click="clear_assignee_filter"
            >
              <.icon name="hero-x-mark" class="w-3 h-3" /> {gettext("Clear")}
            </button>
          </div>

          <%!-- The instant person typeahead: dropdown renders client-side; the
               server answers "assignee_search" with limit+1-probed pages (Load
               more built in) — nothing preloads the people table. --%>
          <.search_picker
            id={"#{@id}-search"}
            dropdown_id={"#{@id}-dropdown"}
            search_event="assignee_search"
            results_event="assignee_results"
            pick_event="assignee_pick"
            staged_event="assignee_staged"
            placeholder={gettext("Add person…")}
            class="input input-bordered input-sm w-full"
            searching_label={gettext("Searching…")}
            more_label={gettext("Load more")}
            loading_more_label={gettext("Loading…")}
            no_matches_label={gettext("No matches")}
            data-search-on-focus
          />

          <%!-- Quick-adders + active chips, one wrapping rail: a tap inserts
               the corresponding chip and the button steps aside — the chip IS
               the visible state, removable like any other. --%>
          <div class="flex flex-wrap items-center gap-2">
            <button
              :if={match?(%{}, @me_scope) and not me_chip_active?(@me_scope, @assignee_selected)}
              type="button"
              class={["btn btn-xs btn-ghost border-base-300 tooltip", CalendarDisplay.loading_class()]}
              data-tip={gettext("Your work — assigned to you, your teams, or your departments")}
              phx-click="toggle_me_chip"
            >
              <.icon name="hero-plus" class="w-3 h-3" /> {gettext("Me")}
            </button>

            <button
              :if={not @include_unassigned?}
              type="button"
              class={["btn btn-xs btn-ghost border-base-300 tooltip", CalendarDisplay.loading_class()]}
              data-tip={gettext("Tasks nobody is assigned to yet — combines with picked people")}
              phx-click="toggle_unassigned"
            >
              <.icon name="hero-plus" class="w-3 h-3" /> {gettext("Unassigned")}
              <span class="badge badge-xs badge-ghost">{@unassigned_count}</span>
            </button>

            <%!-- The Unassigned lens as a first-class, visibly-toggled chip —
                 dashed to say "no person". --%>
            <span :if={@include_unassigned?} class="badge badge-dash gap-1.5">
              <.icon name="hero-user-minus" class="w-3 h-3" />
              {gettext("Unassigned")}
              <span class="badge badge-xs badge-ghost">{@unassigned_count}</span>
              <.chip_remove
                click={JS.push("toggle_unassigned")}
                name={gettext("Unassigned")}
              />
            </span>

            <span :for={p <- @assignee_selected} class="badge badge-outline gap-1.5 max-w-56">
              <span class="truncate">{p.name}</span>
              <.chip_remove
                click={JS.push("remove_assignee_person", value: %{uuid: p.uuid})}
                name={p.name}
              />
            </span>
          </div>

          <div class="divider my-0"></div>

          <%!-- Refinements. "Personal only" sits with the chips it refines and
               never affects the Unassigned lens. --%>
          <label
            :if={@assignee_selected != []}
            class="label cursor-pointer justify-start gap-2 text-xs tooltip"
            data-tip={gettext("Only tasks assigned to these people personally — hides work they inherit from teams and departments")}
          >
            <input
              type="checkbox"
              class={["checkbox checkbox-xs", CalendarDisplay.loading_class()]}
              checked={@assignee_direct_only?}
              phx-click="toggle_assignee_direct"
            />
            {gettext("Personal only")}
          </label>

          <label
            class="label cursor-pointer justify-start gap-2 text-xs tooltip"
            data-tip={gettext("Only late tasks — not done and past their scheduled days")}
          >
            <input
              type="checkbox"
              class={["checkbox checkbox-xs checkbox-error", CalendarDisplay.loading_class()]}
              checked={@overdue_only?}
              phx-click="toggle_overdue_only"
            />
            {gettext("Overdue only")}
          </label>
        </div>
      </div>
    </div>
    """
  end

  # The chip's ✕: optimistic same-frame fade (JS.hide) with the real removal
  # pushed behind it. Bare buttons get no pointer cursor from Tailwind v4's
  # preflight and a 12px hover target is easy to miss — pointer, padded hit
  # area, red disc on hover.
  attr(:click, :any, required: true)
  attr(:name, :string, required: true)

  defp chip_remove(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={
        JS.hide(
          to: {:closest, "span.badge"},
          transition: {"transition-opacity duration-100", "opacity-100", "opacity-0"}
        )
        |> Phoenix.LiveView.JS.concat(@click)
      }
      class="shrink-0 cursor-pointer rounded-full p-0.5 -m-0.5 transition-colors hover:bg-error hover:text-error-content tooltip"
      data-tip={gettext("Remove %{name}", name: @name)}
      aria-label={gettext("Remove %{name}", name: @name)}
    >
      <.icon name="hero-x-mark" class="w-3 h-3 block" />
    </button>
    """
  end

  defp me_chip_active?(%{person_uuid: uuid}, selected),
    do: Enum.any?(selected, &(&1.uuid == uuid))

  defp me_chip_active?(_me_scope, _selected), do: false
end
