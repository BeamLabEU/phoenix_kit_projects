defmodule PhoenixKitProjects.IdempotencyLivenessTest do
  @moduledoc """
  Who is running an idempotent request is decided by a Postgres session lock,
  so these tests need REAL connections (the sandbox's shared one cannot show a
  second session): the sandbox is switched to `:auto` for the module and the
  rows it commits are removed again.

  The claim under test: a live first request is never run beside, and a dead
  one never leaves its key stuck — whatever the clocks say.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitProjects.{ApiKeys, DataCase}
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Test.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    project = DataCase.fixture_project()
    {:ok, key, _token} = ApiKeys.create(project, %{"name" => "liveness"})

    # runs before the mode is restored (on_exit is last in, first out); the
    # key and its idempotency rows go with the project
    on_exit(fn -> Repo.delete_all(from(p in Project, where: p.uuid == ^project.uuid)) end)

    {:ok, key: key}
  end

  defp start_request(key, idem, counter) do
    parent = self()

    spawn(fn ->
      ApiKeys.idempotent(key, idem, fn ->
        :counters.add(counter, 1, 1)
        send(parent, {:running, self()})

        receive do
          :finish -> {201, %{"owner" => "first"}}
        after
          30_000 -> {500, %{}}
        end
      end)
    end)

    assert_receive {:running, work}, 2_000
    work
  end

  test "a live request keeps its key; its answer is the one replayed", %{key: key} do
    counter = :counters.new(1, [])
    first = start_request(key, "live", counter)

    # a second request for the same key, however long the first takes
    assert {:ok, 409, %{error: %{code: "in_progress"}}} =
             ApiKeys.idempotent(key, "live", fn -> raise "must not run beside a live request" end)

    assert :counters.get(counter, 1) == 1

    send(first, :finish)
    Process.sleep(300)

    assert {:replay, 201, %{"owner" => "first"}} =
             ApiKeys.idempotent(key, "live", fn -> raise "must replay" end)
  end

  test "a killed request leaves nothing stuck: the next retry runs the work, once", %{key: key} do
    counter = :counters.new(1, [])
    first = start_request(key, "killed", counter)

    assert {:ok, 409, _} = ApiKeys.idempotent(key, "killed", fn -> raise "alive" end)

    # the request's process dies mid-work (a crash, a kill, a node going down)
    capture_log(fn ->
      Process.exit(first, :kill)
      Process.sleep(500)
    end)

    # its pending row is still there, but nobody holds the lock any more
    assert Repo.exists?(
             from(i in "phoenix_kit_project_api_idempotency",
               where: i.idempotency_key == "killed" and i.status == 0
             )
           )

    assert {:ok, 201, %{"ran" => 2}} =
             ApiKeys.idempotent(key, "killed", fn ->
               :counters.add(counter, 1, 1)
               {201, %{"ran" => :counters.get(counter, 1)}}
             end)

    assert {:replay, 201, %{"ran" => 2}} =
             ApiKeys.idempotent(key, "killed", fn -> raise "must replay" end)

    assert :counters.get(counter, 1) == 2
  end

  test "a request slower than the pool's default checkout limit keeps its lock", %{key: key} do
    # DBConnection drops a connection checked out past 15 s unless told
    # otherwise; the lease passes its own limit, so a slow request is not
    # mistaken for a dead one halfway through.
    counter = :counters.new(1, [])
    first = start_request(key, "slow", counter)

    Process.sleep(16_000)
    assert {:ok, 409, _} = ApiKeys.idempotent(key, "slow", fn -> raise "still alive" end)

    send(first, :finish)
  end
end
