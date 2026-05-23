defmodule PhoenixKitProjects.Web.Components.BulkActionsToolbar do
  @moduledoc """
  Sticky toolbar that appears above a bulk-selectable table, showing
  selection state + actions (Reorder, Delete, Clear).

  The toolbar is always rendered when `bulk_enabled?` is true so the
  user can engage bulk mode by checking the select-all box. When no
  rows are selected, only the select-all checkbox + Reorder-all
  button are interactive (Delete is disabled). When rows are
  selected, the count appears and Delete enables.

  Actions are fixed for projects' three list views (Reorder, Delete,
  Clear). If a consumer needs different actions later, add an
  `:actions` slot.

  ## Example

      <.bulk_actions_toolbar
        selected_count={MapSet.size(@selected_uuids)}
        total_count={length(@projects)}
        all_selected?={MapSet.size(@selected_uuids) == length(@projects)}
        on_toggle_select_all="toggle_select_all"
        on_open_reorder="open_reorder_modal"
        on_bulk_delete="bulk_delete"
        on_clear_selection="clear_selection"
        noun_plural={gettext("projects")}
      />
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  attr :selected_count, :integer, required: true
  attr :total_count, :integer, required: true
  attr :all_selected?, :boolean, required: true

  attr :on_toggle_select_all, :string, required: true
  attr :on_open_reorder, :string, required: true
  attr :on_bulk_delete, :string, required: true
  attr :on_clear_selection, :string, required: true

  attr :noun_plural, :string, default: "items"
  attr :allow_reorder_all, :boolean, default: true
  attr :allow_delete, :boolean, default: true

  def bulk_actions_toolbar(assigns) do
    ~H"""
    <div class="flex items-center gap-3 bg-base-200 rounded-lg px-3 py-2 text-sm">
      <label class="flex items-center gap-2 cursor-pointer select-none">
        <input
          type="checkbox"
          class="checkbox checkbox-sm"
          checked={@all_selected? and @total_count > 0}
          disabled={@total_count == 0}
          phx-click={@on_toggle_select_all}
        />
        <span class="text-base-content/70">
          <%= if @selected_count > 0 do %>
            {gettext("%{count} selected", count: @selected_count)}
          <% else %>
            {gettext("Select all %{noun}", noun: @noun_plural)}
          <% end %>
        </span>
      </label>

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
          :if={@allow_delete}
          type="button"
          class="btn btn-sm btn-ghost text-error"
          phx-click={@on_bulk_delete}
          disabled={@selected_count == 0}
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
