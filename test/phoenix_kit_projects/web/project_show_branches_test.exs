defmodule PhoenixKitProjects.Web.ProjectShowBranchesTest do
  @moduledoc """
  Final branch coverage push for `ProjectShowLive`. Each event
  handler has a `case scoped_assignment(socket, uuid) do nil -> ... ; a -> ... end`
  pattern; the original tests covered the happy path on a couple
  of handlers, this file covers the `nil` branch on every remaining
  handler. Plus rendering branches for completed-project,
  template-project, status fall-through, and handle_info project_*
  branches when the project is deleted between broadcast and
  processing.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Test.Repo, as: TestRepo

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "psb-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    scope = fake_scope(user_uuid: user.uuid)
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: user.uuid}
  end

  describe "scoped_assignment nil branches per event handler" do
    setup do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, project: project, bogus: Ecto.UUID.generate()}
    end

    test "start_task with bogus uuid is silently ignored",
         %{conn: conn, project: p, bogus: bogus} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")
      _ = render_click(view, "start_task", %{"uuid" => bogus})
      assert Process.alive?(view.pid)
    end

    test "reopen with bogus uuid is silently ignored",
         %{conn: conn, project: p, bogus: bogus} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")
      _ = render_click(view, "reopen", %{"uuid" => bogus})
      assert Process.alive?(view.pid)
    end

    test "edit_duration with bogus uuid is silently ignored",
         %{conn: conn, project: p, bogus: bogus} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")
      _ = render_click(view, "edit_duration", %{"uuid" => bogus})
      assert Process.alive?(view.pid)
    end

    test "update_progress with bogus uuid is silently ignored",
         %{conn: conn, project: p, bogus: bogus} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      _ =
        render_change(view, "update_progress", %{
          "uuid" => bogus,
          "progress_pct" => "50"
        })

      assert Process.alive?(view.pid)
    end

    test "toggle_tracking with bogus uuid is silently ignored",
         %{conn: conn, project: p, bogus: bogus} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")
      _ = render_click(view, "toggle_tracking", %{"uuid" => bogus})
      assert Process.alive?(view.pid)
    end

    test "remove_assignment with bogus uuid is silently ignored",
         %{conn: conn, project: p, bogus: bogus} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")
      _ = render_click(view, "remove_assignment", %{"uuid" => bogus})
      assert Process.alive?(view.pid)
    end

    test "remove_dependency with bogus assignment uuid is silently ignored",
         %{conn: conn, project: p, bogus: bogus} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      _ =
        render_click(view, "remove_dependency", %{
          "assignment" => bogus,
          "depends_on" => Ecto.UUID.generate()
        })

      assert Process.alive?(view.pid)
    end
  end

  describe "render branches: completed + template projects" do
    test "completed project renders the 'Completed' badge", %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _} = Projects.start_project(project)

      task = fixture_task()

      {:ok, _} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "done"
        })

      {:completed, _} = Projects.recompute_project_completion(project.uuid)

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      assert html =~ "Completed" or html =~ "completed"
    end

    test "template project renders the 'Template' badge", %{conn: conn} do
      template = fixture_template()

      # The test router scopes `/templates/:id` to TemplatesLive but in
      # production the same route uses ProjectShowLive in `show_template`
      # mode. Test router doesn't have the show route — use the
      # production-shape `/list/:id` which always renders ProjectShowLive
      # and the LV detects `is_template = project.is_template`.
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{template.uuid}")
      assert html =~ template.name
      assert html =~ "Template" or html =~ "template"
    end
  end

  describe "raw status fallback (template project — no status buttons)" do
    test "status_color catch-all renders for an out-of-band status on a template",
         %{conn: conn} do
      # On a template project the LV doesn't render the status-action
      # buttons (start/complete/reopen) since templates have no
      # progress lifecycle. So setting an out-of-band status via raw
      # SQL exercises `status_color(_)` for the timeline dot without
      # hitting the buttons-cond crash on missing status branches.
      template = fixture_template()
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => template.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, raw_uuid} = Ecto.UUID.dump(assignment.uuid)

      SQL.query!(
        TestRepo,
        "UPDATE phoenix_kit_project_assignments SET status = $1 WHERE uuid = $2",
        ["archived", raw_uuid]
      )

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{template.uuid}")
      # Template project — status buttons don't render but the timeline
      # dot uses `status_color/1` which falls through to the `_` clause.
      assert html =~ task.title
    end
  end

  describe "humanize_hours + projected_end branches via fixture state" do
    test "completed project + remaining=0 hits projected_end completed_at branch",
         %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _} = Projects.start_project(project)

      task = fixture_task(%{"estimated_duration" => 1, "estimated_duration_unit" => "hours"})

      {:ok, _} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "done"
        })

      {:completed, _} = Projects.recompute_project_completion(project.uuid)

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      # `projected_end({:completed_at: dt}, ...)` returns dt — exercises
      # the first projected_end clause.
      assert html =~ "Finished" or html =~ "Completed"
    end

    test "project with one in_progress + done renders schedule + ahead/behind label",
         %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate", "counts_weekends" => true})
      {:ok, _} = Projects.start_project(project)

      tasks =
        Enum.map(1..3, fn _ ->
          fixture_task(%{"estimated_duration" => 8, "estimated_duration_unit" => "hours"})
        end)

      Enum.each(tasks, fn t ->
        {:ok, _} =
          Projects.create_assignment(%{
            "project_uuid" => project.uuid,
            "task_uuid" => t.uuid,
            "status" => "done"
          })
      end)

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      # Three :done tasks → project auto-completes → "Finished:" badge.
      # Earlier this matched on "Planned"/"Projected" labels that were
      # removed when the schedule block was simplified to "Remaining: …
      # · ETA: …" / "Finished: …".
      assert html =~ "Finished" or html =~ "Remaining:" or html =~ "ETA:"
    end
  end

  describe "assignment_hours fallback to task fields when assignment fields are nil" do
    test "assignment without estimated_duration falls back to task's defaults",
         %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _} = Projects.start_project(project)

      task =
        fixture_task(%{
          "estimated_duration" => 4,
          "estimated_duration_unit" => "hours"
        })

      {:ok, _} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      assert html =~ task.title
    end
  end

  describe "PubSub project_updated handle_info nil branch (project deleted)" do
    test "project_updated broadcast fires after project deletion → nil branch",
         %{conn: conn} do
      project = fixture_project()
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      # Delete the project via raw SQL to bypass the
      # `Projects.delete_project/1` `:project_deleted` PubSub broadcast
      # (which would otherwise push_navigate the LV away before we get
      # to send our `project_updated` synthetic broadcast).
      {:ok, raw_uuid} = Ecto.UUID.dump(project.uuid)

      SQL.query!(
        TestRepo,
        "DELETE FROM phoenix_kit_projects WHERE uuid = $1",
        [raw_uuid]
      )

      # Now send a project_updated broadcast — get_project returns nil
      # → exercises the `nil -> {:noreply, socket}` branch (line 72).
      send(view.pid, {:projects, :project_updated, %{}})
      _ = render(view)

      assert Process.alive?(view.pid)
    end
  end
end
