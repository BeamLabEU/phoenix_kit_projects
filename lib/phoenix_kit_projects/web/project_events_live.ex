defmodule PhoenixKitProjects.Web.ProjectEventsLive do
  @moduledoc """
  The **Events** extension tab (Step 12): a month calendar of project
  events (meetings, milestones, reviews) + a server-rendered upcoming
  list, mounted by the hub via `live_render` with the extension-tab
  session contract (no `handle_params/3`; same trust model as every
  contributed tab — see `ProjectWhiteboardsLive`).

  Phoenix-first: the calendar grid, the upcoming list, create, and delete
  all render/work server-side. Times are UTC (matches the module's
  scheduling frame); `all_day` events render as month bars, timed events
  as chips with an HH:MM prefix.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext

  # A destructive action that asks through core's confirm modal.
  import PhoenixKitProjects.Web.Components.ConfirmAction, only: [confirm_action_modal: 1]

  alias PhoenixKitProjects.{L10n, ProjectEvents, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.ProjectEvent
  alias PhoenixKitProjects.Web.Components.ConfirmAction
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  require Logger

  @impl true
  def mount(:not_mounted_at_router, session, socket) do
    WebHelpers.maybe_put_locale(session)

    project_uuid = session["project_uuid"]
    project = project_uuid && Projects.get_project(project_uuid)

    if connected?(socket) && project do
      ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(project.uuid))
    end

    {:ok,
     socket
     |> assign(
       project: project,
       current_user_uuid: session["current_user_uuid"],
       can_write: session["can_write"] == true,
       anchor_date: Date.utc_today(),
       today: Date.utc_today(),
       selected: nil,
       modal_open: false,
       modal_date: nil
     )
     |> load_events()}
  end

  # ── PubSub ──────────────────────────────────────────────────────

  @impl true
  def handle_info({:projects, event, _payload}, socket)
      when event in [:project_event_created, :project_event_updated, :project_event_deleted] do
    # Re-resolve the open detail panel too: another session may have
    # updated or DELETED the selected event — a stale struct kept a dead
    # modal open (panel round, Grok).
    selected =
      case {socket.assigns.project, socket.assigns.selected} do
        {%{} = project, %{uuid: uuid}} -> ProjectEvents.get(project.uuid, uuid)
        _ -> nil
      end

    {:noreply, socket |> load_events() |> assign(selected: selected)}
  end

  # The calendar component's callbacks arrive as messages.
  def handle_info({:calendar_event_click, uuid}, socket) do
    selected = socket.assigns.project && ProjectEvents.get(socket.assigns.project.uuid, uuid)
    {:noreply, assign(socket, selected: selected)}
  end

  def handle_info({:calendar_date_click, %Date{} = date}, socket) do
    {:noreply, assign(socket, modal_open: true, modal_date: date)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  # A destructive action asks first through core's confirm modal
  # (`Components.ConfirmAction`); only these events may be put behind it.
  def handle_event("request_confirm", params, socket),
    do: {:noreply, ConfirmAction.request(socket, params, ~w(delete_event))}

  def handle_event("confirm_action_cancel", _params, socket),
    do: {:noreply, ConfirmAction.clear(socket)}

  def handle_event("confirm_action_ok", _params, socket) do
    case ConfirmAction.take(socket) do
      {nil, socket} -> {:noreply, socket}
      {%{event: event, params: params}, socket} -> handle_event(event, params, socket)
    end
  end

  def handle_event("open_new_event", _params, socket) do
    {:noreply, assign(socket, modal_open: true, modal_date: socket.assigns.today)}
  end

  def handle_event("close_new_event", _params, socket) do
    {:noreply, assign(socket, modal_open: false, modal_date: nil)}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, selected: nil)}
  end

  def handle_event("select_event", %{"uuid" => uuid}, socket) do
    selected = socket.assigns.project && ProjectEvents.get(socket.assigns.project.uuid, uuid)
    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("create_event", params, socket) do
    case {socket.assigns.can_write, socket.assigns.project} do
      {false, _} ->
        {:noreply,
         put_flash(socket, :error, gettext("You don't have permission to change events."))}

      {true, nil} ->
        {:noreply, socket}

      {true, project} ->
        case ProjectEvents.create(project, event_attrs(params),
               actor_uuid: socket.assigns.current_user_uuid
             ) do
          {:ok, event} ->
            {:noreply,
             socket
             |> assign(
               modal_open: false,
               modal_date: nil,
               anchor_date: DateTime.to_date(event.starts_at)
             )
             |> load_events()
             |> put_flash(:info, gettext("Event added."))}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, put_flash(socket, :error, first_error(changeset))}
        end
    end
  end

  def handle_event("delete_event", %{"uuid" => uuid}, socket) do
    with true <- socket.assigns.can_write,
         %{} = project <- socket.assigns.project,
         %ProjectEvent{} = event <- ProjectEvents.get(project.uuid, uuid),
         :ok <- ProjectEvents.delete(event, actor_uuid: socket.assigns.current_user_uuid) do
      {:noreply,
       socket
       |> assign(selected: nil)
       |> load_events()
       |> put_flash(:info, gettext("Event removed."))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("prev_month", _params, socket) do
    {:noreply, shift_month(socket, -1)}
  end

  def handle_event("next_month", _params, socket) do
    {:noreply, shift_month(socket, 1)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Internals ───────────────────────────────────────────────────

  defp load_events(socket) do
    case socket.assigns.project do
      nil ->
        assign(socket, events: [], calendar_events: [], upcoming: [])

      project ->
        events = ProjectEvents.list_for_project(project.uuid)
        now = DateTime.utc_now()
        today = Date.utc_today()

        assign(socket,
          events: events,
          calendar_events: Enum.map(events, &to_calendar_event/1),
          upcoming:
            events
            |> Enum.filter(&still_upcoming?(&1, now, today))
            |> Enum.take(10)
        )
    end
  end

  # All-day moments are stored as midnights, so a raw DateTime compare
  # dropped an all-day event from Upcoming for its ENTIRE active day
  # (panel round, Grok) — compare by date instead; timed events keep the
  # instant comparison.
  defp still_upcoming?(%ProjectEvent{all_day: true} = e, _now, today) do
    last_day = DateTime.to_date(e.ends_at || e.starts_at)
    Date.compare(last_day, today) != :lt
  end

  defp still_upcoming?(%ProjectEvent{} = e, now, _today) do
    DateTime.compare(e.ends_at || e.starts_at, now) != :lt
  end

  # Month-grid mapping: all-day events span their date range as bars
  # (exclusive end, per the calendar lib); timed events are chips with an
  # HH:MM prefix — the Calendar-tab convention of keeping the month grid
  # all-day-honest.
  defp to_calendar_event(%ProjectEvent{} = e) do
    start_d = DateTime.to_date(e.starts_at)

    end_d =
      case e.ends_at do
        nil -> Date.add(start_d, 1)
        ends_at -> Date.add(DateTime.to_date(ends_at), 1)
      end

    title =
      if e.all_day do
        e.title
      else
        "#{Calendar.strftime(e.starts_at, "%H:%M")} #{e.title}"
      end

    PhoenixLiveCalendar.event(e.uuid, start_d,
      title: title,
      end: end_d,
      all_day: true,
      color: "bg-info"
    )
  end

  defp shift_month(socket, offset) do
    anchor = socket.assigns.anchor_date
    first = %{anchor | day: 1}
    shifted = Date.add(first, if(offset > 0, do: 32, else: -1))
    assign(socket, anchor_date: %{shifted | day: 1})
  end

  defp event_attrs(params) do
    all_day = params["all_day"] in ["true", "on"]
    starts_at = parse_moment(params["date"], params["start_time"], all_day)

    # A timed end WITHOUT an end date means "same day": the form labels
    # End date optional, so 09:00–10:00 on one day silently persisted as
    # open-ended before (panel round, Grok).
    end_date =
      case blank_to_nil(params["end_date"]) do
        nil ->
          if not all_day and blank_to_nil(params["end_time"]), do: params["date"]

        d ->
          d
      end

    ends_at = parse_moment(end_date, params["end_time"], all_day)

    %{
      title: params["title"],
      description: blank_to_nil(params["description"]),
      location: blank_to_nil(params["location"]),
      all_day: all_day,
      starts_at: starts_at,
      ends_at: ends_at
    }
  end

  # Date (+ optional HH:MM when not all-day) → UTC DateTime. A nil/blank
  # date yields nil and the changeset's required validation answers.
  defp parse_moment(date_str, time_str, all_day) do
    with date_str when is_binary(date_str) and date_str != "" <- date_str,
         {:ok, date} <- Date.from_iso8601(date_str) do
      time =
        if all_day do
          ~T[00:00:00]
        else
          case Time.from_iso8601("#{time_str}:00") do
            {:ok, t} -> t
            _ -> ~T[00:00:00]
          end
        end

      DateTime.new!(date, time, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp blank_to_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp first_error(changeset) do
    case Enum.at(changeset.errors, 0) do
      {:title, _} -> gettext("Give the event a title (up to 200 characters).")
      {:starts_at, _} -> gettext("Pick a date for the event.")
      {:ends_at, _} -> gettext("The end must not be before the start.")
      _ -> gettext("Could not save the event.")
    end
  end

  defp event_time_label(%ProjectEvent{all_day: true} = e) do
    case e.ends_at do
      nil -> L10n.format_date(e.starts_at)
      ends_at -> "#{L10n.format_date(e.starts_at)} – #{L10n.format_date(ends_at)}"
    end
  end

  defp event_time_label(%ProjectEvent{} = e) do
    start_label = "#{L10n.format_date(e.starts_at)} #{Calendar.strftime(e.starts_at, "%H:%M")}"

    case e.ends_at do
      nil -> start_label
      ends_at -> "#{start_label} – #{Calendar.strftime(ends_at, "%H:%M")}"
    end
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"project-events-#{(@project && @project.uuid) || "none"}"} class="flex flex-col gap-4">
      <%!-- Inline flash: nested live_render LVs get no app layout. --%>
      <div
        :if={Phoenix.Flash.get(@flash, :error)}
        class="alert alert-error text-sm py-2"
        phx-click="lv:clear-flash"
        phx-value-key="error"
        role="alert"
      >
        {Phoenix.Flash.get(@flash, :error)}
      </div>
      <div
        :if={Phoenix.Flash.get(@flash, :info)}
        class="alert alert-success text-sm py-2"
        phx-click="lv:clear-flash"
        phx-value-key="info"
        role="status"
      >
        {Phoenix.Flash.get(@flash, :info)}
      </div>

      <%= if is_nil(@project) do %>
        <div class="alert alert-warning text-sm">{gettext("Project not found.")}</div>
      <% else %>
        <div class="flex items-center justify-between gap-2">
          <div class="flex items-center gap-1">
            <button type="button" class="btn btn-ghost btn-sm" phx-click="prev_month" aria-label={gettext("Previous month")}>
              <.icon name="hero-chevron-left" class="w-4 h-4" />
            </button>
            <span class="font-medium text-sm min-w-32 text-center">
              {Calendar.strftime(@anchor_date, "%B %Y")}
            </span>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="next_month" aria-label={gettext("Next month")}>
              <.icon name="hero-chevron-right" class="w-4 h-4" />
            </button>
          </div>
          <button
            :if={@can_write}
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="open_new_event"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New event")}
          </button>
        </div>

        <.live_component
          module={PhoenixLiveCalendar.CalendarComponent}
          id={"project-events-cal-#{@project.uuid}"}
          events={@calendar_events}
          views={[:month]}
          date={@anchor_date}
          today={@today}
          expand_cells={true}
          on_event_click={fn id -> send(self(), {:calendar_event_click, id}) end}
          on_date_select={fn date -> send(self(), {:calendar_date_click, date}) end}
        />

        <%!-- Upcoming list — the no-JS answer to "what's next". --%>
        <div class="flex flex-col gap-2">
          <h4 class="text-sm font-semibold text-base-content/70">{gettext("Upcoming")}</h4>
          <%= if @upcoming == [] do %>
            <p class="text-sm text-base-content/50">{gettext("Nothing scheduled.")}</p>
          <% else %>
            <div
              :for={event <- @upcoming}
              class="flex items-center gap-3 rounded-lg border border-base-200 px-3 py-2"
            >
              <.icon name="hero-calendar" class="w-4 h-4 text-info shrink-0" />
              <button
                type="button"
                phx-click="select_event"
                phx-value-uuid={event.uuid}
                class="text-left text-sm font-medium link link-hover truncate"
              >
                {event.title}
              </button>
              <span class="text-xs text-base-content/60 ml-auto shrink-0">
                {event_time_label(event)}
              </span>
            </div>
          <% end %>
        </div>

        <%!-- Detail panel --%>
        <.modal :if={@selected} show on_close="close_detail" id={"event-detail-#{@project.uuid}"} max_width="md">
          <:title>{@selected.title}</:title>
          <div class="flex flex-col gap-2 text-sm">
            <div class="flex items-center gap-2">
              <.icon name="hero-clock" class="w-4 h-4 opacity-60" />
              <span>{event_time_label(@selected)}</span>
              <span :if={@selected.all_day} class="badge badge-ghost badge-sm">
                {gettext("All day")}
              </span>
            </div>
            <div :if={@selected.location} class="flex items-center gap-2">
              <.icon name="hero-map-pin" class="w-4 h-4 opacity-60" />
              <span>{@selected.location}</span>
            </div>
            <p :if={@selected.description} class="text-base-content/70 whitespace-pre-wrap">
              {@selected.description}
            </p>
          </div>
          <:actions>
            <.button
              :if={@can_write}
              type="button"
              variant="ghost"
              size="sm"
              class="text-error"
              {ConfirmAction.ask("delete_event",
                uuid: @selected.uuid,
                title: gettext("Remove event"),
                message: gettext("Remove \"%{title}\"?", title: @selected.title),
                confirm: gettext("Remove")
              )}
            >
              <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Remove")}
            </.button>
            <.button type="button" size="sm" phx-click="close_detail">
              {gettext("Close")}
            </.button>
          </:actions>
        </.modal>

        <%!-- Create modal. `close_guard`: a quick Esc must not throw away
             what was just typed. --%>
        <.modal
          :if={@modal_open}
          show
          on_close="close_new_event"
          id={"event-new-#{@project.uuid}"}
          max_width="md"
          close_guard={:input}
        >
          <:title>{gettext("New event")}</:title>
          <form id={"new-event-form-#{@project.uuid}"} phx-submit="create_event" class="flex flex-col gap-3">
            <.input
              id={"event-title-#{@project.uuid}"}
              name="title"
              value=""
              label={gettext("Title")}
              required
              maxlength="200"
              class="input-sm"
              placeholder={gettext("e.g. Sprint review")}
            />
            <div class="flex items-start gap-2">
              <.input
                id={"event-date-#{@project.uuid}"}
                type="date"
                name="date"
                label={gettext("Date")}
                required
                value={@modal_date && Date.to_iso8601(@modal_date)}
                class="input-sm"
                wrapper_class="flex-1"
              />
              <.input
                id={"event-end-date-#{@project.uuid}"}
                type="date"
                name="end_date"
                value=""
                label={gettext("End date (optional)")}
                class="input-sm"
                wrapper_class="flex-1"
              />
            </div>
            <.checkbox
              id={"event-all-day-#{@project.uuid}"}
              name="all_day"
              checked
              label={gettext("All day")}
              class="checkbox-primary checkbox-sm"
              wrapper_class="gap-2"
            />
            <div class="flex items-start gap-2">
              <.input
                id={"event-start-time-#{@project.uuid}"}
                type="time"
                name="start_time"
                value=""
                label={gettext("Start time (UTC)")}
                class="input-sm"
                wrapper_class="flex-1"
              />
              <.input
                id={"event-end-time-#{@project.uuid}"}
                type="time"
                name="end_time"
                value=""
                label={gettext("End time (UTC)")}
                class="input-sm"
                wrapper_class="flex-1"
              />
            </div>
            <.input
              id={"event-location-#{@project.uuid}"}
              name="location"
              value=""
              label={gettext("Location (optional)")}
              maxlength="200"
              class="input-sm"
            />
            <.textarea
              id={"event-description-#{@project.uuid}"}
              name="description"
              value=""
              label={gettext("Description (optional)")}
              rows="2"
              class="textarea-sm"
            />
            <%!-- Inside the form (not the modal's :actions slot) so Enter
                 and the submit button reach phx-submit. --%>
            <div class="modal-action">
              <.button type="button" variant="ghost" size="sm" phx-click="close_new_event">
                {gettext("Cancel")}
              </.button>
              <.button type="submit" size="sm" phx-disable-with={gettext("Adding…")}>
                {gettext("Add event")}
              </.button>
            </div>
          </form>
        </.modal>
      <% end %>
      <.confirm_action_modal confirm={assigns[:confirm_action]} />
    </div>
    """
  end
end
