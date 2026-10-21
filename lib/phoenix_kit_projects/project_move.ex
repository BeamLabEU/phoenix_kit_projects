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
    * **keys** — chosen API keys that reached the project through an old
      ancestor get the same access on the project itself, so the token an
      agent already holds keeps working (a grant a key already has on the
      project is left as it is).

  `preview/2` says what a move would leave behind; `run/4` does it.

  One thing a move cannot carry is somebody else's records. A task here
  may be linked to an interaction logged on the old parent (the client
  meeting it came out of); that meeting stays the parent's. The preview
  counts those links (`:links`) so the dialog can say what keeps them
  readable: the project having the same client, which the module settings
  carry.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.{ApiKeys, Authz, Extensions, Members, MoveLock, Projects}
  alias PhoenixKitProjects.Schemas.{ApiKey, Project, ProjectModule}

  @type preview :: %{
          project: Project.t(),
          parent: Project.t() | nil,
          parent_open?: boolean(),
          targets: [Project.t()],
          members: [map()],
          modules: [ProjectModule.t()],
          keys: [ApiKey.t()],
          key_from: %{binary() => binary()},
          links: %{count: non_neg_integer(), own?: boolean(), carried?: boolean()}
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

    # Rights on the sub-project say nothing about its parent (roles are not
    # inherited either way): the parent's people and module settings are
    # offered — shown, and copied — only to someone who may open the parent,
    # and a key only to someone who manages the project it belongs to.
    parent_open? =
      not is_nil(parent) and (project.is_template or Authz.can?(scope, parent, :view))

    source = if parent_open?, do: parent
    modules = carried_modules(project, source)
    carried_keys = ancestor_keys(project, ancestors, scope)

    %{
      project: project,
      parent: parent,
      parent_open?: parent_open?,
      targets: targets(project, parent, scope),
      members: carried_members(project, source),
      modules: modules,
      keys: carried_keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq_by(& &1.uuid),
      key_from: Map.new(carried_keys, fn {key, from} -> {key.uuid, from} end),
      links: outside_links(project, modules)
    }
  end

  # The task ↔ interaction links of the project (and what is nested in it)
  # that point at an interaction logged on a project OUTSIDE it — the ones
  # a move does not bring along. The provider says where each was logged
  # (`projects_of/1`, optional); without one there is nothing to say.
  # `own?`: the project has the provider's extension switched on itself;
  # `carried?`: the old parent's row for it is among what can be copied.
  defp outside_links(%Project{is_template: true}, _modules),
    do: %{count: 0, own?: false, carried?: false}

  defp outside_links(%Project{} = project, modules) do
    with %{ext: ext, module: provider} <- Extensions.api_provider("interactions"),
         true <- Code.ensure_loaded?(provider) and function_exported?(provider, :projects_of, 1),
         inside = Projects.subtree_uuids(project.uuid),
         [_ | _] = linked <- Projects.interaction_links_in(inside) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      logged_on = apply(provider, :projects_of, [Enum.uniq(linked)])

      %{
        count:
          Enum.count(linked, fn uuid ->
            case Map.get(logged_on, uuid) do
              nil -> false
              where -> where not in inside
            end
          end),
        own?: Extensions.enabled?(project, ext.key),
        carried?: Enum.any?(modules, &(&1.ext_key == ext.key and &1.enabled))
      }
    else
      _ -> %{count: 0, own?: false, carried?: false}
    end
  rescue
    e ->
      Logger.warning("[Projects.ProjectMove] counting interaction links: #{Exception.message(e)}")
      %{count: 0, own?: false, carried?: false}
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

  defp ancestor_keys(_project, [], _scope), do: []

  # The live keys that reach the project NOW through a grant on one of its
  # ancestors — the grant `ApiKeys.access_for/2` actually picks, so a grant
  # that stops above the project (`inherit: false`) or that a nearer one
  # shadows is never offered — as `{key, source_project_uuid}`. Only for
  # someone who manages that source, and a personal key only when its
  # person is on the project itself (the copied grant reads their role
  # there; anywhere else it would carry nothing).
  defp ancestor_keys(project, ancestors, scope) do
    now = DateTime.utc_now()
    by_uuid = Map.new(ancestors, &{&1.uuid, &1})

    ancestors
    |> Enum.flat_map(&ApiKeys.list_for_project(&1.uuid))
    |> Enum.uniq_by(& &1.uuid)
    |> Enum.filter(&ApiKey.active?(&1, now))
    |> Enum.flat_map(fn key ->
      with {:ok, %{grant: %{project_uuid: from}}} <- ApiKeys.access_for(key, project.uuid),
           %{} = source <- by_uuid[from],
           true <- Authz.can?(scope, source, :manage_modules),
           true <-
             is_nil(key.user_uuid) or not is_nil(Authz.effective_role(project, key.user_uuid)) do
        [{key, from}]
      else
        _ -> []
      end
    end)
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
  reasons, or `{:error, {:locked, reason}}` when the host's move lock
  (`PhoenixKitProjects.MoveLock`) holds the project in place. What is
  carried is read BEFORE the move (afterwards there is no
  old parent to read it from) and written after it commits.
  """
  @spec run(Project.t(), :top | binary(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Project{} = project, target, scope, opts \\ []) do
    with true <- allowed?(project, target, scope) || {:error, :forbidden},
         nil <- MoveLock.reason(project) do
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
      {:error, _} = error -> error
      reason when is_binary(reason) -> {:error, {:locked, reason}}
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

  defp carry_keys(%{keys: keys, key_from: key_from, project: project}, _scope, opts, actor) do
    wanted = opts |> Keyword.get(:keys, []) |> List.wrap() |> MapSet.new()

    keys
    |> Enum.filter(&MapSet.member?(wanted, &1.uuid))
    |> Enum.count(fn key ->
      from = key_from[key.uuid]

      # `key_from` was worked out before the move, for this mover.
      is_binary(from) and
        match?({:ok, _}, ApiKeys.carry_grant(key, from, project.uuid, actor_uuid: actor))
    end)
  end
end
