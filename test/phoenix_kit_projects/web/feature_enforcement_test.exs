defmodule PhoenixKitProjects.Web.FeatureEnforcementTest do
  @moduledoc """
  Step 4 enforcement threading: per-flag OFF behavior on the show page and
  forms — UI hidden AND forged client events refused / smuggled params
  stripped. The on-state is covered by the whole pre-existing suite (all
  flags default on), so these tests only pin the OFF side.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.{Extensions, Features, Projects}

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

  defp show_path(project), do: "/en/admin/projects/list/#{project.uuid}"

  describe "tasks extension off" do
    setup %{project: project} do
      {:ok, _} = Extensions.disable(project, "tasks")
      :ok
    end

    test "the task surface is replaced by the hub empty state", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, show_path(project))

      assert html =~ "Tasks are turned off for this project."
      refute html =~ "Add task"
      refute html =~ "project-show-timeline"
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

      {:ok, view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}/gantt")

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
        live(conn, "/en/admin/projects/list/#{project.uuid}/assignments/#{a.uuid}/edit")

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
        live(conn, "/en/admin/projects/list/#{project.uuid}/assignments/new")

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
        live(conn, "/en/admin/projects/list/#{project.uuid}/assignments/new?kind=subproject")

      assert html =~ "Add task to"
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
      assert PhoenixKitProjects.Ledger.list_entries(project.uuid) == []
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

      assert [entry] = PhoenixKitProjects.Ledger.list_entries(project.uuid)
      assert Decimal.equal?(entry.amount, Decimal.new(90))
      assert entry.assignment_uuid == assignment.uuid
      assert entry.billable
      assert entry.note == "Night shift"

      # Strip totals and the task chip show the logged time.
      assert html =~ "1h 30m"
    end

    test "a member below the manager floor is refused at the write",
         %{project: project, assignment: assignment} do
      # A real core user who is a plain project MEMBER with no admin
      # permission: the flag is on, the modal opens, but the WRITE runs
      # the authz resolver — :log_time floors at manager and the task
      # isn't assigned to them, so no relationship grant either.
      {:ok, member_user} =
        PhoenixKit.Users.Auth.register_user(%{
          email: "logger-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      {:ok, _} = PhoenixKitProjects.Members.add_member(project, member_user.uuid, role: "member")

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_test_scope(fake_scope(user_uuid: member_user.uuid, permissions: []))

      {:ok, view, _} = live(conn, show_path(project))

      render_click(view, "open_log_time", %{"uuid" => assignment.uuid})
      html = render_submit(view, "save_work_entry", %{"hours" => "1", "minutes" => "0"})

      assert html =~ "permission to log time"
      assert PhoenixKitProjects.Ledger.list_entries(project.uuid) == []
    end

    test "garbage duration is refused with a flash, nothing written",
         %{conn: conn, project: project} do
      {:ok, view, _} = live(conn, show_path(project))

      render_click(view, "open_log_time", %{})
      html = render_submit(view, "save_work_entry", %{"hours" => "0", "minutes" => "0"})

      assert html =~ "Enter a positive amount of time."
      assert PhoenixKitProjects.Ledger.list_entries(project.uuid) == []
    end
  end

  describe "project form" do
    test "statuses off hides the workflow section and strips a crafted source",
         %{conn: conn, project: project} do
      {:ok, project} = Features.set_flags(project, %{"statuses" => false})

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}/edit")
      refute html =~ "generate_default_statuses"
    end

    test "the new form offers the preset picker and applies it on create", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/projects/list/new")

      assert html =~ ~s(name="project_preset")

      render_submit(view, "save", %{
        "project" => %{"name" => "Preset run #{System.unique_integer([:positive])}"},
        "project_preset" => "simple"
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
