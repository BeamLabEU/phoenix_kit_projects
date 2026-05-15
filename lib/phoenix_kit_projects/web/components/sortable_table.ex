defmodule PhoenixKitProjects.Web.Components.SortableTable do
  @moduledoc """
  Drag-to-reorder list table. Wraps the core `SortableGrid` hook
  (`priv/static/assets/phoenix_kit.js`) with the projects module's
  standard chrome: card-shadow shell, table layout, drag-handle
  column with bars-3 icon, hover state, and `align-middle` cells so
  icons stay vertically centered during drag.

  When `draggable={false}` the drag handle column is dropped and the
  hook isn't attached — useful when the list is filtered (archived /
  all) so reordering wouldn't write consistent positions.

  ## Slots

    * `:col` — one per visible column. `:label` becomes the `<th>`
      text; the inner block renders the cell. `:class` is appended
      to the `<td>` (`align-middle` is always merged in).

  ## Example

      <.sortable_table
        id="tasks-list-body"
        rows={@tasks}
        row_id={& &1.uuid}
        event="reorder_tasks"
        draggable={true}
      >
        <:col label={gettext("Title")}>
          <.smart_link
            navigate={Paths.edit_task(t.uuid)}
            emit={{PhoenixKitProjects.Web.TaskFormLive,
                   %{"live_action" => "edit", "id" => t.uuid}}}
            embed_mode={@embed_mode}
            class="link link-hover font-medium"
          >
            {Task.localized_title(t, lang)}
          </.smart_link>
        </:col>
        <:col label={gettext("Actions")} class="text-right">
          ...
        </:col>
      </.sortable_table>
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon

  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:row_id, :any, required: true, doc: "1-arity fn returning the uuid for a row")
  attr(:event, :string, required: true)
  attr(:draggable, :boolean, default: true)
  attr(:row_class, :string, default: nil)

  slot :col, required: true do
    attr(:label, :string, required: true)
    attr(:class, :string)
  end

  def sortable_table(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body p-0">
        <table class="table">
          <thead>
            <tr>
              <th :if={@draggable} class="w-8"></th>
              <th :for={col <- @col} class={Map.get(col, :class, nil)}>{col.label}</th>
            </tr>
          </thead>
          <tbody
            id={@id}
            phx-hook={if @draggable, do: "SortableGrid"}
            data-sortable={if @draggable, do: "true"}
            data-sortable-event={@event}
            data-sortable-items=".sortable-item"
            data-sortable-handle=".pk-drag-handle"
          >
            <tr :for={row <- @rows} class={["hover sortable-item", @row_class]} data-id={@row_id.(row)}>
              <td
                :if={@draggable}
                class="pk-drag-handle cursor-grab text-base-content/40 hover:text-base-content align-middle"
                title={gettext("Drag to reorder")}
              >
                <.icon name="hero-bars-3" class="w-4 h-4" />
              </td>
              <td :for={col <- @col} class={["align-middle", Map.get(col, :class, nil)]}>
                {render_slot(col, row)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
