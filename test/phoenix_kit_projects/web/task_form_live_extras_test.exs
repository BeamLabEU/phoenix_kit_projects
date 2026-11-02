defmodule PhoenixKitProjects.Web.TaskFormLiveExtrasTest do
  @moduledoc """
  Coverage extension for `TaskFormLive` — the original sweep covered
  mount + validate + Errors translation. This file adds:

  - save (new + edit) success/error
  - add_dep / remove_dep handler coverage
  - assign_type toggling (validate event branches)
  - clear_other_default_assignees branches
  - missing-task redirect on edit
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitStaff.Schemas.Department

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "new task save" do
    test "successful save logs activity + redirects", %{conn: conn, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/new")

      title = "T-#{System.unique_integer([:positive])}"

      {:error, {:live_redirect, _}} =
        view
        |> form("#task-form",
          task: %{
            title: title,
            estimated_duration: "1",
            estimated_duration_unit: "hours"
          }
        )
        |> render_submit(%{"task" => %{"description" => ""}})

      assert_activity_logged("projects.task_created",
        actor_uuid: actor_uuid,
        metadata_has: %{"title" => title}
      )
    end
  end

  describe "edit task save + missing redirect" do
    test "missing task id redirects to tasks list with flash", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      {:error, {:live_redirect, %{to: redirect_to, flash: flash}}} =
        live(conn, "/en/admin/projects/tasks/#{bogus}/edit")

      assert redirect_to =~ "/tasks"
      assert flash["error"] =~ "Task not found"
    end

    test "save updates and logs activity", %{conn: conn, actor_uuid: actor_uuid} do
      task = fixture_task()

      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/#{task.uuid}/edit")

      new_title = "Renamed-#{System.unique_integer([:positive])}"

      {:error, {:live_redirect, _}} =
        view
        |> form("#task-form",
          task: %{
            title: new_title,
            estimated_duration: "2",
            estimated_duration_unit: "hours"
          }
        )
        |> render_submit(%{"task" => %{"description" => "d"}})

      assert_activity_logged("projects.task_updated",
        actor_uuid: actor_uuid,
        resource_uuid: task.uuid,
        metadata_has: %{"title" => new_title}
      )
    end
  end

  describe "task dependency handlers" do
    setup do
      task_a = fixture_task()
      task_b = fixture_task()
      {:ok, task_a: task_a, task_b: task_b}
    end

    test "add_dep adds a template-level dependency + logs activity",
         %{conn: conn, task_a: a, task_b: b, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/#{a.uuid}/edit")

      _ =
        render_submit(view, "add_dep", %{
          "depends_on_task_uuid" => b.uuid
        })

      assert [_dep] = Projects.list_task_dependencies(a.uuid)

      assert_activity_logged("projects.task_dependency_added",
        actor_uuid: actor_uuid,
        resource_uuid: a.uuid,
        metadata_has: %{"task" => a.title}
      )
    end

    test "add_dep with empty uuid is silently ignored", %{conn: conn, task_a: a} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/#{a.uuid}/edit")

      _ =
        render_submit(view, "add_dep", %{
          "depends_on_task_uuid" => ""
        })

      assert Projects.list_task_dependencies(a.uuid) == []
    end

    test "remove_dep removes the dep + logs activity",
         %{conn: conn, task_a: a, task_b: b, actor_uuid: actor_uuid} do
      {:ok, _} = Projects.add_task_dependency(a.uuid, b.uuid)

      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/#{a.uuid}/edit")

      _ = render_click(view, "remove_dep", %{"uuid" => b.uuid})

      assert Projects.list_task_dependencies(a.uuid) == []

      assert_activity_logged("projects.task_dependency_removed",
        actor_uuid: actor_uuid,
        resource_uuid: a.uuid
      )
    end
  end

  describe "validate event toggles assign_type" do
    # The default assignee is the task popup's picker now: the kind rides a
    # hidden input, so these drive the event as the picker posts it.
    for kind <- ~w(team department person) do
      test "validate with default_assign_type=#{kind}", %{conn: conn} do
        task = fixture_task()
        {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/#{task.uuid}/edit")

        render_change(view, "validate", %{
          "task" => %{
            "title" => task.title,
            "estimated_duration" => "1",
            "estimated_duration_unit" => "hours"
          },
          "default_assign_type" => unquote(kind)
        })

        assert Process.alive?(view.pid)
      end
    end

    test "the default assignee is picked with the shared picker and saved", %{conn: conn} do
      task = fixture_task()

      dept =
        Repo.insert!(%Department{
          name: "Paigaldus #{System.unique_integer([:positive])}"
        })

      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/#{task.uuid}/edit")

      assert has_element?(view, "#task-default-assignee-search")
      render_click(view, "assignee_pick", %{"kind" => "department", "uuid" => dept.uuid})
      assert has_element?(view, "#task-default-assignee-chips", dept.name)

      view |> form("#task-form") |> render_submit()
      assert Projects.get_task(task.uuid).default_assigned_department_uuid == dept.uuid
    end
  end
end
