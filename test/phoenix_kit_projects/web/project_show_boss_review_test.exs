defmodule PhoenixKitProjects.Web.ProjectShowBossReviewTest do
  @moduledoc """
  The project page after the boss's review of 2026-10-30 (tim-dev): the
  assignee shown as the picker shows it, the header in one line, the
  status popup, the time-logging and comments switches, sub-project rows
  and the confirm dialogs.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Features, Projects}
  alias PhoenixKitProjects.Schemas.{Assignment, Project}
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitProjects.Web.ProjectShowLive
  alias PhoenixKitStaff.{Departments, Teams}

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "boss-review-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))
    {:ok, conn: conn, actor_uuid: user.uuid}
  end

  defp started_project(attrs \\ %{}) do
    project = fixture_project(Map.merge(%{"start_mode" => "immediate"}, attrs))
    {:ok, _} = Projects.start_project(project)
    Projects.get_project!(project.uuid)
  end

  defp assignment!(project, attrs \\ %{}) do
    {:ok, a} =
      Projects.create_assignment(
        Map.merge(
          %{
            "project_uuid" => project.uuid,
            "task_uuid" => fixture_task().uuid,
            "status" => "todo"
          },
          attrs
        )
      )

    a
  end

  defp embed(conn, project, actor_uuid, extra \\ %{}) do
    {:ok, _} = PhoenixKitProjects.Members.add_member(project, actor_uuid, role: "member")

    live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
      session: Map.merge(%{"id" => project.uuid, "current_user_uuid" => actor_uuid}, extra)
    )
  end

  describe "no lone words on a row (item 8)" do
    test "an embed has no \"Projects\" link above its title", %{conn: conn, actor_uuid: actor} do
      project = started_project()
      {:ok, _view, html} = embed(conn, project, actor)

      refute html =~ "hero-arrow-left"
      assert html =~ project.name
    end
  end

  describe "no \"(optional)\" (item 17)" do
    test "the log-time and reopen dialogs carry no \"(optional)\"", %{conn: conn} do
      project = started_project()
      a = assignment!(project, %{"status" => "done"})
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      html = render_click(view, "open_log_time", %{"uuid" => a.uuid})
      assert html =~ ~s(id="work-entry-form-#{project.uuid}")
      refute html =~ "(optional)"

      render_click(view, "close_log_time", %{})
      html = render_click(view, "ask_reopen", %{"uuid" => a.uuid})
      assert html =~ ~s(id="reopen-form-#{project.uuid}")
      refute html =~ ~r/optional/i
    end
  end

  describe "confirm dialogs (item 10)" do
    test "deleting a task asks one question, names it, and says its subtasks go too",
         %{conn: conn} do
      project = started_project()
      parent = assignment!(project)
      child = assignment!(project)
      grandchild = assignment!(project)
      {:ok, _} = PhoenixKitProjects.Outline.move(child, parent.uuid, :last)
      {:ok, _} = PhoenixKitProjects.Outline.move(grandchild, child.uuid, :last)
      label = Assignment.label(Projects.get_assignment(parent.uuid))

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      html =
        view
        |> element(~s(#assignment-menu-#{parent.uuid} [phx-value-event="remove_assignment"]))
        |> render_click()

      assert html =~ "Delete task “#{label}”?"
      assert html =~ "Its 2 subtasks are deleted too."
      refute html =~ "Do you want to continue?"
      # No warning box repeating the question.
      refute html =~ "bg-warning/10"

      html = render_click(view, "confirm_action_ok", %{})
      assert html =~ "Task deleted."
      assert Projects.get_assignment(parent.uuid) == nil
    end

    test "a task with nothing under it gets no body line", %{conn: conn} do
      project = started_project()
      a = assignment!(project)
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      html =
        view
        |> element(~s(#assignment-menu-#{a.uuid} [phx-value-event="remove_assignment"]))
        |> render_click()

      assert html =~ "Delete task “"
      refute html =~ "deleted too"
    end
  end

  # The boss's third list, items 2, 3, 10.
  # The boss's third list, items 11, 13, 14.
  describe "the task row (third list)" do
    test "the handle runs the card's height; the ref sits at the end of the title row",
         %{conn: conn} do
      project = started_project()
      a = assignment!(project)
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      card = view |> element(~s([data-pkp-card="#{a.uuid}"])) |> render()
      # The handle is a column of the card, not part of the title row.
      assert card =~
               ~r/data-pkp-card="#{a.uuid}"[^>]*>\s*<span[^>]*data-pkp-rel[^>]*><\/span>\s*<span[^>]*pk-drag-handle[^>]*self-stretch/

      # The status opens the statuses; the ref is beside the row's icons.
      assert has_element?(view, "#row-status-pop-#{a.uuid} #row-status-#{a.uuid}-done")
      assert card =~ ~r/data-ref=.*assignment-menu-#{a.uuid}/s
    end

    test "the status chip runs the same step as the ⋮ list", %{conn: conn} do
      project = started_project()
      a = assignment!(project)
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      view |> element("#row-status-#{a.uuid}-in_progress") |> render_click()
      assert Projects.get_assignment(a.uuid).status == "in_progress"
    end

    test "Done on a finished task's chip asks why (reopen), nothing written yet",
         %{conn: conn} do
      project = started_project()
      a = assignment!(project, %{"status" => "done"})
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      html = view |> element("#row-status-#{a.uuid}-todo") |> render_click()
      assert html =~ ~s(id="reopen-form-#{project.uuid}")
      assert Projects.get_assignment(a.uuid).status == "done"
    end

    test "the deadline chip takes a day and a typed time, and Clear removes it",
         %{conn: conn} do
      project = started_project()

      a =
        assignment!(project, %{
          "deadline" =>
            DateTime.add(DateTime.utc_now(), 3 * 86_400, :second) |> DateTime.truncate(:second)
        })

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      assert has_element?(view, "#row-deadline-form-#{a.uuid}")

      view
      |> form("#row-deadline-form-#{a.uuid}", %{"date" => "2030-05-06", "time" => "1730"})
      |> render_submit()

      at = Projects.get_assignment(a.uuid).deadline
      assert DateTime.to_date(at) == ~D[2030-05-06]

      render_submit(view, "save_deadline", %{"uuid" => a.uuid, "clear" => "1"})
      assert is_nil(Projects.get_assignment(a.uuid).deadline)
    end

    test "a typed clock reads as people type it" do
      clock = &ProjectShowLive.typed_clock/1
      assert clock.("17") == {:ok, ~T[17:00:00]}
      assert clock.("1730") == {:ok, ~T[17:30:00]}
      assert clock.("9:05") == {:ok, ~T[09:05:00]}
      assert clock.("5:30 pm") == {:ok, ~T[17:30:00]}
      assert clock.("12am") == {:ok, ~T[00:00:00]}
      assert clock.("") == {:ok, ~T[17:00:00]}
      assert clock.("25") == :bad_time
    end

    test "one person assigned links to their staff page", %{conn: conn} do
      n = System.unique_integer([:positive])
      {:ok, dept} = Departments.create(%{"name" => "Dept-#{n}"})
      {:ok, team} = Teams.create(%{"name" => "Fitters-#{n}", "department_uuid" => dept.uuid})
      project = started_project()
      assignment!(project, %{"assigned_team_uuid" => team.uuid})
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      assert has_element?(view, ~s(a[href*="/admin/staff/teams/#{team.uuid}"]), "Fitters-#{n}")
    end
  end

  describe "the header as the project's settings say" do
    defp with_header(project, header) do
      {:ok, project} =
        Projects.update_project(project, %{
          "external_url" => "/admin/orders/1",
          "external_label" => "Order 1",
          "settings" => Map.put(project.settings || %{}, "header", header)
        })

      project
    end

    test "the link hides by default inside a host page and shows on the project's own page",
         %{conn: conn, actor_uuid: actor} do
      project = started_project() |> with_header(%{})
      {:ok, _view, html} = embed(conn, project, actor)
      refute html =~ "data-project-link"

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")
      assert has_element?(view, "[data-project-link]")
    end

    test "shown with the back arrow, it opens here without a reload",
         %{conn: conn, actor_uuid: actor} do
      project =
        started_project()
        |> with_header(%{"link_show" => "always", "link_icon" => "back", "link_target" => "here"})

      {:ok, _view, html} = embed(conn, project, actor)
      [link] = Regex.run(~r/<a[^>]*data-project-link[^>]*>.*?<\/a>/s, html)
      assert link =~ ~s(data-phx-link="redirect")
      refute link =~ "_blank"
      assert link =~ "hero-arrow-up-left"
      refute link =~ "hero-arrow-top-right-on-square"
    end

    test "Ongoing, since and open tasks are off unless switched on",
         %{conn: conn, actor_uuid: actor} do
      project = started_project()

      {:ok, project} =
        Projects.update_project(project, %{
          "settings" => Map.put(project.settings || %{}, "completion", "manual")
        })

      _ = assignment!(project)

      {:ok, _view, html} = embed(conn, project, actor)
      refute html =~ "project-ongoing-"
      refute html =~ "open task"

      project = with_header(project, %{"ongoing" => true, "open_tasks" => true, "since" => true})
      {:ok, _view, html} = embed(conn, project, actor)
      assert html =~ "project-ongoing-"
      assert html =~ "1 open task"
      assert html =~ "since "
    end

    test "unknown header values read as the defaults" do
      header =
        Project.header(%{
          settings: %{"header" => %{"link_show" => "bogus", "ongoing" => "yes"}}
        })

      assert header["link_show"] == "auto"
      assert header["ongoing"] == false
    end
  end

  describe "the header line (item 19)" do
    test "an embed puts the name, key, link and ⋮ on one centred line",
         %{conn: conn, actor_uuid: actor} do
      project = started_project()

      {:ok, project} =
        Projects.update_project(project, %{
          "external_url" => "/somewhere",
          "settings" => Map.put(project.settings || %{}, "header", %{"link_show" => "always"})
        })

      {:ok, _view, html} = embed(conn, project, actor)

      [line] =
        Regex.run(
          ~r/<div class="flex flex-wrap items-center gap-2 min-w-0">.*?<\/h1>.*?data-project-link.*?project-header-menu-/s,
          html
        )

      assert line =~ project.key
    end
  end

  describe "time logging on the project and billable time (item 20)" do
    test "both are off by default: no project Log time, no Logged bar, no billable box",
         %{conn: conn} do
      project = started_project()
      a = assignment!(project)
      fx = Features.gates(project)
      refute fx.project_time
      refute fx.billable

      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      refute html =~ "project-logged-"

      # A task's own Log time stays.
      html = render_click(view, "open_log_time", %{"uuid" => a.uuid})
      assert html =~ ~s(id="work-entry-form-#{project.uuid}")
      refute html =~ ~s(id="log-time-billable-#{project.uuid}")

      # A forged project-level log is refused, and a forged billable mark
      # is dropped.
      render_click(view, "close_log_time", %{})
      assert render_click(view, "open_log_time", %{}) =~ "turned off for this project"

      render_click(view, "open_log_time", %{"uuid" => a.uuid})

      render_submit(view, "save_work_entry", %{
        "duration" => %{"amount" => "60", "unit" => "minutes"},
        "billable" => "true"
      })

      [entry] = PhoenixKitProjects.Ledger.list_entries(project.uuid)
      refute entry.billable
    end

    test "a project that turns them on gets both", %{conn: conn} do
      project = started_project()
      {:ok, project} = Features.set_flags(project, %{"project_time" => true, "billable" => true})

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")
      html = render_click(view, "open_log_time", %{})
      assert html =~ "On the project overall"
      assert html =~ ~s(id="log-time-billable-#{project.uuid}")
    end

    test "the site default is set on the settings page and a project inherits it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/settings/projects")

      view |> element("#site-flag-project_time") |> render_click()
      assert Features.site_default_values()["project_time"] == true

      project = started_project()
      assert Features.gates(project).project_time

      # The project's own value still wins.
      {:ok, project} = Features.set_flags(project, %{"project_time" => false})
      refute Features.gates(project).project_time
    end

    test "the site default's box sets the value it is switched to, never a flip",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/settings/projects")

      # Two presses sent from the same drawing (a double click, a resent
      # event) both mean "on": the second must not turn it off again.
      press = %{"key" => "project_time", "enabled" => "true"}
      render_click(view, "toggle_site_flag", press)
      render_click(view, "toggle_site_flag", press)
      assert Features.site_default_values()["project_time"] == true

      # The box itself carries the value it switches to.
      assert has_element?(view, ~s(#site-flag-project_time[phx-value-enabled="false"]))
    end
  end

  describe "the header line instead of full-width bars (item 32)" do
    test "a not-started project gets a small Start in the header, no bar", %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

      [crumbs] = Regex.run(~r/<div id="test-breadcrumb".*?<div id="test-flashes"/s, html)
      assert crumbs =~ ~s(phx-click="open_start_modal")
      refute html =~ "Not started — set up tasks, then start"
    end

    # Off by default since the third list (item 3); switched on, it shows.
    test "a started project says since when, quietly, in the header", %{conn: conn} do
      project = started_project()

      {:ok, project} =
        Projects.update_project(project, %{
          "settings" => Map.put(project.settings || %{}, "header", %{"since" => true})
        })

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

      [crumbs] = Regex.run(~r/<div id="test-breadcrumb".*?<div id="test-flashes"/s, html)
      assert crumbs =~ "since "
      refute crumbs =~ "open_start_modal"
      # The full "Started …" is the tooltip, not a bar's text.
      refute html =~ ~r/>\s*Started [A-Z]/
    end

    test "with time on the project on, the logged time is a header chip", %{conn: conn} do
      project = started_project()
      {:ok, project} = Features.set_flags(project, %{"project_time" => true})
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

      [crumbs] = Regex.run(~r/<div id="test-breadcrumb".*?<div id="test-flashes"/s, html)
      assert crumbs =~ ~s(id="project-logged-#{project.uuid}")
      refute html =~ "Logged:"
    end
  end

  describe "Change status (item 4; a side list in ⋮ since list 2, item 13)" do
    test "the ⋮ menu lists the statuses beside it, the current one marked", %{conn: conn} do
      project = started_project()
      a = assignment!(project)
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      menu = view |> element("#assignment-menu-#{a.uuid}") |> render()
      assert menu =~ "data-pkp-submenu-toggle"
      assert menu =~ ~r/id="status-menu-#{a.uuid}-todo"[^>]*aria-checked="true"/s
      assert menu =~ ~r/id="status-menu-#{a.uuid}-done"[^>]*aria-checked="false"/s
      refute has_element?(view, ~s([phx-click="open_status_change"]))

      view |> element("#status-menu-#{a.uuid}-in_progress") |> render_click()
      assert Projects.get_assignment(a.uuid).status == "in_progress"
    end

    test "Can be started from Waiting opens the release dialog, nothing written yet",
         %{conn: conn} do
      project = started_project()
      a = assignment!(project, %{"status" => "waiting"})
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      html = render_click(view, "set_status", %{"uuid" => a.uuid, "status" => "todo"})

      assert html =~ ~s(id="next-up-form-#{project.uuid}")
      assert Projects.get_assignment(a.uuid).status == "waiting"
    end

    test "Done on a task that unlocks another asks next up first", %{conn: conn} do
      project = started_project()
      first = assignment!(project)
      second = assignment!(project, %{"status" => "waiting"})
      {:ok, _} = Projects.add_dependency(second.uuid, first.uuid)
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      html = render_click(view, "set_status", %{"uuid" => first.uuid, "status" => "done"})
      assert html =~ ~s(id="next-up-form-#{project.uuid}")
      assert Projects.get_assignment(first.uuid).status == "todo"
    end

    test "a status changed meanwhile is not overwritten", %{conn: conn} do
      project = started_project()
      a = assignment!(project)
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      # Written behind the page's back (no broadcast), so the page still
      # holds the old status when the pick arrives.
      a |> Ecto.Changeset.change(status: "done") |> Repo.update!()

      html =
        render_click(view, "set_status", %{
          "uuid" => a.uuid,
          "status" => "in_progress",
          "from" => "todo"
        })

      assert html =~ "This task changed meanwhile"
      assert Projects.get_assignment(a.uuid).status == "done"
    end

    # List 2, item 9: the arrows' gutter is filled by the top-level cards
    # until arrows show (`PkpLinks` draws them back).
    test "with connections the cards reach over the arrows' gutter", %{conn: conn} do
      project = started_project()
      first = assignment!(project)
      second = assignment!(project, %{"status" => "waiting"})
      {:ok, _} = Projects.add_dependency(second.uuid, first.uuid)
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

      assert has_element?(view, "#project-task-links-#{project.uuid}.pkp-links-gutter")
      assert has_element?(view, "#task-#{first.uuid} .pkp-row-card")
    end

    test "a board card has the same statuses in a menu of its own", %{conn: conn} do
      project = started_project()
      a = assignment!(project)
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")
      assert has_element?(view, "#board-card-#{a.uuid} #board-status-#{a.uuid}-done")
    end
  end

  describe "the comment tabs (item 25)" do
    setup do
      :ok = PhoenixKitProjects.DataCase.with_comments_module()
      :ok
    end

    defp comment!(type, uuid, user, text) do
      {:ok, c} = PhoenixKitComments.create_comment(type, uuid, user, %{content: text})
      c
    end

    test "All comments lists every task's comments, newest first, under its task",
         %{conn: conn, actor_uuid: actor} do
      project = started_project()
      {:ok, project} = Features.set_flags(project, %{"all_comments" => true})
      a = assignment!(project)
      b = assignment!(project)
      comment!("assignment", a.uuid, actor, "First on A")
      Process.sleep(5)
      comment!("assignment", b.uuid, actor, "Then on B")
      comment!("project", project.uuid, actor, "On the project itself")

      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      assert html =~ ~s(phx-value-tab="all_comments")

      html = render_click(view, "switch_tab", %{"tab" => "all_comments"})
      pane = Regex.run(~r/id="project-all-comments-.*?<\/ul>/s, html) |> hd()
      assert pane =~ "Then on B"
      assert pane =~ "First on A"
      refute pane =~ "On the project itself"
      {b_at, _} = :binary.match(pane, "Then on B")
      {a_at, _} = :binary.match(pane, "First on A")
      assert b_at < a_at
      b_label = Assignment.label(Projects.get_assignment(b.uuid))
      assert pane =~ b_label

      html =
        view
        |> element("#all-comments-filter-#{project.uuid}")
        |> render_change(%{"task" => a.uuid})

      pane = Regex.run(~r/id="project-all-comments-.*?<\/ul>/s, html) |> hd()
      assert pane =~ "First on A"
      refute pane =~ "Then on B"

      html =
        view
        |> element("#all-comments-filter-#{project.uuid}")
        |> render_change(%{"task" => "", "project" => "true"})

      assert html =~ "On the project itself"
    end

    test "each tab has its own switch", %{conn: conn} do
      project = started_project()
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      assert html =~ ~s(phx-value-tab="comments")
      refute html =~ ~s(phx-value-tab="all_comments")

      {:ok, project} =
        Features.set_flags(project, %{"project_comments" => false, "all_comments" => true})

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      refute html =~ ~s(phx-value-tab="comments")
      assert html =~ ~s(phx-value-tab="all_comments")
    end
  end

  describe "sub-project rows like task rows (item 26)" do
    defp subproject!(parent, attrs \\ %{}) do
      {:ok, %{child_project: child, assignment: link}} =
        Projects.create_subproject(parent.uuid, Map.merge(%{"name" => "Phase"}, attrs))

      {child, link}
    end

    test "a waiting sub-project is released through the same dialog as a task",
         %{conn: conn} do
      parent = started_project()
      {child, link} = subproject!(parent)
      {:ok, link} = Projects.update_assignment_status(link, %{status: "waiting"})
      _ = child

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{parent.uuid}")

      assert has_element?(
               view,
               "#assignment-menu-#{link.uuid} #status-menu-#{link.uuid}-todo"
             )

      assert has_element?(view, ~s([data-pkp-card="#{link.uuid}"]))

      html = render_click(view, "set_status", %{"uuid" => link.uuid, "status" => "todo"})
      assert html =~ ~s(id="next-up-form-#{parent.uuid}")

      render_submit(view, "next_up_confirm", %{"uuid" => link.uuid})
      assert Projects.get_assignment(link.uuid).status == "todo"
    end

    test "following its tasks: waiting until released, in progress once one starts, done when all are" do
      parent = started_project()
      {child, link} = subproject!(parent)
      {:ok, link} = Projects.update_assignment_status(link, %{status: "waiting"})
      task = assignment!(child)

      Projects.recompute_project_completion(child.uuid)
      assert Projects.get_assignment(link.uuid).status == "waiting"

      {:ok, task} = Projects.update_assignment_status(task, %{status: "in_progress"})
      Projects.recompute_project_completion(child.uuid)
      assert Projects.get_assignment(link.uuid).status == "in_progress"

      {:ok, _} = Projects.update_assignment_status(task, %{status: "done"})
      Projects.recompute_project_completion(child.uuid)
      assert Projects.get_assignment(link.uuid).status == "done"
    end

    test "with the setting off its status is set by hand and stays", %{conn: conn} do
      parent = started_project()
      {:ok, parent} = Features.set_flags(parent, %{"subproject_auto" => false})
      {child, link} = subproject!(parent)
      task = assignment!(child)

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{parent.uuid}")
      assert has_element?(view, "#status-menu-#{link.uuid}-done")

      render_click(view, "set_status", %{"uuid" => link.uuid, "status" => "in_progress"})
      assert Projects.get_assignment(link.uuid).status == "in_progress"

      {:ok, _} = Projects.update_assignment_status(task, %{status: "done"})
      Projects.recompute_project_completion(child.uuid)
      assert Projects.get_assignment(link.uuid).status == "in_progress"
    end

    test "with the setting on, the menu offers only release and hold", %{conn: conn} do
      parent = started_project()
      {_child, link} = subproject!(parent)
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{parent.uuid}")

      assert has_element?(view, "#status-menu-#{link.uuid}-waiting")
      refute has_element?(view, "#status-menu-#{link.uuid}-done")
    end
  end

  describe "the assignee (item 5)" do
    test "a row names its team with no \"Team:\" before it", %{conn: conn} do
      n = System.unique_integer([:positive])
      {:ok, dept} = Departments.create(%{"name" => "Dept-#{n}"})
      {:ok, team} = Teams.create(%{"name" => "Fitters-#{n}", "department_uuid" => dept.uuid})
      project = started_project()
      assignment!(project, %{"assigned_team_uuid" => team.uuid})

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

      assert html =~ "Fitters-#{n}"
      refute html =~ "Team: Fitters-#{n}"
      refute html =~ ~r/Team:\s*<\/span>|Team:\s+Fitters/
      assert html =~ "hero-users"
    end
  end
end
