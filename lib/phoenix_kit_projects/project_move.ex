defmodule PhoenixKitProjects.ProjectMove do
  @moduledoc """
  Moving a project to another place in the tree, with what it would
  otherwise leave behind.

  `Projects.move_project/2` changes only where the project hangs. But a
  sub-project is usually run from its parent: created with no members of
  its own (only site admins and the parent's people working through the
  parent could reach it), switched on through the parent's modules, and
  worked by an agent whose key belongs to the parent and reaches it only
  because it is nested there. Moved out bare, it would be a project nobody
  but an admin can open, with no client tab and an agent locked out.

  So a move can carry three things along, each the mover's choice and each
  checked against what they may do:

    * **members** — the old parent's people join the project with the role
      they had there (people already on it keep their role);
    * **modules** — the old parent's module switches and their settings
      (the linked client, …) are copied for every module the project has
      not made its own choice about;
    * **keys** — chosen API keys of the old ancestors are pointed at the
      project, so the token an agent already holds keeps working.

  `preview/2` says what a move would leave behind; `run/4` does it.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.{ApiKeys, Authz, Extensions, Members, Projects}
  alias PhoenixKitProjects.Schemas.{ApiKey, Project, ProjectModule}

  @type preview :: %{
          project: Project.t(),
          parent: Project.t() | nil,
          targets: [Project.t()],
          members: [map()],
          modules: [ProjectModule.t()],
          keys: [ApiKey.t()]
        }

  @doc """
  What `scope` would be offered when moving `project`: where it is now, the
  projects it could go under (the ones `scope` may add tasks to), and what
  of the current parent's it does not have — members, module rows, and the
  live keys of its ancestors, which reach it only while it is nested there.
  """
  @spec preview(Project.t(), term()) :: preview()
  def preview(%Project{} = project, scope) do
    ancestors = Projects.parent_chain(project.uuid)
    parent = List.last(ancestors)

    %{
      project: project,
      parent: parent,
      targets: targets(project, parent, scope),
      members: carried_members(project, parent),
      modules: carried_modules(project, parent),
      keys: ancestor_keys(ancestors)
    }
  end

  # A project can go under any project that could take it as a sub-project
  # (`available_projects_to_link/2`'s rules, except "already a sub-project":
  # it is leaving that place), the viewer may add tasks to, and that is not
  # inside the project itself.
  defp targets(%Project{} = project, parent, scope) do
    inside = Projects.subtree_uuids(project.uuid)
    parent_uuid = parent && parent.uuid

    Project
    |> where([p], p.is_template == ^project.is_template and is_nil(p.archived_at))
    |> where([p], p.uuid not in ^inside)
    |> order_by([p], asc: p.name, asc: p.uuid)
    |> RepoHelper.repo().all()
    |> Enum.reject(&(&1.uuid == parent_uuid))
    |> Enum.filter(&(project.is_template or Authz.can?(scope, &1, :edit_tasks)))
  end

  defp carried_members(_project, nil), do: []
  defp carried_members(%Project{is_template: true}, _parent), do: []

  defp carried_members(%Project{} = project, %Project{} = parent) do
    own = project.uuid |> Members.list_members() |> MapSet.new(& &1.user_uuid)
    parent.uuid |> Members.list_members() |> Enum.reject(&MapSet.member?(own, &1.user_uuid))
  end

  defp carried_modules(_project, nil), do: []

  defp carried_modules(%Project{} = project, %Project{} = parent) do
    own = project.uuid |> Extensions.list_rows() |> MapSet.new(&{&1.ext_key, &1.instance_key})

    parent.uuid
    |> Extensions.list_rows()
    |> Enum.reject(&MapSet.member?(own, {&1.ext_key, &1.instance_key}))
  end

  defp ancestor_keys([]), do: []

  defp ancestor_keys(ancestors) do
    now = DateTime.utc_now()

    ancestors
    |> Enum.flat_map(&ApiKeys.list_for_project(&1.uuid))
    |> Enum.filter(&ApiKey.active?(&1, now))
  end

  @doc """
  Moves `project` to `target` (`:top` or a parent's uuid) for `scope`.

  Options: `:members` and `:modules` (booleans — carry the old parent's
  along), `:keys` (uuids of ancestor keys to point at the project),
  `:actor_uuid`. The mover must hold `:edit_settings` on the project and,
  for a new parent, `:edit_tasks` there; each carried thing is taken only
  where they may grant it (`:manage_members` / `:manage_modules` on the
  project, `:manage_modules` on a key's own project) and skipped otherwise.

  Returns `{:ok, %{project:, from:, to:, members: n, modules: n, keys: n}}`
  or `{:error, :forbidden | reason}` with `Projects.move_project/2`'s
  reasons. What is carried is read BEFORE the move (afterwards there is no
  old parent to read it from) and written after it commits.
  """
  @spec run(Project.t(), :top | binary(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Project{} = project, target, scope, opts \\ []) do
    if allowed?(project, target, scope) do
      before = preview(project, scope)

      with {:ok, moved} <- Projects.move_project(project.uuid, target) do
        actor = Keyword.get(opts, :actor_uuid)

        # The move has committed. Whatever a carry step does from here — one
        # that raises included — the caller still gets `{:ok, …}` with what
        # was carried, so the move is logged and shown; a step that failed
        # carried nothing and says so in the log.
        {:ok,
         Map.merge(moved, %{
           members: safely(:members, fn -> carry_members(before, scope, opts, actor) end),
           modules: safely(:modules, fn -> carry_modules(before, scope, opts, actor) end),
           keys: safely(:keys, fn -> carry_keys(before, scope, opts, actor) end)
         })}
      end
    else
      {:error, :forbidden}
    end
  end

  defp safely(what, fun) do
    fun.()
  rescue
    e ->
      Logger.warning("[Projects.ProjectMove] carrying #{what} failed: #{Exception.message(e)}")
      0
  catch
    kind, reason ->
      Logger.warning("[Projects.ProjectMove] carrying #{what} #{kind}: #{inspect(reason)}")
      0
  end

  defp allowed?(project, :top, scope), do: Authz.can?(scope, project, :edit_settings)

  defp allowed?(project, target, scope) when is_binary(target) do
    Authz.can?(scope, project, :edit_settings) and
      (project.is_template or
         case Projects.get_project(target) do
           nil -> false
           parent -> Authz.can?(scope, parent, :edit_tasks)
         end)
  end

  defp allowed?(_project, _target, _scope), do: false

  defp carry_members(%{members: members, project: project}, scope, opts, actor) do
    if Keyword.get(opts, :members, false) and Authz.can?(scope, project, :manage_members) do
      Enum.count(members, fn m ->
        match?(
          {:ok, _},
          Members.add_member(project.uuid, m.user_uuid, role: m.role, actor_uuid: actor)
        )
      end)
    else
      0
    end
  end

  defp carry_modules(%{modules: rows, project: project}, scope, opts, actor) do
    if Keyword.get(opts, :modules, false) and Authz.can?(scope, project, :manage_modules) do
      Enum.count(rows, &copy_module(&1, project, actor))
    else
      0
    end
  end

  # Through the context's own switches, so the config is whitelisted
  # against the extension's schema and its callbacks run as for a toggle.
  defp copy_module(%ProjectModule{enabled: true} = row, project, actor) do
    match?(
      {:ok, _},
      Extensions.enable(project.uuid, row.ext_key,
        instance_key: row.instance_key,
        config: row.config || %{},
        actor_uuid: actor
      )
    )
  end

  defp copy_module(%ProjectModule{} = row, project, actor) do
    match?(
      {:ok, _},
      Extensions.disable(project.uuid, row.ext_key,
        instance_key: row.instance_key,
        actor_uuid: actor
      )
    )
  end

  defp carry_keys(%{keys: keys, project: project}, scope, opts, actor) do
    wanted = opts |> Keyword.get(:keys, []) |> List.wrap() |> MapSet.new()

    keys
    |> Enum.filter(&MapSet.member?(wanted, &1.uuid))
    |> Enum.count(fn key ->
      Authz.can?(scope, Projects.get_project(key.project_uuid), :manage_modules) and
        match?({:ok, _}, ApiKeys.move(key, project.uuid, actor_uuid: actor))
    end)
  end
end
