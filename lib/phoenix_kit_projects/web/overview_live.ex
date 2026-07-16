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
  @default_wrapper_class "flex flex-col w-full px-4 py-6 gap-6"

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
        # Assignee filter over the Tasks mode: :everyone | :me | :unassigned |
        # :people (one or more picked via the core search_picker — chips in
        # `assignee_selected`, resolved scopes in `assignee_scopes`). Inherited
        # semantics by default (the person, their teams, their departments —
        # resolved by PhoenixKitProjects.Assignees); `assignee_direct_only?`
        # narrows to personal assignments. `me_scope` caches the viewer's own
        # resolution (:unresolved until the first calendar load; nil = no
        # staff person, which hides the Me shortcut).
        assignee_filter: :everyone,
        assignee_selected: [],
        assignee_scopes: %{},
        assignee_direct_only?: false,
        me_scope: :unresolved,
        unassigned_count: 0,
        # Show only late tasks (not done + scheduled span already ended).
        overdue_only?: false,
        # The whole-day popup (Google-style): nil when closed, else
        # %{date: Date, rows: [row]} filled by a day-cell / "+N more" click.
        day_popup: nil
      )
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

    overdue_anim = CalendarDisplay.read_animation()

    calendar_events =
      CalendarDisplay.events(
        all_summaries,
        completed_projects,
        upcoming_projects,
        L10n.current_content_lang(),
        today,
        offset
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
      my_assignments: if(user_uuid, do: Projects.list_assignments_for_user(user_uuid), else: []),
      status_counts: Projects.assignment_status_counts(),
      today: today,
      tz_offset: offset,
      calendar_events: calendar_events,
      # The overdue-animation <style>, generated from the settings on
      # /admin/settings/projects (mode/speed/brightness), plus the mode itself so
      # the calendar's info popover can describe it accurately. Read once here so a
      # page (re)load reflects the latest config.
      overdue_style: CalendarDisplay.animation_style(overdue_anim),
      overdue_mode: overdue_anim.mode,
      overdue_pattern: overdue_anim.pattern
    )
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

    me_scope =
      case socket.assigns.me_scope do
        :unresolved ->
          Assignees.scope_for_user(socket.assigns[:user_uuid], L10n.current_content_lang())

        resolved ->
          resolved
      end

    socket
    |> assign(
      task_calendar_items: items_with_spans,
      task_calendar_loaded?: true,
      tz_offset: offset,
      me_scope: me_scope,
      unassigned_count:
        Enum.count(items_with_spans, fn {it, _} -> Assignees.unassigned?(it.assignment) end)
    )
    |> apply_task_filter()
  end

  # Derives the visible events/meta from the cached walk + the current
  # assignee/overdue filter. In-memory only — filter flips never re-query.
  defp apply_task_filter(socket) do
    %{
      task_calendar_items: items,
      assignee_filter: filter,
      assignee_direct_only?: direct_only?,
      overdue_only?: overdue_only?,
      tz_offset: offset
    } = socket.assigns

    scopes = current_scopes(socket)
    now = DateTime.utc_now() |> DateTime.to_naive()

    {kept, provenance} = filter_items(items, filter, scopes, direct_only?)

    {events, meta} =
      CalendarDisplay.task_events(kept, L10n.current_content_lang(), offset, now: now)

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

  # The resolved scopes the current filter matches against — [me] for :me,
  # the picked people's scopes for :people, [] otherwise.
  defp current_scopes(%{assigns: %{assignee_filter: :me, me_scope: %{} = scope}}), do: [scope]

  defp current_scopes(%{assigns: %{assignee_filter: :people} = assigns}) do
    assigns.assignee_selected
    |> Enum.map(&Map.get(assigns.assignee_scopes, &1.uuid))
    |> Enum.reject(&is_nil/1)
  end

  defp current_scopes(_socket), do: []

  # Applies the assignee filter to the raw items. For person scopes, returns
  # the provenance map (uuid => :direct | {:team, name} | {:department, name})
  # alongside; direct-only narrows to :direct matches. Multiple selected
  # people match as a UNION — a task counts when ANY of them would see it.
  defp filter_items(items, :everyone, _scopes, _direct), do: {items, %{}}

  defp filter_items(items, :unassigned, _scopes, _direct) do
    {Enum.filter(items, fn {it, _} -> Assignees.unassigned?(it.assignment) end), %{}}
  end

  defp filter_items(items, _person_or_me, [], _direct), do: {items, %{}}

  defp filter_items(items, _person_or_me, scopes, direct_only?) do
    Enum.reduce(items, {[], %{}}, fn {it, span}, {kept, prov} ->
      case match_any(it.assignment, scopes) do
        nil -> {kept, prov}
        :direct -> {[{it, span} | kept], prov}
        _via when direct_only? -> {kept, prov}
        via -> {[{it, span} | kept], Map.put(prov, it.uuid, via)}
      end
    end)
    |> then(fn {kept, prov} -> {Enum.reverse(kept), prov} end)
  end

  # Match across every selected scope; a :direct hit for anyone wins (so
  # direct-only keeps a task any selected person holds personally), otherwise
  # the first inherited provenance found labels the row.
  defp match_any(assignment, scopes) do
    Enum.reduce_while(scopes, nil, fn scope, acc ->
      case Assignees.match(assignment, scope) do
        nil -> {:cont, acc}
        :direct -> {:halt, :direct}
        via -> {:cont, acc || via}
      end
    end)
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
    case socket.assigns[:phoenix_kit_current_user] do
      %{} = user -> PhoenixKit.Utils.Date.get_user_timezone(user)
      _ -> PhoenixKit.Settings.get_setting("time_zone", "0")
    end
  rescue
    _ -> "0"
  end

  # A stored UTC datetime as a calendar Date in the viewer's timezone, so every
  # day/date display on the Overview shares the same (local) basis as `today`.
  # The module otherwise works in UTC, but day boundaries are where a viewer
  # notices the difference — at 00:30 in UTC+3 it's already tomorrow locally.
  defp to_local_date(%DateTime{} = dt, offset) do
    dt |> PhoenixKit.Utils.Date.shift_to_offset(offset) |> DateTime.to_date()
  end

  # The calendar info-popover sentence describing the overdue indicator, worded
  # to match the configured animation mode (set on /admin/settings/projects).
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

  # Assignee quick filters. "me" only applies when the viewer resolved to a
  # staff person (the button is hidden otherwise, but the guard is
  # server-side). A quick filter clears any picked-people chips.
  def handle_event("set_assignee_filter", %{"filter" => filter}, socket) do
    new =
      case filter do
        "everyone" -> :everyone
        "unassigned" -> :unassigned
        "me" -> if(match?(%{}, socket.assigns.me_scope), do: :me)
        _ -> nil
      end

    if new do
      {:noreply,
       socket
       |> assign(assignee_filter: new, assignee_selected: [], assignee_scopes: %{})
       |> apply_task_filter()}
    else
      {:noreply, socket}
    end
  end

  # ── Person picker (core <.search_picker> contract) ──────────────
  # The dropdown renders client-side; this answers with rows + has_more
  # (limit+1 probe at the DB — nothing loads the whole people table).
  def handle_event("assignee_search", %{"q" => q} = params, socket) do
    limit =
      case params["limit"] do
        n when is_integer(n) and n > 0 ->
          n

        n when is_binary(n) ->
          case Integer.parse(n) do
            {i, _} -> max(i, 1)
            :error -> 8
          end

        _ ->
          8
      end

    {rows, has_more} = Assignees.search_people(q, limit)

    {:noreply, push_event(socket, "assignee_results", %{q: q, results: rows, has_more: has_more})}
  end

  # A person picked from the dropdown — add a chip (deduped) and switch the
  # filter to the picked set. `assignee_staged` confirms so the hook clears
  # the input. An unknown uuid resolves to nil scope and is ignored.
  def handle_event("assignee_pick", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    already? = Enum.any?(socket.assigns.assignee_selected, &(&1.uuid == uuid))

    case if(already?,
           do: :duplicate,
           else: Assignees.scope_for_person(uuid, L10n.current_content_lang())
         ) do
      nil ->
        {:noreply, socket}

      :duplicate ->
        {:noreply, push_event(socket, "assignee_staged", %{})}

      scope ->
        {:noreply,
         socket
         |> assign(
           assignee_filter: :people,
           assignee_selected:
             socket.assigns.assignee_selected ++ [%{uuid: uuid, name: scope.person_name}],
           assignee_scopes: Map.put(socket.assigns.assignee_scopes, uuid, scope)
         )
         |> apply_task_filter()
         |> push_event("assignee_staged", %{})}
    end
  end

  # Chip ✕ — drop one picked person; an empty set falls back to Everyone.
  def handle_event("remove_assignee_person", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    selected = Enum.reject(socket.assigns.assignee_selected, &(&1.uuid == uuid))

    {:noreply,
     socket
     |> assign(
       assignee_selected: selected,
       assignee_scopes: Map.delete(socket.assigns.assignee_scopes, uuid),
       assignee_filter: if(selected == [], do: :everyone, else: :people)
     )
     |> apply_task_filter()}
  end

  # "Direct only" narrows a person scope to personal assignments (team/
  # department inheritance off).
  def handle_event("toggle_assignee_direct", _params, socket) do
    {:noreply,
     socket
     |> update(:assignee_direct_only?, &(not &1))
     |> apply_task_filter()}
  end

  # "Overdue only" — late tasks (not done, scheduled span already ended).
  def handle_event("toggle_overdue_only", _params, socket) do
    {:noreply,
     socket
     |> update(:overdue_only?, &(not &1))
     |> apply_task_filter()}
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
    |> events_on(date)
    |> Enum.map(fn e ->
      m = Map.get(meta, e.id, %{})

      %{
        id: e.id,
        title: e.title,
        color: e.color,
        subtitle: row_subtitle(m),
        status: m[:status],
        late: m[:late] || false,
        project_uuid: m[:project_uuid]
      }
    end)
  end

  defp day_rows(socket, date) do
    socket.assigns.calendar_events
    |> events_on(date)
    |> Enum.map(fn e ->
      %{
        id: e.id,
        title: e.title,
        color: e.color,
        subtitle: project_span_label(e),
        status: nil,
        late: false,
        project_uuid: e.id
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

  # Events whose [start, end) span covers `date`, soonest-starting first.
  defp events_on(events, date) do
    events
    |> Enum.filter(fn e ->
      Date.compare(e.start, date) != :gt and Date.compare(date, Date.add(e.end, -1)) != :gt
    end)
    |> Enum.sort_by(&{&1.start, &1.title})
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
      <.page_header
        title={gettext("Projects")}
        description={gettext("Overview of active work, upcoming projects, and your assignments.")}
      >
        <:actions>
          <.smart_link
            navigate={Paths.new_project()}
            emit={{PhoenixKitProjects.Web.ProjectFormLive, %{"live_action" => "new"}}}
            embed_mode={@embed_mode}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New project")}
          </.smart_link>
          <.smart_link
            navigate={Paths.new_task()}
            emit={{PhoenixKitProjects.Web.TaskFormLive, %{"live_action" => "new"}}}
            embed_mode={@embed_mode}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New task")}
          </.smart_link>
        </:actions>
      </.page_header>

      <%!-- Stats row --%>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
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
                <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-2 mb-2">
                  <%!-- Assignee + overdue filters (Tasks mode only). Inherited
                       semantics by default: Me / a person includes their teams
                       and departments; "Direct only" narrows to personal
                       assignments. Unassigned is a triage view with a live
                       count over ALL tasks. --%>
                  <div class={["flex flex-wrap items-center gap-2", @calendar_mode != :tasks && "hidden"]}>
                    <div class="join">
                      <button
                        type="button"
                        class={["btn btn-xs join-item", @assignee_filter == :everyone && "btn-active"]}
                        phx-click="set_assignee_filter"
                        phx-value-filter="everyone"
                      >
                        {gettext("Everyone")}
                      </button>
                      <button
                        :if={match?(%{}, @me_scope)}
                        type="button"
                        class={["btn btn-xs join-item", @assignee_filter == :me && "btn-active"]}
                        phx-click="set_assignee_filter"
                        phx-value-filter="me"
                      >
                        {gettext("Me")}
                      </button>
                      <button
                        type="button"
                        class={["btn btn-xs join-item", @assignee_filter == :unassigned && "btn-active"]}
                        phx-click="set_assignee_filter"
                        phx-value-filter="unassigned"
                      >
                        {gettext("Unassigned")}
                        <span class="badge badge-xs badge-ghost">{@unassigned_count}</span>
                      </button>
                    </div>

                    <%!-- Instant person typeahead (core search_picker): the
                         dropdown renders client-side, the server answers
                         "assignee_search" with limit+1-probed pages (Load
                         more built in) — nothing preloads the people table.
                         Picked people become removable chips; several chips
                         filter as a union. --%>
                    <div class="w-44">
                      <.search_picker
                        id="overview-assignee-search"
                        dropdown_id="overview-assignee-dropdown"
                        search_event="assignee_search"
                        results_event="assignee_results"
                        pick_event="assignee_pick"
                        staged_event="assignee_staged"
                        placeholder={gettext("Add person…")}
                        class="input input-bordered input-xs w-full"
                        searching_label={gettext("Searching…")}
                        more_label={gettext("Load more")}
                        loading_more_label={gettext("Loading…")}
                        no_matches_label={gettext("No matches")}
                        data-search-on-focus
                      />
                    </div>

                    <span
                      :for={p <- @assignee_selected}
                      class="badge badge-sm badge-outline gap-1 max-w-40"
                    >
                      <span class="truncate">{p.name}</span>
                      <button
                        type="button"
                        phx-click="remove_assignee_person"
                        phx-value-uuid={p.uuid}
                        class="shrink-0 hover:text-error"
                        aria-label={gettext("Remove %{name}", name: p.name)}
                      >
                        <.icon name="hero-x-mark" class="w-3 h-3" />
                      </button>
                    </span>

                    <label
                      :if={@assignee_filter in [:me, :people]}
                      class="label cursor-pointer gap-1.5 text-xs"
                    >
                      <input
                        type="checkbox"
                        class="checkbox checkbox-xs"
                        checked={@assignee_direct_only?}
                        phx-click="toggle_assignee_direct"
                      />
                      {gettext("Direct only")}
                    </label>

                    <label class="label cursor-pointer gap-1.5 text-xs">
                      <input
                        type="checkbox"
                        class="checkbox checkbox-xs checkbox-error"
                        checked={@overdue_only?}
                        phx-click="toggle_overdue_only"
                      />
                      {gettext("Overdue only")}
                    </label>
                  </div>

                  <div class="join ml-auto">
                    <button
                      type="button"
                      class={["btn btn-xs join-item", @calendar_mode == :tasks && "btn-active"]}
                      phx-click="set_calendar_mode"
                      phx-value-mode="tasks"
                    >
                      {gettext("Tasks")}
                    </button>
                    <button
                      type="button"
                      class={["btn btn-xs join-item", @calendar_mode == :projects && "btn-active"]}
                      phx-click="set_calendar_mode"
                      phx-value-mode="projects"
                    >
                      {gettext("Projects")}
                    </button>
                  </div>
                </div>

                <div
                  id="overview-calendar-day-trigger"
                  phx-hook="PkDialogTrigger"
                  data-dialog="overview-day-modal"
                  data-trigger=".cal-day-cell, .cal-more-link"
                >
                  <%!-- Tasks mode (default): capped day cells — at most 4 bars +
                       3 chips per day, the rest behind "+N more". --%>
                  <div class={if(@calendar_mode != :tasks, do: "hidden")}>
                    <.live_component
                      module={PhoenixLiveCalendar.CalendarComponent}
                      id="overview-tasks-calendar"
                      events={@task_calendar_events}
                      views={[:month, :agenda]}
                      date={@today}
                      today={@today}
                      fixed_weeks={false}
                      expand_cells={true}
                      max_events={3}
                      max_multiday={4}
                      info_label={gettext("About this calendar")}
                      on_event_click={fn id -> send(self(), {:calendar_open_task, id}) end}
                      on_date_select={fn date -> send(self(), {:calendar_day_click, date}) end}
                      on_more_click={fn date -> send(self(), {:calendar_day_more, date}) end}
                    >
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
                          {gettext("A red ring marks a late task — not done, but past its scheduled days.")}
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
                    {Phoenix.HTML.raw(@overdue_style)}
                    <div id="overview-calendar-sync" phx-hook="SyncAnimations">
                      <.live_component
                        module={PhoenixLiveCalendar.CalendarComponent}
                        id="projects-overview-calendar"
                        events={@calendar_events}
                        views={[:month]}
                        date={@today}
                        today={@today}
                        fixed_weeks={false}
                        expand_cells={true}
                        info_label={gettext("About this calendar")}
                        on_event_click={fn id -> send(self(), {:calendar_open_project, id}) end}
                        on_date_select={fn date -> send(self(), {:calendar_day_click, date}) end}
                        on_more_click={fn date -> send(self(), {:calendar_day_more, date}) end}
                      >
                        <:info>
                          <p class="mb-1 text-sm font-semibold text-base-content">
                            {gettext("Reading the calendar")}
                          </p>
                          <p>{gettext("Each project is an ongoing line across the month.")}</p>
                          <p class="mt-1.5">{overdue_legend(@overdue_pattern)}</p>
                          <p class="mt-1.5 text-base-content/50">
                            {gettext("Late projects are grouped at the top.")}
                          </p>
                        </:info>
                      </.live_component>
                    </div>
                  </div>
                </div>

                <%!-- Whole-day popup. Kept in the DOM so PkDialogTrigger can open
                     it in the same frame as the click; the body is a skeleton
                     until the server round-trip fills @day_popup. --%>
                <.modal
                  keep_in_dom
                  id="overview-day-modal"
                  show={@day_popup != nil}
                  on_close="close_day_popup"
                  max_width="md"
                >
                  <:title>
                    <%= if @day_popup do %>
                      <.icon name="hero-calendar-days" class="w-5 h-5" />
                      {L10n.format_date(@day_popup.date)}
                    <% else %>
                      <span class="inline-block w-28 h-5 bg-base-content/10 rounded animate-pulse">
                      </span>
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
                          phx-click="day_popup_open_project"
                          phx-value-uuid={row.project_uuid}
                          class="flex items-center gap-2.5 w-full p-2 rounded-lg hover:bg-base-200 text-left transition"
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
                      <div :for={_i <- 1..3} class="h-9 bg-base-content/10 rounded-lg animate-pulse">
                      </div>
                    </div>
                  <% end %>
                </.modal>
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

      <%!-- Bottom navigation row --%>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
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
        <.smart_link
          navigate={Paths.new_template()}
          emit={{PhoenixKitProjects.Web.TemplateFormLive, %{"live_action" => "new"}}}
          embed_mode={@embed_mode}
          class="card bg-base-100 shadow-sm hover:shadow-md transition border border-base-200"
        >
          <div class="card-body p-4">
            <div class="flex items-center gap-2 text-base-content/70">
              <.icon name="hero-plus" class="w-5 h-5" />
              <span class="text-sm font-medium">{gettext("New template")}</span>
            </div>
            <div class="text-xs text-base-content/50">{gettext("Blueprint from scratch")}</div>
          </div>
        </.smart_link>
      </div>
    </div>
    """
  end
end
