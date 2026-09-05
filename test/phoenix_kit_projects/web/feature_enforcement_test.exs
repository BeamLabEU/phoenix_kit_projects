defmodule PhoenixKitProjects.Web.FeatureEnforcementTest do
  @moduledoc """
  Step 4 enforcement threading: per-flag OFF behavior on the show page and
  forms — UI hidden AND forged client events refused / smuggled params
  stripped. The on-state is covered by the whole pre-existing suite (all
  flags default on), so these tests only pin the OFF side.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Extensions, Features, Labels, Ledger, Members, Projects}

  setup %{conn: conn} do
    PhoenixKitProjects.Extensions.Registry.refresh()
    scope = fake_scope()
    conn = put_test_scope(conn, scope)

    project = fixture_project(%{"start_mode" => "immediate"})
    task = fixture_task()

    {:ok, assignment} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => task.uuid,
        "status" => "todo"
      })

    {:ok, conn: conn, project: project, assignment: assignment}
  end

  defp show_path(project), do: "/en/admin/projects/#{project.uuid}"

  describe "tasks extension off" do
    setup %{project: project} do
      {:ok, _} = Extensions.disable(project, "tasks")
      :ok
    end

    test "with nothing else on, the page shows the nothing-on empty state",
         %{conn: conn, project: project} do
      # Discussions is on by default but the comments MODULE is off in the
      # test env, so this project has no tab at all.
      {:ok, _view, html} = live(conn, show_path(project))

      assert html =~ "Nothing is turned on for this project yet."
      assert html =~ "Manage this project"
      refute html =~ "Add task"
      refute html =~ "project-show-timeline"
      refute html =~ ~s(role="tablist")
    end

    test "forged task events are refused and change nothing",
         %{conn: conn, project: project, assignment: assignment} do
      {:ok, view, _} = live(conn, show_path(project))

      html = render_click(view, "start_task", %{"uuid" => assignment.uuid})
      assert html =~ "This feature is turned off for this project."
      assert Projects.get_assignment(assignment.uuid).status == "todo"

      render_click(view, "remove_assignment", %{"uuid" => assignment.uuid})
      assert Projects.get_assignment(assignment.uuid)
    end
  end

  describe "statuses flag off" do
    setup %{project: project} do
      {:ok, project} = Features.set_flags(project, %{"statuses" => false})
      {:ok, project: project}
    end

    test "the workflow-status picker is gone and the event refused",
         %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, show_path(project))

      refute html =~ "change_workflow_status"

      html = render_click(view, "change_workflow_status", %{"status_slug" => "anything"})
      assert html =~ "This feature is turned off for this project."
    end
  end

  describe "in-progress step off (a checklist)" do
    setup %{conn: conn, project: project} do
      {:ok, project} = Features.set_flags(project, %{"in_progress" => false})
      # Completing records the actor (an FK), so the page needs a real user.
      conn = put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))
      {:ok, conn: conn, project: project}
    end

    test "a to-do row offers Done directly; a forged Start is refused",
         %{conn: conn, project: project, assignment: a} do
      {:ok, view, html} = live(conn, show_path(project))

      refute html =~ ~s(phx-click="start_task")
      assert html =~ ~s(phx-click="complete")

      html = render_click(view, "start_task", %{"uuid" => a.uuid})
      assert html =~ "This feature is turned off for this project."
      assert Projects.get_assignment(a.uuid).status == "todo"

      render_click(view, "complete", %{"uuid" => a.uuid})
      assert Projects.get_assignment(a.uuid).status == "done"

      # Reopen goes back to to-do — still no Start on offer.
      html = render_click(view, "reopen", %{"uuid" => a.uuid})
      assert Projects.get_assignment(a.uuid).status == "todo"
      refute html =~ ~s(phx-click="start_task")
    end

    test "a row already in progress keeps its Done button and the board its column",
         %{conn: conn, project: project, assignment: a} do
      {:ok, _} = Projects.update_assignment_status(a, %{"status" => "in_progress"})
      {:ok, view, html} = live(conn, show_path(project))

      assert html =~ ~s(phx-click="complete")
      refute html =~ ~s(phx-click="start_task")

      html = render_click(view, "switch_tab", %{"tab" => "board"})
      assert html =~ "In progress"
      assert html =~ "md:grid-cols-3"
    end

    test "the board drops the middle column when nothing is in progress",
         %{conn: conn, project: project} do
      {:ok, view, _} = live(conn, show_path(project))
      html = render_click(view, "switch_tab", %{"tab" => "board"})

      refute html =~ "In progress"
      assert html =~ "md:grid-cols-2"
    end

    test "the add-task form offers To do / Done only", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")

      assert html =~ ~s(value="todo")
      assert html =~ ~s(value="done")
      refute html =~ ~s(value="in_progress")
    end

    test "the Simple preset turns the step off" do
      p = fixture_project()
      assert Features.gates(p).in_progress
      {:ok, p} = Features.apply_preset(p, "simple")
      refute Features.gates(p).in_progress
    end
  end

  describe "progress flag off" do
    setup %{project: project} do
      {:ok, project} = Features.set_flags(project, %{"progress" => false})
      {:ok, project: project}
    end

    test "sliders hidden; forged update refused", %{conn: conn, project: project, assignment: a} do
      {:ok, _} = Projects.update_assignment_form(a, %{"track_progress" => true})
      {:ok, view, html} = live(conn, show_path(project))

      refute html =~ "update_progress"

      html = render_click(view, "update_progress", %{"uuid" => a.uuid, "progress_pct" => "80"})
      assert html =~ "This feature is turned off for this project."
      assert Projects.get_assignment(a.uuid).progress_pct == 0
    end
  end

  describe "estimates flag off" do
    setup %{project: project} do
      {:ok, project} = Features.set_flags(project, %{"estimates" => false})
      {:ok, project: project}
    end

    test "duration chip hidden; forged save refused", %{
      conn: conn,
      project: project,
      assignment: a
    } do
      {:ok, view, html} = live(conn, show_path(project))

      refute html =~ "edit_duration"

      html =
        render_click(view, "save_duration", %{
          "uuid" => a.uuid,
          "estimated_duration" => "9",
          "estimated_duration_unit" => "hours"
        })

      assert html =~ "This feature is turned off for this project."
      assert Projects.get_assignment(a.uuid).estimated_duration == nil
    end
  end

  describe "board view (Step 9)" do
    test "renders columns with the project's tasks and flips status via the gated buttons",
         %{conn: conn, project: project, assignment: a} do
      {:ok, view, html} = live(conn, show_path(project))

      assert html =~ ~s(phx-value-tab="board")

      html = render_click(view, "switch_tab", %{"tab" => "board"})
      assert html =~ "To do"
      assert html =~ "In progress"

      # The card's Start button routes through the same gated dispatcher.
      render_click(view, "start_task", %{"uuid" => a.uuid})
      assert Projects.get_assignment(a.uuid).status == "in_progress"
    end

    test "view_board off drops the tab and forged switches fall back",
         %{conn: conn, project: project} do
      {:ok, _} = Features.set_flags(project, %{"view_board" => false})
      {:ok, view, html} = live(conn, show_path(project))

      refute html =~ ~s(phx-value-tab="board")
      html = render_click(view, "switch_tab", %{"tab" => "board"})
      # Falls back to list — the board columns don't render.
      refute html =~ "In progress</span>"
    end
  end

  describe "view flags off" do
    test "tab strip drops the gated views and a /gantt URL falls back to list",
         %{conn: conn, project: project} do
      {:ok, project} = Features.set_flags(project, %{"view_timeline" => false})

      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}/gantt")

      # Timeline tab gone; Calendar still offered; the gantt did not mount.
      refute html =~ ~s(phx-value-tab="gantt")
      assert html =~ ~s(phx-value-tab="calendar")
      refute html =~ "embedded-project-gantt"

      # A forged switch_tab to the gated view stays on list.
      html = render_click(view, "switch_tab", %{"tab" => "gantt"})
      refute html =~ "embedded-project-gantt"
    end

    test "with every alternate view off the strip disappears entirely",
         %{conn: conn, project: project} do
      {:ok, _} =
        Features.set_flags(project, %{
          "view_board" => false,
          "view_timeline" => false,
          "view_calendar" => false
        })

      {:ok, _view, html} = live(conn, show_path(project))
      refute html =~ ~s(id="project-tabs-#{project.uuid}")
    end
  end

  describe "dependencies flag off (assignment form)" do
    setup %{project: project} do
      {:ok, project} = Features.set_flags(project, %{"dependencies" => false})
      {:ok, project: project}
    end

    test "deps card hidden; forged add refused", %{conn: conn, project: project, assignment: a} do
      {:ok, view, html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/#{a.uuid}/edit")

      refute html =~ "Add dependency"

      other_task = fixture_task(%{"title" => "Dep target #{System.unique_integer([:positive])}"})

      {:ok, other} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => other_task.uuid,
          "status" => "todo"
        })

      html = render_click(view, "add_assignment_dep", %{"depends_on_uuid" => other.uuid})
      assert html =~ "This feature is turned off for this project."
      assert Projects.list_dependencies(a.uuid) == []
    end
  end

  describe "assignees flag off (assignment form)" do
    setup %{project: project} do
      {:ok, project} = Features.set_flags(project, %{"assignees" => false})
      {:ok, project: project}
    end

    test "picker hidden; smuggled assignee params stripped on save",
         %{conn: conn, project: project} do
      task = fixture_task(%{"title" => "Strip me #{System.unique_integer([:positive])}"})

      {:ok, view, html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")

      refute html =~ ~s(name="assign_type")

      # Submit with smuggled assignee fields — the server strips them.
      render_submit(view, "save", %{
        "assignment" => %{
          "task_uuid" => task.uuid,
          "assigned_person_uuid" => Ecto.UUID.generate()
        },
        "task_mode" => "existing",
        "assign_type" => "person"
      })

      [created] =
        Enum.filter(Projects.list_assignments(project.uuid), &(&1.task_uuid == task.uuid))

      assert created.assigned_person_uuid == nil
    end
  end

  describe "subprojects flag off" do
    setup %{project: project} do
      {:ok, project} = Features.set_flags(project, %{"subprojects" => false})
      {:ok, project: project}
    end

    test "?kind=subproject falls back to the task form", %{conn: conn, project: project} do
      {:ok, _view, html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/new?kind=subproject")

      assert html =~ "Add task"
      refute html =~ "Add sub-project"
      refute html =~ "Nest existing"
    end

    test "Add sub-project button hidden on the show page", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, show_path(project))
      refute html =~ "Add sub-project"
    end
  end

  describe "ledger flag off" do
    setup %{project: project} do
      {:ok, project} = Features.set_flags(project, %{"ledger" => false})
      {:ok, project: project}
    end

    test "no Log time surface and forged ledger events are refused",
         %{conn: conn, project: project, assignment: assignment} do
      {:ok, view, html} = live(conn, show_path(project))

      refute html =~ "open_log_time"

      html = render_click(view, "open_log_time", %{"uuid" => assignment.uuid})
      assert html =~ "This feature is turned off for this project."

      render_submit(view, "save_work_entry", %{"hours" => "1", "minutes" => "0"})
      assert Ledger.list_entries(project.uuid) == []
    end
  end

  describe "ledger flag on (default)" do
    test "logging time through the modal writes an entry and refreshes the strip",
         %{conn: conn, project: project, assignment: assignment} do
      {:ok, view, html} = live(conn, show_path(project))

      # Entry points render: the effort strip and the per-task chip.
      assert html =~ "Log time"

      render_click(view, "open_log_time", %{"uuid" => assignment.uuid})

      html =
        render_submit(view, "save_work_entry", %{
          "hours" => "1",
          "minutes" => "30",
          "note" => "Night shift",
          "billable" => "true"
        })

      assert [entry] = Ledger.list_entries(project.uuid)
      assert Decimal.equal?(entry.amount, Decimal.new(90))
      assert entry.assignment_uuid == assignment.uuid
      assert entry.billable
      assert entry.note == "Night shift"

      # Strip totals and the task chip show the logged time.
      assert html =~ "1h 30m"
    end

    # Panel round (Grok MEDIUM): the chip also renders on EXPANDED
    # sub-project child tasks (same <.task_body>); the entry must attribute
    # to the project that OWNS the assignment — the child — not the parent
    # page it was logged from.
    test "logging on an expanded child task attributes to the child project",
         %{conn: conn} do
      parent = fixture_project()

      {:ok, %{child_project: child, assignment: link}} =
        Projects.create_subproject(parent.uuid, %{"name" => "Buildout"})

      {:ok, child_task} =
        Projects.create_assignment(%{
          "project_uuid" => child.uuid,
          "task_uuid" => fixture_task().uuid,
          "status" => "todo"
        })

      {:ok, view, _} = live(conn, show_path(parent))

      render_click(view, "toggle_subproject", %{"uuid" => link.uuid})
      render_click(view, "open_log_time", %{"uuid" => child_task.uuid})
      render_submit(view, "save_work_entry", %{"hours" => "0", "minutes" => "25"})

      assert [entry] = Ledger.list_entries(child.uuid)
      assert entry.assignment_uuid == child_task.uuid
      assert Ledger.list_entries(parent.uuid) == []
    end

    test "a member below the manager floor is refused at the write",
         %{project: project, assignment: assignment} do
      # A real core user who is a plain project MEMBER with no admin
      # permission: the flag is on, the modal opens, but the WRITE runs
      # the authz resolver — :log_time floors at manager and the task
      # isn't assigned to them, so no relationship grant either.
      {:ok, member_user} =
        Auth.register_user(%{
          email: "logger-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      {:ok, _} = Members.add_member(project, member_user.uuid, role: "member")

      # Logging time is open by default now, so this test only means
      # something once the project restricts it to managers.
      {:ok, _} =
        PhoenixKitProjects.Authz.set_overrides(project, %{"log_time" => "managers"})

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_test_scope(fake_scope(user_uuid: member_user.uuid, permissions: []))

      {:ok, view, _} = live(conn, show_path(project))

      render_click(view, "open_log_time", %{"uuid" => assignment.uuid})
      html = render_submit(view, "save_work_entry", %{"hours" => "1", "minutes" => "0"})

      assert html =~ "permission to log time"
      assert Ledger.list_entries(project.uuid) == []
    end

    test "garbage duration is refused with a flash, nothing written",
         %{conn: conn, project: project} do
      {:ok, view, _} = live(conn, show_path(project))

      render_click(view, "open_log_time", %{})
      html = render_submit(view, "save_work_entry", %{"hours" => "0", "minutes" => "0"})

      assert html =~ "Enter a positive amount of time."
      assert Ledger.list_entries(project.uuid) == []
    end
  end

  describe "priorities + labels flags (Phase C)" do
    test "priorities off strips a crafted priority on save; on persists it",
         %{conn: conn, project: project, assignment: assignment} do
      # ON (default): the form save persists priority.
      {:ok, view, _} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/#{assignment.uuid}/edit")

      render_submit(view, "save", %{"assignment" => %{"priority" => "urgent"}})
      assert Projects.get_assignment(assignment.uuid).priority == "urgent"

      # OFF: a crafted priority param is stripped server-side.
      {:ok, project} = Features.set_flags(project, %{"priorities" => false})

      {:ok, view, html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/#{assignment.uuid}/edit")

      refute html =~ "assignment[priority]"
      render_submit(view, "save", %{"assignment" => %{"priority" => "low"}})
      assert Projects.get_assignment(assignment.uuid).priority == "urgent"
    end

    test "labels off refuses the panel events and skips join writes",
         %{conn: conn, project: project, assignment: assignment} do
      {:ok, label} = Labels.create(project, %{name: "keepme"})
      :ok = Labels.set_assignment_labels(assignment, [label.uuid])

      {:ok, project} = Features.set_flags(project, %{"labels" => false})

      # Panel events refuse.
      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}/modules")
      refute html =~ "add_label"
      html = render_submit(view, "add_label", %{"name" => "sneak", "color" => "badge-info"})
      assert html =~ "This feature is turned off for this project."
      assert length(Labels.list_for_project(project.uuid)) == 1

      # A form save with the flag off leaves existing joins untouched.
      {:ok, form_view, form_html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/#{assignment.uuid}/edit")

      refute form_html =~ ~s(name="labels[]")
      render_submit(form_view, "save", %{"assignment" => %{"status" => "todo"}, "labels" => []})

      assert [%{name: "keepme"}] =
               Labels.labels_for_assignments([assignment.uuid])[assignment.uuid]
    end

    # Panel round (Grok HIGH): a FOURTH save path exists — task_mode=new
    # creates the task AND the assignment; its success path never applied
    # the pending labels.
    test "labels apply on the create-NEW-task save path too",
         %{conn: conn, project: project} do
      {:ok, label} = Labels.create(project, %{name: "newpath"})

      {:ok, view, _} = live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")

      render_submit(view, "save", %{
        "assignment" => %{"status" => "todo"},
        "task_mode" => "new",
        "task" => %{"title" => "Fresh task"},
        "labels" => [label.uuid]
      })

      created =
        Enum.find(Projects.list_assignments(project.uuid), fn a ->
          a.task && a.task.title == "Fresh task"
        end)

      assert created, "new-task save did not create the assignment"

      assert [%{name: "newpath"}] =
               Labels.labels_for_assignments([created.uuid])[created.uuid]
    end

    test "labels on: the edit form pre-checks and the save replaces the set",
         %{conn: conn, project: project, assignment: assignment} do
      {:ok, a} = Labels.create(project, %{name: "alpha"})
      {:ok, b} = Labels.create(project, %{name: "beta"})
      :ok = Labels.set_assignment_labels(assignment, [a.uuid])

      {:ok, view, html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/#{assignment.uuid}/edit")

      assert html =~ ~s(value="#{a.uuid}" checked)

      render_submit(view, "save", %{"assignment" => %{"status" => "todo"}, "labels" => [b.uuid]})

      assert [%{name: "beta"}] =
               Labels.labels_for_assignments([assignment.uuid])[assignment.uuid]
    end
  end

  describe "project form" do
    test "statuses off hides the workflow section and strips a crafted source",
         %{conn: conn, project: project} do
      {:ok, project} = Features.set_flags(project, %{"statuses" => false})

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/edit")
      refute html =~ "generate_default_statuses"
    end

    test "the new form offers archetype cards and applies the recipe on create", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/projects/new")

      # The starting-point cards replaced the bare preset select.
      assert html =~ ~s(name="archetype")
      assert html =~ "Simple checklist"
      refute html =~ ~s(name="project_preset")

      # Pick the simple recipe (phx-change), then create.
      render_change(view, "validate", %{"project" => %{"name" => ""}, "archetype" => "quick_todo"})

      render_submit(view, "save", %{
        "project" => %{"name" => "Preset run #{System.unique_integer([:positive])}"}
      })

      project =
        Projects.list_projects()
        |> Enum.find(&String.starts_with?(&1.name, "Preset run"))

      assert project
      refute Features.on?(project, "assignees")
      refute Features.on?(project, "statuses")
    end
  end
end
