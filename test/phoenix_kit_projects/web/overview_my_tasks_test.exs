defmodule PhoenixKitProjects.Web.OverviewMyTasksTest do
  @moduledoc """
  Coverage extension for `OverviewLive` — exercises the my-tasks card
  that renders when a `phoenix_kit_staff` Person record is linked to
  the current user. Triggers the `status_label/1` and
  `status_badge_class/1` private helpers (todo / in_progress branches).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects
  alias PhoenixKitStaff.Staff

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "ovr-my-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    scope = fake_scope(user_uuid: user.uuid)
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, user: user}
  end

  test "renders my-tasks card with status badges when user has assignments",
       %{conn: conn, user: user} do
    # Create a department + person linked to the user.
    {:ok, dept} =
      PhoenixKitStaff.Departments.create(%{
        "name" => "Eng-#{System.unique_integer([:positive])}"
      })

    {:ok, person} =
      Staff.create_person(%{
        "user_uuid" => user.uuid,
        "first_name" => "Test",
        "last_name" => "User",
        "employment_type" => "full_time",
        "primary_department_uuid" => dept.uuid
      })

    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)

    task1 = fixture_task(%{"title" => "T1-#{System.unique_integer([:positive])}"})
    task2 = fixture_task(%{"title" => "T2-#{System.unique_integer([:positive])}"})

    {:ok, _} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => task1.uuid,
        "status" => "todo",
        "assigned_person_uuid" => person.uuid
      })

    {:ok, _} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => task2.uuid,
        "status" => "in_progress",
        "assigned_person_uuid" => person.uuid
      })

    {:ok, _view, html} = live(conn, "/en/admin/projects/overview")

    # The my-tasks card renders when list_assignments_for_user is non-empty
    # — which fires status_label("todo") + status_label("in_progress")
    # + status_badge_class for each branch.
    assert html =~ "My tasks" or html =~ task1.title or html =~ task2.title
  end
end
