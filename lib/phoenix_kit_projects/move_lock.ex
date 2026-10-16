defmodule PhoenixKitProjects.MoveLock do
  @moduledoc """
  The host's say over which projects may not change their place in the tree.

  A host that ties a project to something of its own (an order that must
  keep its project where it is) sets, in its config:

      config :phoenix_kit_projects, move_lock: {MyApp.ProjectMoveLock, :reasons}

  `MyApp.ProjectMoveLock.reasons/1` receives a LIST of `%Project{}` and
  returns `%{project_uuid => reason}` for the ones that are locked (the
  reason is a non-empty string shown to the user; a project not in the map
  is free). The list form is the contract: callers hand over every project
  of a page in one call, so the hook can answer with one query and never
  runs per row.

  Unset (the default), nothing is locked; a value that is not
  `{Module, :function}` is ignored with one warning. A hook that raises,
  exits, or returns something that is not a map fails OPEN — nothing is
  locked, and a warning is logged — like the module's other host hooks: a
  bug in the host must not take "Move…" away from everybody.

  Enforced where a move happens: `PhoenixKitProjects.ProjectMove.run/4`
  (`{:error, {:locked, reason}}`), the Move… dialog, and the «Project to
  nest» picker. The context functions (`Projects.move_project/2`,
  `Projects.link_subproject/2`) stay policy-free — they are the host's own
  tools too.
  """

  require Logger

  alias PhoenixKitProjects.Schemas.Project

  @doc """
  `%{uuid => reason}` for the locked projects among `projects`. One hook
  call for the whole list; `%{}` for an empty list or no hook.
  """
  @spec reasons([Project.t()]) :: %{optional(binary()) => String.t()}
  def reasons([]), do: %{}

  def reasons(projects) when is_list(projects) do
    case Application.get_env(:phoenix_kit_projects, :move_lock) do
      {mod, fun} when is_atom(mod) and is_atom(fun) -> call(mod, fun, projects)
      nil -> %{}
      other -> warn_malformed(other)
    end
  end

  # A typo in config must not be as silent as "not configured", but pages
  # reload often: say it once per distinct value.
  defp warn_malformed(value) do
    if :persistent_term.get({__MODULE__, :malformed}, :none) != value do
      :persistent_term.put({__MODULE__, :malformed}, value)

      Logger.warning(
        "[Projects.MoveLock] ignoring move_lock config #{inspect(value)}; " <>
          "expected {Module, :function}. Nothing is locked"
      )
    end

    %{}
  end

  @doc "The reason `project` is locked, or `nil`."
  @spec reason(Project.t()) :: String.t() | nil
  def reason(%Project{uuid: uuid} = project), do: [project] |> reasons() |> Map.get(uuid)

  defp call(mod, fun, projects) do
    uuids = MapSet.new(projects, & &1.uuid)

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(mod, fun, [projects]) do
      %{} = map ->
        for {uuid, reason} <- map,
            MapSet.member?(uuids, uuid),
            is_binary(reason) and reason != "",
            into: %{} do
          {uuid, reason}
        end

      other ->
        Logger.warning(
          "[Projects.MoveLock] move_lock hook #{inspect(mod)}.#{fun}/1 returned " <>
            "#{inspect(other)}, expected a map; nothing is locked"
        )

        %{}
    end
  rescue
    e ->
      Logger.warning(
        "[Projects.MoveLock] move_lock hook failed: #{Exception.message(e)}; nothing is locked"
      )

      %{}
  catch
    kind, reason ->
      Logger.warning(
        "[Projects.MoveLock] move_lock hook #{kind}: #{inspect(reason)}; nothing is locked"
      )

      %{}
  end
end
