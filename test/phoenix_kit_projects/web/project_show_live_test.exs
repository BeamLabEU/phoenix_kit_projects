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

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitStaff.Schemas.Person

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

  # An off-router mount runs no on_mount, so the LV has no scope and gates
  # :view against the viewer the session names. These embed tests are about
  # layout, locale and tabs — not authz — so give them a viewer who can
  # actually see the project. (The refusal paths have their own tests in
  # embedding_test.exs.)
  defp embed_session(project, actor_uuid, extra \\ %{}) do
    {:ok, _} = PhoenixKitProjects.Members.add_member(project, actor_uuid, role: "member")
    Map.merge(%{"id" => project.uuid, "current_user_uuid" => actor_uuid}, extra)
  end

  describe "mount" do
    test "router mount: no in-content h1 (breadcrumb owns the name) + empty state", %{
      conn: conn
    } do
      project = fixture_project()

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      # The standalone admin page pushes the name into the site
      # breadcrumb (page_title + a linked "Projects" section) — the body
      # renders no h1/name row. The test layout renders the fixture
      # breadcrumb consumers this asserts against.
      refute html =~ "<h1"
      assert html =~ ~s(data-page-title="#{project.name}")
      assert html =~ ~s(data-crumb-section="Projects")
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

      assert redirect_to == PhoenixKitProjects.Paths.projects()
      assert flash["error"] =~ "Project not found"
    end
  end

  # Issue #5: host apps embed `ProjectShowLive` via `live_render` so any
  # upstream timeline / dependency / comments improvement lands in their
  # workflow without re-implementation. `live_isolated/3` is the test-side
  # equivalent — it mounts the LV with `params == :not_mounted_at_router`
  # and the session map flowing into `mount/3`.
  describe "embedded (live_isolated)" do
    test "mounts when given id via session and renders project name", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      project = fixture_project()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: embed_session(project, actor_uuid)
        )

      assert html =~ project.name
    end

    test "wrapper_class defaults to the standalone full-width layout", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      project = fixture_project()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: embed_session(project, actor_uuid)
        )

      assert html =~ "flex flex-col w-full px-4 pt-2 pb-4 gap-4"
    end

    test "wrapper_class override from session replaces the default", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      project = fixture_project()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: embed_session(project, actor_uuid, %{"wrapper_class" => "host-specific-class"})
        )

      assert html =~ "host-specific-class"
      refute html =~ "flex flex-col w-full px-4 py-6 gap-4"
    end

    test "locale from session is applied to embedded mount", %{conn: conn, actor_uuid: actor_uuid} do
      project = fixture_project()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: embed_session(project, actor_uuid, %{"locale" => "et"})
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

    test "remove_dependency rejects an edge whose endpoints are in another project",
         %{conn: conn, project: p} do
      # A second project with its own dependency edge b1 -> b2.
      other = fixture_project(%{"start_mode" => "immediate"})

      {:ok, b1} =
        Projects.create_assignment(%{
          "project_uuid" => other.uuid,
          "task_uuid" => fixture_task().uuid,
          "status" => "todo"
        })

      {:ok, b2} =
        Projects.create_assignment(%{
          "project_uuid" => other.uuid,
          "task_uuid" => fixture_task().uuid,
          "status" => "todo"
        })

      {:ok, _} = Projects.add_dependency(b1.uuid, b2.uuid)

      # Crafted event from project p's LV must NOT touch the other project's edge.
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      _ =
        render_click(view, "remove_dependency", %{
          "assignment" => b1.uuid,
          "depends_on" => b2.uuid
        })

      assert [_] = Projects.list_dependencies(b1.uuid)
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

    test "project_updated re-preloads the assignee (regression: NotLoaded crash)",
         %{conn: conn, actor_uuid: actor_uuid} do
      # A project WITH an assignee: the render derefs @project.assigned_person.user
      # (assignee_label/1). Before the fix the handler reloaded via get_project/1
      # (no preload), so the re-render crashed on the NotLoaded assoc.
      {:ok, person} =
        Repo.insert(%Person{user_uuid: actor_uuid, status: "active"})

      project = fixture_project(%{"assigned_person_uuid" => person.uuid})
      {:ok, view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      assert html =~ "Person"

      send(view.pid, {:projects, :project_updated, %{}})

      # render/1 raises if the LV crashed re-rendering the assignee badge.
      assert render(view) =~ "Person"
      assert Process.alive?(view.pid)
    end

    test "project_deleted flashes + redirects to projects index",
         %{conn: conn, project: p} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      send(view.pid, {:projects, :project_deleted, %{}})

      # The LV pushes a navigate via `push_navigate/2` after putting a
      # flash. phoenix_kit core PR #552 made the primary-locale strip
      # on `Routes.admin_path/2` conditional on the site-wide
      # `default_language_no_prefix` setting (default `false`), so the
      # canonical primary-admin shape is back to `/en/admin/...`.
      assert_redirect(view, "/en/admin/projects")
    end
  end

  describe "workflow status picker (change_workflow_status)" do
    setup do
      PhoenixKitProjects.StatusFixtures.seed_shared_status_entity!()
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, started} = Projects.start_project(project)
      {:ok, project: started}
    end

    test "selecting a valid status sets current_status_slug + logs", %{
      conn: conn,
      project: p,
      actor_uuid: actor_uuid
    } do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      view
      |> element("form[phx-change=change_workflow_status]")
      |> render_change(%{"status_slug" => "backlog"})

      assert Projects.get_project!(p.uuid).current_status_slug == "backlog"

      assert_activity_logged("projects.project_status_changed",
        actor_uuid: actor_uuid,
        resource_uuid: p.uuid,
        metadata_has: %{"status_slug" => "backlog"}
      )
    end

    test "selecting an unknown slug is rejected (no change) + error flash", %{
      conn: conn,
      project: p
    } do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{p.uuid}")

      html =
        view
        |> element("form[phx-change=change_workflow_status]")
        |> render_change(%{"status_slug" => "not-a-real-slug"})

      assert Projects.get_project!(p.uuid).current_status_slug == nil
      assert html =~ "Could not change the status."
    end
  end

  describe "view tabs (list / gantt / calendar)" do
    defp started_project_for_tabs do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _} = Projects.start_project(project)
      project = Projects.get_project!(project.uuid)
      task = fixture_task(%{"estimated_duration" => 2, "estimated_duration_unit" => "days"})

      {:ok, _} =
        Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => task.uuid})

      project
    end

    test "the list route shows the tab bar but does NOT mount the gantt (lazy)", %{conn: conn} do
      project = started_project_for_tabs()
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      assert html =~ ~s(role="tablist")
      assert html =~ "Timeline"
      assert html =~ "Calendar"
      # Lazy: neither nested view is live_rendered until its tab is opened.
      refute html =~ "lg-wrap"
      refute html =~ "cal-container"
    end

    test "the /gantt route opens the gantt tab with the nested chart mounted", %{conn: conn} do
      project = started_project_for_tabs()
      {:ok, view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}/gantt")

      assert html =~ ~s(role="tablist")
      # Same page, gantt tab active → the nested ProjectGanttLive is rendered.
      # Its build is deferred off the first paint, so settle the child LV before
      # asserting the chart (render/1 drains the child's :load_gantt message).
      gantt = find_live_child(view, "project-gantt-live-#{project.uuid}")
      chart = render(gantt)
      assert chart =~ "lg-wrap"
      assert chart =~ "lg-bar"
    end

    test "switch_tab mounts the gantt on first open, then keeps it mounted", %{conn: conn} do
      project = started_project_for_tabs()
      {:ok, view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      refute html =~ "lg-wrap"

      render_click(view, "switch_tab", %{"tab" => "gantt"})
      gantt = find_live_child(view, "project-gantt-live-#{project.uuid}")
      assert render(gantt) =~ "lg-wrap"

      # Switching back hides it (CSS) but keeps it mounted (lazy-once) — the
      # built chart stays in the (hidden) DOM.
      html = render_click(view, "switch_tab", %{"tab" => "list"})
      assert html =~ "lg-wrap"
    end

    test "the /calendar route opens the calendar tab with the nested grid mounted", %{
      conn: conn
    } do
      project = started_project_for_tabs()
      {:ok, view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}/calendar")

      assert html =~ ~s(role="tablist")
      # Same page, calendar tab active → the nested ProjectCalendarLive is
      # rendered. Its build is deferred off the first paint, so settle the
      # child LV before asserting the grid.
      calendar = find_live_child(view, "project-calendar-live-#{project.uuid}")
      grid = render(calendar)
      assert grid =~ "cal-container"
      assert grid =~ "cal-month-grid"
    end

    test "switch_tab mounts the calendar on first open, then keeps it mounted", %{conn: conn} do
      project = started_project_for_tabs()
      {:ok, view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      refute html =~ "cal-container"

      render_click(view, "switch_tab", %{"tab" => "calendar"})
      assert_push_event(view, "project_tab_url", %{tab: "calendar"})
      calendar = find_live_child(view, "project-calendar-live-#{project.uuid}")
      assert render(calendar) =~ "cal-container"

      # Switching back hides it (CSS) but keeps it mounted (lazy-once) — the
      # built grid stays in the (hidden) DOM, so its month nav survives.
      html = render_click(view, "switch_tab", %{"tab" => "list"})
      assert html =~ "cal-container"
    end

    test "embedded ProjectShowLive renders the List/Timeline tabs (lazy gantt)", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      project = started_project_for_tabs()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: embed_session(project, actor_uuid)
        )

      # The tab bar now renders in embeds too (only templates stay list-only),
      # so a host embedding the show page gets the Timeline switch as well.
      assert html =~ ~s(role="tablist")
      assert html =~ "Timeline"
      # Still lazy — the nested gantt isn't live_rendered until its tab opens.
      refute html =~ "lg-wrap"
    end

    test "embedded ProjectShowLive does not sync the URL on tab switch (off by default)", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      project = started_project_for_tabs()

      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: embed_session(project, actor_uuid)
        )

      render_click(view, "switch_tab", %{"tab" => "gantt"})
      # URL sync defaults OFF in embeds: an embed must never rewrite the host
      # page's address bar, so no `project_tab_url` push fires.
      refute_push_event(view, "project_tab_url", %{})
    end

    test "an embed can opt into URL sync via session[\"tab_url_sync\"]", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      project = started_project_for_tabs()

      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: embed_session(project, actor_uuid, %{"tab_url_sync" => true})
        )

      render_click(view, "switch_tab", %{"tab" => "gantt"})
      assert_push_event(view, "project_tab_url", %{tab: "gantt"})
    end

    test "a template show page (router-mounted) renders no tabs — no template gantt route",
         %{conn: conn} do
      template = fixture_template()
      {:ok, _view, html} = live(conn, "/en/admin/projects/templates/#{template.uuid}")

      refute html =~ ~s(role="tablist")
    end

    test "switch_tab pushes the URL event; a history-sourced switch does not", %{conn: conn} do
      project = started_project_for_tabs()
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      render_click(view, "switch_tab", %{"tab" => "gantt"})
      assert_push_event(view, "project_tab_url", %{tab: "gantt"})

      # A switch that came FROM the URL (browser back/forward) must NOT push the
      # URL again, or pushState/popstate would loop.
      render_click(view, "switch_tab", %{"tab" => "list", "source" => "history"})
      refute_push_event(view, "project_tab_url", %{})
    end

    test "the schedule summary and progress bar render as one fused card", %{conn: conn} do
      project = started_project_for_tabs()
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      # The schedule line renders.
      assert html =~ "Remaining:"
      assert html =~ "ETA:"

      # One rounded-top container with a square bottom, so the progress bar reads
      # as the card's bottom border.
      assert html =~ "rounded-t-lg overflow-hidden"

      # The progress bar is the thin (h-1.5) strip at the card's bottom edge, and
      # the task count lives only in its title tooltip — not a visible "N/M done"
      # label (which the merge intentionally removed).
      assert html =~ ~r/class="w-full bg-base-300 h-1\.5"\s+title="[^"]*done"/
    end
  end

  describe "the list lens" do
    setup %{conn: conn} do
      n = System.unique_integer([:positive])

      {:ok, project} =
        Projects.create_project(%{
          "name" => "Lens #{n}",
          "start_mode" => "immediate"
        })

      done = task_named(project, "Finished thing #{n}", "done")
      active = task_named(project, "Live thing #{n}", "todo")

      {:ok, conn: conn, project: project, done: done, active: active}
    end

    defp task_named(project, title, status) do
      {:ok, task} = Projects.create_task(%{"title" => title})

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => status
        })

      assignment
    end

    test "opens on active work, and says how much it is not showing", %{
      conn: conn,
      project: project,
      done: done,
      active: active
    } do
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      # Scoped to the list itself: the board tab renders every assignment
      # into the same document (hidden by CSS), so asserting on the whole
      # page proves nothing about what the list is showing.
      assert list_rows(html) == [active.uuid]

      refute done.uuid in list_rows(html),
             "a mature project opened on its finished work, which is what buried the live tasks"

      # Hiding rows is fine; hiding the number is not. The done count has to
      # stay on the page or the project silently looks smaller than it is.
      assert html =~ "Done"
    end

    test "a task with an out-of-band status is never silently hidden", %{
      conn: conn,
      project: project
    } do
      # "Active" means NOT FINISHED, not "one of the two statuses I thought
      # of". This codebase renders a fallback badge for out-of-band statuses
      # on purpose, and the first cut of this filter made every one of them
      # vanish from the default view.
      # The changeset validates the vocabulary, so an out-of-band status can
      # only arrive by a raw write or from legacy data — which is exactly
      # the case the rendering fallback exists for.
      odd = task_named(project, "Odd status #{System.unique_integer([:positive])}", "todo")
      {:ok, raw_uuid} = Ecto.UUID.dump(odd.uuid)

      SQL.query!(
        Repo,
        "UPDATE phoenix_kit_project_assignments SET status = $1 WHERE uuid = $2",
        ["archived", raw_uuid]
      )

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      assert odd.uuid in list_rows(html)
    end

    test "a task keeps its number when the lens moves", %{
      conn: conn,
      project: project,
      done: done,
      active: active
    } do
      # A finished row shows a check rather than a number, so `active` is
      # the one whose digit can be compared across lenses.
      # `done` was created first, so in manual order it is 1 and `active` is
      # 2. Numbering the rows on screen instead of the project made `active`
      # render as "1" under the default lens and "2" under All — the same
      # task, two numbers, depending on what else you happened to be
      # looking at.
      {:ok, view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      # Under the default lens `active` is the only row on screen, so a
      # counter over the visible rows would call it 1.
      assert list_rows(html) == [active.uuid]
      assert number_for(html, active.uuid) == "2"

      all = view |> element("button[phx-value-tab=all]") |> render_click()

      assert list_rows(all) == [done.uuid, active.uuid]
      assert number_for(all, active.uuid) == "2"
    end

    test "a submission is not in the project until somebody accepts it", %{
      conn: conn,
      project: project
    } do
      # A stranger's request is not work. Until a person agrees to it, it
      # must be in no list, no count and no lens — mixing it into the plan
      # was what made every filter and drag treat a message as a task.
      pending = task_named(project, "Please fix #{System.unique_integer([:positive])}", "todo")

      {:ok, _} =
        pending
        |> Ecto.Changeset.change(review_status: "pending", source: "portal")
        |> Repo.update()

      {:ok, view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      refute pending.uuid in list_rows(html)
      assert html =~ "Review submissions"

      # Even with every lens wide open it stays out — it is not a filtered
      # task, it is not a task.
      all = view |> element("button[phx-value-tab=all]") |> render_click()
      refute pending.uuid in list_rows(all)

      view |> element(~s(button[phx-click="open_review"])) |> render_click()

      accepted =
        view
        |> element(
          ~s(button[phx-click="review_submission"][phx-value-uuid="#{pending.uuid}"][phx-value-decision="accepted"])
        )
        |> render_click()

      assert pending.uuid in list_rows(accepted)
      assert Projects.get_assignment(pending.uuid).review_status == "accepted"
    end

    test "a submission opens to show what the person actually sent", %{
      conn: conn,
      project: project
    } do
      first = task_named(project, "First report #{System.unique_integer([:positive])}", "todo")
      second = task_named(project, "Second report #{System.unique_integer([:positive])}", "todo")

      for a <- [first, second] do
        {:ok, _} =
          a
          |> Ecto.Changeset.change(
            review_status: "pending",
            source: "portal",
            description: "Steps for #{a.uuid}"
          )
          |> Repo.update()
      end

      # Both rows land in the same second (utc_datetime truncation), so
      # backdate one or "newest first" has no defined answer.
      {:ok, _} =
        first
        |> Ecto.Changeset.change(inserted_at: ~U[2026-01-01 00:00:00Z])
        |> Repo.update()

      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")
      opened = view |> element(~s(button[phx-click="open_review"])) |> render_click()

      assert opened =~ "Submissions to review"

      # Newest first, and the top one is already expanded — with a single
      # submission waiting, which is the common case, an extra click to see
      # anything at all tells nobody anything.
      assert opened =~ "Steps for #{second.uuid}"
      refute opened =~ "Steps for #{first.uuid}"

      switched =
        view
        |> element(~s(button[phx-click="select_review"][phx-value-uuid="#{first.uuid}"]))
        |> render_click()

      assert switched =~ "Steps for #{first.uuid}"
      refute switched =~ "Steps for #{second.uuid}"

      # Clicking the open one closes it, so the dialog reads back down to a
      # list without hunting for a control.
      collapsed =
        view
        |> element(~s(button[phx-click="select_review"][phx-value-uuid="#{first.uuid}"]))
        |> render_click()

      refute collapsed =~ "Steps for #{first.uuid}"
    end

    test "rejecting keeps the record and shows it to nobody", %{conn: conn, project: project} do
      pending = task_named(project, "Spam #{System.unique_integer([:positive])}", "todo")

      {:ok, _} =
        pending
        |> Ecto.Changeset.change(review_status: "pending", source: "portal")
        |> Repo.update()

      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      view |> element(~s(button[phx-click="open_review"])) |> render_click()

      view
      |> element(
        ~s(button[phx-click="review_submission"][phx-value-uuid="#{pending.uuid}"][phx-value-decision="rejected"])
      )
      |> render_click()

      all = view |> element("button[phx-value-tab=all]") |> render_click()
      refute pending.uuid in list_rows(all)

      # Kept, not deleted: a public intake has to be able to answer what
      # strangers sent and what was done about it.
      assert Projects.get_assignment(pending.uuid).review_status == "rejected"
    end

    test "a forged uuid cannot be reviewed through this project's queue", %{
      conn: conn,
      project: project
    } do
      other = fixture_project(%{"name" => "Other #{System.unique_integer([:positive])}"})
      stranger = task_named(other, "Not yours", "todo")

      {:ok, _} =
        stranger |> Ecto.Changeset.change(review_status: "pending") |> Repo.update()

      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      render_hook(view, "review_submission", %{
        "uuid" => stranger.uuid,
        "decision" => "accepted"
      })

      assert Projects.get_assignment(stranger.uuid).review_status == "pending",
             "a submission from another project was decided from this page"
    end

    test "the rail and the drag handles are gone under a lens", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      # Default is "active" — a filter — so neither may render.
      assert html =~ ~s(data-sortable="false")
      refute html =~ "bottom-0 w-0.5"

      # Showing everything in manual order brings both back together: they
      # are one affordance, and either without the other is a lie.
      manual = view |> element("button[phx-value-tab=all]") |> render_click()

      assert manual =~ ~s(data-sortable="true")
      assert manual =~ "bottom-0 w-0.5"
      assert manual =~ "pk-drag-handle"
    end

    test "reordering is refused under a lens, not merely hidden", %{
      conn: conn,
      project: project,
      done: done,
      active: active
    } do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      before = ordered_uuids(project)

      # A forged event carrying only the rows the client could SEE. Accepting
      # it rewrites `position` for the whole project from a partial list, and
      # nothing afterwards says the order used to mean something.
      html =
        render_hook(view, "reorder_assignments", %{
          "ordered_ids" => [active.uuid],
          "moved_id" => active.uuid
        })

      assert html =~ "manual order"
      assert ordered_uuids(project) == before
      assert done.uuid in before
    end

    test "reordering works once everything is in view", %{
      conn: conn,
      project: project,
      done: done,
      active: active
    } do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      view |> element("button[phx-value-tab=all]") |> render_click()

      render_hook(view, "reorder_assignments", %{
        "ordered_ids" => [active.uuid, done.uuid],
        "moved_id" => active.uuid
      })

      assert ordered_uuids(project) == [active.uuid, done.uuid]
    end

    # The number rendered in a row's timeline dot.
    defp number_for(html, uuid) do
      case Regex.run(
             ~r/data-id="#{uuid}".*?rounded-full[^>]*>\s*(?:<span[^>]*><\/span>\s*)?([0-9]+)/s,
             html
           ) do
        [_, number] -> number
        _ -> nil
      end
    end

    # The uuids the LIST tab is drawing, in order.
    #
    # Sliced to the timeline container first: the board tab renders every
    # card into the same document (CSS-hidden) and its cards are ALSO
    # `sortable-item`s now that they can be dragged between columns, so an
    # unscoped scan counts each task twice.
    defp list_rows(html) do
      html
      |> timeline_fragment()
      |> then(&Regex.scan(~r/sortable-item"[^>]*data-id="([^"]+)"/, &1))
      |> Enum.map(fn [_, uuid] -> uuid end)
    end

    defp timeline_fragment(html) do
      case :binary.match(html, "id=\"project-show-timeline\"") do
        {start, _} ->
          rest = binary_part(html, start, byte_size(html) - start)

          case :binary.match(rest, "id=\"board-column-") do
            {stop, _} -> binary_part(rest, 0, stop)
            :nomatch -> rest
          end

        :nomatch ->
          ""
      end
    end

    defp ordered_uuids(project) do
      project.uuid
      |> Projects.list_assignments()
      |> Enum.map(& &1.uuid)
    end
  end

  describe "the board" do
    setup %{conn: conn} do
      n = System.unique_integer([:positive])

      {:ok, project} =
        Projects.create_project(%{"name" => "Board #{n}", "start_mode" => "immediate"})

      {:ok, task} = Projects.create_task(%{"title" => "Draggable #{n}"})

      {:ok, a} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, conn: conn, project: project, a: a}
    end

    test "dragging to another column changes the status", %{conn: conn, project: project, a: a} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      render_hook(view, "board_move", %{
        "moved_id" => a.uuid,
        "status" => "in_progress",
        "ordered_ids" => [a.uuid]
      })

      assert Projects.get_assignment(a.uuid).status == "in_progress"
    end

    test "dropping in Done carries the same side effects as the button", %{
      conn: conn,
      project: project,
      a: a
    } do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      render_hook(view, "board_move", %{
        "moved_id" => a.uuid,
        "status" => "done",
        "ordered_ids" => [a.uuid]
      })

      done = Projects.get_assignment(a.uuid)

      # A naked status write would look identical on the board and leave a
      # finished task with no record of who finished it.
      assert done.status == "done"
      assert done.progress_pct == 100
      refute is_nil(done.completed_at)
    end

    test "a drop lands where it was dropped, without disturbing anyone else", %{
      conn: conn,
      project: project,
      a: a
    } do
      others =
        for i <- 1..3 do
          {:ok, t} =
            Projects.create_task(%{"title" => "Other #{i}-#{System.unique_integer([:positive])}"})

          {:ok, x} =
            Projects.create_assignment(%{
              "project_uuid" => project.uuid,
              "task_uuid" => t.uuid,
              "status" => "todo"
            })

          x
        end

      [o1, o2, o3] = others

      # Move `a` to In progress, dropped ABOVE o2 in that column's order.
      # o2 is in a different column here, which is the point: the client's
      # list is partial, and only the insertion point may be taken from it.
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      render_hook(view, "board_move", %{
        "moved_id" => a.uuid,
        "status" => "in_progress",
        "ordered_ids" => [a.uuid, o2.uuid]
      })

      order = Projects.list_assignments(project.uuid) |> Enum.map(& &1.uuid)

      # It sits where it was let go...
      assert Enum.find_index(order, &(&1 == a.uuid)) ==
               Enum.find_index(order, &(&1 == o2.uuid)) - 1

      # ...and every card the client never sent keeps its relative order.
      # Renumbering from the column's partial list would have thrown these
      # to the end of the plan.
      untouched = Enum.filter(order, &(&1 in [o1.uuid, o2.uuid, o3.uuid]))
      assert untouched == [o1.uuid, o2.uuid, o3.uuid]
    end

    test "a drop with no ordered_ids leaves the plan alone", %{
      conn: conn,
      project: project,
      a: a
    } do
      before = Projects.list_assignments(project.uuid) |> Enum.map(& &1.uuid)

      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      render_hook(view, "board_move", %{"moved_id" => a.uuid, "status" => "done"})

      assert Projects.list_assignments(project.uuid) |> Enum.map(& &1.uuid) == before
      assert Projects.get_assignment(a.uuid).status == "done"
    end

    test "a forged destination status is refused", %{conn: conn, project: project, a: a} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      render_hook(view, "board_move", %{
        "moved_id" => a.uuid,
        "status" => "archived",
        "ordered_ids" => [a.uuid]
      })

      assert Projects.get_assignment(a.uuid).status == "todo"
    end

    test "a card from another project cannot be moved from here", %{conn: conn, project: project} do
      other = fixture_project(%{"name" => "Elsewhere #{System.unique_integer([:positive])}"})
      {:ok, t} = Projects.create_task(%{"title" => "Theirs"})

      {:ok, stranger} =
        Projects.create_assignment(%{
          "project_uuid" => other.uuid,
          "task_uuid" => t.uuid,
          "status" => "todo"
        })

      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      render_hook(view, "board_move", %{
        "moved_id" => stranger.uuid,
        "status" => "done",
        "ordered_ids" => [stranger.uuid]
      })

      assert Projects.get_assignment(stranger.uuid).status == "todo"
    end

    test "a status the board cannot place is named, not silently dropped", %{
      conn: conn,
      project: project,
      a: a
    } do
      {:ok, raw_uuid} = Ecto.UUID.dump(a.uuid)

      SQL.query!(
        Repo,
        "UPDATE phoenix_kit_project_assignments SET status = $1 WHERE uuid = $2",
        ["archived", raw_uuid]
      )

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      assert html =~ "does not show"
    end
  end
end
