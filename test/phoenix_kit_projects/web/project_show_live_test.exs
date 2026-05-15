defmodule PhoenixKitProjects.Web.ProjectShowLiveTest do
  @moduledoc """
  Event-handler coverage for `ProjectShowLive` — the largest LV in
  the module (~1100 lines). Pins:

  - mount happy + not-found redirect
  - status transitions: complete / start_task / reopen
  - inline duration editing: edit_duration / cancel_edit_duration / save_duration
  - remove_assignment + remove_dependency + start_project
  - toggle_tracking + update_progress
  - bogus uuid scoping (cross-project crafted-event guard)
  - PubSub `handle_info` recognized branches (assignment_*, project_*, task_*)
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    # Use a real registered user — the `complete` / `reopen` paths
    # set `completed_by_uuid` which is FK to `phoenix_kit_users(uuid)`.
    # A bare UUIDv4 from `fake_scope/0` raises Ecto.ConstraintError on
    # write. Pattern mirrored from the existing integration suite's
    # `real_user_uuid!/0` helper.
    {:ok, user} =
      Auth.register_user(%{
        "email" => "ps-actor-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    scope = fake_scope(user_uuid: user.uuid)
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: user.uuid}
  end

  describe "mount" do
    test "renders project name + timeline empty state", %{conn: conn} do
      project = fixture_project()

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      assert html =~ project.name
      assert html =~ "No tasks in this project yet."
    end

    test "renders timeline when project has assignments", %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})
      task = fixture_task()

      {:ok, _} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      assert html =~ task.title
    end

    test "missing project flashes + redirects to projects list", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      {:error, {:live_redirect, %{to: redirect_to, flash: flash}}} =
        live(conn, "/en/admin/projects/list/#{bogus}")

      assert redirect_to =~ "/list"
      assert flash["error"] =~ "Project not found"
    end
  end

  # Issue #5: host apps embed `ProjectShowLive` via `live_render` so any
  # upstream timeline / dependency / comments improvement lands in their
  # workflow without re-implementation. `live_isolated/3` is the test-side
  # equivalent — it mounts the LV with `params == :not_mounted_at_router`
  # and the session map flowing into `mount/3`.
  describe "embedded (live_isolated)" do
    test "mounts when given id via session and renders project name", %{conn: conn} do
      project = fixture_project()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: %{"id" => project.uuid}
        )

      assert html =~ project.name
    end

    test "wrapper_class defaults to the standalone full-width layout", %{conn: conn} do
      project = fixture_project()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: %{"id" => project.uuid}
        )

      assert html =~ "flex flex-col w-full px-4 py-6 gap-4"
    end

    test "wrapper_class override from session replaces the default", %{conn: conn} do
      project = fixture_project()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: %{
            "id" => project.uuid,
            "wrapper_class" => "host-specific-class"
          }
        )

      assert html =~ "host-specific-class"
      refute html =~ "flex flex-col w-full px-4 py-6 gap-4"
    end

    test "locale from session is applied to embedded mount", %{conn: conn} do
      project = fixture_project()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: %{
            "id" => project.uuid,
            "locale" => "et"
          }
        )

      # The back-link breadcrumb renders "Projects" translated.
      assert html =~ "Projektid"
      refute html =~ "Projects"
    end
  end

  describe "status-transition events" do
    setup do
      project = fixture_project(%{"start_mode" => "immediate"})

      {:ok, _} = Projects.start_project(project)
      project = Projects.get_project!(project.uuid)

      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, project: project, assignment: assignment, task: task}
    end

    test "start_task sets status to in_progress + logs activity",
         %{conn: conn, project: project, assignment: a, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      _ = render_click(view, "start_task", %{"uuid" => a.uuid})

      reread = Projects.get_assignment(a.uuid)
      assert reread.status == "in_progress"

      assert_activity_logged("projects.assignment_started",
        actor_uuid: actor_uuid,
        resource_uuid: a.uuid
      )
    end

    test "complete sets status to done + logs activity",
         %{conn: conn, project: project, assignment: a, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      _ = render_click(view, "complete", %{"uuid" => a.uuid})

      reread = Projects.get_assignment(a.uuid)
      assert reread.status == "done"
      assert reread.progress_pct == 100

      assert_activity_logged("projects.assignment_completed",
        actor_uuid: actor_uuid,
        resource_uuid: a.uuid
      )
    end

    test "reopen reverts done → todo + clears completion",
         %{conn: conn, project: project, assignment: a, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      _ = render_click(view, "complete", %{"uuid" => a.uuid})
      _ = render_click(view, "reopen", %{"uuid" => a.uuid})

      reread = Projects.get_assignment(a.uuid)
      assert reread.status == "todo"
      assert reread.progress_pct == 0
      assert reread.completed_by_uuid == nil

      assert_activity_logged("projects.assignment_reopened",
        actor_uuid: actor_uuid,
        resource_uuid: a.uuid
      )
    end

    test "scoped_assignment guard: bogus uuid is silently ignored",
         %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      # Crafted uuid that doesn't belong to this project — must NOT raise.
      _ = render_click(view, "complete", %{"uuid" => Ecto.UUID.generate()})
      assert Process.alive?(view.pid)
    end

    test "cross-project assignment uuid is rejected by scoped_assignment",
         %{conn: conn, project: project} do
      # Create a SECOND project with its own assignment, then try to
      # complete it from project A's LV.
      other_project = fixture_project(%{"start_mode" => "immediate"})
      task = fixture_task()

      {:ok, other_assignment} =
        Projects.create_assignment(%{
          "project_uuid" => other_project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      _ = render_click(view, "complete", %{"uuid" => other_assignment.uuid})

      # Other-project assignment must remain untouched.
      reread = Projects.get_assignment(other_assignment.uuid)
      assert reread.status == "todo"
    end
  end

  describe "duration editing" do
    setup do
      project = fixture_project(%{"start_mode" => "immediate"})
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo",
          "estimated_duration" => 2,
          "estimated_duration_unit" => "hours"
        })

      {:ok, project: project, assignment: assignment}
    end

    test "edit_duration assigns the editing_duration_uuid", %{
      conn: conn,
      project: p,
      assignment: a
    } do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      html = render_click(view, "edit_duration", %{"uuid" => a.uuid})
      assert html =~ "phx-submit=\"save_duration\""
    end

    test "cancel_edit_duration clears the editing state", %{conn: conn, project: p, assignment: a} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      _ = render_click(view, "edit_duration", %{"uuid" => a.uuid})
      _ = render_click(view, "cancel_edit_duration", %{})

      assert Process.alive?(view.pid)
    end

    test "save_duration persists + logs activity",
         %{conn: conn, project: p, assignment: a, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      _ = render_click(view, "edit_duration", %{"uuid" => a.uuid})

      _ =
        render_submit(view, "save_duration", %{
          "estimated_duration" => "5",
          "estimated_duration_unit" => "days"
        })

      reread = Projects.get_assignment(a.uuid)
      assert reread.estimated_duration == 5
      assert reread.estimated_duration_unit == "days"

      assert_activity_logged("projects.assignment_duration_changed",
        actor_uuid: actor_uuid,
        resource_uuid: a.uuid
      )
    end
  end

  describe "remove_assignment + start_project + toggle_tracking + remove_dependency" do
    setup do
      project = fixture_project(%{"start_mode" => "immediate"})
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

    test "remove_assignment deletes + logs",
         %{conn: conn, project: p, a1: a, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      _ = render_click(view, "remove_assignment", %{"uuid" => a.uuid})

      assert Projects.get_assignment(a.uuid) == nil

      assert_activity_logged("projects.assignment_removed",
        actor_uuid: actor_uuid,
        resource_uuid: a.uuid
      )
    end

    test "open_start_modal → confirm_start_project stamps started_at + logs",
         %{conn: conn, actor_uuid: actor_uuid} do
      project = fixture_project(%{"start_mode" => "immediate"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      # Page button opens the modal — no DB write here.
      _ = render_click(view, "open_start_modal", %{})

      reread = Projects.get_project!(project.uuid)
      assert reread.started_at == nil

      # Submitting the modal's form with today's datetime stamps started_at.
      # `<input type="datetime-local">` posts "YYYY-MM-DDTHH:mm" — same
      # shape the LV's `parse_start_at/1` accepts (UTC, no offset).
      today =
        NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()

      _ = render_click(view, "confirm_start_project", %{"start_at" => today})

      reread = Projects.get_project!(project.uuid)
      assert reread.started_at != nil
      assert DateTime.to_date(reread.started_at) == Date.utc_today()

      assert_activity_logged("projects.project_started",
        actor_uuid: actor_uuid,
        resource_uuid: project.uuid
      )
    end

    test "confirm_start_project accepts a backdated date", %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})

      backdated =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-7 * 86_400, :second)
        |> NaiveDateTime.truncate(:second)
        |> NaiveDateTime.to_iso8601()

      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      _ = render_click(view, "open_start_modal", %{})
      _ = render_click(view, "confirm_start_project", %{"start_at" => backdated})

      reread = Projects.get_project!(project.uuid)
      assert reread.started_at != nil
      assert DateTime.to_date(reread.started_at) == Date.utc_today() |> Date.add(-7)
    end

    test "toggle_tracking flips track_progress + logs",
         %{conn: conn, project: p, a1: a, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      _ = render_click(view, "toggle_tracking", %{"uuid" => a.uuid})

      reread = Projects.get_assignment(a.uuid)
      assert reread.track_progress == true

      assert_activity_logged("projects.assignment_tracking_toggled",
        actor_uuid: actor_uuid,
        resource_uuid: a.uuid
      )
    end

    test "update_progress updates the progress_pct",
         %{conn: conn, project: p, a1: a} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      # update_progress uses phx-change on a form — drive it via render_change.
      _ =
        render_change(view, "update_progress", %{
          "uuid" => a.uuid,
          "progress_pct" => "50"
        })

      reread = Projects.get_assignment(a.uuid)
      assert reread.progress_pct == 50
    end

    test "remove_dependency unlinks an existing edge + logs",
         %{conn: conn, project: p, a1: a1, a2: a2, actor_uuid: actor_uuid} do
      {:ok, _} = Projects.add_dependency(a1.uuid, a2.uuid)

      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      _ =
        render_click(view, "remove_dependency", %{
          "assignment" => a1.uuid,
          "depends_on" => a2.uuid
        })

      # Edge is gone.
      assert Projects.list_dependencies(a1.uuid) == []

      assert_activity_logged("projects.dependency_removed",
        actor_uuid: actor_uuid,
        resource_uuid: a1.uuid
      )
    end
  end

  describe "PubSub recognized handle_info branches" do
    setup do
      project = fixture_project()
      {:ok, project: project}
    end

    test "assignment_created/updated/deleted reload the timeline",
         %{conn: conn, project: p} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      send(view.pid, {:projects, :assignment_created, %{uuid: Ecto.UUID.generate()}})
      send(view.pid, {:projects, :assignment_updated, %{uuid: Ecto.UUID.generate()}})
      send(view.pid, {:projects, :assignment_deleted, %{uuid: Ecto.UUID.generate()}})
      send(view.pid, {:projects, :dependency_added, %{}})
      send(view.pid, {:projects, :dependency_removed, %{}})
      send(view.pid, {:projects, :task_updated, %{}})
      send(view.pid, {:projects, :task_deleted, %{}})

      _ = render(view)
      assert Process.alive?(view.pid)
    end

    test "project_updated reloads project + assignments", %{conn: conn, project: p} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      send(view.pid, {:projects, :project_updated, %{}})
      send(view.pid, {:projects, :project_completed, %{}})
      send(view.pid, {:projects, :project_reopened, %{}})
      send(view.pid, {:projects, :project_started, %{}})

      _ = render(view)
      assert Process.alive?(view.pid)
    end

    test "project_deleted flashes + redirects to projects index",
         %{conn: conn, project: p} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      send(view.pid, {:projects, :project_deleted, %{}})

      # The LV pushes a navigate via `push_navigate/2` after putting a
      # flash. `assert_redirect/2` takes a string `to`, so we read it
      # from the redirect tuple — a regex assertion is more permissive.
      assert_redirect(view, "/en/admin/projects/list")
    end
  end
end
