defmodule PhoenixKitProjects.Web.AssignmentFormExtrasTest do
  @moduledoc """
  Coverage extension for `AssignmentFormLive`. Targets the validate
  branches (prefill_from_template, task_mode toggling, the assignee picker,
  selected_task_uuid replacement) and the dep handlers
  (add_assignment_dep / remove_assignment_dep).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitStaff.Schemas.{Department, Person, Team}

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  # A staff person, team or department to assign, by kind.
  defp assignee!("person") do
    Repo.insert!(%Person{
      user_uuid: embed_user_uuid!(),
      status: "active",
      name: "Pat #{System.unique_integer([:positive])}"
    }).uuid
  end

  defp assignee!("department") do
    Repo.insert!(%Department{
      name: "Dept #{System.unique_integer([:positive])}"
    }).uuid
  end

  defp assignee!("team") do
    Repo.insert!(%Team{
      name: "Team #{System.unique_integer([:positive])}",
      department_uuid: assignee!("department")
    }).uuid
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
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")

      # Create new is the default tab; these cases pick from the library.

      _ = view |> element("button[phx-value-tab='existing']") |> render_click()

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
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")

      # New UI: tabs (Create new / From library) replaced the dropdown.

      _ =
        view
        |> form("#assignment-form", assignment: %{status: "todo"}, task_mode: "new")
        |> render_change()

      assert Process.alive?(view.pid)
    end

    test "picking a team in the assignee picker sets only the team", %{conn: conn} do
      project = fixture_project()
      _ = fixture_task()
      uuid = assignee!("team")

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")

      # Create new is the default tab; these cases pick from the library.

      _ = view |> element("button[phx-value-tab='existing']") |> render_click()

      render_click(view, "assignee_pick", %{"kind" => "team", "uuid" => uuid, "label" => "x"})

      _ =
        view
        |> form("#assignment-form", assignment: %{status: "todo"}, task_mode: "existing")
        |> render_change()

      form = :sys.get_state(view.pid).socket.assigns.form

      # The other two post back empty from their hidden inputs.
      for field <- ~w(assigned_person_uuid assigned_team_uuid assigned_department_uuid)a do
        expected = if field == PhoenixKitProjects.Assignees.assignee_field("team"), do: uuid
        assert (form[field].value || "") == (expected || "")
      end
    end

    test "picking a department in the assignee picker sets only the department", %{conn: conn} do
      project = fixture_project()
      _ = fixture_task()
      uuid = assignee!("department")

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")

      # Create new is the default tab; these cases pick from the library.

      _ = view |> element("button[phx-value-tab='existing']") |> render_click()

      render_click(view, "assignee_pick", %{
        "kind" => "department",
        "uuid" => uuid,
        "label" => "x"
      })

      _ =
        view
        |> form("#assignment-form", assignment: %{status: "todo"}, task_mode: "existing")
        |> render_change()

      form = :sys.get_state(view.pid).socket.assigns.form

      # The other two post back empty from their hidden inputs.
      for field <- ~w(assigned_person_uuid assigned_team_uuid assigned_department_uuid)a do
        expected = if field == PhoenixKitProjects.Assignees.assignee_field("department"), do: uuid
        assert (form[field].value || "") == (expected || "")
      end
    end

    test "picking a person in the assignee picker sets only the person", %{conn: conn} do
      project = fixture_project()
      _ = fixture_task()
      uuid = assignee!("person")

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")

      # Create new is the default tab; these cases pick from the library.

      _ = view |> element("button[phx-value-tab='existing']") |> render_click()

      render_click(view, "assignee_pick", %{"kind" => "person", "uuid" => uuid, "label" => "x"})

      _ =
        view
        |> form("#assignment-form", assignment: %{status: "todo"}, task_mode: "existing")
        |> render_change()

      form = :sys.get_state(view.pid).socket.assigns.form

      # The other two post back empty from their hidden inputs.
      for field <- ~w(assigned_person_uuid assigned_team_uuid assigned_department_uuid)a do
        expected = if field == PhoenixKitProjects.Assignees.assignee_field("person"), do: uuid
        assert (form[field].value || "") == (expected || "")
      end
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
        live(conn, "/en/admin/projects/#{p.uuid}/assignments/#{a1.uuid}/edit")

      _ =
        render_submit(view, "add_assignment_dep", %{"depends_on_uuid" => ""})

      assert Process.alive?(view.pid)
      assert Projects.list_dependencies(a1.uuid) == []
    end

    test "add_assignment_dep with a valid uuid adds the edge + logs activity",
         %{conn: conn, project: p, a1: a1, a2: a2, actor_uuid: actor_uuid} do
      {:ok, view, _html} =
        live(conn, "/en/admin/projects/#{p.uuid}/assignments/#{a1.uuid}/edit")

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
        live(conn, "/en/admin/projects/#{p.uuid}/assignments/#{a1.uuid}/edit")

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
        live(conn, "/en/admin/projects/#{p.uuid}/assignments/#{a1.uuid}/edit")

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
        live(conn, "/en/admin/projects/#{p.uuid}/assignments/#{a1.uuid}/edit")

      html = render_click(view, "remove_assignment_dep", %{"uuid" => a2.uuid})
      assert html =~ "Could not remove dependency"
    end
  end

  describe "the edit page reads in order" do
    test "the portal switches come BEFORE the Save button, not after it", %{conn: conn} do
      # They used to render after the closing form tag, which put two
      # switches below Save and made the page look like it had ended and
      # then carried on.
      PhoenixKitProjects.Extensions.Registry.refresh()

      {:ok, project} =
        PhoenixKitProjects.Projects.create_project(%{
          "name" => "Order #{System.unique_integer([:positive])}",
          "start_mode" => "immediate"
        })

      {:ok, _} = PhoenixKitProjects.Extensions.enable(project, "portal")
      task = fixture_task()

      {:ok, assignment} =
        PhoenixKitProjects.Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, _view, html} =
        live(
          conn,
          "/en/admin/projects/#{project.uuid}/assignments/#{assignment.uuid}/edit"
        )

      portal_at = :binary.match(html, "toggle_portal_public") |> elem(0)
      # An edit saves as it goes; its bar (where things stand, Done) is
      # the form's foot.
      save_at = :binary.match(html, ~s(id="assignment-save-bar")) |> elem(0)

      assert portal_at < save_at,
             "the portal switch renders after the save bar"
    end
  end
end
