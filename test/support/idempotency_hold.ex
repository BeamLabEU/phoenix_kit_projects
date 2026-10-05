defmodule PhoenixKitProjects.IdempotencyHold do
  @moduledoc """
  Holds an idempotency key's advisory lock from a SEPARATE Postgres session —
  what a live first request is, as far as a retry can tell.

  The test sandbox runs every process on one shared connection, and an
  advisory lock is reentrant within a session, so a second request in the
  test process would always "get" the lock. A raw Postgrex connection is its
  own session; `release/1` closes it, which is how a dying request drops its
  lock too.
  """

  alias PhoenixKitProjects.{ApiKeys, Test.Repo}

  @doc """
  Reserves the key (a pending row, as a first request would) and holds its
  lock. Returns the connection to pass to `release/1`.
  """
  @spec hold(binary(), String.t()) :: pid()
  def hold(key_uuid, idempotency_key) do
    {:ok, conn} =
      Repo.config()
      |> Keyword.take([:hostname, :port, :database, :username, :password, :socket_dir, :ssl])
      |> Postgrex.start_link()

    %{rows: [[true]]} =
      Postgrex.query!(conn, "SELECT pg_try_advisory_lock(hashtextextended($1, 0))", [
        ApiKeys.lock_name(key_uuid, idempotency_key)
      ])

    conn
  end

  @doc "Ends the holder's session: Postgres drops the lock, as it does when a request dies."
  @spec release(pid()) :: :ok
  def release(conn) do
    ref = Process.monitor(conn)
    GenServer.stop(conn)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      2_000 -> :ok
    end

    # let the server notice the closed socket before the next try
    Process.sleep(150)
  end
end
