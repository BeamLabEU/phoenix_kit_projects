defmodule PhoenixKitProjects.Web.ListLVsTest do
  @moduledoc """
  Event-handler coverage for the three list LVs (`ProjectsLive`,
  `TasksLive`, `TemplatesLive`). Pins:

  - mount with empty + populated state
  - `delete` on existing record (success + activity log)
  - `delete` on missing uuid (not-found flash)

  All three LVs share the same shape; one test file keeps the
  fixtures cheap.
  """

  use PhoenixKitProjects.LiveCase, async: false

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "ProjectsLive" do
    test "mount renders the projects list page", %{conn: conn} do
      p = fixture_project(%{"name" => "Listed-#{System.unique_integer([:positive])}"})

      {:ok, _view, html} = live(conn, "/en/admin/projects/list")
      assert html =~ p.name
    end

    test "delete on missing uuid surfaces a flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list")
      bogus = Ecto.UUID.generate()

      html = render_click(view, "delete", %{"uuid" => bogus})
      assert html =~ "Project not found"
    end

    test "delete on existing project logs activity + removes from list",
         %{conn: conn, actor_uuid: actor_uuid} do
      project = fixture_project()

      {:ok, view, _html} = live(conn, "/en/admin/projects/list")

      html = render_click(view, "delete", %{"uuid" => project.uuid})

      assert html =~ "Project deleted"

      assert_activity_logged("projects.project_deleted",
        actor_uuid: actor_uuid,
        resource_uuid: project.uuid,
        metadata_has: %{"name" => project.name}
      )
    end
  end

  describe "TasksLive" do
    test "mount renders the tasks list page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/tasks")
      assert html =~ "No tasks yet."
    end

    test "delete on missing uuid surfaces a flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")
      html = render_click(view, "delete", %{"uuid" => Ecto.UUID.generate()})
      assert html =~ "Task not found"
    end

    test "delete on existing task logs activity",
         %{conn: conn, actor_uuid: actor_uuid} do
      task = fixture_task()

      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")

      html = render_click(view, "delete", %{"uuid" => task.uuid})

      assert html =~ "Task deleted"

      assert_activity_logged("projects.task_deleted",
        actor_uuid: actor_uuid,
        resource_uuid: task.uuid,
        metadata_has: %{"title" => task.title}
      )
    end
  end

  describe "TemplatesLive" do
    test "mount renders the templates list page", %{conn: conn} do
      # No in-content header row anymore (the create action lives in the
      # admin breadcrumb + the list's add-row) — pin the empty state.
      {:ok, _view, html} = live(conn, "/en/admin/projects/templates")
      assert html =~ "No templates yet."
    end

    test "breadcrumb producer contract: page_title + page_action reach the layout", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, "/en/admin/projects/templates")

      # The test layout renders these fixture consumers — see
      # test/support/test_layouts.ex. Core's admin layout is the real
      # consumer (breadcrumb "+" button); this pins the producer half.
      assert html =~ ~s(data-page-title="Project Templates")
      assert html =~ ~r{data-crumb-action[^>]*href="[^"]*templates/new"}
    end

    test "delete on missing uuid surfaces a flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/templates")
      html = render_click(view, "delete", %{"uuid" => Ecto.UUID.generate()})
      assert html =~ "Template not found"
    end

    test "delete on existing template logs activity",
         %{conn: conn, actor_uuid: actor_uuid} do
      template = fixture_template()

      {:ok, view, _html} = live(conn, "/en/admin/projects/templates")

      html = render_click(view, "delete", %{"uuid" => template.uuid})

      assert html =~ "Template deleted"

      assert_activity_logged("projects.template_deleted",
        actor_uuid: actor_uuid,
        resource_uuid: template.uuid,
        metadata_has: %{"name" => template.name}
      )
    end
  end
end
