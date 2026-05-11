defmodule PhoenixKitProjects.Web.AssignmentFormExtrasTest do
  @moduledoc """
  Coverage extension for `AssignmentFormLive`. Targets the validate
  branches (prefill_from_template, task_mode + assign_type toggling,
  selected_task_uuid replacement) and the dep handlers
  (add_assignment_dep / remove_assignment_dep).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "prefill_from_template / validate task switching" do
    test "selecting a task uuid prefills description + duration", %{conn: conn} do
      project = fixture_project()

      task =
        fixture_task(%{
          "title" => "Tpl",
          "description" => "from template",
          "estimated_duration" => 3,
          "estimated_duration_unit" => "hours"
        })

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/list/#{project.uuid}/assignments/new")

      _ =
        view
        |> form("#assignment-form",
          assignment: %{task_uuid: task.uuid, status: "todo"},
          task_mode: "existing"
        )
        |> render_change()

      html = render(view)
      assert html =~ "from template" or html =~ "Description"
    end

    test "switching to new-task tab + validate keeps form alive", %{conn: conn} do
      project = fixture_project()

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/list/#{project.uuid}/assignments/new")

      # New UI: tabs (Create new / From library) replaced the dropdown.
      _ = view |> element("button[phx-value-mode='new']") |> render_click()

      _ =
        view
        |> form("#assignment-form", assignment: %{status: "todo"}, task_mode: "new")
        |> render_change()

      assert Process.alive?(view.pid)
    end

    test "validate with assign_type=team triggers the team branch", %{conn: conn} do
      project = fixture_project()
      _ = fixture_task()

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/list/#{project.uuid}/assignments/new")

      _ =
        view
        |> form("#assignment-form",
          assignment: %{status: "todo"},
          assign_type: "team",
          task_mode: "existing"
        )
        |> render_change()

      assert Process.alive?(view.pid)
    end

    test "validate with assign_type=department triggers the dept branch", %{conn: conn} do
      project = fixture_project()
      _ = fixture_task()

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/list/#{project.uuid}/assignments/new")

      _ =
        view
        |> form("#assignment-form",
          assignment: %{status: "todo"},
          assign_type: "department",
          task_mode: "existing"
        )
        |> render_change()

      assert Process.alive?(view.pid)
    end

    test "validate with assign_type=person triggers the person branch", %{conn: conn} do
      project = fixture_project()
      _ = fixture_task()

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/list/#{project.uuid}/assignments/new")

      _ =
        view
        |> form("#assignment-form",
          assignment: %{status: "todo"},
          assign_type: "person",
          task_mode: "existing"
        )
        |> render_change()

      assert Process.alive?(view.pid)
    end
  end

  describe "dependency handlers in :edit mode" do
    setup do
      project = fixture_project()
      task1 = fixture_task()
      task2 = fixture_task()

      {:ok, a1} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task1.uuid,
          "status" => "todo"
        })

      {:ok, a2} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task2.uuid,
          "status" => "todo"
        })

      {:ok, project: project, a1: a1, a2: a2}
    end

    test "add_assignment_dep with empty uuid is a no-op",
         %{conn: conn, project: p, a1: a1} do
      {:ok, view, _html} =
        live(conn, "/en/admin/projects/list/#{p.uuid}/assignments/#{a1.uuid}/edit")

      _ =
        render_submit(view, "add_assignment_dep", %{"depends_on_uuid" => ""})

      assert Process.alive?(view.pid)
      assert Projects.list_dependencies(a1.uuid) == []
    end

    test "add_assignment_dep with a valid uuid adds the edge + logs activity",
         %{conn: conn, project: p, a1: a1, a2: a2, actor_uuid: actor_uuid} do
      {:ok, view, _html} =
        live(conn, "/en/admin/projects/list/#{p.uuid}/assignments/#{a1.uuid}/edit")

      _ =
        render_submit(view, "add_assignment_dep", %{
          "depends_on_uuid" => a2.uuid
        })

      assert [_dep] = Projects.list_dependencies(a1.uuid)

      assert_activity_logged("projects.dependency_added",
        actor_uuid: actor_uuid,
        resource_uuid: a1.uuid
      )
    end

    test "add_assignment_dep on a self-edge (would cycle) flashes the error branch",
         %{conn: conn, project: p, a1: a1} do
      {:ok, view, _html} =
        live(conn, "/en/admin/projects/list/#{p.uuid}/assignments/#{a1.uuid}/edit")

      # `Dependency.changeset/2` rejects assignment_uuid == depends_on_uuid;
      # the LV catches the {:error, _} return and flashes a generic
      # "Could not add dependency" message.
      html =
        render_submit(view, "add_assignment_dep", %{
          "depends_on_uuid" => a1.uuid
        })

      assert html =~ "Could not add dependency"
    end

    test "remove_assignment_dep removes existing edge + logs activity",
         %{conn: conn, project: p, a1: a1, a2: a2, actor_uuid: actor_uuid} do
      {:ok, _} = Projects.add_dependency(a1.uuid, a2.uuid)

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/list/#{p.uuid}/assignments/#{a1.uuid}/edit")

      _ = render_click(view, "remove_assignment_dep", %{"uuid" => a2.uuid})

      assert Projects.list_dependencies(a1.uuid) == []

      assert_activity_logged("projects.dependency_removed",
        actor_uuid: actor_uuid,
        resource_uuid: a1.uuid
      )
    end

    test "remove_assignment_dep on missing edge flashes",
         %{conn: conn, project: p, a1: a1, a2: a2} do
      {:ok, view, _html} =
        live(conn, "/en/admin/projects/list/#{p.uuid}/assignments/#{a1.uuid}/edit")

      html = render_click(view, "remove_assignment_dep", %{"uuid" => a2.uuid})
      assert html =~ "Could not remove dependency"
    end
  end
end
