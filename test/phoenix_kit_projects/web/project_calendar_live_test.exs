defmodule PhoenixKitProjects.Web.ProjectCalendarLiveTest do
  @moduledoc """
  Smoke tests for `ProjectCalendarLive` — the month-calendar view that
  renders the same `ScheduleLayout` schedule as the Timeline tab through
  the `PhoenixLiveCalendar` component. Verifies the assignment→event
  mapping (top level only, status colors, exclusive ends), the click
  targets, the initial month anchor, and the empty/not-found states.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Paths, Projects, ScheduleLayout}
  alias PhoenixKitProjects.Web.ProjectCalendarLive

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "cal-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    scope = fake_scope(user_uuid: user.uuid)
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: user.uuid}
  end

  defp started_project_with_tasks do
    project = fixture_project(%{"start_mode" => "immediate", "counts_weekends" => false})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    t1 = fixture_task(%{"estimated_duration" => 2, "estimated_duration_unit" => "days"})
    t2 = fixture_task(%{"estimated_duration" => 3, "estimated_duration_unit" => "days"})

    {:ok, a1} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => t1.uuid,
        "status" => "done"
      })

    {:ok, a2} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => t2.uuid,
        "status" => "in_progress"
      })

    {project, a1, a2}
  end

  test "renders one all-day bar per assignment with titles and status colors", %{conn: conn} do
    {project, _a1, _a2} = started_project_with_tasks()

    {:ok, view, _html} =
      live_isolated(conn, ProjectCalendarLive, session: %{"id" => project.uuid})

    html = render(view)

    # The month grid renders with a multi-day bar per (multi-day) assignment.
    assert html =~ "cal-container"
    assert html =~ "cal-month-grid"
    assert html =~ "cal-multiday-bar"

    # Status colors match the Timeline tab's bars.
    assert html =~ "bg-success"
    assert html =~ "bg-warning"

    # Titles render on the bars.
    {items, _layout} = ScheduleLayout.tree(Projects.get_project_with_assignee(project.uuid))
    for it <- items, do: assert(html =~ it.assignment.task.title)
  end

  test "bars land on the same dates as the shared schedule walk", %{conn: conn} do
    {project, a1, _a2} = started_project_with_tasks()

    {:ok, view, _html} =
      live_isolated(conn, ProjectCalendarLive, session: %{"id" => project.uuid})

    html = render(view)

    {_items, layout} = ScheduleLayout.tree(Projects.get_project_with_assignee(project.uuid))
    %{start: s} = Map.fetch!(layout, a1.uuid)

    # The bar's per-day DOM carries no dates, but the grid cell for the walk's
    # start day exists in the rendered month (the anchor month covers the
    # schedule start).
    assert html =~ Date.to_iso8601(NaiveDateTime.to_date(s))
  end

  test "clicking a task bar navigates to its assignment edit form", %{conn: conn} do
    {project, a1, _a2} = started_project_with_tasks()

    {:ok, view, _html} =
      live_isolated(conn, ProjectCalendarLive, session: %{"id" => project.uuid})

    # The component reports clicks to the parent as a process message; drive
    # the handler directly (the chip→callback wiring is the library's own).
    render(view)
    send(view.pid, {:calendar_event_click, a1.uuid})
    assert_redirect(view, Paths.edit_assignment(project.uuid, a1.uuid))
  end

  test "clicking a sub-project bar drills into the child project", %{conn: conn} do
    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    {:ok, %{child_project: child, assignment: link}} =
      Projects.create_subproject(project.uuid, %{"name" => "Child sub"})

    {:ok, view, _html} =
      live_isolated(conn, ProjectCalendarLive, session: %{"id" => project.uuid})

    render(view)
    send(view.pid, {:calendar_event_click, link.uuid})
    assert_redirect(view, Paths.project(child.uuid))
  end

  test "only top-level assignments render — a sub-project's children stay on its own calendar",
       %{conn: conn} do
    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    {:ok, %{child_project: child}} =
      Projects.create_subproject(project.uuid, %{"name" => "Kitchen deep clean"})

    child_task =
      fixture_task(%{
        "title" => "Scrub the oven racks",
        "estimated_duration" => 2,
        "estimated_duration_unit" => "days"
      })

    {:ok, _} =
      Projects.create_assignment(%{
        "project_uuid" => child.uuid,
        "task_uuid" => child_task.uuid
      })

    {:ok, view, _html} =
      live_isolated(conn, ProjectCalendarLive, session: %{"id" => project.uuid})

    html = render(view)

    # The sub-project bar renders; its child task does not (no double-draw —
    # the parent bar already spans the child's scheduled time).
    assert html =~ "Kitchen deep clean"
    refute html =~ "Scrub the oven racks"
  end

  test "a future scheduled project opens on its schedule's month, not today's", %{conn: conn} do
    future = DateTime.add(DateTime.utc_now(), 70 * 24 * 3600, :second)

    project =
      fixture_project(%{
        "start_mode" => "scheduled",
        "scheduled_start_date" => DateTime.to_iso8601(future)
      })

    task = fixture_task(%{"estimated_duration" => 2, "estimated_duration_unit" => "days"})

    {:ok, _} =
      Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => task.uuid})

    {:ok, view, _html} =
      live_isolated(conn, ProjectCalendarLive, session: %{"id" => project.uuid})

    html = render(view)

    # ~70 days out is always a different month; the grid must contain the
    # schedule anchor's date cell, not today's.
    anchor = DateTime.to_date(future)
    assert html =~ Date.to_iso8601(anchor)
    refute html =~ Date.to_iso8601(Date.utc_today())
  end

  test "shows the empty state (with an add-task CTA) when the project has no tasks", %{
    conn: conn
  } do
    project = fixture_project(%{"start_mode" => "immediate"})

    {:ok, view, _html} =
      live_isolated(conn, ProjectCalendarLive, session: %{"id" => project.uuid})

    html = render(view)
    assert html =~ "No tasks to place on the calendar yet."
    assert html =~ "Add a task"
    refute html =~ "cal-container"
  end

  test "unknown project id redirects to the projects list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live_isolated(conn, ProjectCalendarLive, session: %{"id" => Ecto.UUID.generate()})

    assert to == Paths.projects()
  end

  test "headless embed drops the back-link header", %{conn: conn} do
    {project, _a1, _a2} = started_project_with_tasks()

    {:ok, view, _html} =
      live_isolated(conn, ProjectCalendarLive,
        session: %{"id" => project.uuid, "headless" => true, "wrapper_class" => ""}
      )

    html = render(view)
    refute html =~ "Back to project"
    assert html =~ "cal-container"
  end

  test "a day-cell or +N more click fills the whole-day popup; a row click navigates", %{
    conn: conn
  } do
    {project, a1, _a2} = started_project_with_tasks()

    {:ok, view, _html} =
      live_isolated(conn, ProjectCalendarLive, session: %{"id" => project.uuid})

    render(view)

    # Both triggers land on the same popup; rows carry the status badge.
    {items, layout} = ScheduleLayout.tree(Projects.get_project_with_assignee(project.uuid))
    %{start: s} = Map.fetch!(layout, a1.uuid)
    day = NaiveDateTime.to_date(s)
    a1_title = Enum.find(items, &(&1.uuid == a1.uuid)).assignment.task.title

    send(view.pid, {:calendar_date_click, day})
    html = render(view)
    assert html =~ a1_title
    assert html =~ "day_popup_item_click"

    send(view.pid, {:calendar_more_click, day})
    assert render(view) =~ a1_title

    # Closing resets to the skeleton.
    html = render_click(view, "close_day_popup", %{})
    refute html =~ "day_popup_item_click"

    # A row click routes like a chip click — to the assignment edit form.
    send(view.pid, {:calendar_date_click, day})
    render(view)
    render_click(view, "day_popup_item_click", %{"uuid" => a1.uuid})
    assert_redirect(view, Paths.edit_assignment(project.uuid, a1.uuid))
  end

  test "an empty day's popup says nothing is scheduled", %{conn: conn} do
    {project, _a1, _a2} = started_project_with_tasks()

    {:ok, view, _html} =
      live_isolated(conn, ProjectCalendarLive, session: %{"id" => project.uuid})

    render(view)
    send(view.pid, {:calendar_date_click, Date.add(Date.utc_today(), 400)})
    assert render(view) =~ "Nothing scheduled this day."
  end

  test "reloads on a projects PubSub broadcast (new assignment appears)", %{conn: conn} do
    {project, _a1, _a2} = started_project_with_tasks()

    {:ok, view, _html} =
      live_isolated(conn, ProjectCalendarLive, session: %{"id" => project.uuid})

    render(view)

    t3 =
      fixture_task(%{
        "title" => "Late-added chore",
        "estimated_duration" => 1,
        "estimated_duration_unit" => "days"
      })

    {:ok, _} =
      Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => t3.uuid})

    assert render(view) =~ "Late-added chore"
  end
end
