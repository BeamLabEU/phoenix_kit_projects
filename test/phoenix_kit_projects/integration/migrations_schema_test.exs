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

  alias PhoenixKitProjects.Migrations.Schema
  alias PhoenixKitProjects.Test.Repo, as: TestRepo

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
