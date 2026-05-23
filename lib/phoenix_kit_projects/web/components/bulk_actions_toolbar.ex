defmodule PhoenixKitProjects.Web.Components.BulkActionsToolbar do
  @moduledoc """
  Toolbar that appears above a bulk-selectable table. Shows the current
  selection count + actions (Reorder, Delete, Clear). The select-all
  control lives in the table header (the empty checkbox column cell),
  not here — convention for admin tables, also keeps the toolbar simple.

  When `selected_count == 0`, the toolbar still renders so the
  "Reorder all" affordance is reachable without first selecting
  anything. Delete + Clear only appear with a non-empty selection.

  ## Example

      <.bulk_actions_toolbar
        selected_count={MapSet.size(@selected_uuids)}
        total_count={length(@projects)}
        on_open_reorder="open_reorder_modal"
        on_bulk_delete="bulk_delete"
        on_clear_selection="clear_selection"
        noun_plural={gettext("projects")}
        allow_delete={false}
      />
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  attr :selected_count, :integer, required: true
  attr :total_count, :integer, required: true

  attr :on_open_reorder, :string, required: true
  attr :on_bulk_delete, :string, required: true
  attr :on_clear_selection, :string, required: true

  attr :noun_plural, :string, default: "items"
  attr :allow_reorder_all, :boolean, default: true
  attr :allow_delete, :boolean, default: true

  def bulk_actions_toolbar(assigns) do
    ~H"""
    <div class="flex items-center gap-3 bg-base-200 rounded-lg px-3 py-2 text-sm">
      <span class="text-base-content/70">
        <%= if @selected_count > 0 do %>
          {gettext("%{count} selected", count: @selected_count)}
        <% else %>
          {gettext("No selection")}
        <% end %>
      </span>

      <div class="flex items-center gap-2 ml-auto">
        <button
          :if={@allow_reorder_all or @selected_count > 0}
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click={@on_open_reorder}
          disabled={@total_count == 0}
        >
          <.icon name="hero-arrows-up-down" class="w-4 h-4" />
          {if @selected_count > 0,
            do: gettext("Reorder selected"),
            else: gettext("Reorder all")}
        </button>

        <button
          :if={@allow_delete and @selected_count > 0}
          type="button"
          class="btn btn-sm btn-ghost text-error"
          phx-click={@on_bulk_delete}
          data-confirm={
            gettext("Delete %{count} selected %{noun}? This cannot be undone.",
              count: @selected_count,
              noun: @noun_plural
            )
          }
        >
          <.icon name="hero-trash" class="w-4 h-4" />
          {gettext("Delete")}
        </button>

        <button
          :if={@selected_count > 0}
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click={@on_clear_selection}
        >
          {gettext("Clear")}
        </button>
      </div>
    </div>
    """
  end
end
