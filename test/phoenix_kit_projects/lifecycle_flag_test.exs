defmodule PhoenixKitProjects.LifecycleFlagTest do
  @moduledoc """
  A simple checklist has no beginning and no end.

  The `simple` preset used to leave the whole start/finish ceremony on: the
  hub asked the reader to "start" a shared to-do list, parked it in the
  dashboard's not-started bucket until they did, then congratulated them
  for "completing" it when the last box was ticked. It also left the work
  ledger on, which put a `Logged: 0m` readout on a list nobody is billing.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.{Features, Projects}

  setup do
    PhoenixKitProjects.Extensions.Registry.refresh()
    :ok
  end

  defp checklist do
    {:ok, project} =
      Projects.create_project(%{"name" => "List #{uniq()}", "start_mode" => "immediate"})

    {:ok, project} = Features.apply_preset(project, "simple")
    project
  end

  defp uniq, do: System.unique_integer([:positive])

  describe "the simple preset" do
    test "turns off the lifecycle, the ledger and the board" do
      project = checklist()

      refute Features.on?(project, "lifecycle")
      refute Features.on?(project, "ledger"), "a checklist showed a Logged: 0m readout"
      refute Features.on?(project, "view_board"), "a board view of statuses this preset turns off"
    end

    test "leaves every other project alone — the flag defaults on" do
      {:ok, project} =
        Projects.create_project(%{"name" => "Normal #{uniq()}", "start_mode" => "immediate"})

      assert Features.on?(project, "lifecycle"),
             "existing projects must be unchanged with no backfill"
    end
  end

  describe "dashboard buckets" do
    test "a checklist is running from the moment it exists" do
      project = checklist()

      assert is_nil(project.started_at)

      assert Enum.any?(Projects.list_active_projects(), &(&1.uuid == project.uuid)),
             "a checklist that never starts must not be invisible"

      refute Enum.any?(Projects.list_setup_projects(), &(&1.uuid == project.uuid)),
             "a checklist sat in the not-started bucket forever"
    end

    test "a normal unstarted project still waits to be started" do
      {:ok, project} =
        Projects.create_project(%{"name" => "Normal #{uniq()}", "start_mode" => "immediate"})

      refute Enum.any?(Projects.list_active_projects(), &(&1.uuid == project.uuid))
      assert Enum.any?(Projects.list_setup_projects(), &(&1.uuid == project.uuid))
    end
  end

  describe "completion" do
    test "ticking the last box does not 'complete' a checklist" do
      project = checklist()
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, _} = Projects.update_assignment_status(assignment, %{status: "done"})

      assert Projects.recompute_project_completion(project.uuid) == :ok
      assert is_nil(Projects.get_project(project.uuid).completed_at)
    end

    test "a project WITH a lifecycle still completes" do
      {:ok, project} =
        Projects.create_project(%{"name" => "Normal #{uniq()}", "start_mode" => "immediate"})

      {:ok, project} = Projects.start_project(project)
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, _} = Projects.update_assignment_status(assignment, %{status: "done"})

      assert {:completed, _} = Projects.recompute_project_completion(project.uuid)
    end
  end

  describe "the rendered hub" do
    setup %{conn: conn} do
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "a checklist shows neither the start bar nor the effort readout", %{conn: conn} do
      project = checklist()

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      refute html =~ "Not started", "the hub still asked a checklist to be started"
      refute html =~ "Start project"
      refute html =~ "Start now"
      refute html =~ "Logged:", "the hub still showed a time readout on a checklist"
    end

    test "a normal project still shows both", %{conn: conn} do
      {:ok, project} =
        Projects.create_project(%{"name" => "Normal #{uniq()}", "start_mode" => "immediate"})

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      assert html =~ "Not started"
      assert html =~ "Logged:"
    end
  end

  describe "backfill for checklists made before the fix" do
    # New checklists get the corrected preset; existing ones can't, because
    # absence means "inherit the default" and the default is on. Max's own
    # list was exactly this: eleven flags off, ledger and lifecycle absent.

    setup do
      PhoenixKit.Settings.update_setting("projects_checklist_flags_backfilled", "false")
      :ok
    end

    test "completes the bundle on a project carrying the old preset" do
      {:ok, project} =
        Projects.create_project(%{"name" => "Old list #{uniq()}", "start_mode" => "immediate"})

      old_bundle =
        Map.new(
          ~w(assignees priorities labels estimates progress dependencies
             statuses scheduling subprojects view_timeline view_calendar),
          &{&1, false}
        )

      {:ok, project} = Features.set_flags(project, old_bundle)
      assert Features.on?(project, "lifecycle"), "precondition: the old preset left it on"

      PhoenixKitProjects.migrate_legacy()

      project = Projects.get_project(project.uuid)
      refute Features.on?(project, "lifecycle")
      refute Features.on?(project, "ledger")
      refute Features.on?(project, "view_board")
    end

    test "leaves a project that merely resembles it alone" do
      {:ok, project} =
        Projects.create_project(%{"name" => "Partial #{uniq()}", "start_mode" => "immediate"})

      # Only some of the bundle — not a checklist, just a configured project.
      {:ok, _} = Features.set_flags(project, %{"assignees" => false, "labels" => false})

      PhoenixKitProjects.migrate_legacy()

      assert Features.on?(Projects.get_project(project.uuid), "lifecycle")
    end

    test "runs once, so turning a flag back on sticks" do
      {:ok, project} =
        Projects.create_project(%{"name" => "Old list #{uniq()}", "start_mode" => "immediate"})

      old_bundle =
        Map.new(
          ~w(assignees priorities labels estimates progress dependencies
             statuses scheduling subprojects view_timeline view_calendar),
          &{&1, false}
        )

      {:ok, project} = Features.set_flags(project, old_bundle)
      PhoenixKitProjects.migrate_legacy()

      # The owner decides they DO want time tracking on this list.
      {:ok, project} = Features.set_flags(project, %{"ledger" => true})

      PhoenixKitProjects.migrate_legacy()

      assert Features.on?(Projects.get_project(project.uuid), "ledger"),
             "the backfill re-disabled a flag the owner turned back on"
    end
  end
end
