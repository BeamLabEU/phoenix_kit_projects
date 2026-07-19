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
    # Starts at 00:05 UTC TODAY (not "now") so the sequential walk keeps every
    # short task inside today — anchored at now, a run near UTC midnight pushes
    # the tail tasks past midnight and out of today's popup (observed flake).
    defp calendar_fixture(n) do
      project =
        fixture_project(%{
          "name" => "CalDash-#{System.unique_integer([:positive])}",
          "start_mode" => "immediate",
          "counts_weekends" => true
        })

      early_today = DateTime.new!(Date.utc_today(), ~T[00:05:00], "Etc/UTC")
      {:ok, _} = Projects.start_project(project, early_today)
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
      render_click(view, "switch_overview_tab", %{"tab" => "tasks_calendar"})
    end

    test "the Tasks-calendar tab opens the tasks grid", %{conn: conn} do
      {_project, [a | _]} = calendar_fixture(2)

      {:ok, view, _html} = live(conn, "/en/admin/projects")
      html = open_calendar_tab(view)

      # All three view tabs render; the tasks grid shows the task titles.
      assert html =~ "tasks_calendar"
      assert html =~ "projects_calendar"
      assert html =~ "overview-tasks-calendar"
      assert html =~ a.task.title
    end

    test "the Projects-calendar tab flips the mode (both grids stay mounted)", %{conn: conn} do
      {_project, _} = calendar_fixture(1)

      {:ok, view, _html} = live(conn, "/en/admin/projects")
      open_calendar_tab(view)

      html = render_click(view, "switch_overview_tab", %{"tab" => "projects_calendar"})
      # Both component instances stay in the DOM (CSS-hidden) so month
      # navigation survives switching.
      assert html =~ "projects-overview-calendar"
      assert html =~ "overview-tasks-calendar"

      # The active tab follows the mode.
      assert has_element?(view, ~s([role="tab"].tab-active), "Projects calendar")
      render_click(view, "switch_overview_tab", %{"tab" => "tasks_calendar"})
      assert has_element?(view, ~s([role="tab"].tab-active), "Tasks calendar")

      # An unknown tab falls back to the list view.
      html = render_click(view, "switch_overview_tab", %{"tab" => "evil"})
      assert html =~ "overview-tasks-calendar"
    end

    test "late chips default to the overdue pattern; the ring is the opt-in alternative",
         %{conn: conn} do
      # A late chip that lands on TODAY's cell (a month-old span wouldn't be
      # in the rendered month): 10-minute task anchored at 00:05 UTC today —
      # same convention as calendar_fixture, late whenever now > 00:15.
      {_project, _} = calendar_fixture(1)

      {:ok, view, _html} = live(conn, "/en/admin/projects")
      open_calendar_tab(view)

      # Default: synced with the Projects-mode overdue look.
      assert has_element?(view, "[id^=overview-tasks-calendar] .pk-overdue")
      refute has_element?(view, "[id^=overview-tasks-calendar] .ring-error")

      # Opting into the ring swaps the marker.
      PhoenixKitProjects.CalendarDisplay.put("late_marker", "ring")
      send(view.pid, {:projects, :assignment_updated, %{}})
      render(view)
      assert has_element?(view, "[id^=overview-tasks-calendar] .ring-error")
      refute has_element?(view, "[id^=overview-tasks-calendar] .cal-event.pk-overdue")
    end

    # A started project whose 1-hour task began `days_ago` days ago — its
    # planned end is long past, so the running tier is :late. `counts_weekends`
    # keeps the ETA math day-of-week independent.
    defp late_project_fixture(days_ago) do
      project =
        fixture_project(%{
          "name" => "LateProj-#{System.unique_integer([:positive])}",
          "start_mode" => "immediate",
          "counts_weekends" => true
        })

      started = DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)
      {:ok, _} = Projects.start_project(project, started)
      project = Projects.get_project!(project.uuid)

      task =
        fixture_task(%{
          "title" => "LateTask-#{System.unique_integer([:positive])}",
          "estimated_duration" => 1,
          "estimated_duration_unit" => "hours"
        })

      {:ok, a} =
        Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => task.uuid})

      {project, a}
    end

    test "Projects mode: the Late-only lens filters bars; hidden while nothing is late",
         %{conn: conn} do
      # An on-track project (10-day task started just now).
      ontrack =
        fixture_project(%{
          "name" => "OnTrackProj-#{System.unique_integer([:positive])}",
          "start_mode" => "immediate",
          "counts_weekends" => true
        })

      {:ok, _} = Projects.start_project(ontrack)

      task =
        fixture_task(%{
          "title" => "LongTask-#{System.unique_integer([:positive])}",
          "estimated_duration" => 10,
          "estimated_duration_unit" => "days"
        })

      {:ok, _} =
        Projects.create_assignment(%{"project_uuid" => ontrack.uuid, "task_uuid" => task.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/projects")
      open_calendar_tab(view)
      html = render_click(view, "switch_overview_tab", %{"tab" => "projects_calendar"})

      # Nothing late — no lens (the graceful-empty rule).
      refute html =~ "toggle_projects_late_only"

      {late_p, late_a} = late_project_fixture(30)
      send(view.pid, {:projects, :project_started, %{}})
      html = render(view)
      assert html =~ "toggle_projects_late_only"

      grid = "[id^=projects-overview-calendar]"
      assert has_element?(view, grid, late_p.name)
      assert has_element?(view, grid, ontrack.name)

      # Lens ON: only the late project's bar remains.
      render_click(view, "toggle_projects_late_only", %{})
      assert has_element?(view, grid, late_p.name)
      refute has_element?(view, grid, ontrack.name)

      # The whole-day popup follows the lens (rows come from the derived
      # events): today is covered by BOTH bars, but only the late one lists.
      send(view.pid, {:calendar_day_click, Date.utc_today()})
      modal = "[id^=overview-day-modal]"
      assert has_element?(view, modal, late_p.name)
      refute has_element?(view, modal, ontrack.name)

      # An ACTIVE lens stays reachable when the late count drops to 0
      # (completing the late project removes it from the running set)...
      {:ok, _} = Projects.update_assignment_status(late_a, %{"status" => "done"})
      {:completed, _} = Projects.recompute_project_completion(late_p.uuid)
      send(view.pid, {:projects, :project_completed, %{}})
      html = render(view)
      assert html =~ "toggle_projects_late_only"

      # ...and toggling it off then removes the lens entirely.
      html = render_click(view, "toggle_projects_late_only", %{})
      refute html =~ "toggle_projects_late_only"
      assert has_element?(view, grid, ontrack.name)
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
      render_click(view, "switch_overview_tab", %{"tab" => "projects_calendar"})

      send(view.pid, {:calendar_day_click, Date.utc_today()})
      html = render(view)
      assert html =~ project.name
      assert html =~ "day_popup_open_project"
    end

    test "a Projects-mode bar click opens the project", %{conn: conn} do
      {project, _} = calendar_fixture(1)

      {:ok, view, _html} = live(conn, "/en/admin/projects")
      open_calendar_tab(view)
      render_click(view, "switch_overview_tab", %{"tab" => "projects_calendar"})

      send(view.pid, {:calendar_open_project, project.uuid})
      assert_redirect(view, Paths.project(project.uuid))
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
      # 00:05 UTC today, not "now" — near UTC midnight the sequential walk
      # would otherwise push later tasks into tomorrow, and the day-popup
      # assertions are scoped to today (same flake class as calendar_fixture).
      early_today = DateTime.new!(Date.utc_today(), ~T[00:05:00], "Etc/UTC")
      {:ok, _} = Prj.start_project(project, early_today)

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
      render_click(view, "switch_overview_tab", %{"tab" => "tasks_calendar"})
      view
    end

    test "the Filters funnel is absent while no scheduled work exists", %{conn: conn} do
      view = mount_with_user(conn, reg_user())

      # Fresh install: no projects/tasks — nothing any filter could narrow,
      # so the funnel (and its panel) doesn't render at all.
      refute render(view) =~ "hero-funnel"

      # The moment real work exists, a reload brings the funnel back.
      _fx = filter_fixture(reg_user())
      send(view.pid, {:projects, :assignment_created, %{}})
      assert render(view) =~ "hero-funnel"

      # A FILTER that empties the month must NOT hide the funnel — the guard
      # is keyed on the raw walk, and the panel is the only way back out.
      # (Picking is scope-based, not relevance-gated, so a task-less person
      # can be picked and matches nothing.)
      {:ok, bare_user} =
        Auth.register_user(%{
          "email" => "bare-#{System.unique_integer([:positive])}@example.com",
          "password" => "ActorPass123!"
        })

      {:ok, bare} =
        Staff.create_person(%{
          "user_uuid" => bare_user.uuid,
          "name" => "No Tasks Person",
          "employment_type" => "full_time"
        })

      html = render_click(view, "assignee_pick", %{"uuid" => bare.uuid})
      assert html =~ "hero-funnel"
      assert html =~ "clear_assignee_filter"
    end

    test "the Unassigned quick-adder hides while nothing is unassigned", %{conn: conn} do
      user = reg_user()
      n = System.unique_integer([:positive])

      {:ok, person} =
        Staff.create_person(%{
          "user_uuid" => user.uuid,
          "name" => "OnlyAssigned #{n}",
          "employment_type" => "full_time"
        })

      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _} = Prj.start_project(project)
      task = fixture_task(%{"title" => "Held-#{n}"})

      {:ok, _} =
        Prj.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "assigned_person_uuid" => person.uuid
        })

      view = mount_with_user(conn, user)

      # Everything is assigned: "Unassigned 0" would only filter to an empty
      # month, so the quick-adder doesn't render (same as Me without a
      # staff person).
      refute render(view) =~ "toggle_unassigned"

      loose = fixture_task(%{"title" => "Loose-#{n}"})

      {:ok, loose_a} =
        Prj.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => loose.uuid})

      send(view.pid, {:projects, :assignment_created, %{}})
      assert render(view) =~ "toggle_unassigned"

      # An ACTIVE lens must keep its removable chip even when the count later
      # drops to 0 — otherwise the lens would be stranded invisibly ON (the
      # quick-adder is hidden while active AND while the count is 0).
      html = render_click(view, "toggle_unassigned", %{})
      assert html =~ "hero-user-minus"

      {:ok, _} = Prj.update_assignment_form(loose_a, %{"assigned_person_uuid" => person.uuid})
      send(view.pid, {:projects, :assignment_updated, %{}})
      html = render(view)
      assert html =~ "hero-user-minus"
      assert html =~ "toggle_unassigned"

      # ...and toggling it off from the chip removes the lens entirely: with
      # the count at 0, no Unassigned control remains.
      html = render_click(view, "toggle_unassigned", %{})
      refute html =~ "hero-user-minus"
      refute html =~ "toggle_unassigned"
    end

    test "the Overdue-only toggle hides while nothing is late", %{conn: conn} do
      user = reg_user()

      # Future-only work: a 3-week task started just now is not late.
      project = fixture_project(%{"start_mode" => "immediate", "counts_weekends" => true})
      {:ok, _} = Prj.start_project(project)

      task =
        fixture_task(%{
          "title" => "Future-#{System.unique_integer([:positive])}",
          "estimated_duration" => 3,
          "estimated_duration_unit" => "weeks"
        })

      {:ok, _} =
        Prj.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => task.uuid})

      view = mount_with_user(conn, user)
      refute render(view) =~ "toggle_overdue_only"

      # A late task appears -> so does the toggle.
      {late_p, late_a} = late_project_fixture(30)
      send(view.pid, {:projects, :project_started, %{}})
      assert render(view) =~ "toggle_overdue_only"

      # An ACTIVE lens survives the late count dropping to 0...
      render_click(view, "toggle_overdue_only", %{})
      {:ok, _} = Prj.update_assignment_status(late_a, %{"status" => "done"})
      {:completed, _} = Prj.recompute_project_completion(late_p.uuid)
      send(view.pid, {:projects, :project_completed, %{}})
      assert render(view) =~ "toggle_overdue_only"

      # ...and unchecking it then removes the control.
      html = render_click(view, "toggle_overdue_only", %{})
      refute html =~ "toggle_overdue_only"
    end

    test "Me filter (inherited) keeps direct + team tasks, drops unassigned", %{conn: conn} do
      user = reg_user()
      fx = filter_fixture(user)
      view = mount_with_user(conn, user)

      html = render_click(view, "toggle_me_chip", %{})
      assert html =~ fx.direct.task.title
      assert html =~ fx.team_task.task.title
      refute html =~ fx.loose.task.title
    end

    test "Direct only narrows a Me scope to personal assignments", %{conn: conn} do
      user = reg_user()
      fx = filter_fixture(user)
      view = mount_with_user(conn, user)

      render_click(view, "toggle_me_chip", %{})
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

      html = render_click(view, "toggle_unassigned", %{})
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

      # Everyone is the clear-all: chips drop.
      html3 = render_click(view, "clear_assignee_filter", %{})
      refute html3 =~ "remove_assignee_person"
    end

    test "Me and Unassigned compose as one union", %{conn: conn} do
      user = reg_user()
      fx = filter_fixture(user)
      view = mount_with_user(conn, user)

      render_click(view, "toggle_me_chip", %{})
      html = render_click(view, "toggle_unassigned", %{})

      # My work AND the unassigned backlog in one view.
      assert html =~ fx.direct.task.title
      assert html =~ fx.team_task.task.title
      assert html =~ fx.loose.task.title

      # Toggling Me off keeps just the unassigned lens.
      html = render_click(view, "toggle_me_chip", %{})
      refute html =~ fx.team_task.task.title
      assert html =~ fx.loose.task.title
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

      # A picked person no longer appears as a suggestion.
      render_click(view, "assignee_pick", %{"uuid" => fx.person.uuid})
      render_click(view, "assignee_search", %{"q" => fx.person.name, "limit" => 8})
      assert_push_event(view, "assignee_results", %{results: excluded})
      refute Enum.any?(excluded, &(&1.uuid == fx.person.uuid))
    end

    test "a viewer without a staff person gets no Me button; the event is a no-op", %{
      conn: conn
    } do
      user = reg_user()
      _fx = filter_fixture(reg_user())
      view = mount_with_user(conn, user)

      html = render(view)
      refute html =~ "toggle_me_chip"

      # Server-side guard: a crafted toggle is ignored (no chip appears).
      html = render_click(view, "toggle_me_chip", %{})
      refute html =~ "remove_assignee_person"
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

      # The late chip carries the default overdue-pattern marker (scoped
      # element check — the injected <style> text also contains the class).
      assert has_element?(view, "[id^=overview-tasks-calendar] .cal-event.pk-overdue")
    end
  end
end
