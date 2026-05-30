defmodule PhoenixKitProjects.StatusesTest do
  @moduledoc """
  Behaviour of the entities-backed workflow-status context.

  `async: false` because the tests toggle the process-wide
  `entities_enabled` setting (ETS cache, not sandbox-isolated).
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{Projects, Statuses}
  alias PhoenixKitProjects.Schemas.ProjectStatus
  alias PhoenixKitProjects.StatusFixtures

  setup do
    # Default to disabled so each test opts in explicitly; reset after.
    StatusFixtures.disable_entities!()
    on_exit(&StatusFixtures.disable_entities!/0)
    :ok
  end

  describe "graceful degradation (entities disabled)" do
    test "available?/0 is false" do
      refute Statuses.available?()
    end

    test "statuses_for/1 returns [] for an unstarted project" do
      project = fixture_project()
      assert Statuses.statuses_for(project) == []
    end

    test "current_status/1 is nil" do
      project = fixture_project(%{"current_status_slug" => "done"})
      assert Statuses.current_status(project) == nil
    end

    test "cement_project_statuses/2 is a no-op (no local rows) and start still works" do
      project = fixture_project()
      assert {:ok, started} = Projects.start_project(project)
      assert started.started_at
      assert Statuses.list_project_statuses(started) == []
    end
  end

  describe "shared catalog provisioning" do
    setup do
      StatusFixtures.enable_entities!()
      %{actor_uuid: StatusFixtures.ensure_actor!()}
    end

    test "create_default_status_entity/1 creates project_statuses seeded with the defaults",
         %{actor_uuid: actor} do
      assert {:ok, entity} = Statuses.create_default_status_entity(actor_uuid: actor)
      assert entity.name == "project_statuses"

      statuses = Statuses.list_catalog_statuses(entity.uuid)
      assert length(statuses) == length(Statuses.default_statuses())
      labels = Enum.map(statuses, & &1.label)
      assert "Backlog" in labels
      assert "Done" in labels
    end

    test "generating again creates a fresh, auto-incremented entity" do
      assert {:ok, first} = Statuses.create_default_status_entity()
      assert {:ok, second} = Statuses.create_default_status_entity()
      assert {:ok, third} = Statuses.create_default_status_entity()

      assert first.name == "project_statuses"
      assert second.name == "project_statuses_2"
      assert third.name == "project_statuses_3"
      assert first.uuid != second.uuid
      # Each fresh list is independently seeded.
      assert length(Statuses.list_catalog_statuses(second.uuid)) ==
               length(Statuses.default_statuses())
    end

    test "available?/0 is true" do
      assert Statuses.available?()
    end
  end

  describe "reading statuses pre-start (live catalog)" do
    setup do
      entity = StatusFixtures.seed_shared_status_entity!()
      %{entity: entity}
    end

    test "statuses_for/1 resolves to the shared catalog for an unstarted project" do
      project = fixture_project()
      slugs = project |> Statuses.statuses_for() |> Enum.map(& &1.slug)
      assert "backlog" in slugs
      assert "done" in slugs
    end

    test "current_status/1 resolves the selected slug against the catalog" do
      project = fixture_project()
      {:ok, project} = Statuses.set_current_status(project, "in-progress")

      assert %{slug: "in-progress", label: "In Progress"} = Statuses.current_status(project)
    end

    test "set_current_status/3 rejects a slug not in the list" do
      project = fixture_project()
      assert {:error, :invalid_status} = Statuses.set_current_status(project, "nonexistent")
    end
  end

  describe "cement at start (freeze)" do
    setup do
      entity = StatusFixtures.seed_shared_status_entity!()
      %{entity: entity}
    end

    test "start_project copies the catalog into local rows", %{entity: _entity} do
      project = fixture_project()
      {:ok, project} = Statuses.set_current_status(project, "planned")

      {:ok, started} = Projects.start_project(project)

      local = Statuses.list_project_statuses(started)
      assert length(local) == length(Statuses.default_statuses())
      assert Enum.any?(local, &(&1.slug == "planned"))
      # statuses_for now reads the local (cemented) rows.
      assert length(Statuses.statuses_for(started)) == length(local)
    end

    test "editing the catalog after start does NOT change the started project", %{entity: entity} do
      project = fixture_project()
      {:ok, started} = Projects.start_project(project)
      before = Statuses.list_project_statuses(started)

      # Add a brand-new status to the shared catalog.
      {:ok, _} =
        PhoenixKitEntities.EntityData.create(%{
          entity_uuid: entity.uuid,
          title: "Archived Work",
          slug: "archived-work",
          position: 99,
          status: "published",
          data: %{"color" => "#000000"}
        })

      after_edit = Statuses.list_project_statuses(started)

      assert length(after_edit) == length(before)
      refute Enum.any?(after_edit, &(&1.slug == "archived-work"))
    end

    test "cementing is idempotent — re-cementing a started project adds no rows", %{entity: _e} do
      project = fixture_project()
      {:ok, started} = Projects.start_project(project)
      count = length(Statuses.list_project_statuses(started))

      :ok = Statuses.cement_project_statuses(started)
      assert length(Statuses.list_project_statuses(started)) == count
    end
  end

  describe "local CRUD post-start" do
    setup do
      StatusFixtures.seed_shared_status_entity!()
      :ok
    end

    test "add / update / remove a cemented status row" do
      project = fixture_project()
      {:ok, started} = Projects.start_project(project)

      {:ok, %ProjectStatus{} = row} =
        Statuses.add_project_status(started, %{label: "Custom", data: %{"color" => "#123456"}})

      assert row.slug == "custom"
      custom = Enum.find(Statuses.list_project_statuses(started), &(&1.slug == "custom"))
      assert custom.color == "#123456"

      {:ok, updated} = Statuses.update_project_status_row(row, %{label: "Custom 2"})
      assert updated.label == "Custom 2"

      {:ok, _} = Statuses.remove_project_status(updated)
      refute Enum.any?(Statuses.list_project_statuses(started), &(&1.uuid == row.uuid))
    end
  end

  describe "reverse_reference_count/1" do
    setup do
      entity = StatusFixtures.seed_shared_status_entity!()
      %{entity: entity}
    end

    test "counts projects sourcing from a given catalog entity", %{entity: entity} do
      assert Statuses.reverse_reference_count(entity.uuid) == 0

      _a = fixture_project(%{"status_entity_uuid" => entity.uuid})
      _b = fixture_project(%{"status_entity_uuid" => entity.uuid})

      assert Statuses.reverse_reference_count(entity.uuid) == 2
    end
  end

  describe "label localization" do
    test "a cemented row resolves its label to the current content locale" do
      project = fixture_project()

      {:ok, _} =
        %ProjectStatus{}
        |> ProjectStatus.changeset(%{
          project_uuid: project.uuid,
          label: "Done",
          slug: "done",
          translations: %{"es-ES" => %{"label" => "Hecho"}}
        })
        |> Repo.insert()

      on_exit(fn -> Gettext.put_locale(PhoenixKitWeb.Gettext, "en") end)

      Gettext.put_locale(PhoenixKitWeb.Gettext, "es-ES")
      assert [%{slug: "done", label: "Hecho"}] = Statuses.list_project_statuses(project)

      Gettext.put_locale(PhoenixKitWeb.Gettext, "en")
      assert [%{slug: "done", label: "Done"}] = Statuses.list_project_statuses(project)
    end
  end

  describe "translation display toggle (global + per-project override)" do
    test "defaults to true (no override, default global)" do
      assert Statuses.use_status_translations?(fixture_project())
    end

    test "per-project override wins over the global default" do
      {:ok, off} =
        Projects.update_project(fixture_project(), %{
          "settings" => %{"use_status_translations" => false}
        })

      refute Statuses.use_status_translations?(off)

      {:ok, on} =
        Projects.update_project(fixture_project(), %{
          "settings" => %{"use_status_translations" => true}
        })

      assert Statuses.use_status_translations?(on)
    end

    test "falls back to the global setting when there's no override" do
      PhoenixKit.Settings.update_setting("projects_use_status_translations", "false")

      on_exit(fn ->
        PhoenixKit.Settings.update_setting("projects_use_status_translations", "true")
      end)

      refute Statuses.use_status_translations?(fixture_project())
    end

    test "override off shows primary titles even when a translation exists" do
      {:ok, project} =
        Projects.update_project(fixture_project(), %{
          "settings" => %{"use_status_translations" => false}
        })

      {:ok, _} =
        %ProjectStatus{}
        |> ProjectStatus.changeset(%{
          project_uuid: project.uuid,
          label: "Done",
          slug: "done",
          translations: %{"es-ES" => %{"label" => "Hecho"}}
        })
        |> Repo.insert()

      on_exit(fn -> Gettext.put_locale(PhoenixKitWeb.Gettext, "en") end)
      Gettext.put_locale(PhoenixKitWeb.Gettext, "es-ES")

      assert [%{slug: "done", label: "Done"}] = Statuses.list_project_statuses(project)
    end
  end

  describe "selecting a status entity (existing / started projects)" do
    test "lists source entities grouped with status catalogs first" do
      StatusFixtures.seed_shared_status_entity!()
      groups = Statuses.list_status_source_entities()

      assert [{"Status lists", items} | _] = groups
      assert Enum.any?(items, fn {name, _uuid} -> name == "Project Statuses" end)
    end

    test "an already-started project with no statuses can adopt a list (cement on select)" do
      # Simulate a pre-feature started project: start while entities is off
      # so nothing cements.
      project = fixture_project()
      {:ok, started} = Projects.start_project(project)
      assert Statuses.list_project_statuses(started) == []

      # Enable entities + seed the shared catalog, then adopt it.
      entity = StatusFixtures.seed_shared_status_entity!()
      {:ok, updated} = Statuses.set_status_entity(started, entity.uuid)

      assert updated.status_entity_uuid == entity.uuid

      assert length(Statuses.list_project_statuses(updated)) ==
               length(Statuses.default_statuses())
    end

    test "switching the entity on a started project re-cements (replaces local rows)" do
      entity = StatusFixtures.seed_shared_status_entity!()
      project = fixture_project()
      {:ok, started} = Projects.start_project(project)

      assert length(Statuses.list_project_statuses(started)) ==
               length(Statuses.default_statuses())

      {:ok, _} = Statuses.add_project_status(started, %{label: "Local Only"})

      assert length(Statuses.list_project_statuses(started)) ==
               length(Statuses.default_statuses()) + 1

      {:ok, restated} = Statuses.set_status_entity(started, entity.uuid)
      local = Statuses.list_project_statuses(restated)

      assert length(local) == length(Statuses.default_statuses())
      refute Enum.any?(local, &(&1.slug == "local-only"))
    end

    test "an unstarted project just records the choice (no cement)" do
      entity = StatusFixtures.seed_shared_status_entity!()
      project = fixture_project()

      {:ok, updated} = Statuses.set_status_entity(project, entity.uuid)

      assert updated.status_entity_uuid == entity.uuid
      assert Statuses.list_project_statuses(updated) == []
      # Reads the catalog live until started.
      assert length(Statuses.statuses_for(updated)) == length(Statuses.default_statuses())
    end
  end
end
