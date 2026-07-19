defmodule PhoenixKitProjects.Web.OverviewLive do
  @moduledoc "Projects module dashboard."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{
    Activity,
    Assignees,
    CalendarDisplay,
    L10n,
    Paths,
    Projects,
    ScheduleLayout
  }

  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Project, Task}
  alias PhoenixKitProjects.Web.AssigneeFilter
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  require Logger

  # How many "Running" projects to show on the dashboard. The count
  # badge on "View all →" reveals when the total exceeds this cap.
  @running_display_limit 10
  # Fallback "late" threshold (days since `started_at`) when a project
  # has no estimated durations — without sum-of-durations we can't
  # compute a real planned_end. Projects with durations use planned_end
  # directly (started_at + total estimated hours), per the same logic
  # the project show page uses.
  @late_fallback_days 14
  # Progress percentage (>=) for the "near done" tier on the dashboard.
  @near_done_threshold_pct 75

  # Default wrapper class for the standalone admin page. Embedders can
  # override via `live_render(... session: %{"wrapper_class" => "..."})`.
  # py-4/gap-4 (not 6): the client screens are short — tighter vertical
  # rhythm buys another two rows of real content.
  @default_wrapper_class "flex flex-col w-full px-4 py-4 gap-4"

  # The shared filter's events, forwarded to Web.AssigneeFilter.update/3.
  @assignee_filter_events AssigneeFilter.events()

  @impl true
  def mount(_params, session, socket) do
    WebHelpers.maybe_put_locale(session)

    if connected?(socket), do: ProjectsPubSub.subscribe(ProjectsPubSub.topic_all())

    wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)

    # Load on both the disconnected HTTP render AND the connected
    # WebSocket mount so the first paint already has real content (no
    # empty-skeleton pop-in). The skeleton assigns below stay as defensive
    # defaults — `reload/1` overwrites them on the same socket — but the
    # render path never actually sees them. `handle_params/3` is
    # intentionally absent: Phoenix LV refuses to mount a LV exporting it
    # outside a router live route, which would block embedding via
    # `live_render`. See dev_docs/embedding_audit.md.
    socket =
      socket
      |> assign(
        user_uuid: Activity.actor_uuid(socket),
        # Per-instance DOM-id suffix: this LV is embeddable, and its calendar
        # chrome is wired by CSS-selector JS (PkDialogTrigger's data-dialog,
        # the SearchPicker's picker_target). Static ids would cross-route two
        # embeds on one host page to the first match. socket.id is stable
        # across the dead render and the join, so ids match on hydration.
        sfx: socket.id,
        page_title: gettext("Projects"),
        wrapper_class: wrapper_class,
        task_count: 0,
        project_count: 0,
        template_count: 0,
        active_count: 0,
        active_summaries: [],
        running_display_limit: @running_display_limit,
        completed_projects: [],
        upcoming_projects: [],
        setup_projects: [],
        any_projects?: false,
        my_assignments: [],
        status_counts: %{},
        today: Date.utc_today(),
        tz_offset: "0",
        calendar_events: [],
        # The calendar-display config (CalendarDisplay.read/0) — reload/1
        # refreshes it; pure defaults here so no render can ever dot-access
        # a nil config.
        overdue_anim: CalendarDisplay.defaults(),
        # Projects-mode "Late only" filter: the raw event list is cached and
        # the visible `calendar_events` derive from it in memory (same shape
        # as the Tasks-mode filters — a toggle never re-queries).
        all_project_events: [],
        late_project_uuids: MapSet.new(),
        projects_late_only?: false,
        # Which VIEW of the running projects is shown: :list (vertical list,
        # default) or :calendar (the month view), toggled by tabs. The calendar is
        # lazy-mounted on first switch, then kept (hidden) so its paged month
        # survives toggling.
        overview_tab: :list,
        calendar_seen?: false,
        # Calendar mode: :tasks (default — every task across all projects, on
        # the days it's scheduled) or :projects (the original one-bar-per-project
        # view). Both stay mounted once seen; the toggle hides with CSS so each
        # grid keeps its own month navigation.
        calendar_mode: :tasks,
        # Tasks-mode data — computed lazily on the first calendar open (the
        # schedule walk is per-project queries), then kept fresh by reload/1.
        # `task_calendar_items` caches the raw {item, span} walk; the filtered
        # events/meta derive from it in memory, so filter flips never re-query.
        task_calendar_items: [],
        task_calendar_events: [],
        task_calendar_meta: %{},
        task_calendar_loaded?: false,
        # Assignee/overdue filter state comes from Web.AssigneeFilter.defaults()
        # (piped in below) — the shared chip-rail glue both calendars use.
        # The whole-day popup (Google-style): nil when closed, else
        # %{date: Date, rows: [row]} filled by a day-cell / "+N more" click.
        day_popup: nil
      )
      |> assign(AssigneeFilter.defaults())
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
      |> WebHelpers.attach_open_embed_hook()

    {:ok, reload(socket)}
  end

  defp reload(socket) do
    user_uuid = socket.assigns[:user_uuid]
    active_projects = Projects.list_active_projects()
    completed_projects = Projects.list_recently_completed_projects()
    upcoming_projects = Projects.list_upcoming_projects()
    setup_projects = Projects.list_setup_projects()

    any_projects? =
      active_projects != [] or completed_projects != [] or upcoming_projects != [] or
        setup_projects != []

    # One `now` (UTC instant — "has the deadline passed" is timezone-independent)
    # and one `today` (the viewer's local calendar day — for every day/date
    # display). Computing both once keeps the whole Overview internally
    # consistent.
    now = DateTime.utc_now()
    offset = resolve_offset(socket)
    today = to_local_date(now, offset)

    # Compute every active project's tree summary once and tag its lifecycle
    # tier (with that single `now`), so the Running cards, the sort order, and
    # the calendar's late-blink all agree on which projects are late. The
    # capped/sorted slice feeds the cards; the full list feeds the calendar.
    all_summaries =
      active_projects
      |> Enum.map(&Projects.project_tree_summary/1)
      |> Enum.map(fn s ->
        tier = running_tier(s, now)
        s |> Map.put(:tier, tier) |> Map.put(:late, tier == :late)
      end)

    {top_summaries, total_active} = prioritize_running(all_summaries, today, now)

    # Read + assign the animation/marker config BEFORE the Tasks-mode build
    # below — apply_task_filter derives the late-marker class from it.
    overdue_anim = CalendarDisplay.read()
    socket = assign(socket, overdue_anim: overdue_anim)

    calendar_events =
      CalendarDisplay.events(
        all_summaries,
        completed_projects,
        upcoming_projects,
        L10n.current_content_lang(),
        today,
        offset,
        late_marker: overdue_anim.late_marker
      )

    # Tasks-mode events are only worth their per-project schedule walks once
    # the calendar tab has been opened; until then reload keeps the empty
    # defaults and the tab-switch handler does the first build.
    socket =
      if socket.assigns[:calendar_seen?],
        do:
          load_task_calendar(
            socket,
            active_projects,
            upcoming_projects,
            completed_projects,
            offset
          ),
        else: socket

    socket =
      assign(socket,
        task_count: Projects.count_tasks(),
        project_count: Projects.count_projects(),
        template_count: Projects.count_templates(),
        active_count: total_active,
        active_summaries: top_summaries,
        completed_projects: completed_projects,
        upcoming_projects: upcoming_projects,
        setup_projects: setup_projects,
        any_projects?: any_projects?,
        my_assignments:
          if(user_uuid, do: Projects.list_assignments_for_user(user_uuid), else: []),
        status_counts: Projects.assignment_status_counts(),
        today: today,
        tz_offset: offset,
        all_project_events: calendar_events,
        late_project_uuids:
          all_summaries
          |> Enum.filter(& &1.late)
          |> MapSet.new(& &1.project.uuid),
        # The overdue-animation <style>, generated from the settings on
        # /admin/settings/projects (mode/speed/brightness), plus the pattern so
        # the calendar's info popover can describe it accurately. Read once here
        # so a page (re)load reflects the latest config.
        overdue_style: CalendarDisplay.animation_style(overdue_anim),
        overdue_pattern: overdue_anim.pattern
      )

    # Derive the visible Projects-mode events BEFORE the popup refresh below —
    # its rows read `calendar_events`.
    socket = apply_projects_filter(socket)

    # An open whole-day popup caches its rows at open time; a broadcast-driven
    # reload just rebuilt the events/meta those rows come from, so refresh it
    # too — otherwise the popup keeps showing a task's stale status/lateness
    # (or one that was deleted/reassigned) until the viewer closes and reopens it.
    case socket.assigns[:day_popup] do
      %{date: date} -> assign(socket, day_popup: %{date: date, rows: day_rows(socket, date)})
      nil -> socket
    end
  end

  # Builds the Tasks-mode calendar: run the shared schedule walk per project
  # (same walk as the show page's Timeline/Calendar tabs), keep LEAF tasks
  # (sub-project containers excluded — their child tasks stand for
  # themselves), cache the raw {item, span} list, and derive the filtered
  # events/meta from it. Also resolves the picker options, the unassigned
  # count (over ALL items — it's a triage signal, not a filtered view), and
  # the viewer's own assignee scope (once per mount).
  defp load_task_calendar(socket, active, upcoming, completed, offset) do
    items_with_spans =
      (active ++ upcoming ++ completed)
      |> Enum.uniq_by(& &1.uuid)
      |> Enum.flat_map(fn project ->
        {items, layout} = ScheduleLayout.tree(project)

        items
        |> Enum.reject(&Assignment.subproject?(&1.assignment))
        |> Enum.map(&{&1, Map.fetch!(layout, &1.uuid)})
      end)

    now = DateTime.utc_now() |> DateTime.to_naive()

    socket
    |> AssigneeFilter.resolve_me()
    |> assign(
      task_calendar_items: items_with_spans,
      task_calendar_loaded?: true,
      tz_offset: offset,
      unassigned_count:
        Enum.count(items_with_spans, fn {it, _} -> Assignees.unassigned?(it.assignment) end),
      overdue_count:
        Enum.count(items_with_spans, fn {it, span} ->
          CalendarDisplay.task_late?(it.assignment, span, now)
        end)
    )
    |> apply_task_filter()
  end

  # Projects mode: the visible bars from the cached raw list + the "Late
  # only" flag. Late = the tier the Running cards show (`summary.late`), so
  # the calendar and the cards can't disagree; completed/scheduled markers
  # are never late, so the lens drops them too.
  defp apply_projects_filter(socket) do
    %{
      all_project_events: all,
      late_project_uuids: late,
      projects_late_only?: late_only?
    } = socket.assigns

    events = if late_only?, do: Enum.filter(all, &MapSet.member?(late, &1.id)), else: all
    assign(socket, calendar_events: events)
  end

  # Derives the visible events/meta from the cached walk + the current
  # assignee/overdue filter. In-memory only — filter flips never re-query.
  defp apply_task_filter(socket) do
    %{
      task_calendar_items: items,
      include_unassigned?: include_unassigned?,
      assignee_direct_only?: direct_only?,
      overdue_only?: overdue_only?,
      tz_offset: offset
    } = socket.assigns

    scopes = AssigneeFilter.current_scopes(socket.assigns)
    now = DateTime.utc_now() |> DateTime.to_naive()

    {kept, provenance} = filter_items(items, scopes, include_unassigned?, direct_only?)

    late_class =
      CalendarDisplay.late_marker_class(socket.assigns[:overdue_anim] || CalendarDisplay.read())

    {events, meta} =
      CalendarDisplay.task_events(kept, L10n.current_content_lang(), offset,
        now: now,
        late_class: late_class
      )

    # Provenance ("via <team>") rides the meta so popup rows can show WHY a
    # task is in a person's view without implying personal ownership.
    meta =
      Map.new(meta, fn {uuid, entry} ->
        {uuid, Map.put(entry, :via, Map.get(provenance, uuid))}
      end)

    {events, meta} =
      if overdue_only? do
        late = events |> Enum.filter(&meta[&1.id].late) |> MapSet.new(& &1.id)
        {Enum.filter(events, &MapSet.member?(late, &1.id)), meta}
      else
        {events, meta}
      end

    assign(socket, task_calendar_events: events, task_calendar_meta: meta)
  end

  # Applies the unified assignee filter to the raw items: a task is kept when
  # it's unassigned (and the Unassigned toggle is on) OR any selected person's
  # scope matches it — one UNION across chips + toggle. No chips and no
  # toggle = everything. Person matches return the provenance map (uuid =>
  # :direct | {:team, name} | {:department, name}) alongside; direct-only
  # narrows PERSON matches to :direct (it never affects the Unassigned part).
  defp filter_items(items, [], false, _direct), do: {items, %{}}

  defp filter_items(items, scopes, include_unassigned?, direct_only?) do
    Enum.reduce(items, {[], %{}}, fn {it, span}, {kept, prov} ->
      if include_unassigned? and Assignees.unassigned?(it.assignment) do
        {[{it, span} | kept], prov}
      else
        case AssigneeFilter.match_any(it.assignment, scopes) do
          nil -> {kept, prov}
          :direct -> {[{it, span} | kept], prov}
          _via when direct_only? -> {kept, prov}
          via -> {[{it, span} | kept], Map.put(prov, it.uuid, via)}
        end
      end
    end)
    |> then(fn {kept, prov} -> {Enum.reverse(kept), prov} end)
  end

  # First-open build (reload/1 skips the walk until the tab has been seen).
  defp ensure_task_calendar(%{assigns: %{task_calendar_loaded?: true}} = socket), do: socket

  defp ensure_task_calendar(socket) do
    load_task_calendar(
      socket,
      Projects.list_active_projects(),
      Projects.list_upcoming_projects(),
      Projects.list_recently_completed_projects(),
      resolve_offset(socket)
    )
  end

  # The viewer's timezone offset. Precedence matches the rest of PhoenixKit
  # (`Utils.Date.get_user_timezone/1`): the current user's own `user_timezone`,
  # else the website's `time_zone` setting, else UTC ("0").
  defp resolve_offset(socket) do
    # Match the field, not just a map: a partial user (a test scope, a
    # degraded embed) without :user_timezone falls through to the site
    # setting instead of KeyError-ing inside get_user_timezone/1.
    case socket.assigns[:phoenix_kit_current_user] do
      %{user_timezone: _} = user -> PhoenixKit.Utils.Date.get_user_timezone(user)
      _ -> PhoenixKit.Settings.get_setting("time_zone", "0")
    end
  rescue
    # DB-read resilience only — a genuine programming error should surface,
    # not silently pin every viewer to UTC.
    e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      Logger.debug("[OverviewLive] timezone read failed: #{Exception.message(e)}")
      "0"
  end

  # A stored UTC datetime as a calendar Date in the viewer's timezone, so every
  # day/date display on the Overview shares the same (local) basis as `today`.
  # The module otherwise works in UTC, but day boundaries are where a viewer
  # notices the difference — at 00:30 in UTC+3 it's already tomorrow locally.
  defp to_local_date(%DateTime{} = dt, offset) do
    dt |> PhoenixKit.Utils.Date.shift_to_offset(offset) |> DateTime.to_date()
  end

  # The Tasks/Projects mode toggle, rendered into BOTH calendar grids'
  # toolbar_end slots (each grid shows its own copy; only one grid is visible
  # at a time). tooltip-left on the edge button so it doesn't clip.
  defp mode_toggle(assigns) do
    ~H"""
    <%!-- Boxed segmented control (same look as the List/Calendar nav_tabs) so
         the DATA-mode choice reads differently from the lib's Month/Agenda
         VIEW switcher sitting beside it — as plain buttons the two groups
         blended into one row of pills. --%>
    <div class="tabs tabs-boxed bg-base-200 p-0.5" role="group" aria-label={gettext("Calendar mode")}>
      <button
        type="button"
        class={[
          "tab tooltip",
          CalendarDisplay.loading_class(),
          @calendar_mode == :tasks && "tab-active"
        ]}
        data-tip={gettext("Every task on the days it is scheduled to run")}
        aria-pressed={to_string(@calendar_mode == :tasks)}
        phx-click="set_calendar_mode"
        phx-value-mode="tasks"
      >
        {gettext("Tasks")}
      </button>
      <button
        type="button"
        class={[
          "tab tooltip tooltip-left",
          CalendarDisplay.loading_class(),
          @calendar_mode == :projects && "tab-active"
        ]}
        data-tip={gettext("One line per project, with the overdue marker")}
        aria-pressed={to_string(@calendar_mode == :projects)}
        phx-click="set_calendar_mode"
        phx-value-mode="projects"
      >
        {gettext("Projects")}
      </button>
    </div>
    """
  end

  # The calendar info-popover sentence describing the overdue indicator, worded
  # to match the configured marker + pattern (set on /admin/settings/projects).
  defp overdue_legend("ring") do
    gettext(
      "A project running past its planned end wears a red ring — the same marker late tasks get."
    )
  end

  defp overdue_legend("none") do
    gettext(
      "Late projects are not visually marked (changeable in the project settings); the cards and the Late-only lens still know them."
    )
  end

  defp overdue_legend("solid") do
    gettext(
      "When a project runs past its planned end, that overdue stretch is filled with the inverse of its colour — the longer it is, the more overdue the project."
    )
  end

  defp overdue_legend(_stripes) do
    gettext(
      "When a project runs past its planned end, that overdue stretch is marked with diagonal stripes — the longer the striped part, the more overdue the project."
    )
  end

  # Sorts running-project summaries into four importance tiers and
  # caps to @running_display_limit. Returns {capped_list, total_count}.
  #
  # Tier 0 ("late"):    started ≥ @late_threshold_days ago AND progress < 100.
  #                     Within tier, oldest-started first (most stalled).
  # Tier 1 ("near done"): progress ≥ @near_done_threshold_pct, not Tier 0.
  #                     Within tier, highest progress first.
  # Tier 2 ("rest"):    has tasks, not late, not near-done. Most-recently-started first.
  # Tier 3 ("empty"):   total == 0 tasks. Sinks to the bottom regardless of age —
  #                     these projects can't show meaningful progress and would
  #                     otherwise outrank real work via the recency sort.
  defp prioritize_running(summaries, today, now) do
    sorted =
      summaries
      |> Enum.map(&{running_sort_key(&1, today, now), &1})
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn {_, s} -> s end)

    {Enum.take(sorted, @running_display_limit), length(summaries)}
  end

  # Template-facing tier label for a summary row. Late = past
  # `planned_end` (sum of estimated durations from started_at) with
  # progress < 100. When a project has no durations we fall back to
  # the 14-day age heuristic since there's no real budget to compare
  # against.
  defp running_tier(summary, now) do
    %{project: project, progress_pct: pct, total: total, planned_end: planned_end} = summary

    cond do
      total == 0 ->
        :empty

      late?(planned_end, project, now, pct) ->
        :late

      pct >= @near_done_threshold_pct ->
        :near_done

      true ->
        :on_track
    end
  end

  defp late?(_planned_end, _project, _now, pct) when pct >= 100, do: false

  defp late?(%DateTime{} = planned_end, _project, now, _pct),
    do: DateTime.compare(now, planned_end) == :gt

  defp late?(nil, %{started_at: %DateTime{} = started_at}, now, _pct),
    do: DateTime.diff(now, started_at, :second) / 86_400 >= @late_fallback_days

  defp late?(_, _, _, _), do: false

  defp running_sort_key(summary, today, now) do
    %{project: project, progress_pct: pct, total: total, tier: tier} = summary

    days_running =
      case project.started_at do
        %DateTime{} = dt -> Date.diff(today, DateTime.to_date(dt))
        _ -> 0
      end

    case tier do
      :late ->
        # Tier 0: most overdue first. Use seconds-past-planned_end when
        # available, else fall back to age. Negated for ascending sort.
        overdue_seconds = overdue_seconds(summary, now)
        {0, -overdue_seconds, project.uuid}

      :near_done ->
        # Tier 1: highest progress first.
        {1, -pct, project.uuid}

      :on_track ->
        # Tier 2: most-recently-started first.
        {2, days_running, project.uuid}

      :empty ->
        # Tier 3: empty projects sink to the bottom.
        _ = total
        {3, days_running, project.uuid}
    end
  end

  defp overdue_seconds(%{planned_end: %DateTime{} = planned_end}, now) do
    DateTime.diff(now, planned_end, :second)
  end

  defp overdue_seconds(%{project: %{started_at: %DateTime{} = started_at}}, now) do
    DateTime.diff(now, started_at, :second)
  end

  defp overdue_seconds(_, _now), do: 0

  # Running card tabs. The calendar is lazy-mounted on first open (then kept
  # hidden when inactive, so its paged month survives toggling back and forth);
  # the first open also builds the Tasks-mode events (per-project walks that
  # reload/1 skips until the tab has been seen).
  @impl true
  def handle_event("switch_overview_tab", %{"tab" => "calendar"}, socket) do
    {:noreply,
     socket
     |> assign(overview_tab: :calendar, calendar_seen?: true)
     |> ensure_task_calendar()}
  end

  def handle_event("switch_overview_tab", _params, socket) do
    {:noreply, assign(socket, overview_tab: :list)}
  end

  # Calendar mode toggle: :tasks (default) | :projects. Hardcoded map — never
  # String.to_existing_atom on a client param.
  def handle_event("set_calendar_mode", %{"mode" => mode}, socket) do
    case %{"tasks" => :tasks, "projects" => :projects} do
      %{^mode => new_mode} -> {:noreply, assign(socket, calendar_mode: new_mode)}
      _ -> {:noreply, socket}
    end
  end

  # Projects-mode "Late only" lens — in-memory re-derivation, no re-query.
  def handle_event("toggle_projects_late_only", _params, socket) do
    {:noreply,
     socket
     |> assign(projects_late_only?: not socket.assigns.projects_late_only?)
     |> apply_projects_filter()}
  end

  # Every assignee/overdue-filter event routes through the shared glue; a
  # state change re-derives the filtered events, picker searches just reply.
  def handle_event(event, params, socket) when event in @assignee_filter_events do
    case AssigneeFilter.update(socket, event, params) do
      {socket, :reapply} -> {:noreply, apply_task_filter(socket)}
      {socket, :noop} -> {:noreply, socket}
    end
  end

  # Close the whole-day popup (the PkDialog hook mirrors ESC/backdrop/✕ back
  # to this event so the server flag stays in sync).
  def handle_event("close_day_popup", _params, socket) do
    {:noreply, assign(socket, day_popup: nil)}
  end

  # A row inside the day popup — open the owning project.
  def handle_event("day_popup_open_project", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    {:noreply,
     socket
     |> assign(day_popup: nil)
     |> WebHelpers.navigate_or_open(
       to: Paths.project(uuid),
       open: {PhoenixKitProjects.Web.ProjectShowLive, %{"id" => uuid}}
     )}
  end

  @impl true
  def handle_info({:projects, _event, _payload}, socket) do
    {:noreply, reload(socket)}
  end

  # A project bar on the calendar was clicked — open that project (navigate in
  # standalone, emit an :opened intent when embedded).
  def handle_info({:calendar_open_project, uuid}, socket) when is_binary(uuid) do
    {:noreply,
     WebHelpers.navigate_or_open(socket,
       to: Paths.project(uuid),
       open: {PhoenixKitProjects.Web.ProjectShowLive, %{"id" => uuid}}
     )}
  end

  # A task chip on the Tasks-mode calendar was clicked — open its OWNING
  # project (a child task inside a sub-project opens the sub-project). The
  # meta map is server-built; an unknown id (stale render) is a no-op.
  def handle_info({:calendar_open_task, uuid}, socket) when is_binary(uuid) do
    case Map.get(socket.assigns.task_calendar_meta, uuid) do
      %{project_uuid: project_uuid} ->
        {:noreply,
         WebHelpers.navigate_or_open(socket,
           to: Paths.project(project_uuid),
           open: {PhoenixKitProjects.Web.ProjectShowLive, %{"id" => project_uuid}}
         )}

      _ ->
        {:noreply, socket}
    end
  end

  # A day cell or its "+N more" link was clicked — fill the whole-day popup.
  # (The PkDialogTrigger hook already opened the dialog client-side in the
  # same frame; these assigns replace its skeleton with the day's rows.)
  def handle_info({:calendar_day_click, %Date{} = date}, socket) do
    {:noreply, open_day_popup(socket, date)}
  end

  def handle_info({:calendar_day_more, %Date{} = date}, socket) do
    {:noreply, open_day_popup(socket, date)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[OverviewLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ── Whole-day popup ─────────────────────────────────────────────

  defp open_day_popup(socket, date) do
    assign(socket, day_popup: %{date: date, rows: day_rows(socket, date)})
  end

  # The popup's rows for `date`, from the CURRENT mode's already-built event
  # list: Tasks mode enriches each event with its meta (project name/status);
  # Projects mode lists that day's project bars with their date span.
  defp day_rows(%{assigns: %{calendar_mode: :tasks}} = socket, date) do
    meta = socket.assigns.task_calendar_meta

    socket.assigns.task_calendar_events
    |> CalendarDisplay.events_on(date)
    |> Enum.map(fn e ->
      m = Map.get(meta, e.id, %{})

      %{
        value: m[:project_uuid],
        title: e.title,
        color: e.color,
        subtitle: row_subtitle(m),
        status: m[:status],
        late: m[:late] || false
      }
    end)
  end

  defp day_rows(socket, date) do
    late = socket.assigns.late_project_uuids

    socket.assigns.calendar_events
    |> CalendarDisplay.events_on(date)
    |> Enum.map(fn e ->
      %{
        value: e.id,
        title: e.title,
        color: e.color,
        subtitle: project_span_label(e),
        status: nil,
        # Same tier the cards/lens/marker use — the popup row of a late
        # project carries the late badge too.
        late: MapSet.member?(late, e.id)
      }
    end)
  end

  # "Project · via Team" — the provenance rider explains WHY a task appears
  # in a person-scoped view (it may be a team/department assignment, not a
  # personal one).
  defp row_subtitle(m) do
    case m[:via] do
      {_kind, name} -> "#{m[:project_name]} · #{gettext("via %{name}", name: name)}"
      _ -> m[:project_name]
    end
  end

  # "May 3 – Jul 16, 2026" (single-day bars collapse to one date). `end` is
  # exclusive, so the shown last day is end - 1.
  defp project_span_label(e) do
    last = Date.add(e.end, -1)

    if Date.compare(e.start, last) == :eq,
      do: L10n.format_date(e.start),
      else: "#{L10n.format_date(e.start)} – #{L10n.format_date(last)}"
  end

  # Accepts either a `Date` or a `DateTime` — `scheduled_start_date`
  # was retyped to `:utc_datetime` in V112; this helper preserves the
  # daily-cadence comparison by collapsing datetimes to their date
  # portion.
  defp days_until(%DateTime{} = dt, today, offset),
    do: days_until(to_local_date(dt, offset), today, offset)

  defp days_until(%Date{} = date, today, _offset), do: Date.diff(date, today)

  defp relative_day(days) do
    cond do
      days == 0 -> gettext("today")
      days == 1 -> gettext("tomorrow")
      days == -1 -> gettext("yesterday")
      days > 1 and days < 14 -> ngettext("in %{count} day", "in %{count} days", days)
      days > 1 -> gettext("in %{n} weeks", n: Float.round(days / 7, 1))
      days < 0 and days > -14 -> ngettext("%{count} day ago", "%{count} days ago", abs(days))
      true -> gettext("%{n} weeks ago", n: Float.round(abs(days) / 7, 1))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <%!-- No page header: the client screens are short, the sidebar already
           says where you are, and creation lives on the list pages + the
           empty-state CTAs — the dashboard starts with the data. The stat
           tiles moved into the bottom row for the same reason. --%>
      <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <%!-- Left: Active projects (span 2) --%>
        <div class="lg:col-span-2 card bg-base-100 shadow">
          <%!-- Tighter body padding on phones so the 7-column calendar isn't squeezed. --%>
          <div class="card-body max-sm:p-3">
            <div class="flex items-start justify-between gap-3">
              <div>
                <h2 class="card-title text-lg">
                  <.icon name="hero-play" class="w-5 h-5 text-success" /> {gettext("Running")}
                </h2>
                <p class="text-xs text-base-content/50 mt-0.5">
                  {gettext("Started and not yet completed.")}
                </p>
              </div>
              <.smart_link
                navigate={Paths.projects()}
                emit={{PhoenixKitProjects.Web.ProjectsLive, %{}}}
                embed_mode={@embed_mode}
                class="link link-hover text-sm shrink-0 mt-1"
              >
                <%= if @active_count > @running_display_limit do %>
                  {gettext("View all (%{count}) →", count: @active_count)}
                <% else %>
                  {gettext("View all →")}
                <% end %>
              </.smart_link>
            </div>

            <%!-- Same running projects, two views to choose from: a vertical list
                 (default) and the month calendar. --%>
            <.nav_tabs
              active_tab={to_string(@overview_tab)}
              on_change="switch_overview_tab"
              tabs={[
                %{id: "list", label: gettext("List"), icon: "hero-list-bullet"},
                %{id: "calendar", label: gettext("Calendar"), icon: "hero-calendar-days"}
              ]}
              class="mt-3"
            />

            <%!-- List view --%>
            <div class={["mt-2", if(@overview_tab != :list, do: "hidden")]}>
              <%= if @active_summaries == [] do %>
              <%= if @any_projects? do %>
                <.empty_state
                  icon="hero-clipboard-document-list"
                  title={gettext("Nothing running right now.")}
                  description={gettext("Open a project and click Start to begin.")}
                  class="py-10"
                >
                  <:cta>
                    <.smart_link
                      navigate={Paths.projects()}
                      emit={{PhoenixKitProjects.Web.ProjectsLive, %{}}}
                      embed_mode={@embed_mode}
                      class="btn btn-ghost btn-xs"
                    >
                      <.icon name="hero-clipboard-document-list" class="w-3.5 h-3.5" /> {gettext("View projects")}
                    </.smart_link>
                  </:cta>
                </.empty_state>
              <% else %>
                <.empty_state
                  icon="hero-clipboard-document-list"
                  title={gettext("No projects yet.")}
                  description={gettext("Create one to get started.")}
                  class="py-10"
                >
                  <:cta>
                    <.smart_link
                      navigate={Paths.new_project()}
                      emit={{PhoenixKitProjects.Web.ProjectFormLive, %{"live_action" => "new"}}}
                      embed_mode={@embed_mode}
                      class="btn btn-primary btn-xs"
                    >
                      <.icon name="hero-plus" class="w-3.5 h-3.5" /> {gettext("New project")}
                    </.smart_link>
                  </:cta>
                </.empty_state>
              <% end %>
            <% else %>
              <div class="flex flex-col gap-2 mt-2">
                <.running_card
                  :for={s <- @active_summaries}
                  node={s}
                  tier={s.tier}
                  embed_mode={@embed_mode}
                  lang={L10n.current_content_lang()}
                />
              </div>
            <% end %>
            </div>

            <%!-- Calendar tab. Lazy-mounted on first open, then kept (hidden when
                 inactive) so month + animation state survive toggling. Two modes,
                 both kept mounted once seen (CSS-hidden, so each grid keeps its
                 own month navigation): Tasks (default — every task across all
                 projects, capped per day with a Google-style "+N more") and
                 Projects (the original one-bar-per-project view, with its overdue
                 <style> + SyncAnimations wrapper). The PkDialogTrigger wrapper
                 makes a day-cell or "+N more" click open the whole-day popup
                 INSTANTLY (client dispatch); the matching server event fills the
                 rows in. Event chips/bars have their own phx-click and correctly
                 don't match the trigger — they navigate instead. --%>
            <div class={["mt-2", if(@overview_tab != :calendar, do: "hidden")]}>
              <%= if @calendar_seen? do %>
                <%!-- No header row at all: the Filters funnel lives in the
                     tasks-calendar's OWN toolbar (lib 0.3.0 toolbar_start slot)
                     and the Tasks/Projects mode toggle rides toolbar_end of
                     BOTH grids — the calendar chrome is the chrome. --%>
                <div
                  id={"overview-calendar-day-trigger-#{@sfx}"}
                  phx-hook="PkDialogTrigger"
                  data-dialog={"overview-day-modal-#{@sfx}"}
                  data-trigger=".cal-day-cell, .cal-more-link"
                >
                  <%!-- In-flight pulse for the LIB-rendered clickables (chips/
                       bars/cells/more-links) — their classes aren't ours to
                       extend, so a tiny static style covers them. --%>
                  {Phoenix.HTML.raw(CalendarDisplay.loading_style())}
                  <%!-- The overdue/late-marker <style> serves BOTH grids: the
                       Projects-mode overdue stretch always, and Tasks-mode
                       late chips when the marker is set to the pattern. The
                       SyncAnimations wrapper keeps stripes aligned + in phase
                       across cells. --%>
                  {Phoenix.HTML.raw(@overdue_style)}
                  <%!-- Tasks mode (default): capped day cells — at most 4 bars +
                       3 chips per day, the rest behind "+N more". --%>
                  <div
                    id={"overview-tasks-sync-#{@sfx}"}
                    phx-hook="SyncAnimations"
                    class={if(@calendar_mode != :tasks, do: "hidden")}
                  >
                    <.live_component
                      module={PhoenixLiveCalendar.CalendarComponent}
                      id={"overview-tasks-calendar-#{@sfx}"}
                      events={@task_calendar_events}
                      views={[:month, :agenda]}
                      date={@today}
                      today={@today}
                      week_start={@overdue_anim.week_start}
                      show_weekends={@overdue_anim.show_weekends}
                      show_week_numbers={@overdue_anim.show_week_numbers}
                      fixed_weeks={@overdue_anim.fixed_weeks}
                      expand_cells={true}
                      max_events={@overdue_anim.max_events}
                      max_multiday={@overdue_anim.max_multiday}
                      info_label={gettext("About this calendar")}
                      on_event_click={fn id -> send(self(), {:calendar_open_task, id}) end}
                      on_date_select={fn date -> send(self(), {:calendar_day_click, date}) end}
                      on_more_click={fn date -> send(self(), {:calendar_day_more, date}) end}
                    >
                      <%!-- No Filters funnel while there is no scheduled work
                           at all (fresh install / everything deleted) — with
                           zero raw items every filter yields the same empty
                           month. Keyed on the UNFILTERED walk, so a filter
                           that empties the month keeps the panel reachable. --%>
                      <:toolbar_start :if={@task_calendar_items != []}>
                        <.assignee_filter_panel
                          id={"overview-filter-#{@sfx}"}
                          assignee_selected={@assignee_selected}
                          include_unassigned?={@include_unassigned?}
                          unassigned_count={@unassigned_count}
                          assignee_direct_only?={@assignee_direct_only?}
                          overdue_only?={@overdue_only?}
                          overdue_count={@overdue_count}
                          me_scope={@me_scope}
                          picker_target={"#overview-calendar-day-trigger-#{@sfx}"}
                        />
                      </:toolbar_start>
                      <:toolbar_end>
                        {mode_toggle(%{calendar_mode: @calendar_mode})}
                      </:toolbar_end>
                      <:info>
                        <p class="mb-1 text-sm font-semibold text-base-content">
                          {gettext("Reading the calendar")}
                        </p>
                        <p>
                          {gettext("Every task from every project, shown on the days it is scheduled to run.")}
                        </p>
                        <p class="mt-1.5">
                          {gettext("Tasks share their project's color. Click a task to open its project.")}
                        </p>
                        <p class="mt-1.5">
                          <%= case @overdue_anim.late_marker do %>
                            <% "ring" -> %>
                              {gettext("A red ring marks a late task — not done, but past its scheduled days.")}
                            <% "none" -> %>
                              {gettext("Late tasks are not visually marked (changeable in the project settings); the Overdue-only filter and day popups still know them.")}
                            <% _ -> %>
                              {gettext("The overdue pattern marks a late task — not done, but past its scheduled days.")}
                          <% end %>
                        </p>
                        <p class="mt-1.5 text-base-content/50">
                          {gettext("Busy days cap the list — click the day or its +N more link to see everything scheduled that day.")}
                        </p>
                        <p class="mt-1.5 text-base-content/50">
                          {gettext("Placement is computed from each project's task order and durations — it moves as tasks are edited, reordered, or completed.")}
                        </p>
                      </:info>
                    </.live_component>
                  </div>

                  <%!-- Projects mode: the original ongoing-line view. --%>
                  <div class={if(@calendar_mode != :projects, do: "hidden")}>
                    <div id={"overview-calendar-sync-#{@sfx}"} phx-hook="SyncAnimations">
                      <.live_component
                        module={PhoenixLiveCalendar.CalendarComponent}
                        id={"projects-overview-calendar-#{@sfx}"}
                        events={@calendar_events}
                        views={[:month]}
                        date={@today}
                        today={@today}
                        week_start={@overdue_anim.week_start}
                        show_weekends={@overdue_anim.show_weekends}
                        show_week_numbers={@overdue_anim.show_week_numbers}
                        fixed_weeks={@overdue_anim.fixed_weeks}
                        expand_cells={true}
                        max_events={@overdue_anim.max_events}
                        max_multiday={@overdue_anim.max_multiday}
                        info_label={gettext("About this calendar")}
                        on_event_click={fn id -> send(self(), {:calendar_open_project, id}) end}
                        on_date_select={fn date -> send(self(), {:calendar_day_click, date}) end}
                        on_more_click={fn date -> send(self(), {:calendar_day_more, date}) end}
                      >
                        <%!-- "Late only" lens. Hidden while no project is late
                             (nothing to filter — fresh installs included) but
                             kept while ACTIVE even at 0, so the lens can
                             always be toggled back off. --%>
                        <:toolbar_start :if={MapSet.size(@late_project_uuids) > 0 or @projects_late_only?}>
                          <button
                            type="button"
                            class={[
                              "btn btn-xs gap-1.5 tooltip",
                              CalendarDisplay.loading_class(),
                              if(@projects_late_only?,
                                do: "btn-error",
                                else: "btn-ghost border-base-300"
                              )
                            ]}
                            data-tip={gettext("Only projects running past their planned end")}
                            aria-pressed={to_string(@projects_late_only?)}
                            phx-click="toggle_projects_late_only"
                          >
                            <.icon name="hero-exclamation-triangle" class="w-3.5 h-3.5" />
                            {gettext("Late only")}
                            <span class="badge badge-xs badge-ghost">
                              {MapSet.size(@late_project_uuids)}
                            </span>
                          </button>
                        </:toolbar_start>
                        <:toolbar_end>
                          {mode_toggle(%{calendar_mode: @calendar_mode})}
                        </:toolbar_end>
                        <:info>
                          <p class="mb-1 text-sm font-semibold text-base-content">
                            {gettext("Reading the calendar")}
                          </p>
                          <p>{gettext("Each project is an ongoing line across the month.")}</p>
                          <p class="mt-1.5">{overdue_legend(
                              if(@overdue_anim.late_marker in ["ring", "none"],
                                do: @overdue_anim.late_marker,
                                else: @overdue_pattern
                              )
                            )}</p>
                          <p class="mt-1.5 text-base-content/50">
                            {gettext("Late projects are grouped at the top.")}
                          </p>
                        </:info>
                      </.live_component>
                    </div>
                  </div>
                </div>

                <.day_popup_modal
                  id={"overview-day-modal-#{@sfx}"}
                  day_popup={@day_popup}
                  row_click="day_popup_open_project"
                />
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Right: My tasks + upcoming + recently completed --%>
        <div class="flex flex-col gap-4">
          <%!-- My assignments --%>
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-lg">
                <.icon name="hero-user" class="w-5 h-5" /> {gettext("My tasks")}
              </h2>

              <%= if @my_assignments == [] do %>
                <p class="text-sm text-base-content/50 py-2">
                  {gettext("Nothing assigned to you right now.")}
                </p>
              <% else %>
                <div class="flex flex-col gap-2 mt-2">
                  <.smart_link
                    :for={a <- Enum.take(@my_assignments, 6)}
                    navigate={Paths.project(a.project.uuid)}
                    emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => a.project.uuid}}}
                    embed_mode={@embed_mode}
                    class="flex items-start gap-2 p-2 rounded hover:bg-base-200 transition"
                  >
                    <.assignment_status_badge status={a.status} size="xs" class="mt-1" />
                    <div class="flex-1 min-w-0">
                      <div class="text-sm font-medium truncate">{Task.localized_title(a.task, L10n.current_content_lang())}</div>
                      <div class="text-xs text-base-content/60 truncate">{Project.localized_name(a.project, L10n.current_content_lang())}</div>
                    </div>
                  </.smart_link>

                  <%= if length(@my_assignments) > 6 do %>
                    <div class="text-xs text-base-content/50 text-center pt-1">
                      {gettext("+%{count} more", count: length(@my_assignments) - 6)}
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Recently completed --%>
          <%= if @completed_projects != [] do %>
            <div class="card bg-base-100 shadow">
              <div class="card-body">
                <h2 class="card-title text-lg">
                  <.icon name="hero-trophy" class="w-5 h-5 text-success" /> {gettext("Recently completed")}
                </h2>
                <div class="flex flex-col gap-1 mt-2">
                  <.smart_link
                    :for={p <- @completed_projects}
                    navigate={Paths.project(p.uuid)}
                    emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => p.uuid}}}
                    embed_mode={@embed_mode}
                    class="flex items-center gap-2 p-2 rounded hover:bg-base-200 transition"
                  >
                    <.icon name="hero-check-circle" class="w-4 h-4 text-success shrink-0" />
                    <div class="flex-1 min-w-0">
                      <div class="text-sm font-medium truncate">{Project.localized_name(p, L10n.current_content_lang())}</div>
                      <div class="text-xs text-base-content/60">
                        {relative_day(Date.diff(to_local_date(p.completed_at, @tz_offset), @today))}
                      </div>
                    </div>
                  </.smart_link>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Upcoming & Setup --%>
          <%= if @upcoming_projects != [] or @setup_projects != [] do %>
            <div class="card bg-base-100 shadow">
              <div class="card-body">
                <h2 class="card-title text-lg">
                  <.icon name="hero-calendar" class="w-5 h-5 text-info" /> {gettext("Upcoming")}
                </h2>

                <%= if @setup_projects != [] do %>
                  <div class="text-xs text-base-content/50 uppercase tracking-wide mt-2">{gettext("In setup")}</div>
                  <.smart_link
                    :for={p <- @setup_projects}
                    navigate={Paths.project(p.uuid)}
                    emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => p.uuid}}}
                    embed_mode={@embed_mode}
                    class="flex items-center gap-2 p-2 rounded hover:bg-base-200 transition"
                  >
                    <.icon name="hero-clock" class="w-4 h-4 text-warning shrink-0" />
                    <span class="text-sm font-medium truncate flex-1">{Project.localized_name(p, L10n.current_content_lang())}</span>
                  </.smart_link>
                <% end %>

                <%= if @upcoming_projects != [] do %>
                  <div class="text-xs text-base-content/50 uppercase tracking-wide mt-2">{gettext("Scheduled")}</div>
                  <.smart_link
                    :for={p <- @upcoming_projects}
                    navigate={Paths.project(p.uuid)}
                    emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => p.uuid}}}
                    embed_mode={@embed_mode}
                    class="flex items-center gap-2 p-2 rounded hover:bg-base-200 transition"
                  >
                    <.icon name="hero-calendar" class="w-4 h-4 text-info shrink-0" />
                    <div class="flex-1 min-w-0">
                      <div class="text-sm font-medium truncate">{Project.localized_name(p, L10n.current_content_lang())}</div>
                      <div class="text-xs text-base-content/60">
                        {L10n.format_datetime(p.scheduled_start_date)}
                        · {relative_day(days_until(p.scheduled_start_date, @today, @tz_offset))}
                      </div>
                    </div>
                  </.smart_link>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Bottom row: the three nav cards + the stat tiles, one compact
           strip under the content that matters (short client screens). --%>
      <div class="grid grid-cols-2 sm:grid-cols-4 lg:grid-cols-7 gap-3">
        <.smart_link
          navigate={Paths.projects()}
          emit={{PhoenixKitProjects.Web.ProjectsLive, %{}}}
          embed_mode={@embed_mode}
          class="card bg-base-100 shadow-sm hover:shadow-md transition border border-base-200"
        >
          <div class="card-body p-4">
            <div class="flex items-center gap-2 text-base-content/70">
              <.icon name="hero-clipboard-document-list" class="w-5 h-5" />
              <span class="text-sm font-medium">{gettext("Projects")}</span>
            </div>
            <div class="text-xl font-bold">{@project_count}</div>
          </div>
        </.smart_link>
        <.smart_link
          navigate={Paths.tasks()}
          emit={{PhoenixKitProjects.Web.TasksLive, %{}}}
          embed_mode={@embed_mode}
          class="card bg-base-100 shadow-sm hover:shadow-md transition border border-base-200"
        >
          <div class="card-body p-4">
            <div class="flex items-center gap-2 text-base-content/70">
              <.icon name="hero-rectangle-stack" class="w-5 h-5" />
              <span class="text-sm font-medium">{gettext("Task Library")}</span>
            </div>
            <div class="text-xl font-bold">{@task_count}</div>
          </div>
        </.smart_link>
        <.smart_link
          navigate={Paths.templates()}
          emit={{PhoenixKitProjects.Web.TemplatesLive, %{}}}
          embed_mode={@embed_mode}
          class="card bg-base-100 shadow-sm hover:shadow-md transition border border-base-200"
        >
          <div class="card-body p-4">
            <div class="flex items-center gap-2 text-base-content/70">
              <.icon name="hero-document-duplicate" class="w-5 h-5" />
              <span class="text-sm font-medium">{gettext("Templates")}</span>
            </div>
            <div class="text-xl font-bold">{@template_count}</div>
          </div>
        </.smart_link>
        <.stat_tile label={gettext("Running")} value={@active_count} />
        <.stat_tile
          label={gettext("Tasks in progress")}
          value={Map.get(@status_counts, "in_progress", 0)}
          value_class="text-warning"
        />
        <.stat_tile label={gettext("Tasks todo")} value={Map.get(@status_counts, "todo", 0)} />
        <.stat_tile
          label={gettext("Tasks done")}
          value={Map.get(@status_counts, "done", 0)}
          value_class="text-success"
        />
      </div>
    </div>
    """
  end
end
