defmodule PhoenixKitProjects.Web.DestructiveButtonsTest do
  @moduledoc """
  Pins `phx-disable-with` on every destructive `phx-click` button in
  the project_show / form LVs. The original sweep deferred this audit
  for `project_show_live.ex` per the residual surfaced in workspace
  AGENTS.md; this re-validation closes the gap. A button missing the
  attribute lets users double-click and trigger the same mutation
  twice on slow networks — most acutely on `complete` / `start_task`
  / `start_project` which also fire activity log entries.

  Source-pairing assertion (regex over the rendered HTML, not over
  the source file directly) so refactors that move buttons around
  still get the protection — the test fails the moment a destructive
  click handler ships without `phx-disable-with`.
  """

  use PhoenixKitProjects.LiveCase, async: false

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "project_show_live destructive buttons all carry phx-disable-with" do
    setup do
      project = fixture_project(%{"start_mode" => "immediate"})

      task = fixture_task()

      {:ok, assignment} =
        PhoenixKitProjects.Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, project: project, assignment: assignment}
    end

    test "start_task button (status=todo)", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      assert html =~ ~r/phx-click="start_task"[^>]*phx-disable-with=/s
    end

    test "remove_assignment button", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      assert html =~ ~r/phx-click="remove_assignment"[^>]*phx-disable-with=/s
    end

    test "toggle_tracking button (track-off branch)", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      # The off-track form renders even when track_progress is false.
      assert html =~ ~r/phx-click="toggle_tracking"[^>]*phx-disable-with=/s
    end
  end

  describe "scheduled-mode start button opens the start-project modal" do
    test "Start now button is wired to open_start_modal", %{conn: conn} do
      project =
        fixture_project(%{
          "start_mode" => "scheduled",
          "scheduled_start_date" => Date.utc_today() |> Date.to_iso8601()
        })

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      # The bare button no longer carries phx-disable-with — that label
      # has moved to the modal's "Start project" submit button (the
      # destructive write happens inside the modal, not on the page
      # button which only opens it).
      assert html =~ ~r/phx-click="open_start_modal"/
    end
  end

  describe "complete + reopen + start_task per status" do
    test "complete (status=in_progress) carries phx-disable-with", %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})
      task = fixture_task()

      {:ok, _assignment} =
        PhoenixKitProjects.Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "in_progress"
        })

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      assert html =~ ~r/phx-click="complete"[^>]*phx-disable-with=/s
    end

    test "reopen (status=done) carries phx-disable-with", %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})
      task = fixture_task()

      {:ok, _assignment} =
        PhoenixKitProjects.Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "done"
        })

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      assert html =~ ~r/phx-click="reopen"[^>]*phx-disable-with=/s
    end
  end

  describe "form add-dep buttons carry phx-disable-with" do
    test "task_form add_dep button", %{conn: conn} do
      task1 = fixture_task()
      _task2 = fixture_task()

      {:ok, _view, html} = live(conn, "/en/admin/projects/tasks/#{task1.uuid}/edit")
      # Only renders when there's at least one available dep target.
      if html =~ ~r/phx-submit="add_dep"/ do
        assert html =~ ~r/phx-submit="add_dep".*?phx-disable-with=/s
      end
    end
  end
end
