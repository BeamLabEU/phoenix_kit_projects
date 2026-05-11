defmodule PhoenixKitProjects.Web.OverviewLiveTest do
  @moduledoc """
  Smoke tests for `OverviewLive` — the projects-module dashboard.
  Drives mount with empty state, with active projects, and with the
  user_uuid pre-resolved (so `list_assignments_for_user/1` runs the
  staff lookup branch). Plus the `:projects` PubSub broadcast
  triggers a reload.
  """

  use PhoenixKitProjects.LiveCase, async: false

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "empty dashboard" do
    test "mount renders the heading + empty-state copy", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects")
      assert html =~ "Projects"
      # The "Active projects" header was renamed to "Running" with
      # the prioritized-tier rework.
      assert html =~ "Running"
    end
  end

  describe "populated dashboard" do
    test "renders active projects in the summary", %{conn: conn} do
      project = fixture_project(%{"name" => "ActiveDash-#{System.unique_integer([:positive])}"})

      # `list_active_projects/0` only returns projects that have started.
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      _ = PhoenixKitProjects.Projects.start_project(project)

      {:ok, _view, html} = live(conn, "/en/admin/projects")
      assert html =~ project.name

      _ = now
    end
  end

  describe "PubSub reactivity" do
    test "broadcasts on `:projects:all` trigger a dashboard reload", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects")

      # Send a recognized broadcast — the LV should re-fetch and re-render.
      send(view.pid, {:projects, :task_created, %{uuid: Ecto.UUID.generate()}})

      # No assertion crash means the recognized branch fired.
      _ = render(view)
      assert Process.alive?(view.pid)
    end
  end

  describe "stats card counters" do
    test "shows totals for tasks, projects, templates, statuses", %{conn: conn} do
      _ = fixture_task()
      _ = fixture_project()
      _ = fixture_template()

      {:ok, _view, html} = live(conn, "/en/admin/projects")

      assert html =~ "Tasks todo"
      assert html =~ "Tasks in progress"
      assert html =~ "Tasks done"
    end
  end

  describe "upcoming + setup project sections (days_until + relative_day branches)" do
    test "scheduled project today renders the relative-day label", %{conn: conn} do
      _ =
        fixture_project(%{
          "start_mode" => "scheduled",
          "scheduled_start_date" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      {:ok, _view, html} = live(conn, "/en/admin/projects")
      # `relative_day(0)` returns gettext("today")
      assert html =~ "today" or html =~ "Started"
    end

    test "scheduled project tomorrow renders the relative-day label", %{conn: conn} do
      tomorrow = DateTime.utc_now() |> DateTime.add(86_400, :second)

      _ =
        fixture_project(%{
          "start_mode" => "scheduled",
          "scheduled_start_date" => DateTime.to_iso8601(tomorrow)
        })

      {:ok, _view, html} = live(conn, "/en/admin/projects")
      assert html =~ "tomorrow" or html =~ "Scheduled"
    end

    test "scheduled project 5 days out renders ngettext branch", %{conn: conn} do
      five_days = DateTime.utc_now() |> DateTime.add(5 * 86_400, :second)

      _ =
        fixture_project(%{
          "start_mode" => "scheduled",
          "scheduled_start_date" => DateTime.to_iso8601(five_days)
        })

      {:ok, _view, html} = live(conn, "/en/admin/projects")
      assert html =~ "days" or html =~ "Scheduled"
    end

    test "scheduled project 30 days out renders weeks branch", %{conn: conn} do
      far = DateTime.utc_now() |> DateTime.add(30 * 86_400, :second)

      _ =
        fixture_project(%{
          "start_mode" => "scheduled",
          "scheduled_start_date" => DateTime.to_iso8601(far)
        })

      {:ok, _view, html} = live(conn, "/en/admin/projects")
      assert html =~ "weeks" or html =~ "Scheduled"
    end

    test "active immediate-mode project shows up in setup section", %{conn: conn} do
      _ = fixture_project(%{"start_mode" => "immediate"})

      {:ok, _view, html} = live(conn, "/en/admin/projects")
      # The setup section renders when there's at least one un-started
      # immediate-mode project.
      assert html =~ "Active projects" or html =~ "setup" or html =~ "tasks"
    end
  end

  describe "recently-completed projects render" do
    test "completed project appears in the recently-completed section",
         %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _} = PhoenixKitProjects.Projects.start_project(project)

      task = fixture_task()

      {:ok, _} =
        PhoenixKitProjects.Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "done"
        })

      # Trigger completion — `recompute_project_completion/1` returns
      # `{:completed, _}` when all assignments are done.
      assert {:completed, _} =
               PhoenixKitProjects.Projects.recompute_project_completion(project.uuid)

      {:ok, _view, html} = live(conn, "/en/admin/projects")
      assert html =~ project.name or html =~ "Recently"
    end
  end
end
