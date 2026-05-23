defmodule PhoenixKitProjects.Web.Components.BulkActionsToolbar do
  @moduledoc """
  Bulk-select toolkit for admin tables. Two function components:

    * `<.bulk_select_header_checkbox>` — goes in the table header's
      checkbox column. Cycles unchecked → indeterminate (partial) →
      checked (all). Same `phx-click` event drives all transitions; the
      consumer LV's handler picks "all" or "none" based on current count.

    * `<.bulk_actions_toolbar>` — floating toolbar above the table.
      Shows the selection count + actions (Reorder, Delete, Clear).
      Renders only when bulk mode is engaged on the consumer side.

  Both are projects-local for now; lift to core when a third consumer
  module shows up.

  ## Example

      <.table_default_header>
        <.table_default_row>
          <.table_default_header_cell class="w-8">
            <.bulk_select_header_checkbox
              id="projects-select-all"
              selected_count={MapSet.size(@selected_uuids)}
              total_count={length(@projects)}
              on_toggle="toggle_select_all"
              aria_label={gettext("Select all projects")}
            />
          </.table_default_header_cell>
          ...
        </.table_default_row>
      </.table_default_header>

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

  @doc """
  Header checkbox for a bulk-selectable table. Reflects the current
  selection as one of three states via daisyUI's `checkbox` + native
  `indeterminate` (set by the `PkCheckboxIndeterminate` JS hook):

    * 0 selected      → unchecked
    * 0 < N < total   → indeterminate
    * N == total      → checked

  Clicking it always emits `on_toggle`; the LV handler decides whether
  to select-all or clear based on the current state.
  """
  attr :id, :string, required: true
  attr :selected_count, :integer, required: true
  attr :total_count, :integer, required: true
  attr :on_toggle, :string, required: true
  attr :aria_label, :string, default: "Toggle select all"

  def bulk_select_header_checkbox(assigns) do
    ~H"""
    <input
      type="checkbox"
      id={@id}
      class="checkbox checkbox-sm"
      checked={@selected_count > 0 and @selected_count == @total_count}
      data-indeterminate={to_string(@selected_count > 0 and @selected_count < @total_count)}
      phx-hook="PkCheckboxIndeterminate"
      phx-click={@on_toggle}
      aria-label={@aria_label}
    />
    """
  end

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
