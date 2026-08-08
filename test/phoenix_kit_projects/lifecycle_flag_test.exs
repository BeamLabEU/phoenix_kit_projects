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

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Features, Members, Projects}

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

  describe "a checklist can still be ended" do
    # No START ceremony doesn't mean no way out: the list is implicitly
    # running, and archiving is the end — reversible, and the only one,
    # since completion was always automatic and is now off here.

    test "archiving a checklist takes it out of the running list", %{conn: _conn} do
      project = checklist()

      assert Enum.any?(Projects.list_active_projects(), &(&1.uuid == project.uuid))

      {:ok, project} = Projects.archive_project(project)

      assert project.archived_at
      refute Enum.any?(Projects.list_active_projects(), &(&1.uuid == project.uuid))

      # ...and it's reversible, so ending it is never a one-way door.
      {:ok, project} = Projects.unarchive_project(project)
      assert Enum.any?(Projects.list_active_projects(), &(&1.uuid == project.uuid))
    end

    test "the Archive action is on the hub for a checklist", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      project = checklist()

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      assert html =~ "archive_project",
             "a checklist has no start bar, so archiving is its only way out"
    end
  end

  describe "the hub menu reflects what the project is" do
    test "a checklist offers no health judgment", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      project = checklist()

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      refute html =~ "open_health_modal",
             "health asks whether a project is on track to finish; this one has no finish"
    end

    test "a normal project still offers it", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, project} =
        Projects.create_project(%{"name" => "Normal #{uniq()}", "start_mode" => "immediate"})

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      assert html =~ "open_health_modal"
    end

    test "setting health on a checklist is refused, not just hidden", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      project = checklist()

      {:ok, view, _} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      render_click(view, "save_health", %{"status" => "at_risk", "note" => "forged"})

      assert is_nil(Projects.get_project(project.uuid).settings["health"]),
             "a forged event set health on a project that has none"
    end

    test "Modules & features is no longer its own menu entry", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, project} =
        Projects.create_project(%{"name" => "Normal #{uniq()}", "start_mode" => "immediate"})

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      refute html =~ "Modules &amp; features",
             "it lives inside Edit now — changing what a project is IS editing it"
    end
  end

  describe "the simple archetype's extensions" do
    test "files and discussions are not seeded on" do
      archetype = PhoenixKitProjects.Archetypes.get("quick_todo")

      assert "files" in archetype.extensions_off

      assert "discussions" in archetype.extensions_off,
             "a shared checklist arrived with a Files page and a Comments button"
    end

    test "the other archetypes suppress nothing" do
      for key <- ~w(standard client_hub public_intake),
          archetype = PhoenixKitProjects.Archetypes.get(key),
          archetype != nil do
        assert archetype.extensions_off == []
      end
    end
  end

  describe "Modules & features embedded in Edit" do
    test "the owner sees it inside the edit form", %{conn: conn} do
      # A REAL user: the embedded panel mounts off-router and rebuilds its
      # scope from the uuid we thread through the session, so a synthetic
      # scope resolves to nobody and the panel refuses.
      conn = put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))

      {:ok, project} =
        Projects.create_project(%{"name" => "Normal #{uniq()}", "start_mode" => "immediate"})

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}/edit")

      assert html =~ "Modules &amp; features"
      assert html =~ "Presets:", "the embedded panel didn't render its contents"
    end

    test "a manager can't reach the edit form at all — both are owner-only", %{conn: conn} do
      # The embedded panel enforces :manage_modules itself, but refuses by
      # REDIRECTING, which inside a host page would navigate the whole edit
      # form away. Today that can't bite, because :edit_settings is
      # owner-only too, so anyone who reaches this form can also manage
      # modules. The conditional render is the guard for the day those
      # floors diverge; this test pins the assumption it rests on, so a
      # change to either floor fails here rather than silently bouncing
      # someone out of editing.
      {:ok, user} =
        Auth.register_user(%{
          "email" => "manager-#{uniq()}@example.com",
          "password" => "ValidPassword123!"
        })

      {:ok, project} =
        Projects.create_project(%{"name" => "Normal #{uniq()}", "start_mode" => "immediate"})

      {:ok, _} = Members.add_member(project, user.uuid, role: "manager")
      scope = fake_scope(user_uuid: user.uuid, permissions: ["projects"])

      refute PhoenixKitProjects.Authz.can?(scope, project, :edit_settings)
      refute PhoenixKitProjects.Authz.can?(scope, project, :manage_modules)

      assert {:error, {:live_redirect, _}} =
               conn
               |> put_test_scope(scope)
               |> live("/en/admin/projects/list/#{project.uuid}/edit")
    end
  end
end
