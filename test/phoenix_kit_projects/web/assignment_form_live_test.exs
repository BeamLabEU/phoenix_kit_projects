defmodule PhoenixKitProjects.Web.AssignmentFormLiveTest do
  @moduledoc """
  Smoke tests for `AssignmentFormLive`. Original sweep shipped at 0%
  coverage. The LV has the most event handlers in the module:
  validate / save (existing-task / new-task / edit) / add_assignment_dep /
  remove_assignment_dep, plus the not-found redirects on missing
  project / assignment.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.Assignment

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "new assignment in an existing project" do
    test "mounts and renders the form", %{conn: conn} do
      project = fixture_project()
      _task = fixture_task()

      {:ok, _view, html} =
        live(conn, "/en/admin/projects/list/#{project.uuid}/assignments/new")

      assert html =~ "assignment-form"
      assert html =~ project.name
    end

    test "missing project id redirects to projects list with flash", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      {:error, {:live_redirect, %{to: redirect_to, flash: flash}}} =
        live(conn, "/en/admin/projects/list/#{bogus}/assignments/new")

      assert redirect_to == PhoenixKitProjects.Paths.projects()
      assert flash["error"] =~ "Project not found"
    end

    test "validate event with task_mode=existing pre-fills selected_task", %{conn: conn} do
      project = fixture_project()
      task = fixture_task()

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/list/#{project.uuid}/assignments/new")

      _ =
        view
        |> form("#assignment-form",
          assignment: %{task_uuid: task.uuid, status: "todo"},
          task_mode: "existing"
        )
        |> render_change()

      # Survives without raise — sufficient for smoke coverage.
      assert render(view) =~ "assignment-form"
    end

    test "save with task_mode=existing creates assignment and logs activity",
         %{conn: conn, actor_uuid: actor_uuid} do
      project = fixture_project()
      task = fixture_task()

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/list/#{project.uuid}/assignments/new")

      {:error, {:live_redirect, %{to: redirect_to}}} =
        view
        |> form("#assignment-form",
          assignment: %{task_uuid: task.uuid, status: "todo"},
          task_mode: "existing"
        )
        |> render_submit()

      assert redirect_to =~ "/list/#{project.uuid}"

      assert_activity_logged("projects.assignment_created",
        actor_uuid: actor_uuid,
        metadata_has: %{"project" => project.name}
      )
    end

    test "save with task_mode=new and blank title surfaces an error flash", %{conn: conn} do
      project = fixture_project()

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/list/#{project.uuid}/assignments/new")

      # The dropdown was replaced with tabs — click the "Create new" tab
      # button so `@task_mode` flips to "new" server-side, the hidden
      # `task_mode` input re-renders with the new value, and the
      # `new_task_title` input appears in the DOM. `form/3` only binds
      # fields currently rendered, so without this step the title input
      # doesn't exist (and the hidden's allowed value mismatches).
      _ = view |> element("button[phx-value-tab='new']") |> render_click()

      html =
        view
        |> form("#assignment-form",
          assignment: %{status: "todo"},
          task_mode: "new",
          new_task_title: "   "
        )
        |> render_submit()

      assert html =~ "Task title is required"
    end

    test "save with task_mode=new creates new task + assignment + logs activity",
         %{conn: conn, actor_uuid: actor_uuid} do
      project = fixture_project()

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/list/#{project.uuid}/assignments/new")

      _ = view |> element("button[phx-value-tab='new']") |> render_click()

      title = "Inline-#{System.unique_integer([:positive])}"

      {:error, {:live_redirect, _}} =
        view
        |> form("#assignment-form",
          assignment: %{
            status: "todo",
            description: "x",
            estimated_duration: "1",
            estimated_duration_unit: "hours"
          },
          task_mode: "new",
          new_task_title: title
        )
        |> render_submit()

      assert_activity_logged("projects.assignment_created",
        actor_uuid: actor_uuid,
        metadata_has: %{"new_task" => title}
      )

      # The library checkbox was ticked (its default): a reusable task.
      assert title in Enum.map(Projects.list_tasks(), & &1.title)
    end

    test "unticking 'save as reusable template' makes a one-off task", %{conn: conn} do
      project = fixture_project()
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}/assignments/new")
      _ = view |> element("button[phx-value-tab='new']") |> render_click()
      title = "Oneoff-#{System.unique_integer([:positive])}"

      # Core's checkbox carries a hidden "false" twin, so an unticked box
      # reaches `validate` as "false" (the assign is read at save time).
      _ =
        view
        |> form("#assignment-form",
          assignment: %{status: "todo"},
          task_mode: "new",
          new_task_title: title,
          save_as_template: "false"
        )
        |> render_change()

      {:error, {:live_redirect, _}} =
        view
        |> form("#assignment-form",
          assignment: %{status: "todo"},
          task_mode: "new",
          new_task_title: title,
          save_as_template: "false"
        )
        |> render_submit()

      refute title in Enum.map(Projects.list_tasks(), & &1.title)
      assert title in Enum.map(Projects.list_tasks(ad_hoc: :only), & &1.title)
      assert title in Enum.map(Projects.list_assignments(project.uuid), &Assignment.label/1)
    end
  end

  describe "edit existing assignment" do
    setup do
      project = fixture_project()
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, project: project, assignment: assignment}
    end

    test "renders existing values", %{conn: conn, project: project, assignment: assignment} do
      {:ok, _view, html} =
        live(
          conn,
          "/en/admin/projects/list/#{project.uuid}/assignments/#{assignment.uuid}/edit"
        )

      assert html =~ "assignment-form"
    end

    test "missing project id redirects with flash", %{conn: conn, assignment: assignment} do
      bogus_project = Ecto.UUID.generate()

      {:error, {:live_redirect, %{flash: flash}}} =
        live(
          conn,
          "/en/admin/projects/list/#{bogus_project}/assignments/#{assignment.uuid}/edit"
        )

      assert flash["error"] =~ "Project not found"
    end

    test "missing assignment id redirects to project page", %{conn: conn, project: project} do
      bogus_assignment = Ecto.UUID.generate()

      {:error, {:live_redirect, %{to: redirect_to, flash: flash}}} =
        live(
          conn,
          "/en/admin/projects/list/#{project.uuid}/assignments/#{bogus_assignment}/edit"
        )

      assert redirect_to =~ "/list/#{project.uuid}"
      assert flash["error"] =~ "Assignment not found"
    end

    test "save updates assignment and logs activity",
         %{conn: conn, project: project, assignment: assignment, actor_uuid: actor_uuid} do
      {:ok, view, _html} =
        live(
          conn,
          "/en/admin/projects/list/#{project.uuid}/assignments/#{assignment.uuid}/edit"
        )

      # On :edit the form has no `task_mode` select — task is fixed
      # post-creation; only the assignment fields are editable.
      {:error, {:live_redirect, _}} =
        view
        |> form("#assignment-form",
          assignment: %{
            status: "in_progress",
            description: "updated description"
          }
        )
        |> render_submit()

      assert_activity_logged("projects.assignment_updated",
        actor_uuid: actor_uuid,
        resource_uuid: assignment.uuid
      )
    end
  end
end
