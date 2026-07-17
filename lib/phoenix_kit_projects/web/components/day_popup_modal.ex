defmodule PhoenixKitProjects.Web.Components.DayPopupModal do
  @moduledoc """
  `<.day_popup_modal>` — the whole-day popup both calendars share.

  Kept in the DOM (`keep_in_dom`) so `PkDialogTrigger` can open it in the
  same frame as a day-cell / "+N more" click; the body renders a skeleton
  until the server round-trip fills `day_popup`, then one row per event
  scheduled that day (color dot, title, optional subtitle, `late` badge,
  status badge).

  The owning LiveView supplies normalized rows
  (`%{value:, title:, color:, subtitle:, late:, status:}`) plus the
  `row_click` event its rows push (`phx-value-uuid={row.value}`), and must
  handle `"close_day_popup"`.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitProjects.Web.Components.AssignmentStatusBadge
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]

  alias PhoenixKitProjects.CalendarDisplay
  alias PhoenixKitProjects.L10n

  attr(:id, :string, required: true, doc: "modal DOM id (unique per page/embed)")

  attr(:day_popup, :any,
    required: true,
    doc: "nil (closed / skeleton) | %{date: Date.t(), rows: [row]}"
  )

  attr(:row_click, :string,
    required: true,
    doc: "event a row click pushes; the row's :value rides phx-value-uuid"
  )

  def day_popup_modal(assigns) do
    ~H"""
    <.modal keep_in_dom id={@id} show={@day_popup != nil} on_close="close_day_popup" max_width="md">
      <:title>
        <%= if @day_popup do %>
          <.icon name="hero-calendar-days" class="w-5 h-5" />
          {L10n.format_date(@day_popup.date)}
        <% else %>
          <span class="inline-block w-28 h-5 bg-base-content/10 rounded animate-pulse"></span>
        <% end %>
      </:title>

      <%= if @day_popup do %>
        <%= if @day_popup.rows == [] do %>
          <p class="text-sm text-base-content/50 py-4 text-center">
            {gettext("Nothing scheduled this day.")}
          </p>
        <% else %>
          <div class="flex flex-col gap-1">
            <button
              :for={row <- @day_popup.rows}
              type="button"
              phx-click={@row_click}
              phx-value-uuid={row.value}
              class={[
                "flex items-center gap-2.5 w-full p-2 rounded-lg hover:bg-base-200 text-left transition",
                CalendarDisplay.loading_class()
              ]}
            >
              <span class={["w-2.5 h-2.5 rounded-full shrink-0", row.color]}></span>
              <span class="flex-1 min-w-0">
                <span class="block text-sm font-medium truncate">{row.title}</span>
                <span :if={row.subtitle} class="block text-xs text-base-content/60 truncate">
                  {row.subtitle}
                </span>
              </span>
              <span :if={row.late} class="badge badge-xs badge-error">
                {gettext("late")}
              </span>
              <.assignment_status_badge :if={row.status} status={row.status} size="xs" />
            </button>
          </div>
        <% end %>
      <% else %>
        <div class="flex flex-col gap-2 py-1">
          <div :for={_i <- 1..3} class="h-9 bg-base-content/10 rounded-lg animate-pulse"></div>
        </div>
      <% end %>
    </.modal>
    """
  end
end
