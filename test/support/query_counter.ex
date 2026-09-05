defmodule PhoenixKitProjects.QueryCounter do
  @moduledoc """
  Counts the SQL statements the test repo runs inside a function, through
  the repo's telemetry event — the number every N+1 hides. Ecto preloads
  are statements too, so "one read" is rarely one statement; assert what
  matters: that the count does NOT grow with the size of the input.

      {result, n} = QueryCounter.count(fn -> Projects.gates(project) end)
  """

  @event [:phoenix_kit_projects, :test, :repo, :query]

  @spec count((-> result)) :: {result, non_neg_integer()} when result: term()
  def count(fun) when is_function(fun, 0) do
    handler = "query-counter-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        @event,
        fn _event, _measurements, _meta, _config -> send(parent, {:query_counted, handler}) end,
        nil
      )

    try do
      result = fun.()
      {result, drain(handler, 0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(handler, n) do
    receive do
      {:query_counted, ^handler} -> drain(handler, n + 1)
    after
      0 -> n
    end
  end
end
