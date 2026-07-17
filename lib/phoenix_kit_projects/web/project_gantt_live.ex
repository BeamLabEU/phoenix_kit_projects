defmodule PhoenixKitProjects.Web.ProjectGanttLive do
  @moduledoc """
  Gantt / waterfall view of a project — the same data as
  `ProjectShowLive`, rendered as horizontal bars on a date axis via the
  `PhoenixLiveGantt` component instead of the vertical timeline.

  Read-only: it visualizes the project's assignments as a sequential
  schedule (each task starts where the previous one ends, honoring the
  project's weekday/weekend rules via `Project.eta_from/3`) and draws
  dependency arrows between them. Mutations still happen on the vertical
  show page; the two views share the project UUID.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{GanttDisplay, L10n, Paths, Projects, ScheduleLayout}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Project}
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  # Assignee display helper shared with ProjectShowLive. See WebHelpers.
  # (The schedule math itself lives in ScheduleLayout.)
  import PhoenixKitProjects.Web.Helpers, only: [assignee_label: 1]

  require Logger

  @default_wrapper_class "flex flex-col w-full px-4 py-6 gap-4"
  @valid_zooms ~w(min5 min15 hour day week month)a

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
      # Without this, the emit-mode "Back to project" / "Add a task"
      # smart_links render open_embed buttons no clause handles — a click
      # crashes the embedded LV.
      |> WebHelpers.attach_open_embed_hook()

    case Projects.get_project_with_assignee(id) do
      nil ->
        {:ok,
         socket
         |> assign(default_assigns(session))
         |> put_flash(:error, gettext("Project not found."))
         |> WebHelpers.close_or_navigate(Paths.projects())}

      project ->
        # `topic_tasks` (global task-template edits) is constant; the per-project
        # topics for the whole tree are subscribed in `load_gantt`/`subscribe_tree`.
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

        # On the live (connected) mount, defer the per-project build off the first
        # paint so the Timeline tab shows a skeleton immediately. The dead
        # (HTTP/SEO/no-JS) render builds inline so it ships the real chart.
        socket =
          if connected?(socket) do
            send(self(), :load_gantt)
            assign(socket, gantt_loading: true)
          else
            load_gantt(socket)
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
      # `:auto` → load_gantt picks an initial zoom that fits the project's span;
      # resolved to a concrete zoom on first load, so manual switching sticks.
      zoom: :auto,
      # The visible window. `nil` → fit to the project's tasks (the "Project"
      # home view); a concrete range → the user has navigated (prev/next or
      # jumped to today), and that window persists across zoom changes/reloads
      # until they hit "Project".
      nav_range: nil,
      events: [],
      connectors: [],
      # Per-project PubSub topics already subscribed (the whole rendered tree;
      # grows as sub-projects appear). Avoids double-subscribing on reload.
      subscribed_projects: MapSet.new(),
      expanded: MapSet.new(),
      date_range: Date.range(Date.utc_today(), Date.add(Date.utc_today(), 7)),
      window_start: nil,
      window_end: nil,
      today: Date.utc_today(),
      # Bar-label display settings (style + tuning), set globally on
      # /admin/settings/projects. Read once at mount; a change applies on the next
      # load. Safe defaults (:fit / 0.4) when unconfigured.
      gantt_display: GanttDisplay.read(),
      # True between the connected mount and the `:load_gantt` message that
      # builds the chart — drives the loading skeleton so the first paint isn't
      # blocked on N per-project queries (and doesn't flash the empty state).
      gantt_loading: false
    ]
  end

  # Deferred initial build (off the first paint — see mount).
  @impl true
  def handle_info(:load_gantt, socket), do: {:noreply, load_gantt(socket)}

  # ── PubSub reactivity (read-only — just reload) ──────────────────

  def handle_info({:projects, event, _payload}, socket)
      when event in [
             :assignment_created,
             :assignment_updated,
             :assignment_deleted,
             :assignment_reordered,
             :dependency_added,
             :dependency_removed,
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
      project -> {:noreply, socket |> assign(project: project) |> load_gantt()}
    end
  end

  def handle_info({:projects, :project_deleted, _payload}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("This project was deleted."))
     |> WebHelpers.close_or_navigate(Paths.projects())}
  end

  def handle_info(msg, socket) do
    Logger.debug("[ProjectGanttLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("set_zoom", %{"zoom" => zoom}, socket) do
    case parse_zoom(zoom) do
      nil ->
        # Unknown preset → ignore. (The schedule is zoom-independent — real
        # durations — so a display recompute is all a valid one ever needs.)
        {:noreply, socket}

      z ->
        {:noreply, socket |> assign(zoom: z) |> reflow_display()}
    end
  end

  # ── Timeline navigation ─────────────────────────────────────────
  # The window (`date_range`) can be panned and jumped. `nil` nav_range = the
  # "Project" home view (fit to tasks); any jump/pan sets a concrete window.

  # Page the window earlier/later (‹ ›) by ~3/4 of its width — a sliver of the
  # previous view carries over for orientation. A task overlapping the new
  # window still renders (clipped) even if it started in an earlier page.
  def handle_event("navigate", %{"direction" => dir}, socket) do
    {first, last} = window_bounds(socket.assigns.date_range)
    step = max(div(Date.diff(last, first) * 3, 4), 1)
    delta = if dir == "next", do: step, else: -step

    nav = Date.range(Date.add(first, delta), Date.add(last, delta))
    {:noreply, socket |> assign(nav_range: nav) |> reflow_display()}
  end

  # Jump to today: re-center the current window on today (keeping its width, so
  # the scale is unchanged) and `auto_scroll_today` lands on the today line.
  def handle_event("jump_today", _params, socket) do
    {first, last} = window_bounds(socket.assigns.date_range)
    width = max(Date.diff(last, first), 1)
    half = div(width, 2)
    today = Date.utc_today()

    nav = Date.range(Date.add(today, -half), Date.add(today, width - half))
    {:noreply, socket |> assign(nav_range: nav) |> reflow_display()}
  end

  # Home: drop the navigated window and refit to the project's tasks.
  def handle_event("fit_project", _params, socket) do
    {:noreply, socket |> assign(nav_range: nil) |> reflow_display()}
  end

  # Toggle a sub-project's expand state (the PhoenixLiveGantt chevron fires this).
  # Events already carry every descendant (tagged with parent_id); PhoenixLiveGantt
  # shows/hides them from `expanded`, so no reload/requery is needed here.
  def handle_event("toggle_subproject", %{"event-id" => uuid}, socket) do
    {:noreply, update(socket, :expanded, &PhoenixLiveGantt.toggle_expanded(&1, uuid))}
  end

  # Popover "Edit" action on a task bar → the assignment edit form. The owning
  # project uuid rides along as `phx-value-project` (a child task belongs to a
  # sub-project). Emit-mode-aware via `navigate_or_open/2`.
  def handle_event("gantt_edit", %{"event-id" => uuid, "project" => project_uuid}, socket) do
    {:noreply,
     WebHelpers.navigate_or_open(socket,
       to: Paths.edit_assignment(project_uuid, uuid),
       open:
         {PhoenixKitProjects.Web.AssignmentFormLive,
          %{"live_action" => "edit", "project_id" => project_uuid, "id" => uuid}}
     )}
  end

  # Popover "Open" action on a sub-project bar → drill into the child project.
  def handle_event("gantt_open", %{"child" => child_uuid}, socket) do
    {:noreply,
     WebHelpers.navigate_or_open(socket,
       to: Paths.project(child_uuid),
       open: {PhoenixKitProjects.Web.ProjectShowLive, %{"id" => child_uuid}}
     )}
  end

  # ── Data loading ────────────────────────────────────────────────

  defp load_gantt(socket) do
    project = socket.assigns.project
    lang = L10n.current_content_lang()

    # Subscribe to the root project's topic BEFORE reading the tree, so a
    # broadcast that lands while `build_gantt/2` runs can't be dropped on the
    # floor (mirrors the list LVs' subscribe-before-read). `subscribe_tree/2`
    # is idempotent, so the full-tree subscribe below skips the root.
    socket = subscribe_tree(socket, [project.uuid])

    {events, connectors, project_uuids} = build_gantt(project, lang)

    socket
    |> subscribe_tree(project_uuids)
    |> assign(events: events, connectors: connectors, gantt_loading: false)
    |> reflow_display()
  end

  # Live updates: a sub-project's tasks and dependencies broadcast on the CHILD
  # project's topic, so subscribing to just the root misses every edit inside a
  # sub-project. Subscribe to every project in the rendered tree. A newly added
  # sub-project arrives via a parent-topic broadcast (the link assignment is on
  # the parent), which reloads and subscribes the new child here; `seen` tracks
  # what's already subscribed so we never double-subscribe (and double-reload).
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

  # Display-only recompute from the already-built events: resolve the zoom,
  # the visible window, and the marker. The SCHEDULE itself is zoom-independent
  # (real durations), so changing zoom never rebuilds events — it only changes
  # column density, the range buffer, and the marker precision.
  defp reflow_display(socket) do
    events = socket.assigns.events
    zoom = resolve_zoom(socket.assigns.zoom, events)
    nav = socket.assigns.nav_range

    # At a sub-day zoom, fit the POSITIONING window tight against the tasks (one
    # column of buffer either side) instead of letting the axis run midnight-to-
    # midnight — a whole day is a wall of empty columns at hour/15m/5m. Only when
    # we're showing the auto-fit view; once the user pages (nav_range set) the
    # window is their explicit day-granular choice, so we leave it whole-day.
    {ws, we} =
      if is_nil(nav) and sub_day_zoom?(zoom) and events != [] do
        compute_window(events, zoom)
      else
        {nil, nil}
      end

    assign(socket,
      # Store the resolved concrete zoom so the switcher highlights it and later
      # reloads don't re-auto-pick over the user's choice.
      zoom: zoom,
      # A navigated window wins; otherwise fit to the tasks. So zoom changes and
      # reloads keep wherever the user paged to. `date_range` stays whole-day (it
      # drives event partition / edge counts); the sub-day window is a separate
      # positioning override that must stay covered by it.
      date_range: cover_range(nav || compute_range(events, zoom), ws, we),
      window_start: ws,
      window_end: we,
      # At a sub-day zoom, a precise "now" gives an exact marker + current-slot
      # column highlight; coarser zooms only need the date.
      today: if(sub_day_zoom?(zoom), do: DateTime.utc_now(), else: Date.utc_today())
    )
  end

  # Picks an initial zoom that fits the project's real span; an explicit zoom
  # passes through. A few-hour project opens at hour, a few-week one at day, etc.
  defp resolve_zoom(:auto, events) do
    case span_days(events) do
      nil -> :week
      n when n <= 2 -> :hour
      n when n <= 31 -> :day
      n when n <= 365 -> :week
      _ -> :month
    end
  end

  defp resolve_zoom(zoom, _events), do: zoom

  defp sub_day_zoom?(zoom), do: zoom in [:hour, :min15, :min5]

  defp span_days([]), do: nil

  defp span_days(events) do
    dates =
      Enum.flat_map(events, fn e ->
        [as_date(e.start), as_date(PhoenixLiveGantt.Task.effective_end(e))]
      end)

    Date.diff(Enum.max(dates, Date), Enum.min(dates, Date))
  end

  # Maps the project's assignments — and every sub-project's descendants — onto
  # `PhoenixLiveGantt.Task` structs, ALWAYS at the real (hour-precise) schedule so the
  # layout is identical at every display zoom — a 2-hour task is a 2-hour bar,
  # not padded out to a whole day. The display zoom only changes column density,
  # so tasks pack the same in day, week, or hour view. The tree flattening +
  # durations→dates layout (sequential waterfall, sub-project span, drag-order
  # placement) live in the shared `ScheduleLayout` — the Calendar tab renders
  # the same walk, so the two views can't disagree. Dependencies become
  # finish-to-start connectors.
  defp build_gantt(project, lang) do
    {items, layout} = ScheduleLayout.tree(project)

    # `items` is already in flattened tree order (each sub-project parent
    # immediately followed by its descendants). Pass that index as `extra.order`
    # so the chart keeps this stable hierarchical order — otherwise the library
    # auto-places rows by dependency/date, and expanding a sub-project re-sorts
    # its rolled-up bar away from its siblings.
    events =
      items
      |> Enum.with_index()
      |> Enum.map(fn {it, idx} ->
        %{start: s, end: e} = Map.fetch!(layout, it.uuid)
        build_task(it, s, e, lang, idx)
      end)

    # Every project in the rendered tree (parent + sub-project descendants).
    # Used both to gather dependencies and to subscribe for live updates —
    # dependencies and assignments inside a sub-project live on the CHILD
    # project, not the parent.
    project_uuids = items |> Enum.map(& &1.project.uuid) |> Enum.uniq()

    {events, tree_connectors(project_uuids), project_uuids}
  end

  # A dependency is stored on the project that OWNS the dependent assignment, so
  # a sub-project task's dependencies live under the CHILD project, not the
  # parent. `list_all_dependencies/1` is single-project; gather across every
  # project in the rendered tree so arrows inside and between sub-projects draw —
  # otherwise a project built entirely from sub-project tasks shows no
  # connectors at all.
  defp tree_connectors(project_uuids) do
    project_uuids
    |> Enum.flat_map(&Projects.list_all_dependencies/1)
    |> Enum.map(fn d -> %{from: d.depends_on_uuid, to: d.assignment_uuid} end)
  end

  defp build_task(it, start_date, end_date, lang, order) do
    a = it.assignment

    extra =
      %{actions: task_actions(a, it.project.uuid), order: order}
      |> then(&if(it.parent_uuid, do: Map.put(&1, :parent_id, it.parent_uuid), else: &1))

    %PhoenixLiveGantt.Task{
      id: a.uuid,
      title: Assignment.label(a, lang) || gettext("(untitled task)"),
      start: start_date,
      end: end_date,
      progress_pct: a.progress_pct,
      color: gantt_color(a.status),
      assignee: assignee_label(a),
      extra: extra
    }
  end

  # Popover action buttons per bar. A sub-project gets "Open" (drill into the
  # child project); PhoenixLiveGantt adds the expand/collapse toggle itself. A leaf
  # task gets "Edit" (its assignment form). The owning project uuid rides along
  # so the handler can build the nested edit path for child tasks.
  defp task_actions(%Assignment{} = a, project_uuid) do
    if Assignment.subproject?(a) do
      [
        %{
          id: "open",
          icon: "hero-arrow-top-right-on-square",
          tooltip: gettext("Open sub-project"),
          phx_click: "gantt_open",
          phx_value: %{"child" => a.child_project_uuid}
        }
      ]
    else
      [
        %{
          id: "edit",
          icon: "hero-pencil",
          tooltip: gettext("Edit"),
          phx_click: "gantt_edit",
          phx_value: %{"project" => project_uuid}
        }
      ]
    end
  end

  # ── Display helpers ─────────────────────────────────────────────

  defp gantt_color("done"), do: "bg-success"
  defp gantt_color("in_progress"), do: "bg-warning"
  defp gantt_color(_), do: "bg-primary"

  # The chart's CHROME strings (toolbar, zoom labels, Today, prev/next, popover +
  # expand/collapse labels) — localized via this app's gettext, matching how the
  # rest of the projects UI translates. Task CONTENT (titles, assignees) is
  # already localized upstream in `build_task/5`. Month names reuse
  # `L10n.short_month/1` (the same gettext-backed helper the date formatters use).
  defp gantt_translations do
    %{
      labels: %{
        today: gettext("Today"),
        month: gettext("Month"),
        week: gettext("Week"),
        day: gettext("Day"),
        hour: gettext("Hour"),
        min15: gettext("15m"),
        min5: gettext("5m"),
        task: gettext("Task"),
        ungrouped: gettext("Ungrouped"),
        prev: gettext("Previous"),
        next: gettext("Next"),
        no_title: gettext("(No title)"),
        expand_subproject: gettext("Expand sub-project"),
        collapse_subproject: gettext("Collapse sub-project")
      },
      month_names_short: Map.new(1..12, &{&1, L10n.short_month(&1)})
    }
  end

  # Fit the visible window to the TASKS (small padding either side), NOT to
  # today — otherwise a project whose work is weeks away from today stretches
  # the chart across the empty gap just to keep the today marker on screen.
  # When today falls outside this window, PhoenixLiveGantt shows an off-screen
  # directional "Today" hint at the edge instead of widening the axis.
  defp compute_range([], _zoom) do
    today = Date.utc_today()
    Date.range(Date.add(today, -1), Date.add(today, 7))
  end

  defp compute_range(events, zoom) do
    # Events may be date- or datetime-precise; the window is always whole days,
    # so collapse every endpoint to its date.
    dates =
      Enum.flat_map(events, fn e ->
        [as_date(e.start), as_date(PhoenixLiveGantt.Task.effective_end(e))]
      end)

    # One empty day of buffer on the left (a task ends on its exclusive `end`
    # date, so the right already shows one empty day — no `last` padding). At a
    # sub-day zoom a whole day is many empty columns, so drop the left buffer
    # there and let the first task's empty leading hours be the breathing room.
    left_buffer = if sub_day_zoom?(zoom), do: 0, else: 1

    first = dates |> Enum.min(Date) |> Date.add(-left_buffer)
    last = Enum.max(dates, Date)

    Date.range(first, last)
  end

  defp window_bounds(%Date.Range{first: first, last: last}), do: {first, last}

  # A tight sub-day positioning window: one column-slot before the first task to
  # one slot after the last, snapped to the zoom's slot boundaries (so column
  # labels land on round clock times). Returns `{NaiveDateTime, NaiveDateTime}`.
  defp compute_window(events, zoom) do
    slot = window_slot_minutes(zoom)

    starts = events |> Enum.map(& &1.start) |> Enum.reject(&is_nil/1) |> Enum.map(&as_naive/1)

    ends =
      events
      |> Enum.map(&PhoenixLiveGantt.Task.effective_end/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&as_naive/1)

    case {starts, ends} do
      {[_ | _], [_ | _]} ->
        first = Enum.min(starts, NaiveDateTime)
        last = Enum.max(ends, NaiveDateTime)

        ws = first |> floor_to_slot(slot) |> NaiveDateTime.add(-slot, :minute)
        we = last |> ceil_to_slot(slot) |> NaiveDateTime.add(slot, :minute)
        {ws, we}

      _ ->
        {nil, nil}
    end
  end

  defp window_slot_minutes(:hour), do: 60
  defp window_slot_minutes(:min15), do: 15
  defp window_slot_minutes(:min5), do: 5

  defp floor_to_slot(%NaiveDateTime{} = t, slot) do
    floored = div(t.hour * 60 + t.minute, slot) * slot
    NaiveDateTime.new!(NaiveDateTime.to_date(t), Time.new!(div(floored, 60), rem(floored, 60), 0))
  end

  defp ceil_to_slot(%NaiveDateTime{} = t, slot) do
    floored = floor_to_slot(t, slot)

    if NaiveDateTime.compare(t, floored) == :eq,
      do: floored,
      else: NaiveDateTime.add(floored, slot, :minute)
  end

  # Widen a whole-day range so it still covers a sub-day window whose edges may
  # spill onto an adjacent date (e.g. a first task minutes after midnight pushes
  # `window_start` to the previous day). Keeps partition/edge-count consistent.
  defp cover_range(%Date.Range{} = range, %NaiveDateTime{} = ws, %NaiveDateTime{} = we) do
    Date.range(
      Enum.min([range.first, NaiveDateTime.to_date(ws)], Date),
      Enum.max([range.last, NaiveDateTime.to_date(we)], Date)
    )
  end

  defp cover_range(%Date.Range{} = range, _ws, _we), do: range

  defp as_date(%Date{} = d), do: d
  defp as_date(%NaiveDateTime{} = t), do: NaiveDateTime.to_date(t)
  defp as_date(%DateTime{} = t), do: DateTime.to_date(t)

  defp as_naive(%NaiveDateTime{} = t), do: t
  defp as_naive(%DateTime{} = t), do: DateTime.to_naive(t)
  defp as_naive(%Date{} = d), do: NaiveDateTime.new!(d, ~T[00:00:00])

  defp parse_zoom(zoom) do
    z = String.to_existing_atom(zoom)
    if z in @valid_zooms, do: z, else: nil
  rescue
    ArgumentError -> nil
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
            <span class="text-base-content/50 font-normal text-lg">· {gettext("Timeline")}</span>
          </h1>
        </div>
      </div>

      <%= if @gantt_loading do %>
        <div
          class="border border-base-200 rounded-lg overflow-hidden p-4 space-y-3"
          aria-busy="true"
          aria-label={gettext("Loading the timeline…")}
        >
          <div class="h-6 w-1/3 bg-base-200 rounded animate-pulse"></div>
          <div class="h-4 w-2/3 bg-base-200/70 rounded animate-pulse"></div>
          <div class="h-4 w-1/2 bg-base-200/70 rounded animate-pulse"></div>
          <div class="h-4 w-3/5 bg-base-200/70 rounded animate-pulse"></div>
        </div>
      <% else %>
        <%= if @events == [] do %>
          <.empty_state
            icon="hero-chart-bar-square"
            title={gettext("No tasks to chart yet.")}
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
          <%!-- Bar-label style + tuning come from the global projects settings
               (/admin/settings/projects → Timeline labels), read into
               @gantt_display at mount. --%>
          <PhoenixLiveGantt.gantt
            id={"project-gantt-#{@project.uuid}"}
            events={@events}
            connectors={@connectors}
            date_range={@date_range}
            window_start={@window_start}
            window_end={@window_end}
            zoom={@zoom}
            today={@today}
            expanded={@expanded}
            translations={gantt_translations()}
            on_toggle_expand="toggle_subproject"
            on_zoom_change="set_zoom"
            on_navigate="navigate"
            on_scroll_today="jump_today"
            zooms={[:min5, :min15, :hour, :day, :week, :month]}
            label_position={@gantt_display.label_position}
            label_side={@gantt_display.label_side}
            label_overflow={@gantt_display.label_overflow}
            label_fit_ratio={@gantt_display.label_fit_ratio}
            label_watermark_opacity={@gantt_display.label_watermark_opacity}
            show_progress={@gantt_display.show_progress}
            show_connectors={@gantt_display.show_connectors}
            show_today={@gantt_display.show_today}
            tiny_bar_px={@gantt_display.tiny_bar_px}
            min_bar_px={@gantt_display.min_bar_px}
            row_height={@gantt_display.row_height}
            avoid_collisions={@gantt_display.avoid_collisions}
            bus_attach_mode={@gantt_display.bus_attach_mode}
            show_header={true}
            show_navigation={true}
            show_edge_indicators={false}
            show_today_edge={false}
            enable_hooks={true}
            class="max-h-[70vh]"
          >
            <:toolbar_start>
              <button
                type="button"
                class="btn btn-xs btn-ghost"
                phx-click={
                  Phoenix.LiveView.JS.push("fit_project")
                  |> PhoenixLiveGantt.scroll_to_start("project-gantt-#{@project.uuid}")
                }
                title={gettext("Fit the project's tasks")}
              >
                {gettext("Project")}
              </button>
            </:toolbar_start>
          </PhoenixLiveGantt.gantt>
        </div>
        <% end %>
      <% end %>
    </div>
    """
  end
end
