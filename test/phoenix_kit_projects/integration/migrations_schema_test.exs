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

  alias Ecto.Migration.Runner
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
end
