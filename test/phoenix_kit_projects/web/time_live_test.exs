defmodule PhoenixKitProjects.Web.TimeLiveTest do
  @moduledoc """
  The Time page: people rows with a task's own line, the now line on today,
  "Set deadline" saving through the task form's permission, the tab, and a
  viewer without the module refused.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Extensions, Projects}
  alias PhoenixKitStaff.{Departments, Staff}

  @path "/en/admin/projects/time"

  defp uniq, do: System.unique_integer([:positive])

  defp person(name) do
    {:ok, user} =
      Auth.register_user(%{email: "time-#{uniq()}@example.com", password: "ValidPassword123!"})

    {:ok, dept} = Departments.create(%{"name" => "Dept-#{uniq()}"})

    {:ok, person} =
      Staff.create_person(%{
        "user_uuid" => user.uuid,
        "name" => name,
        "employment_type" => "full_time",
        "primary_department_uuid" => dept.uuid
      })

    person
  end

  defp task(project, title, attrs) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        attrs
      )

    a
  end

  setup %{conn: conn} do
    Extensions.Registry.refresh()
    project = fixture_project(%{"name" => "Kitchen #{uniq()}"})
    {:ok, conn: put_test_scope(conn, fake_scope()), project: project}
  end

  test "lists people with the day's task as its own line, and the now line", %{
    conn: conn,
    project: project
  } do
    ann = person("Ann Planner #{uniq()}")
    idle = person("Idle Ivan #{uniq()}")

    a =
      task(project, "Paint the hall", %{
        "assigned_person_uuid" => ann.uuid,
        "start_date" => Date.utc_today(),
        "end_date" => Date.utc_today()
      })

    {:ok, view, html} = live(conn, @path)

    assert html =~ "Time"
    assert has_element?(view, "#time-row-person-#{ann.uuid}")
    assert has_element?(view, "#time-line-person-#{ann.uuid}-#{a.uuid}", "Paint the hall")
    assert has_element?(view, "#time-line-person-#{ann.uuid}-#{a.uuid} .time-plan")
    # Idle people are still listed.
    assert has_element?(view, "#time-row-person-#{idle.uuid}")
    assert has_element?(view, ".time-now")
  end

  test "Set deadline saves the task's deadline", %{conn: conn, project: project} do
    ann = person("Ann Deadline #{uniq()}")

    a =
      task(project, "Fix the sink", %{
        "assigned_person_uuid" => ann.uuid,
        "start_date" => Date.utc_today(),
        "end_date" => Date.utc_today()
      })

    {:ok, view, _html} = live(conn, @path)
    dom = "person-#{ann.uuid}-#{a.uuid}"

    view |> element("#time-line-#{dom} button[phx-click=edit_deadline]") |> render_click()
    assert has_element?(view, "#time-deadline-#{dom}")

    value = Date.utc_today() |> Date.add(2) |> Date.to_iso8601()

    view
    |> form("#time-deadline-#{dom}", %{"deadline" => value <> "T16:30"})
    |> render_submit()

    assert %{deadline: deadline} = Projects.get_assignment(a.uuid)
    assert DateTime.to_date(deadline) == Date.add(Date.utc_today(), 2)
    refute has_element?(view, "#time-deadline-#{dom}")
  end

  test "Set deadline is refused without :edit_tasks", %{conn: conn, project: project} do
    ann = person("Ann Refused #{uniq()}")

    a =
      task(project, "Not yours", %{
        "assigned_person_uuid" => ann.uuid,
        "start_date" => Date.utc_today(),
        "end_date" => Date.utc_today()
      })

    # A plain module-reacher who is no member of the project.
    conn = put_test_scope(conn, fake_scope(roles: ["User"], permissions: ["projects"]))
    {:ok, view, _html} = live(conn, @path)

    render_submit(view, "save_deadline", %{"uuid" => a.uuid, "deadline" => "2030-01-01T10:00"})
    assert %{deadline: nil} = Projects.get_assignment(a.uuid)
  end

  test "a viewer without the module is refused", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope(roles: ["User"], permissions: []))
    assert {:error, {:redirect, _}} = live(conn, @path)
  end

  test "the week view has seven day columns", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)
    html = view |> element("button[phx-value-view=week]") |> render_click()
    assert html =~ "Mon"
    assert html =~ "Sun"
  end

  test "the Time tab sits next to the Overview" do
    tabs = PhoenixKitProjects.admin_tabs()
    time = Enum.find(tabs, &(&1.id == :admin_projects_time))
    overview = Enum.find(tabs, &(&1.id == :admin_projects_overview))

    assert time.path == "projects/time"
    assert {PhoenixKitProjects.Web.TimeLive, :index} = time.live_view
    assert time.priority < overview.priority
    assert PhoenixKitProjects.Paths.time() =~ "/admin/projects/time"
  end
end
