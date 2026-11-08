defmodule PhoenixKitProjects.Integration.MigrationReplayTest do
  @moduledoc """
  The chain is replayed whole on every bump: `up/1` runs V1 through the
  current version each time `mix phoenix_kit.update` writes a migration for a
  newer one. So every version must hold against TODAY's data, not only against
  the shape it was written for.

  Built in a scratch schema of its own (not `public`, so the prefix handling is
  exercised too), through `Ecto.Migrator` — an `ExUnit.Case` with the sandbox
  in auto mode, `async: false`.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.TestSupport.ModuleChainCheck
  alias PhoenixKitProjects.Migrations.Schema
  alias PhoenixKitProjects.Test.Repo

  @moduletag :integration
  @moduletag timeout: :timer.minutes(3)

  @prerequisites [PhoenixKitEntities.Migrations, PhoenixKitStaff.Migrations]

  setup do
    previous_repo = Application.get_env(:phoenix_kit, :repo)
    Application.put_env(:phoenix_kit, :repo, Repo)

    schema = "pkreplay_" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _tables} = ModuleChainCheck.build_alone(Repo, Schema, schema, after: @prerequisites)

    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
      Sandbox.mode(Repo, :manual)

      if previous_repo,
        do: Application.put_env(:phoenix_kit, :repo, previous_repo),
        else: Application.delete_env(:phoenix_kit, :repo)
    end)

    %{schema: schema}
  end

  test "a replay keeps held tasks and accepted portal requests as they are", %{schema: s} do
    %{rows: [[project]]} =
      Repo.query!(
        ~s[INSERT INTO "#{s}".phoenix_kit_projects (name) VALUES ('Replay') RETURNING uuid]
      )

    %{rows: [[task]]} =
      Repo.query!(
        ~s[INSERT INTO "#{s}".phoenix_kit_project_tasks (title) VALUES ('Tile') RETURNING uuid]
      )

    # A task held by the typed list (V23's `removed`) and a portal request
    # staff accepted that is still waiting to be started.
    held = insert_assignment(s, project, task, "'removed'", "'internal'")
    accepted = insert_assignment(s, project, task, "'accepted'", "'portal'")

    assert :ok = replay(s)

    assert review_status(s, held) == "removed"
    assert review_status(s, accepted) == "accepted"
  end

  test "a replay in a named schema finds its own constraints", %{schema: s} do
    # Twice: the first replay is the upgrade, the second the next one.
    assert :ok = replay(s)
    assert :ok = replay(s)

    for {table, name} <- [
          {"phoenix_kit_project_portals", "phoenix_kit_project_portals_access_mode_check"},
          {"phoenix_kit_project_assignments", "phoenix_kit_project_assignments_dates_check"},
          {"phoenix_kit_project_assignments",
           "phoenix_kit_project_assignments_review_status_check"}
        ] do
      %{rows: [[count]]} =
        Repo.query!(
          "SELECT count(*) FROM pg_constraint WHERE conrelid = $1::text::regclass AND conname = $2",
          [~s("#{s}".#{table}), name]
        )

      assert count == 1, "#{name} on #{s}.#{table}"
    end
  end

  defp insert_assignment(s, project, task, review_status, source) do
    %{rows: [[uuid]]} =
      Repo.query!(
        """
        INSERT INTO "#{s}".phoenix_kit_project_assignments
          (project_uuid, task_uuid, status, source, public, review_status)
        VALUES ($1, $2, 'todo', #{source}, false, #{review_status})
        RETURNING uuid
        """,
        [project, task]
      )

    uuid
  end

  defp review_status(s, uuid) do
    %{rows: [[status]]} =
      Repo.query!(
        ~s(SELECT review_status FROM "#{s}".phoenix_kit_project_assignments WHERE uuid = $1),
        [uuid]
      )

    status
  end

  # The migration `mix phoenix_kit.update` writes into a host, run again
  # under a fresh version so Ecto does not skip it.
  defp replay(schema) do
    name = Module.concat(__MODULE__, "Run#{System.unique_integer([:positive])}")

    contents =
      quote do
        use Ecto.Migration

        def up,
          do: Schema.up(prefix: unquote(schema), version: Schema.current_version())

        def down, do: :ok
      end

    {:module, ^name, _binary, _} = Module.create(name, contents, Macro.Env.location(__ENV__))

    try do
      Ecto.Migrator.up(Repo, System.os_time(:microsecond), name, prefix: schema, log: false)
      :ok
    after
      :code.purge(name)
      :code.delete(name)
    end
  end
end
