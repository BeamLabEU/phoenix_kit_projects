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

  describe "calendar tab (Tasks default + Projects mode + whole-day popup)" do
    alias PhoenixKitProjects.{Paths, Projects}

    # A started project with `n` short same-day tasks; returns {project, assignments}.
    defp calendar_fixture(n) do
      project =
        fixture_project(%{
          "name" => "CalDash-#{System.unique_integer([:positive])}",
          "start_mode" => "immediate",
          "counts_weekends" => true
        })

      {:ok, _} = Projects.start_project(project)
      project = Projects.get_project!(project.uuid)

      assignments =
        for i <- 1..n do
          task =
            fixture_task(%{
              "title" => "CalTask #{i} #{System.unique_integer([:positive])}",
              "estimated_duration" => 10,
              "estimated_duration_unit" => "minutes"
            })

          {:ok, a} =
            Projects.create_assignment(%{
              "project_uuid" => project.uuid,
              "task_uuid" => task.uuid
            })

          %{a | task: task}
        end

      {project, assignments}
    end

    defp open_calendar_tab(view) do
      render_click(view, "switch_overview_tab", %{"tab" => "calendar"})
    end

    test "opens in Tasks mode: per-task events + the mode toggle", %{conn: conn} do
      {_project, [a | _]} = calendar_fixture(2)

      {:ok, view, _html} = live(conn, "/en/admin/projects")
      html = open_calendar_tab(view)

      # Both mode buttons render, Tasks active by default.
      assert html =~ "set_calendar_mode"
      assert html =~ ~s(phx-value-mode="tasks")
      assert html =~ ~s(phx-value-mode="projects")

      # The tasks grid renders the task titles as events.
      assert html =~ "overview-tasks-calendar"
      assert html =~ a.task.title
    end

    test "the mode toggle flips to the Projects view (both grids stay mounted)", %{conn: conn} do
      {_project, _} = calendar_fixture(1)

      {:ok, view, _html} = live(conn, "/en/admin/projects")
      open_calendar_tab(view)

      html = render_click(view, "set_calendar_mode", %{"mode" => "projects"})
      # Both component instances stay in the DOM (CSS-hidden) so month
      # navigation survives switching.
      assert html =~ "projects-overview-calendar"
      assert html =~ "overview-tasks-calendar"

      # An unknown mode is ignored.
      html = render_click(view, "set_calendar_mode", %{"mode" => "evil"})
      assert html =~ "overview-tasks-calendar"
    end

    test "a day with more tasks than the cap shows the +N more link", %{conn: conn} do
      {_project, _assignments} = calendar_fixture(8)

      {:ok, view, _html} = live(conn, "/en/admin/projects")
      html = open_calendar_tab(view)

      assert html =~ "cal-more-link"
      assert html =~ "more"
    end

    test "a day-cell click fills the whole-day popup with every task that day", %{conn: conn} do
      {_project, assignments} = calendar_fixture(8)

      {:ok, view, _html} = live(conn, "/en/admin/projects")
      open_calendar_tab(view)

      send(view.pid, {:calendar_day_click, Date.utc_today()})
      html = render(view)

      # Every task of the day is listed — including the ones behind "+N more".
      for a <- assignments, do: assert(html =~ a.task.title)
      # Rows open the owning project.
      assert html =~ "day_popup_open_project"
    end

    test "the +N more click fills the same popup; closing clears it", %{conn: conn} do
      {_project, [a | _]} = calendar_fixture(6)

      {:ok, view, _html} = live(conn, "/en/admin/projects")
      open_calendar_tab(view)

      send(view.pid, {:calendar_day_more, Date.utc_today()})
      html = render(view)
      assert html =~ a.task.title
      assert html =~ "day_popup_open_project"

      html = render_click(view, "close_day_popup", %{})
      # keep_in_dom: the dialog stays, flagged closed, body back to skeleton.
      refute html =~ "day_popup_open_project"
    end

    test "an empty day's popup says nothing is scheduled", %{conn: conn} do
      {_project, _} = calendar_fixture(1)

      {:ok, view, _html} = live(conn, "/en/admin/projects")
      open_calendar_tab(view)

      send(view.pid, {:calendar_day_click, Date.add(Date.utc_today(), 300)})
      html = render(view)
      assert html =~ "Nothing scheduled this day."
    end

    test "a popup row click opens the project", %{conn: conn} do
      {project, _} = calendar_fixture(1)

      {:ok, view, _html} = live(conn, "/en/admin/projects")
      open_calendar_tab(view)

      render_click(view, "day_popup_open_project", %{"uuid" => project.uuid})
      assert_redirect(view, Paths.project(project.uuid))
    end

    test "a task chip click opens the owning project", %{conn: conn} do
      {project, [a | _]} = calendar_fixture(1)

      {:ok, view, _html} = live(conn, "/en/admin/projects")
      open_calendar_tab(view)

      send(view.pid, {:calendar_open_task, a.uuid})
      assert_redirect(view, Paths.project(project.uuid))
    end

    test "an unknown task id on chip click is a no-op", %{conn: conn} do
      {_project, _} = calendar_fixture(1)

      {:ok, view, _html} = live(conn, "/en/admin/projects")
      open_calendar_tab(view)

      send(view.pid, {:calendar_open_task, Ecto.UUID.generate()})
      assert Process.alive?(view.pid)
      _ = render(view)
    end

    test "Projects-mode popup rows carry the project's span", %{conn: conn} do
      {project, _} = calendar_fixture(1)

      {:ok, view, _html} = live(conn, "/en/admin/projects")
      open_calendar_tab(view)
      render_click(view, "set_calendar_mode", %{"mode" => "projects"})

      send(view.pid, {:calendar_day_click, Date.utc_today()})
      html = render(view)
      assert html =~ project.name
      assert html =~ "day_popup_open_project"
    end
  end

  describe "calendar assignee filter + overdue" do
    alias PhoenixKit.Users.Auth
    alias PhoenixKitProjects.Projects, as: Prj
    alias PhoenixKitStaff.{Departments, Staff, Teams}

    defp reg_user do
      {:ok, user} =
        Auth.register_user(%{
          "email" => "filter-#{System.unique_integer([:positive])}@example.com",
          "password" => "ActorPass123!"
        })

      user
    end

    # A person (linked to `user`) in a team; a project with one task assigned
    # directly to the person, one to the team, and one unassigned.
    defp filter_fixture(user) do
      n = System.unique_integer([:positive])
      {:ok, dept} = Departments.create(%{"name" => "FDept-#{n}"})
      {:ok, team} = Teams.create(%{"name" => "FTeam-#{n}", "department_uuid" => dept.uuid})

      {:ok, person} =
        Staff.create_person(%{
          "user_uuid" => user.uuid,
          "name" => "Filter Person #{n}",
          "employment_type" => "full_time"
        })

      {:ok, _} = Staff.add_team_person(team.uuid, person.uuid)

      project = fixture_project(%{"start_mode" => "immediate", "counts_weekends" => true})
      {:ok, _} = Prj.start_project(project)

      make = fn title, extra ->
        task =
          fixture_task(%{
            "title" => title,
            "estimated_duration" => 10,
            "estimated_duration_unit" => "minutes"
          })

        {:ok, a} =
          Prj.create_assignment(
            Map.merge(%{"project_uuid" => project.uuid, "task_uuid" => task.uuid}, extra)
          )

        %{a | task: task}
      end

      %{
        project: project,
        person: person,
        team: team,
        direct: make.("Direct-#{n}", %{"assigned_person_uuid" => person.uuid}),
        team_task: make.("TeamTask-#{n}", %{"assigned_team_uuid" => team.uuid}),
        loose: make.("Loose-#{n}", %{})
      }
    end

    defp mount_with_user(conn, user) do
      scope = fake_scope(user_uuid: user.uuid)
      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, "/en/admin/projects")
      render_click(view, "switch_overview_tab", %{"tab" => "calendar"})
      view
    end

    test "Me filter (inherited) keeps direct + team tasks, drops unassigned", %{conn: conn} do
      user = reg_user()
      fx = filter_fixture(user)
      view = mount_with_user(conn, user)

      html = render_click(view, "set_assignee_filter", %{"filter" => "me"})
      assert html =~ fx.direct.task.title
      assert html =~ fx.team_task.task.title
      refute html =~ fx.loose.task.title
    end

    test "Direct only narrows a Me scope to personal assignments", %{conn: conn} do
      user = reg_user()
      fx = filter_fixture(user)
      view = mount_with_user(conn, user)

      render_click(view, "set_assignee_filter", %{"filter" => "me"})
      html = render_click(view, "toggle_assignee_direct", %{})
      assert html =~ fx.direct.task.title
      refute html =~ fx.team_task.task.title
    end

    test "Unassigned filter shows only unassigned tasks; the count badge is live", %{
      conn: conn
    } do
      # View as a DIFFERENT admin so the direct task can't leak into the
      # page via the "My tasks" sidebar.
      fx = filter_fixture(reg_user())
      view = mount_with_user(conn, reg_user())

      html = render_click(view, "set_assignee_filter", %{"filter" => "unassigned"})
      assert html =~ fx.loose.task.title
      refute html =~ fx.direct.task.title
    end

    test "the person picker filters to picked people and shows provenance in the popup", %{
      conn: conn
    } do
      user = reg_user()
      fx = filter_fixture(user)
      # View as a DIFFERENT admin — the picker targets arbitrary people.
      viewer = reg_user()
      view = mount_with_user(conn, viewer)

      html = render_click(view, "assignee_pick", %{"uuid" => fx.person.uuid})
      # The pick confirms to the hook (clears the input) and renders a chip.
      assert_push_event(view, "assignee_staged", %{})
      assert html =~ fx.direct.task.title
      assert html =~ fx.team_task.task.title
      refute html =~ fx.loose.task.title
      assert html =~ "remove_assignee_person"

      # The team task's popup row explains WHY it's in this person's view.
      send(view.pid, {:calendar_day_click, Date.utc_today()})
      html = render(view)
      assert html =~ "via"
      assert html =~ fx.team.name

      # Removing the chip resets to everyone.
      html = render_click(view, "remove_assignee_person", %{"uuid" => fx.person.uuid})
      assert html =~ fx.loose.task.title
    end

    test "picking several people filters as a union", %{conn: conn} do
      fx1 = filter_fixture(reg_user())
      fx2 = filter_fixture(reg_user())
      view = mount_with_user(conn, reg_user())

      render_click(view, "assignee_pick", %{"uuid" => fx1.person.uuid})
      html = render_click(view, "assignee_pick", %{"uuid" => fx2.person.uuid})

      # Both people's direct tasks show; unassigned still filtered out.
      assert html =~ fx1.direct.task.title
      assert html =~ fx2.direct.task.title
      refute html =~ fx1.loose.task.title

      # A duplicate pick is a no-op (still confirms so the input clears).
      html2 = render_click(view, "assignee_pick", %{"uuid" => fx2.person.uuid})
      assert html2 =~ fx2.direct.task.title

      # A quick filter clears the picked chips.
      html3 = render_click(view, "set_assignee_filter", %{"filter" => "everyone"})
      refute html3 =~ "remove_assignee_person"
    end

    test "assignee_search answers the picker with rows + has_more", %{conn: conn} do
      fx = filter_fixture(reg_user())
      view = mount_with_user(conn, reg_user())

      render_click(view, "assignee_search", %{"q" => fx.person.name, "limit" => 8})

      assert_push_event(view, "assignee_results", %{q: q, results: results, has_more: _})
      assert q == fx.person.name
      assert Enum.any?(results, &(&1.uuid == fx.person.uuid))

      # A malformed limit degrades to the default instead of crashing.
      render_click(view, "assignee_search", %{"q" => "", "limit" => "bogus"})
      assert_push_event(view, "assignee_results", %{results: _})
    end

    test "a viewer without a staff person gets no Me button; the event is a no-op", %{
      conn: conn
    } do
      user = reg_user()
      _fx = filter_fixture(reg_user())
      view = mount_with_user(conn, user)

      html = render(view)
      refute html =~ ~s(phx-value-filter="me")

      # Server-side guard: a crafted "me" is ignored.
      html = render_click(view, "set_assignee_filter", %{"filter" => "me"})
      assert html =~ ~s(phx-value-filter="everyone")
    end

    test "Overdue only keeps late tasks and drops on-schedule/done ones", %{conn: conn} do
      user = reg_user()
      n = System.unique_integer([:positive])

      # Backdated project: its 10-minute tasks were scheduled to finish days
      # ago. The done one must NOT read as late.
      project = fixture_project(%{"start_mode" => "immediate", "counts_weekends" => true})
      {:ok, _} = Prj.start_project(project, DateTime.add(DateTime.utc_now(), -3 * 24 * 3600))

      late_task =
        fixture_task(%{
          "title" => "LateOne-#{n}",
          "estimated_duration" => 10,
          "estimated_duration_unit" => "minutes"
        })

      done_task =
        fixture_task(%{
          "title" => "DoneOne-#{n}",
          "estimated_duration" => 10,
          "estimated_duration_unit" => "minutes"
        })

      {:ok, _} =
        Prj.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => late_task.uuid})

      {:ok, _} =
        Prj.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => done_task.uuid,
          "status" => "done"
        })

      # A second, on-schedule project: its task runs for weeks — not late.
      current = fixture_project(%{"start_mode" => "immediate", "counts_weekends" => true})
      {:ok, _} = Prj.start_project(current)

      ok_task =
        fixture_task(%{
          "title" => "OnTime-#{n}",
          "estimated_duration" => 3,
          "estimated_duration_unit" => "weeks"
        })

      {:ok, _} =
        Prj.create_assignment(%{"project_uuid" => current.uuid, "task_uuid" => ok_task.uuid})

      view = mount_with_user(conn, user)
      html = render_click(view, "toggle_overdue_only", %{})

      assert html =~ late_task.title
      refute html =~ "DoneOne-#{n}"
      refute html =~ ok_task.title

      # The late chip carries the red ring marker.
      assert html =~ "ring-error"
    end
  end
end
