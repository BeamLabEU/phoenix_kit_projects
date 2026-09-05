defmodule PhoenixKitProjects.Web.Widgets.CalendarWidget do
  @moduledoc """
  Dashboard widget: the Overview's calendar — every scheduled task across
  all projects on its days (Tasks mode, coloured by project, late marker),
  or one ongoing line per project (Projects mode) — as a widget, so a
  dashboards-module board can stand in for the Overview page.

  Same data, same math: the per-project schedule walk
  (`ScheduleLayout.tree/1`) and the event builders in `CalendarDisplay`,
  rendered by the same `PhoenixLiveCalendar.CalendarComponent`, which
  pages months on its own (`internal_date`) and keeps that state across the
  host's refresh ticks because the widget re-renders it under a stable id.

  What the page has and the widget deliberately does not: the assignee
  filter panel, the whole-day popup and click-to-open. A widget is a
  LiveComponent — the calendar's `on_*` callbacks message the parent
  LiveView, which here is the dashboards host, so none are wired.
  Settings cover the useful slices instead: `"mode"` (tasks | projects),
  `"only_mine"`, `"late_only"`. Views: `month` / `agenda`.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitProjects.Gettext

  require Logger

  import PhoenixKitProjects.Web.Widgets.Helpers

  alias PhoenixKitProjects.{CalendarDisplay, L10n, Paths, Projects, RunningTiers, ScheduleLayout}
  alias PhoenixKitProjects.Schemas.Assignment

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, :id, assigns.id)

    if available?() do
      settings = assigns[:settings] || %{}
      mode = if settings["mode"] == "projects", do: :projects, else: :tasks
      view = effective_view(assigns[:view], ~w(month agenda))
      anim = CalendarDisplay.read()
      offset = offset_for(assigns[:scope])
      today = local_today(offset)

      {:ok,
       socket
       |> assign(:available, true)
       |> assign(:view, view)
       |> assign(:mode, mode)
       |> assign(:anim, anim)
       |> assign(:today, today)
       |> assign(:events, events(mode, assigns[:scope], settings, offset, today, anim))}
    else
      {:ok, assign(socket, :available, false)}
    end
  end

  # The viewer's timezone offset (e.g. "+3"), the same basis the Overview
  # uses for day boundaries; the site setting when the scope has no user.
  defp offset_for(scope) do
    case scope do
      %{user: %{user_timezone: _} = user} -> PhoenixKit.Utils.Date.get_user_timezone(user)
      _ -> PhoenixKit.Settings.get_setting("time_zone", "0")
    end
  rescue
    e ->
      Logger.warning(
        "[CalendarWidget] timezone lookup failed, using UTC: #{Exception.message(e)}"
      )

      "0"
  end

  defp local_today(offset) do
    DateTime.utc_now() |> PhoenixKit.Utils.Date.shift_to_offset(offset) |> DateTime.to_date()
  rescue
    e ->
      Logger.warning(
        "[CalendarWidget] offset #{inspect(offset)} rejected, using UTC today: #{Exception.message(e)}"
      )

      Date.utc_today()
  end

  # Viewer-scoped at the query, like every projects widget: a dashboard
  # reader must never see a project they cannot open.
  defp events(:tasks, scope, settings, offset, _today, anim) do
    viewer = viewer_for(scope)

    projects =
      Projects.list_active_projects(viewer: viewer) ++
        Projects.list_upcoming_projects(viewer: viewer)

    # Batched: the whole forest's assignments in one read per depth level
    # (this runs every 60 s, per viewer — the #40 review).
    items =
      projects
      |> Enum.uniq_by(& &1.uuid)
      |> ScheduleLayout.trees()
      |> Enum.flat_map(fn {items, layout} ->
        items
        |> Enum.reject(&Assignment.subproject?(&1.assignment))
        |> Enum.map(&{&1, Map.fetch!(layout, &1.uuid)})
      end)
      |> only_mine(settings, scope)

    now = DateTime.utc_now() |> DateTime.to_naive()

    {events, meta} =
      CalendarDisplay.task_events(items, L10n.current_content_lang(), offset,
        now: now,
        late_class: CalendarDisplay.late_marker_class(anim)
      )

    if late_only?(settings),
      do: Enum.filter(events, &(meta[&1.id] && meta[&1.id].late)),
      else: events
  rescue
    e ->
      Logger.warning("[CalendarWidget] task events failed: #{Exception.message(e)}")
      []
  end

  defp events(:projects, scope, settings, offset, today, anim) do
    viewer = viewer_for(scope)
    now = DateTime.utc_now()

    summaries =
      Projects.list_active_projects(viewer: viewer)
      |> Projects.project_tree_summaries()
      |> Enum.map(&RunningTiers.tag(&1, now))

    {summaries, completed, upcoming} =
      if late_only?(settings),
        do: {Enum.filter(summaries, & &1.late), [], []},
        else:
          {summaries, Projects.list_recently_completed_projects(5, viewer: viewer),
           Projects.list_upcoming_projects(viewer: viewer)}

    CalendarDisplay.events(
      summaries,
      completed,
      upcoming,
      L10n.current_content_lang(),
      today,
      offset,
      late_marker: anim.late_marker
    )
  rescue
    e ->
      Logger.warning("[CalendarWidget] project events failed: #{Exception.message(e)}")
      []
  end

  defp late_only?(settings), do: settings["late_only"] in [true, "true"]

  # "Only my tasks": the viewer's own assignments (direct, team or department,
  # via the same query My tasks uses). No resolvable viewer ⇒ nothing, never
  # everything.
  defp only_mine(items, settings, scope) do
    if settings["only_mine"] in [true, "true"] do
      case scope_user_uuid(scope) do
        nil ->
          []

        user_uuid ->
          mine = user_uuid |> Projects.list_assignments_for_user() |> MapSet.new(& &1.uuid)
          Enum.filter(items, fn {item, _span} -> MapSet.member?(mine, item.assignment.uuid) end)
      end
    else
      items
    end
  end

  @impl true
  def render(%{available: false} = assigns) do
    ~H"""
    <div class="contents">
      <.frame title={gettext("Projects calendar")} icon="hero-calendar-days"><.unavailable /></.frame>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="contents">
      <.frame title={title(@mode)} icon="hero-calendar-days" href={Paths.projects()}>
        <%!-- The configured overdue marker (pattern/ring) — the same <style>
             the Overview emits, so late chips look identical here. --%>
        {Phoenix.HTML.raw(CalendarDisplay.animation_style(@anim))}
        <div id={"#{@id}-sync"} phx-hook="SyncAnimations" class="h-full min-h-0 overflow-hidden text-xs">
          <.live_component
            module={PhoenixLiveCalendar.CalendarComponent}
            id={"#{@id}-calendar"}
            events={@events}
            views={[String.to_existing_atom(@view)]}
            view={String.to_existing_atom(@view)}
            date={@today}
            today={@today}
            week_start={@anim.week_start}
            show_weekends={@anim.show_weekends}
            show_week_numbers={false}
            fixed_weeks={@anim.fixed_weeks}
            expand_cells={true}
            max_events={@anim.max_events}
            max_multiday={@anim.max_multiday}
            show_header={true}
          />
        </div>
      </.frame>
    </div>
    """
  end

  defp title(:projects), do: gettext("Projects calendar")
  defp title(:tasks), do: gettext("Tasks calendar")
end
