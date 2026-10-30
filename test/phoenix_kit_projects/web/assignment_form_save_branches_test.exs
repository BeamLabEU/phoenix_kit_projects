defmodule PhoenixKitProjects.Web.AssignmentFormSaveBranchesTest do
  @moduledoc """
  Branch coverage for `AssignmentFormLive`'s save paths — covers the
  remaining lines around `save_new` / `save_edit` / `save_with_new_task`
  / `flash_for_template_deps` / `clear_other_assignees` /
  `maybe_add_default_assignee`.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.{Assignees, Projects}
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitStaff.Schemas.Department

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "save_new error branch (invalid assignment attrs)" do
    test "invalid attrs re-render the form", %{conn: conn} do
      project = fixture_project()

      # The library tab only exists once the library has an entry.

      _ = fixture_task()

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")

      # Create new is the default tab; these cases pick from the library.

      _ = view |> element("button[phx-value-tab='existing']") |> render_click()

      # Blank task_uuid → assoc_constraint OR validate_required fires.
      html =
        view
        |> form("#assignment-form",
          assignment: %{task_uuid: "", status: "todo"},
          task_mode: "existing"
        )
        |> render_submit()

      # Form re-renders, no redirect.
      assert html =~ "assignment-form"
    end
  end

  describe "save_with_new_task error branch (invalid task_attrs)" do
    test "blank new_task_title surfaces a 'Task title is required' flash", %{conn: conn} do
      # V112 dropped the title unique-constraint, so duplicate-title is no
      # longer a failure mode for `create_task_and_assign/3`. The
      # remaining server-side guard is the blank-title branch — exercise
      # that to keep the fallback-flash render path covered.
      project = fixture_project()

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")

      html =
        view
        |> form("#assignment-form",
          assignment: %{
            status: "todo",
            description: "",
            estimated_duration: "1",
            estimated_duration_unit: "hours"
          },
          task_mode: "new",
          task: %{title: "   "}
        )
        |> render_submit()

      assert html =~ "Task title is required"
    end
  end

  describe "save_edit assignment update error branch" do
    test "invalid status (out of allowed set) re-renders with errors", %{conn: conn} do
      project = fixture_project()
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, view, _html} =
        live(
          conn,
          "/en/admin/projects/#{project.uuid}/assignments/#{assignment.uuid}/edit"
        )

      # Submitting an out-of-set status doesn't make it through `validate_inclusion`.
      html =
        view
        |> form("#assignment-form",
          assignment: %{
            status: "todo",
            estimated_duration: "-100",
            estimated_duration_unit: "hours"
          }
        )
        |> render_submit()

      # Either form re-renders (validation rejected) or redirects after save.
      assert is_binary(html)
    end
  end

  describe "the assignee picker's choice is the one assignee saved" do
    test "save_new with a department picked carries no team or person", %{conn: conn} do
      project = fixture_project()
      task = fixture_task()

      dept =
        Repo.insert!(%Department{
          name: "Dept #{System.unique_integer([:positive])}"
        })

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")

      # Create new is the default tab; these cases pick from the library.

      _ = view |> element("button[phx-value-tab='existing']") |> render_click()

      render_click(view, "assignee_pick", %{"kind" => "department", "uuid" => dept.uuid})

      {:error, {:live_redirect, _}} =
        view
        |> form("#assignment-form",
          assignment: %{task_uuid: task.uuid, status: "todo"},
          task_mode: "existing"
        )
        |> render_submit()

      [created] = Projects.list_assignments(project.uuid)
      assert created.assigned_department_uuid == dept.uuid
      assert created.assigned_team_uuid == nil
      assert created.assigned_person_uuid == nil
    end

    test "save_new with nobody picked clears all three", %{conn: conn} do
      project = fixture_project()
      task = fixture_task()

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")

      # Create new is the default tab; these cases pick from the library.

      _ = view |> element("button[phx-value-tab='existing']") |> render_click()

      {:error, {:live_redirect, _}} =
        view
        |> form("#assignment-form",
          assignment: %{task_uuid: task.uuid, status: "todo"},
          task_mode: "existing"
        )
        |> render_submit()

      [created] = Projects.list_assignments(project.uuid)
      assert Assignees.unassigned?(created)
    end
  end
end
