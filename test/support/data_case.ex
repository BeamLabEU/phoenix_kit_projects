defmodule PhoenixKitProjects.DataCase do
  @moduledoc """
  Test case for tests that hit the database.

  Uses `PhoenixKitProjects.Test.Repo` with SQL Sandbox for per-test isolation.
  Tests using this case are tagged `:integration` and are automatically
  excluded when the database is unavailable (see `test/test_helper.exs`).

  ## Usage

      defmodule PhoenixKitProjects.Integration.SomethingTest do
        use PhoenixKitProjects.DataCase, async: true

        test "creates a record" do
          # Repo is available here; transactions are isolated.
        end
      end
  """

  use ExUnit.CaseTemplate

  alias PhoenixKit.Utils.Routes

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitProjects.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitProjects.ActivityLogAssertions
      import PhoenixKitProjects.DataCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitProjects.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end

  @doc """
  Transforms changeset errors into a map of field → [message] for easy assertions.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ── Fixtures (shared between DataCase and LiveCase consumers) ────

  @doc "Creates a Task template with a unique title."
  def fixture_task(attrs \\ %{}) do
    {:ok, task} =
      PhoenixKitProjects.Projects.create_task(
        Map.merge(%{"title" => "Task #{System.unique_integer([:positive])}"}, attrs)
      )

    task
  end

  @doc """
  The address of the module's admin root as the app writes it: with the
  language segment (`/en/admin/projects`) on a multilingual site and
  without it on a single-language one — core 2.62 dropped the segment
  there, and which of the two a test site is depends on the core it runs
  against. Assertions on a WRITTEN link use this; navigating still uses
  `/en/admin/projects`, the scope the test router mounts.
  """
  def admin_projects, do: Routes.path("/admin/projects")

  @doc "Creates a real (non-template) Project with a unique name."
  def fixture_project(attrs \\ %{}) do
    {:ok, project} =
      PhoenixKitProjects.Projects.create_project(
        Map.merge(
          %{
            "name" => "Project #{System.unique_integer([:positive])}",
            "status" => "active",
            "start_mode" => "immediate",
            "is_template" => "false",
            # A key of its own rather than the one the name suggests: two
            # async tests that both got "P1" would wait on each other's
            # open sandbox transaction at the key registry, and deadlock
            # when each then created a second project. A test of the
            # suggestion itself calls `create_project/1` (in a file that is
            # not async).
            "key" => unique_key()
          },
          attrs
        )
      )

    project
  end

  @doc """
  Turns the comments module on for one test the way a host has it: listed
  in core's module registry (the test environment registers none, so a
  project's `discussions` reads off) and switched on. Restored on exit;
  for `async: false` tests only — the registry is global.
  """
  def with_comments_module do
    key = {PhoenixKit, :registered_modules}
    before = :persistent_term.get(key, :not_initialized)
    current = if before == :not_initialized, do: [], else: before
    :persistent_term.put(key, Enum.uniq([PhoenixKitComments | current]))
    {:ok, _} = PhoenixKit.Settings.update_setting("comments_enabled", "true")

    ExUnit.Callbacks.on_exit(fn ->
      if before == :not_initialized,
        do: :persistent_term.erase(key),
        else: :persistent_term.put(key, before)

      PhoenixKit.Settings.update_setting("comments_enabled", "false")
    end)

    :ok
  end

  @doc """
  A project key no other fixture has: `F` and nine random letters and
  digits. Random rather than a counter, so it cannot meet a key some
  earlier run left committed (a test that leaves the sandbox).
  """
  def unique_key do
    "F" <>
      (9 |> :crypto.strong_rand_bytes() |> Base.encode32(padding: false) |> binary_part(0, 9))
  end

  @doc "Creates a Template Project (`is_template = true`) with a unique name."
  def fixture_template(attrs \\ %{}) do
    {:ok, template} =
      PhoenixKitProjects.Projects.create_project(
        Map.merge(
          %{
            "name" => "Template #{System.unique_integer([:positive])}",
            "status" => "active",
            "start_mode" => "immediate",
            "is_template" => "true"
          },
          attrs
        )
      )

    template
  end
end
