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

  alias PhoenixKitProjects.{Assignees, CalendarDisplay, L10n, Paths, Projects, ScheduleLayout}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Project}
  alias PhoenixKitProjects.Web.AssigneeFilter
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  require Logger

  @default_wrapper_class "flex flex-col w-full px-4 py-6 gap-4"

  # The shared filter's events, forwarded to Web.AssigneeFilter.update/3.
  @assignee_filter_events AssigneeFilter.events()

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

    # Subscribe BEFORE the project read: `load_calendar` reuses the struct
    # fetched below (it never re-reads the project), so a project_updated /
    # project_started broadcast landing between an after-read subscribe and
    # the deferred load would leave a stale header AND a stale schedule
    # anchor. Subscribed-first, any such broadcast queues in the mailbox and
    # the handle_info reload picks it up right after mount.
    if connected?(socket) do
      ProjectsPubSub.subscribe(ProjectsPubSub.topic_tasks())
      ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(id))
    end

    case Projects.get_project_with_assignee(id) do
      nil ->
        {:ok,
         socket
         |> assign(default_assigns(session))
         |> put_flash(:error, gettext("Project not found."))
         |> WebHelpers.close_or_navigate(Paths.projects())}

      project ->
        socket =
          socket
          |> assign(default_assigns(session))
          |> assign(
            page_title: Project.localized_name(project, L10n.current_content_lang()),
            project: project,
            is_template: project.is_template
          )
          # The root topic is already subscribed (pre-read, above) — seed the
          # seen-set so `subscribe_tree` doesn't double-subscribe it (double
          # subscription = duplicate PubSub delivery).
          |> then(fn s ->
            if connected?(s), do: assign(s, subscribed_projects: MapSet.new([id])), else: s
          end)

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
      # The raw walk ({items, layout}) — the filtered events derive from it
      # in memory, so filter flips never re-query.
      calendar_items: {[], %{}},
      events: [],
      # `%{assignment_uuid => click target}` for event clicks — a leaf task
      # opens its assignment edit form, a sub-project drills into the child.
      click_targets: %{},
      # The month the grid INITIALLY opens on. Computed once on the first
      # load and then left alone: the calendar component's `date` prop is
      # initial-plus-controlled, so re-passing the same value on PubSub
      # reloads preserves the user's own month navigation.
      anchor_date: nil,
      # The whole-day popup (same pattern as the Overview calendar): nil when
      # closed, else %{date: Date, rows: [row]} filled by a day-cell / "+N
      # more" click. The dialog itself opens client-side (PkDialogTrigger).
      day_popup: nil,
      today: Date.utc_today(),
      # Per-project PubSub topics already subscribed (the whole rendered tree;
      # grows as sub-projects appear). Avoids double-subscribing on reload.
      subscribed_projects: MapSet.new(),
      # The calendar-display config (CalendarDisplay.read/0), read on every
      # load_calendar so it follows the settings page; pure defaults here so
      # no render can ever dot-access a nil config.
      overdue_anim: CalendarDisplay.defaults(),
      # True between the connected mount and the `:load_calendar` message —
      # drives the loading skeleton so the first paint isn't blocked on the
      # per-project queries (and doesn't flash the empty state).
      calendar_loading: false
    ] ++ AssigneeFilter.defaults()
  end

  # Deferred initial build (off the first paint — see mount).
  @impl true
  def handle_info(:load_calendar, socket), do: {:noreply, load_calendar(socket)}

  # The calendar component's callbacks arrive as process messages.
  def handle_info({:calendar_event_click, assignment_uuid}, socket) do
    {:noreply, navigate_to_target(socket, assignment_uuid)}
  end

  # A day cell or its "+N more" link was clicked — fill the whole-day popup
  # (the dialog already opened client-side in the same frame).
  def handle_info({:calendar_date_click, %Date{} = date}, socket) do
    {:noreply, open_day_popup(socket, date)}
  end

  def handle_info({:calendar_more_click, %Date{} = date}, socket) do
    {:noreply, open_day_popup(socket, date)}
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

  # ── Events (day popup) ──────────────────────────────────────────

  @impl true
  def handle_event("close_day_popup", _params, socket) do
    {:noreply, assign(socket, day_popup: nil)}
  end

  # A row inside the day popup — same targets as a chip click.
  def handle_event("day_popup_item_click", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    {:noreply, socket |> assign(day_popup: nil) |> navigate_to_target(uuid)}
  end

  # Every assignee/overdue-filter event routes through the shared glue; a
  # state change re-derives the filtered events, picker searches just reply.
  def handle_event(event, params, socket) when event in @assignee_filter_events do
    case AssigneeFilter.update(socket, event, params) do
      {socket, :reapply} -> {:noreply, apply_calendar_filter(socket)}
      {socket, :noop} -> {:noreply, socket}
    end
  end

  # A leaf task opens its assignment edit form; a sub-project drills into the
  # child project. Unknown id (stale render) is a no-op.
  defp navigate_to_target(socket, assignment_uuid) do
    case Map.get(socket.assigns.click_targets, assignment_uuid) do
      {:subproject, child_uuid} ->
        WebHelpers.navigate_or_open(socket,
          to: Paths.project(child_uuid),
          open: {PhoenixKitProjects.Web.ProjectShowLive, %{"id" => child_uuid}}
        )

      {:task, project_uuid} ->
        WebHelpers.navigate_or_open(socket,
          to: Paths.edit_assignment(project_uuid, assignment_uuid),
          open:
            {PhoenixKitProjects.Web.AssignmentFormLive,
             %{
               "live_action" => "edit",
               "project_id" => project_uuid,
               "id" => assignment_uuid
             }}
        )

      nil ->
        socket
    end
  end

  # The popup's rows for `date`: every event whose [start, end) span covers
  # it, soonest-starting first, with the status badge the chips can't show.
  defp open_day_popup(socket, date) do
    assign(socket, day_popup: %{date: date, rows: day_popup_rows(socket, date)})
  end

  defp day_popup_rows(socket, date) do
    socket.assigns.events
    |> CalendarDisplay.events_on(date)
    |> Enum.map(fn e ->
      extra = e.extra || %{}

      %{
        value: e.id,
        title: e.title,
        color: e.color,
        status: extra[:status],
        late: extra[:late] || false,
        # The provenance rider explains WHY a row appears in a
        # person-scoped view (team/department inheritance, not personal).
        subtitle:
          case extra[:via] do
            {_kind, name} -> gettext("via %{name}", name: name)
            _ -> nil
          end
      }
    end)
  end

  # ── Data loading ────────────────────────────────────────────────

  defp load_calendar(socket) do
    project = socket.assigns.project

    # Subscribe to the root project's topic BEFORE reading the tree, so a
    # broadcast that lands while the build runs can't be dropped on the floor.
    # `subscribe_tree/2` is idempotent, so the full-tree subscribe below skips
    # the root.
    socket = subscribe_tree(socket, [project.uuid])

    {items, layout} = ScheduleLayout.tree(project)

    # Only top-level assignments become bars: a sub-project's span already
    # covers its children's walk. Click targets stay UNFILTERED so a stale
    # render can't route a click wrong.
    top_items = Enum.filter(items, &is_nil(&1.parent_uuid))
    click_targets = Map.new(top_items, fn it -> {it.uuid, click_target(it.assignment)} end)

    # Live updates: a sub-project's tasks broadcast on the CHILD project's
    # topic, and their edits change the parent bar's span — subscribe to every
    # project in the rendered tree, same as the Timeline tab.
    project_uuids = items |> Enum.map(& &1.project.uuid) |> Enum.uniq()

    now = DateTime.utc_now() |> DateTime.to_naive()

    socket
    |> AssigneeFilter.resolve_me()
    |> subscribe_tree(project_uuids)
    |> assign(overdue_anim: CalendarDisplay.read())
    |> assign(
      calendar_items: {items, layout},
      click_targets: click_targets,
      today: Date.utc_today(),
      calendar_loading: false,
      # The person picker offers only people relevant to THIS project tree's
      # assignments (sub-projects included) — anyone else would only ever
      # filter this calendar to an empty month.
      assignee_search_scope: project_uuids,
      # "Nobody holds this" — a bar counts as unassigned only when its own
      # assignment AND (for a sub-project) every descendant is unassigned.
      unassigned_count:
        Enum.count(top_items, fn it ->
          Enum.all?(assignment_refs(it, items), &Assignees.unassigned?/1)
        end),
      # Late bars in the RAW tree — the Overdue-only toggle hides at 0.
      overdue_count:
        Enum.count(top_items, fn it ->
          CalendarDisplay.task_late?(it.assignment, Map.fetch!(layout, it.uuid), now)
        end)
    )
    |> apply_calendar_filter()
  end

  # Derives the visible events from the cached walk + the current filter.
  # In-memory only — filter flips never re-query. A sub-project bar matches a
  # person when ANY task in its subtree does (descendant-aware), and its
  # provenance labels the bar; direct-only needs a personal hit anywhere in
  # the subtree.
  defp apply_calendar_filter(socket) do
    %{calendar_items: {items, layout}} = socket.assigns
    lang = L10n.current_content_lang()
    scopes = AssigneeFilter.current_scopes(socket.assigns)
    include_unassigned? = socket.assigns.include_unassigned?
    direct_only? = socket.assigns.assignee_direct_only?
    now = DateTime.utc_now() |> DateTime.to_naive()

    late_class =
      CalendarDisplay.late_marker_class(socket.assigns[:overdue_anim] || CalendarDisplay.read())

    top_items = Enum.filter(items, &is_nil(&1.parent_uuid))

    events =
      top_items
      |> Enum.map(fn it -> {it, Map.fetch!(layout, it.uuid), assignment_refs(it, items)} end)
      |> Enum.flat_map(fn {it, span, refs} ->
        case bar_match(refs, scopes, include_unassigned?, direct_only?) do
          :drop ->
            []

          via ->
            late? = CalendarDisplay.task_late?(it.assignment, span, now)

            if socket.assigns.overdue_only? and not late? do
              []
            else
              [to_event(it, span.start, span.end, lang, late? && late_class, via)]
            end
        end
      end)

    socket = socket |> assign(events: events) |> put_initial_anchor(events)

    # An open whole-day popup caches its rows at open time; both a PubSub
    # reload (via load_calendar/1) and a filter toggle land here having just
    # rebuilt `events`, so refresh the popup too — otherwise it keeps showing
    # a task's stale status/lateness, or one no longer matching the filter.
    case socket.assigns[:day_popup] do
      %{date: date} ->
        assign(socket, day_popup: %{date: date, rows: day_popup_rows(socket, date)})

      nil ->
        socket
    end
  end

  # A bar's matchable assignments: its own, plus every descendant's for a
  # sub-project (parent chains walked over the flattened item list).
  defp assignment_refs(top_item, items) do
    children = Enum.group_by(items, & &1.parent_uuid)

    collect = fn collect, uuid ->
      Enum.flat_map(Map.get(children, uuid, []), fn child ->
        [child.assignment | collect.(collect, child.uuid)]
      end)
    end

    [top_item.assignment | collect.(collect, top_item.uuid)]
  end

  # :drop | nil (kept, no provenance) | :direct | {:team|:department, name}
  defp bar_match(refs, [], false, _direct), do: if(refs, do: nil)

  defp bar_match(refs, scopes, include_unassigned?, direct_only?) do
    if include_unassigned? and Enum.all?(refs, &Assignees.unassigned?/1) do
      nil
    else
      refs
      |> Enum.map(&AssigneeFilter.match_any(&1, scopes))
      |> Enum.reduce(:drop, fn
        :direct, _acc -> :direct
        _any, :direct -> :direct
        nil, acc -> acc
        via, :drop -> via
        _via, acc -> acc
      end)
      |> case do
        :drop -> :drop
        :direct -> :direct
        via when direct_only? and not is_nil(via) -> :drop
        via -> via
      end
    end
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
  # exclusive (`[start, end)`). Late bars get the shared red inset ring;
  # `via` carries the filter provenance for the day popup.
  # `late_or_class` is falsy for an on-time bar, else the marker class to
  # apply (ring or pk-overdue, per the settings).
  defp to_event(it, %NaiveDateTime{} = s, %NaiveDateTime{} = e, lang, late_or_class, via) do
    a = it.assignment
    start_d = NaiveDateTime.to_date(s)
    # UTC frame (nil offset) — Timeline-tab parity, unlike the Overview's
    # viewer-local dates.
    end_d = CalendarDisplay.exclusive_end_date(start_d, e)

    PhoenixLiveCalendar.event(a.uuid, start_d,
      title: Assignment.label(a, lang) || gettext("(untitled task)"),
      end: end_d,
      all_day: true,
      color: status_color(a.status),
      class: if(late_or_class, do: late_or_class),
      extra: %{status: a.status, late: !!late_or_class, via: via}
    )
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
        <%= if elem(@calendar_items, 0) == [] do %>
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
          <%!-- PkDialogTrigger makes a day-cell / "+N more" click open the
               whole-day popup in the same frame; event chips have their own
               phx-click and correctly don't match — they navigate instead. --%>
          <%!-- No overflow clip here: the toolbar's tooltip bubbles (the
               Filters button in toolbar_start) must escape the calendar's
               top edge; the calendar clips its own grid. --%>
          <div
            id={"project-calendar-day-trigger-#{@project.uuid}"}
            phx-hook="PkDialogTrigger"
            data-dialog={"project-day-modal-#{@project.uuid}"}
            data-trigger=".cal-day-cell, .cal-more-link"
            class="border border-base-200 rounded-lg"
          >
            <%!-- In-flight pulse for the lib-rendered clickables (chips/bars/
                 cells/more-links) — their classes aren't ours to extend. --%>
            {Phoenix.HTML.raw(CalendarDisplay.loading_style())}
            <%!-- The overdue/late-marker <style> + stripe alignment, for when
                 the late marker is set to the pattern. Inert with the ring.
                 (@overdue_anim is always set once load_calendar has run, and
                 this branch only renders after it has.) --%>
            {Phoenix.HTML.raw(
              if(@overdue_anim, do: CalendarDisplay.animation_style(@overdue_anim), else: "")
            )}
            <div id={"project-calendar-sync-#{@project.uuid}"} phx-hook="SyncAnimations">
            <.live_component
              module={PhoenixLiveCalendar.CalendarComponent}
              id={"project-calendar-#{@project.uuid}"}
              events={@events}
              views={[:month]}
              date={@anchor_date}
              today={@today}
              week_start={@overdue_anim.week_start}
              show_weekends={@overdue_anim.show_weekends}
              show_week_numbers={@overdue_anim.show_week_numbers}
              fixed_weeks={@overdue_anim.fixed_weeks}
              expand_cells={true}
              max_events={@overdue_anim.max_events}
              max_multiday={@overdue_anim.max_multiday}
              info_label={gettext("About this calendar")}
              on_event_click={fn id -> send(self(), {:calendar_event_click, id}) end}
              on_date_select={fn date -> send(self(), {:calendar_date_click, date}) end}
              on_more_click={fn date -> send(self(), {:calendar_more_click, date}) end}
            >
              <%!-- Same shared Filters popup as the Overview calendar (person
                   chips with descendant-aware sub-project matching, Unassigned,
                   Personal/Overdue-only), riding the calendar's own toolbar
                   (lib 0.3.0 toolbar_start slot). Filtering can empty the
                   month — the panel stays reachable, its badge showing why.
                   picker_target routes the SearchPicker hook's events past the
                   enclosing CalendarComponent back to this LiveView. --%>
              <:toolbar_start>
                <.assignee_filter_panel
                  id={"project-cal-filter-#{@project.uuid}"}
                  assignee_selected={@assignee_selected}
                  include_unassigned?={@include_unassigned?}
                  unassigned_count={@unassigned_count}
                  assignee_direct_only?={@assignee_direct_only?}
                  overdue_only?={@overdue_only?}
                  overdue_count={@overdue_count}
                  me_scope={@me_scope}
                  picker_target={"#project-calendar-day-trigger-#{@project.uuid}"}
                />
              </:toolbar_start>
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
          </div>

          <.day_popup_modal
            id={"project-day-modal-#{@project.uuid}"}
            day_popup={@day_popup}
            row_click="day_popup_item_click"
          />
        <% end %>
      <% end %>
    </div>
    """
  end
end
