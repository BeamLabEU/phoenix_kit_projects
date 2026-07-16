defmodule PhoenixKitProjects.Web.ProjectCalendarLive do
  @moduledoc """
  Calendar view of a project — the same scheduled data as the Timeline
  (gantt) tab, rendered as all-day bars on a month grid via the standalone
  `phoenix_live_calendar` component instead of bars on a date axis.

  Read-only: it visualizes the project's top-level assignments at the exact
  spans the shared `ScheduleLayout` walk computes (each task starts where the
  previous one ends, honoring weekday/weekend rules), so this tab and the
  Timeline tab can never disagree about which dates a task occupies. A
  sub-project appears as one bar spanning its children's walk — drilling into
  the child project shows its own calendar. Mutations still happen on the
  vertical show page; the views share the project UUID.

  Dates are the schedule's own UTC calendar dates — deliberately NOT shifted
  to the viewer's timezone offset, matching the sibling Timeline tab (the
  Overview dashboard calendar shifts, but there the bars anchor against the
  viewer's "today"; here the two tabs of one page must agree).

  Like `ProjectGanttLive`, this LV is embeddable via `live_render` (session:
  `id`, plus the shared embed contract keys) and runs `headless` when nested
  as a tab inside `ProjectShowLive`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{L10n, Paths, Projects, ScheduleLayout}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Project}
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  require Logger

  @default_wrapper_class "flex flex-col w-full px-4 py-6 gap-4"

  # ── Mount ───────────────────────────────────────────────────────

  @impl true
  def mount(:not_mounted_at_router, %{"id" => id} = session, socket) do
    WebHelpers.maybe_put_locale(session)
    mount(%{"id" => id}, session, socket)
  end

  def mount(%{"id" => id}, session, socket) do
    WebHelpers.maybe_put_locale(session)

    socket =
      socket
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)

    case Projects.get_project_with_assignee(id) do
      nil ->
        {:ok,
         socket
         |> assign(default_assigns(session))
         |> put_flash(:error, gettext("Project not found."))
         |> WebHelpers.close_or_navigate(Paths.projects())}

      project ->
        # `topic_tasks` (global task-template edits) is constant; the per-project
        # topics for the whole tree are subscribed in `load_calendar`.
        if connected?(socket) do
          ProjectsPubSub.subscribe(ProjectsPubSub.topic_tasks())
        end

        socket =
          socket
          |> assign(default_assigns(session))
          |> assign(
            page_title: Project.localized_name(project, L10n.current_content_lang()),
            project: project,
            is_template: project.is_template
          )

        # On the live (connected) mount, defer the per-project build off the
        # first paint so the Calendar tab shows a skeleton immediately. The
        # dead (HTTP/SEO/no-JS) render builds inline so it ships the real grid.
        socket =
          if connected?(socket) do
            send(self(), :load_calendar)
            assign(socket, calendar_loading: true)
          else
            load_calendar(socket)
          end

        {:ok, socket}
    end
  end

  defp default_assigns(session) do
    [
      page_title: "",
      project: %Project{},
      is_template: false,
      # Headless = nested as a tab inside ProjectShowLive: drop the "Back to
      # project" link (the tabs replace it). Standalone/emit renders keep it.
      headless: Map.get(session, "headless", false),
      wrapper_class: Map.get(session, "wrapper_class", @default_wrapper_class),
      events: [],
      # `%{assignment_uuid => click target}` for event clicks — a leaf task
      # opens its assignment edit form, a sub-project drills into the child.
      click_targets: %{},
      # The month the grid INITIALLY opens on. Computed once on the first
      # load and then left alone: the calendar component's `date` prop is
      # initial-plus-controlled, so re-passing the same value on PubSub
      # reloads preserves the user's own month navigation.
      anchor_date: nil,
      today: Date.utc_today(),
      # Per-project PubSub topics already subscribed (the whole rendered tree;
      # grows as sub-projects appear). Avoids double-subscribing on reload.
      subscribed_projects: MapSet.new(),
      # True between the connected mount and the `:load_calendar` message —
      # drives the loading skeleton so the first paint isn't blocked on the
      # per-project queries (and doesn't flash the empty state).
      calendar_loading: false
    ]
  end

  # Deferred initial build (off the first paint — see mount).
  @impl true
  def handle_info(:load_calendar, socket), do: {:noreply, load_calendar(socket)}

  # The calendar component's callbacks arrive as process messages.
  def handle_info({:calendar_event_click, assignment_uuid}, socket) do
    case Map.get(socket.assigns.click_targets, assignment_uuid) do
      {:subproject, child_uuid} ->
        {:noreply,
         WebHelpers.navigate_or_open(socket,
           to: Paths.project(child_uuid),
           open: {PhoenixKitProjects.Web.ProjectShowLive, %{"id" => child_uuid}}
         )}

      {:task, project_uuid} ->
        {:noreply,
         WebHelpers.navigate_or_open(socket,
           to: Paths.edit_assignment(project_uuid, assignment_uuid),
           open:
             {PhoenixKitProjects.Web.AssignmentFormLive,
              %{
                "live_action" => "edit",
                "project_id" => project_uuid,
                "id" => assignment_uuid
              }}
         )}

      nil ->
        {:noreply, socket}
    end
  end

  # ── PubSub reactivity (read-only — just reload) ──────────────────

  def handle_info({:projects, event, _payload}, socket)
      when event in [
             :assignment_created,
             :assignment_updated,
             :assignment_deleted,
             :assignment_reordered,
             :task_updated,
             :task_deleted,
             :project_updated,
             :project_completed,
             :project_reopened,
             :project_started,
             :project_status_changed,
             :project_archived,
             :project_unarchived
           ] do
    case Projects.get_project_with_assignee(socket.assigns.project.uuid) do
      nil -> {:noreply, socket}
      project -> {:noreply, socket |> assign(project: project) |> load_calendar()}
    end
  end

  def handle_info({:projects, :project_deleted, _payload}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("This project was deleted."))
     |> WebHelpers.close_or_navigate(Paths.projects())}
  end

  def handle_info(msg, socket) do
    Logger.debug("[ProjectCalendarLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ── Data loading ────────────────────────────────────────────────

  defp load_calendar(socket) do
    project = socket.assigns.project
    lang = L10n.current_content_lang()

    # Subscribe to the root project's topic BEFORE reading the tree, so a
    # broadcast that lands while the build runs can't be dropped on the floor.
    # `subscribe_tree/2` is idempotent, so the full-tree subscribe below skips
    # the root.
    socket = subscribe_tree(socket, [project.uuid])

    {items, layout} = ScheduleLayout.tree(project)

    # Only top-level assignments become bars: a sub-project's span already
    # covers its children's walk (ScheduleLayout sizes parents over their
    # subtree), so rendering the descendants too would double-draw the same
    # scheduled time. The child project's own calendar shows its tasks.
    top_items = Enum.filter(items, &is_nil(&1.parent_uuid))

    events =
      Enum.map(top_items, fn it ->
        %{start: s, end: e} = Map.fetch!(layout, it.uuid)
        to_event(it, s, e, lang)
      end)

    click_targets = Map.new(top_items, fn it -> {it.uuid, click_target(it.assignment)} end)

    # Live updates: a sub-project's tasks broadcast on the CHILD project's
    # topic, and their edits change the parent bar's span — subscribe to every
    # project in the rendered tree, same as the Timeline tab.
    project_uuids = items |> Enum.map(& &1.project.uuid) |> Enum.uniq()

    socket
    |> subscribe_tree(project_uuids)
    |> assign(
      events: events,
      click_targets: click_targets,
      today: Date.utc_today(),
      calendar_loading: false
    )
    |> put_initial_anchor(events)
  end

  defp subscribe_tree(socket, project_uuids) do
    if connected?(socket) do
      seen = socket.assigns.subscribed_projects
      fresh = Enum.reject(project_uuids, &MapSet.member?(seen, &1))
      Enum.each(fresh, &ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(&1)))
      assign(socket, subscribed_projects: MapSet.union(seen, MapSet.new(project_uuids)))
    else
      socket
    end
  end

  # ── Event mapping ───────────────────────────────────────────────

  # One all-day bar per top-level assignment, spanning the schedule walk's
  # calendar days. All-day (DATE-pair) rendering keeps the month grid honest
  # for multi-day tasks and stacks same-day short tasks as chips — the
  # hour-precise detail lives one tab over. `phoenix_live_calendar` ends are
  # exclusive (`[start, end)`).
  defp to_event(it, %NaiveDateTime{} = s, %NaiveDateTime{} = e, lang) do
    a = it.assignment
    start_d = NaiveDateTime.to_date(s)
    end_d = exclusive_end_date(start_d, e)

    PhoenixLiveCalendar.event(a.uuid, start_d,
      title: Assignment.label(a, lang) || gettext("(untitled task)"),
      end: end_d,
      all_day: true,
      color: status_color(a.status)
    )
  end

  # The exclusive end DATE for a span ending at `e`: a span that ends exactly
  # at midnight doesn't occupy that day, any later instant does. Floored one
  # day past the start so a zero-length span still shows as a one-day chip.
  defp exclusive_end_date(start_d, %NaiveDateTime{} = e) do
    e_date = NaiveDateTime.to_date(e)

    exclusive =
      if NaiveDateTime.compare(e, NaiveDateTime.new!(e_date, ~T[00:00:00])) == :eq,
        do: e_date,
        else: Date.add(e_date, 1)

    Enum.max([exclusive, Date.add(start_d, 1)], Date)
  end

  # Status → bar color, matching the Timeline tab's bars (NOT the list badges:
  # a light `bg-base-300` todo chip would wash out on the month grid). The
  # calendar lib infers a readable text color for daisyUI semantic classes.
  defp status_color("done"), do: "bg-success"
  defp status_color("in_progress"), do: "bg-warning"
  defp status_color(_), do: "bg-primary"

  defp click_target(%Assignment{} = a) do
    if Assignment.subproject?(a),
      do: {:subproject, a.child_project_uuid},
      else: {:task, a.project_uuid}
  end

  # The month the grid opens on: today when the schedule is in progress
  # around it, else the month the schedule starts — so a past or future
  # project opens showing its tasks instead of an empty current month.
  defp put_initial_anchor(socket, events) do
    if socket.assigns.anchor_date do
      socket
    else
      assign(socket, anchor_date: initial_anchor(events, socket.assigns.today))
    end
  end

  defp initial_anchor([], today), do: today

  defp initial_anchor(events, today) do
    first = events |> Enum.map(& &1.start) |> Enum.min(Date)
    # Exclusive ends: the last occupied day is `end - 1`.
    last = events |> Enum.map(&Date.add(&1.end, -1)) |> Enum.max(Date)

    if Date.compare(today, first) != :lt and Date.compare(today, last) != :gt,
      do: today,
      else: first
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <%!-- Own header (back-link + title) — dropped when headless (nested as a
           tab inside ProjectShowLive, which already shows the project header). --%>
      <div :if={not @headless} class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex flex-col gap-1 min-w-0">
          <.smart_link
            navigate={if @is_template, do: Paths.template(@project.uuid), else: Paths.project(@project.uuid)}
            emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => @project.uuid}}}
            embed_mode={@embed_mode}
            class="link link-hover text-sm"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Back to project")}
          </.smart_link>
          <h1 class="text-2xl font-bold break-words">
            {Project.localized_name(@project, L10n.current_content_lang())}
            <span class="text-base-content/50 font-normal text-lg">· {gettext("Calendar")}</span>
          </h1>
        </div>
      </div>

      <%= if @calendar_loading do %>
        <div
          class="border border-base-200 rounded-lg overflow-hidden p-4 space-y-3"
          aria-busy="true"
          aria-label={gettext("Loading the calendar…")}
        >
          <div class="h-6 w-1/3 bg-base-200 rounded animate-pulse"></div>
          <div class="h-4 w-2/3 bg-base-200/70 rounded animate-pulse"></div>
          <div class="h-4 w-1/2 bg-base-200/70 rounded animate-pulse"></div>
          <div class="h-4 w-3/5 bg-base-200/70 rounded animate-pulse"></div>
        </div>
      <% else %>
        <%= if @events == [] do %>
          <.empty_state
            icon="hero-calendar-days"
            title={gettext("No tasks to place on the calendar yet.")}
          >
            <:cta>
              <.smart_link
                navigate={Paths.new_assignment(@project.uuid)}
                emit={{PhoenixKitProjects.Web.AssignmentFormLive, %{"live_action" => "new", "project_id" => @project.uuid}}}
                embed_mode={@embed_mode}
                class="link link-primary text-sm"
              >
                {gettext("Add a task")}
              </.smart_link>
            </:cta>
          </.empty_state>
        <% else %>
          <div class="border border-base-200 rounded-lg overflow-hidden">
            <.live_component
              module={PhoenixLiveCalendar.CalendarComponent}
              id={"project-calendar-#{@project.uuid}"}
              events={@events}
              views={[:month]}
              date={@anchor_date}
              today={@today}
              fixed_weeks={false}
              expand_cells={true}
              info_label={gettext("About this calendar")}
              on_event_click={fn id -> send(self(), {:calendar_event_click, id}) end}
            >
              <:info>
                <p class="mb-1 text-sm font-semibold text-base-content">
                  {gettext("Reading the calendar")}
                </p>
                <p>
                  {gettext("Each task spans the days it is scheduled to run, in the project's task order — the same schedule as the Timeline tab.")}
                </p>
                <p class="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1">
                  <span class="inline-flex items-center gap-1.5">
                    <span class="inline-block w-2.5 h-2.5 rounded-full bg-primary"></span>
                    {gettext("todo")}
                  </span>
                  <span class="inline-flex items-center gap-1.5">
                    <span class="inline-block w-2.5 h-2.5 rounded-full bg-warning"></span>
                    {gettext("in progress")}
                  </span>
                  <span class="inline-flex items-center gap-1.5">
                    <span class="inline-block w-2.5 h-2.5 rounded-full bg-success"></span>
                    {gettext("done")}
                  </span>
                </p>
                <p class="mt-1.5 text-base-content/50">
                  {gettext("Click a task to edit it; a sub-project opens the child project.")}
                </p>
              </:info>
            </.live_component>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end
end
