defmodule PhoenixKitProjects.Integration.MigrationsSchemaTest do
  @moduledoc """
  Pins the module-owned migration chain's protocol surface
  (`PhoenixKitProjects.Migrations.Schema`).

  Full-chain idempotency is proven structurally on every test boot:
  `test_helper.exs` runs `Schema.up/1` (via the version-keyed migrator
  wrapper) AFTER core's `ensure_current/2` already built the tables, so a
  non-idempotent statement would crash the boot before any test runs. These
  tests cover the version-resolution contract on top of that.
  """

  use PhoenixKitProjects.DataCase, async: false

  import Ecto.Query

  alias Ecto.Migration.Runner
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Migrations.Schema
  alias PhoenixKitProjects.Test.Repo, as: TestRepo
  alias PhoenixKitProjects.Test.SchemaMigration

  # document_creator links a document to a project but does not depend on
  # this package: its chain skips the key while `phoenix_kit_projects` is
  # missing and still stamps itself current. Where it ran first (a fresh
  # install replaying a host's history), this chain adds the key. Without the
  # documents table (this suite's boot) it must do nothing and not fail.
  test "the chain adds document_creator's project key when that table is there" do
    TestRepo.query!("""
    CREATE TABLE public.phoenix_kit_doc_documents (uuid uuid PRIMARY KEY, project_uuid uuid)
    """)

    Runner.run(
      TestRepo,
      TestRepo.config(),
      1,
      SchemaMigration,
      :forward,
      :up,
      :up,
      log: false
    )

    assert %{rows: [[1]]} =
             TestRepo.query!("""
             SELECT count(*) FROM pg_constraint
             WHERE conrelid = 'public.phoenix_kit_doc_documents'::regclass
               AND conname = 'phoenix_kit_doc_documents_project_uuid_fkey'
               AND confrelid = 'public.phoenix_kit_projects'::regclass
             """)
  end

  # A host that already lost the key keeps documents pointing at projects
  # deleted since (nothing set them to NULL). Those references are cleared,
  # as the key's ON DELETE SET NULL would have done, instead of failing the
  # whole projects migration on the key's check.
  test "a document pointing at a deleted project does not stop the key" do
    TestRepo.query!("""
    CREATE TABLE public.phoenix_kit_doc_documents (uuid uuid PRIMARY KEY, project_uuid uuid)
    """)

    dangling = Ecto.UUID.generate()

    TestRepo.query!(
      "INSERT INTO public.phoenix_kit_doc_documents (uuid, project_uuid) VALUES ($1, $2)",
      [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(dangling)]
    )

    Runner.run(TestRepo, TestRepo.config(), 1, SchemaMigration, :forward, :up, :up, log: false)

    assert %{rows: [[nil]]} =
             TestRepo.query!("SELECT project_uuid FROM public.phoenix_kit_doc_documents")

    assert %{rows: [[1]]} =
             TestRepo.query!("""
             SELECT count(*) FROM pg_constraint
             WHERE conname = 'phoenix_kit_doc_documents_project_uuid_fkey'
             """)
  end

  # A host's replay reaches this chain with neither package's tables built
  # (core 3.x no longer creates them). `test_helper.exs` builds them itself, so
  # booting the suite proves nothing about it: take two away and ask the chain.
  test "the chain builds staff's and entities' tables when they are missing" do
    TestRepo.query!("DROP TABLE public.phoenix_kit_staff_teams CASCADE")
    TestRepo.query!("DROP TABLE public.phoenix_kit_entity_data CASCADE")

    Runner.run(TestRepo, TestRepo.config(), 1, SchemaMigration, :forward, :up, :up, log: false)

    assert %{rows: [["phoenix_kit_staff_teams", "phoenix_kit_entity_data"]]} =
             TestRepo.query!("""
             SELECT to_regclass('public.phoenix_kit_staff_teams')::text,
                    to_regclass('public.phoenix_kit_entity_data')::text
             """)
  end

  # `up/1` can add this key, and it points at the table a full `down/1` drops.
  test "a full down takes document_creator's key off, and keeps the documents" do
    TestRepo.query!("""
    CREATE TABLE public.phoenix_kit_doc_documents (uuid uuid PRIMARY KEY, project_uuid uuid)
    """)

    Runner.run(TestRepo, TestRepo.config(), 1, SchemaMigration, :forward, :up, :up, log: false)

    Runner.run(TestRepo, TestRepo.config(), 1, SchemaMigration, :forward, :down, :down,
      log: false
    )

    assert %{rows: [[nil, "phoenix_kit_doc_documents"]]} =
             TestRepo.query!("""
             SELECT to_regclass('public.phoenix_kit_projects')::text,
                    to_regclass('public.phoenix_kit_doc_documents')::text
             """)

    assert %{rows: [[0]]} =
             TestRepo.query!("""
             SELECT count(*) FROM pg_constraint
             WHERE conname = 'phoenix_kit_doc_documents_project_uuid_fkey'
             """)
  end

  test "migration_module/0 points at the chain" do
    assert PhoenixKitProjects.migration_module() == Schema
  end

  test "current_version/0 is a positive integer" do
    assert is_integer(Schema.current_version())
    assert Schema.current_version() >= 1
  end

  test "runtime version resolves to current after boot (marker stamped)" do
    assert Schema.migrated_version_runtime() == Schema.current_version()
    assert Schema.migrated_version_runtime(prefix: "public") == Schema.current_version()
  end

  test "a marker-less existing table reads as V1 (core-chain-built install)" do
    # Sandbox transaction — the comment change rolls back after the test.
    TestRepo.query!("COMMENT ON TABLE public.phoenix_kit_projects IS NULL")
    assert Schema.migrated_version_runtime() == 1
  end

  test "a foreign/garbled marker reads as V1, never crashes" do
    TestRepo.query!("COMMENT ON TABLE public.phoenix_kit_projects IS 'someone elses note'")
    assert Schema.migrated_version_runtime() == 1

    TestRepo.query!("COMMENT ON TABLE public.phoenix_kit_projects IS 'pkp_schema:garbage'")
    assert Schema.migrated_version_runtime() == 1
  end

  test "an absent table reads as V0" do
    # Point resolution at a schema where the table genuinely doesn't exist.
    assert Schema.migrated_version_runtime(prefix: "no_such_schema") == 0
  end

  test "a future marker round-trips" do
    TestRepo.query!("COMMENT ON TABLE public.phoenix_kit_projects IS 'pkp_schema:7'")
    assert Schema.migrated_version_runtime() == 7
  end

  # V30: several assignees on projects and library tasks. DDL is
  # transactional, so each test runs the chain's real `up`/`down` through
  # Ecto.Migrator inside the test's sandbox transaction and everything rolls
  # back with it.
  describe "V30 (several assignees on projects and library tasks)" do
    alias PhoenixKitProjects.Schemas.{Project, ProjectAssignee, Task, TaskDefaultAssignee}
    alias PhoenixKitStaff.Schemas.{Department, Person, Team}

    defmodule UpV30 do
      @moduledoc false
      use Ecto.Migration
      alias PhoenixKitProjects.Migrations.Schema
      def up, do: Schema.up(prefix: "public")
      def down, do: :ok
    end

    defmodule DownV30 do
      @moduledoc false
      use Ecto.Migration
      alias PhoenixKitProjects.Migrations.Schema
      def up, do: Schema.down(prefix: "public", version: 29)
      def down, do: :ok
    end

    # No migration lock: it would hold the sandbox's one connection while the
    # migration's own process asks for it.
    defp run!(module) do
      # The holders' references are deferred; DDL on a table with pending
      # trigger events is refused.
      TestRepo.query!("SET CONSTRAINTS ALL IMMEDIATE")
      version = System.unique_integer([:positive]) + 10_000_000
      Ecto.Migrator.up(TestRepo, version, module, log: false, migration_lock: false)
    end

    defp person!(name) do
      {:ok, user} =
        Auth.register_user(%{
          "email" => "mig-#{System.unique_integer([:positive])}@example.com",
          "password" => "ValidPassword123!"
        })

      TestRepo.insert!(%Person{user_uuid: user.uuid, status: "active", name: name})
    end

    defp subjects do
      n = System.unique_integer([:positive])
      dept = TestRepo.insert!(%Department{name: "Dept #{n}"})
      team = TestRepo.insert!(%Team{name: "Team #{n}", department_uuid: dept.uuid})
      ann = person!("Ann #{n}")
      bob = person!("Bob #{n}")
      %{dept: dept, team: team, ann: ann, bob: bob}
    end

    defp rows(schema, fk, uuid),
      do: TestRepo.all(from(r in schema, where: field(r, ^fk) == ^uuid, order_by: r.position))

    # A holder as it was before V30: only its single column, no rows.
    defp legacy_project(cols) do
      project = fixture_project()
      TestRepo.delete_all(from(r in ProjectAssignee, where: r.project_uuid == ^project.uuid))

      if cols != [],
        do: TestRepo.update_all(from(p in Project, where: p.uuid == ^project.uuid), set: cols)

      project
    end

    test "up backfills one row for a holder with exactly one old column, and leaves the rest" do
      s = subjects()
      one_person = legacy_project(assigned_person_uuid: s.ann.uuid)
      one_team = legacy_project(assigned_team_uuid: s.team.uuid)
      nobody = legacy_project([])

      # Already has rows (two of them, mirror empty): left as it is.
      two = fixture_project()

      TestRepo.insert_all(ProjectAssignee, [
        %{project_uuid: two.uuid, person_uuid: s.ann.uuid, position: 0},
        %{project_uuid: two.uuid, person_uuid: s.bob.uuid, position: 1}
      ])

      task = fixture_task()

      TestRepo.update_all(from(t in Task, where: t.uuid == ^task.uuid),
        set: [default_assigned_department_uuid: s.dept.uuid]
      )

      TestRepo.delete_all(from(r in TaskDefaultAssignee, where: r.task_uuid == ^task.uuid))

      assert :ok = run!(UpV30) |> then(fn _ -> :ok end)

      assert [%{person_uuid: p, position: 0}] =
               rows(ProjectAssignee, :project_uuid, one_person.uuid)

      assert p == s.ann.uuid

      assert [%{team_uuid: t}] = rows(ProjectAssignee, :project_uuid, one_team.uuid)
      assert t == s.team.uuid

      assert rows(ProjectAssignee, :project_uuid, nobody.uuid) == []

      assert Enum.map(rows(ProjectAssignee, :project_uuid, two.uuid), & &1.person_uuid) ==
               [s.ann.uuid, s.bob.uuid]

      assert [%{department_uuid: d}] = rows(TaskDefaultAssignee, :task_uuid, task.uuid)
      assert d == s.dept.uuid
    end

    test "up again changes nothing" do
      s = subjects()
      project = legacy_project(assigned_person_uuid: s.ann.uuid)

      run!(UpV30)
      before = rows(ProjectAssignee, :project_uuid, project.uuid)
      run!(UpV30)

      assert rows(ProjectAssignee, :project_uuid, project.uuid) == before
    end

    test "up recreates a missing table and fills it from the old columns" do
      s = subjects()
      project = legacy_project(assigned_person_uuid: s.ann.uuid)
      TestRepo.query!("DROP TABLE phoenix_kit_project_assignees")

      run!(UpV30)

      assert [%{person_uuid: p}] = rows(ProjectAssignee, :project_uuid, project.uuid)
      assert p == s.ann.uuid
    end

    test "down refuses while a project has several assignees" do
      s = subjects()
      project = fixture_project()

      TestRepo.insert_all(ProjectAssignee, [
        %{project_uuid: project.uuid, person_uuid: s.ann.uuid, position: 0},
        %{project_uuid: project.uuid, person_uuid: s.bob.uuid, position: 1}
      ])

      assert_raise Postgrex.Error, ~r/several assignees/, fn -> run!(DownV30) end

      assert TestRepo.query!("SELECT to_regclass('phoenix_kit_project_assignees')").rows != [
               [nil]
             ]
    end

    test "down puts the one assignee back in the old column and drops the tables" do
      s = subjects()
      project = fixture_project()
      # The row says Ann; the old column went stale (empty).
      TestRepo.insert_all(ProjectAssignee, [
        %{project_uuid: project.uuid, person_uuid: s.ann.uuid, position: 0}
      ])

      TestRepo.update_all(from(p in Project, where: p.uuid == ^project.uuid),
        set: [assigned_person_uuid: nil]
      )

      run!(DownV30)

      assert TestRepo.get!(Project, project.uuid).assigned_person_uuid == s.ann.uuid

      assert TestRepo.query!("SELECT to_regclass('phoenix_kit_project_assignees')").rows == [
               [nil]
             ]

      assert TestRepo.query!("SELECT to_regclass('phoenix_kit_project_task_assignees')").rows ==
               [[nil]]
    end
  end
end
