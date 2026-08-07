defmodule PhoenixKitProjects.Members do
  @moduledoc """
  Per-project membership — the hub's native people layer (P2a).

  Members are core users with a project role (`owner > manager > member >
  viewer`). The project creator becomes the first owner
  (`Projects.create_project/2` with `actor_uuid`). Role semantics live in
  `PhoenixKitProjects.Authz` — this module owns the rows and the guards:

    * **Last-owner guard** — the final owner can be neither removed nor
      demoted (`{:error, :last_owner}`); a project must always have an
      accountable owner (the permission-hardening precedent).
    * Membership mutations log activity WITH `target_uuid` = the affected
      user, so core's activity→notification bridge delivers "you were added
      to a project" through the user's channels automatically.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.PubSub
  alias PhoenixKitProjects.Schemas.ProjectMember

  @doc "All members of a project, owners first, user preloaded."
  @spec list_members(binary()) :: [ProjectMember.t()]
  def list_members(project_uuid) when is_binary(project_uuid) do
    role_order = %{"owner" => 0, "manager" => 1, "member" => 2, "viewer" => 3}

    RepoHelper.repo().all(
      from(m in ProjectMember,
        where: m.project_uuid == ^project_uuid,
        preload: [:user]
      )
    )
    |> Enum.sort_by(&{Map.get(role_order, &1.role, 9), DateTime.to_unix(&1.inserted_at)})
  end

  @doc """
  Every project the user is a member of, as `{project, role}` pairs —
  templates excluded, newest membership first. The member-surface listing
  (`/dashboard/projects`); fail-closed to `[]` on any read error.
  """
  @spec projects_for_user(binary()) :: [{map(), String.t()}]
  def projects_for_user(user_uuid) when is_binary(user_uuid) do
    RepoHelper.repo().all(
      from(m in ProjectMember,
        join: p in PhoenixKitProjects.Schemas.Project,
        on: p.uuid == m.project_uuid,
        where: m.user_uuid == ^user_uuid and p.is_template == false,
        order_by: [desc: m.inserted_at],
        select: {p, m.role}
      )
    )
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  def projects_for_user(_), do: []

  @doc """
  Every non-template project a user can reach, as `{project, role}` — their
  own memberships PLUS anything their teams, departments, or site roles
  grant, with the strongest role per project.

  This is the single scope every listing surface should use. A view that
  keeps joining `phoenix_kit_project_members` directly will silently omit
  group-granted projects — the leak class the quorum flagged first.

  Site admins are NOT special-cased here: this answers "what does this
  person hold", and `projects.admin_all` is a separate question the caller
  asks with `PhoenixKitProjects.Authz.can?/5`.
  """
  @spec accessible_projects(binary()) :: [{map(), String.t()}]
  def accessible_projects(user_uuid) when is_binary(user_uuid) do
    direct = projects_for_user(user_uuid)
    granted = PhoenixKitProjects.Grants.project_roles_for_user(user_uuid)

    direct_uuids = MapSet.new(direct, fn {p, _r} -> p.uuid end)

    extra_uuids =
      granted |> Map.keys() |> Enum.reject(&MapSet.member?(direct_uuids, &1))

    extra =
      if extra_uuids == [] do
        []
      else
        RepoHelper.repo().all(
          from(p in PhoenixKitProjects.Schemas.Project,
            where: p.uuid in ^extra_uuids and p.is_template == false,
            order_by: [desc: p.inserted_at]
          )
        )
        |> Enum.map(&{&1, Map.fetch!(granted, &1.uuid)})
      end

    # A group grant can also RAISE the role on a project they already
    # belong to, so take the strongest of the two per project.
    direct
    |> Enum.map(fn {project, role} ->
      case Map.get(granted, project.uuid) do
        nil -> {project, role}
        group_role -> {project, stronger(role, group_role)}
      end
    end)
    |> Kernel.++(extra)
  rescue
    e ->
      Logger.warning("[Projects.Members] accessible_projects failed: #{Exception.message(e)}")
      []
  catch
    :exit, _ -> []
  end

  def accessible_projects(_), do: []

  defp stronger(a, b) do
    rank = %{"owner" => 0, "manager" => 1, "member" => 2, "viewer" => 3}
    if Map.get(rank, a, 9) <= Map.get(rank, b, 9), do: a, else: b
  end

  @doc "The member row for a user on a project, or nil."
  @spec get_member(binary(), binary()) :: ProjectMember.t() | nil
  def get_member(project_uuid, user_uuid)
      when is_binary(project_uuid) and is_binary(user_uuid) do
    RepoHelper.repo().one(
      from(m in ProjectMember,
        where: m.project_uuid == ^project_uuid and m.user_uuid == ^user_uuid
      )
    )
  end

  @doc "The user's role on a project as an atom, or nil when not a member. Fail-closed."
  @spec role_of(binary() | map(), binary()) :: atom() | nil
  def role_of(project_or_uuid, user_uuid)

  def role_of(%{uuid: uuid}, user_uuid), do: role_of(uuid, user_uuid)

  def role_of(project_uuid, user_uuid)
      when is_binary(project_uuid) and is_binary(user_uuid) do
    case get_member(project_uuid, user_uuid) do
      nil -> nil
      %ProjectMember{role: role} -> String.to_existing_atom(role)
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  def role_of(_, _), do: nil

  @doc """
  Adds a member. Options: `:role` (default `"member"`), `:actor_uuid`.
  Adding an existing member updates their role through the same guards.
  """
  @spec add_member(map() | binary(), binary(), keyword()) ::
          {:ok, ProjectMember.t()} | {:error, term()}
  def add_member(project_or_uuid, user_uuid, opts \\ [])

  def add_member(%{uuid: uuid}, user_uuid, opts), do: add_member(uuid, user_uuid, opts)

  def add_member(project_uuid, user_uuid, opts)
      when is_binary(project_uuid) and is_binary(user_uuid) do
    role = opts |> Keyword.get(:role, "member") |> to_string()
    actor_uuid = Keyword.get(opts, :actor_uuid)

    case get_member(project_uuid, user_uuid) do
      nil ->
        %ProjectMember{}
        |> ProjectMember.changeset(%{
          project_uuid: project_uuid,
          user_uuid: user_uuid,
          role: role,
          invited_by_uuid: actor_uuid
        })
        |> RepoHelper.repo().insert()
        |> tap_ok(fn member ->
          log_member("projects.member_added", project_uuid, member, actor_uuid, %{
            "role" => member.role
          })

          PubSub.broadcast_project(:project_members_changed, %{uuid: project_uuid})
        end)

      existing ->
        change_role(project_uuid, existing, role, actor_uuid)
    end
  end

  @doc """
  Changes a member's role. Demoting the last owner is refused
  (`{:error, :last_owner}`).
  """
  @spec change_role(map() | binary(), binary() | ProjectMember.t(), String.t(), binary() | nil) ::
          {:ok, ProjectMember.t()} | {:error, term()}
  def change_role(project_or_uuid, member_or_user_uuid, new_role, actor_uuid \\ nil)

  def change_role(%{uuid: uuid}, member, new_role, actor_uuid),
    do: change_role(uuid, member, new_role, actor_uuid)

  def change_role(project_uuid, user_uuid, new_role, actor_uuid) when is_binary(user_uuid) do
    case get_member(project_uuid, user_uuid) do
      nil -> {:error, :not_a_member}
      member -> change_role(project_uuid, member, new_role, actor_uuid)
    end
  end

  def change_role(project_uuid, %ProjectMember{} = member, new_role, actor_uuid) do
    new_role = to_string(new_role)

    cond do
      member.role == new_role ->
        {:ok, member}

      member.role == "owner" and new_role != "owner" and owner_count(project_uuid) <= 1 ->
        {:error, :last_owner}

      true ->
        member
        |> ProjectMember.changeset(%{role: new_role})
        |> RepoHelper.repo().update()
        |> tap_ok(fn updated ->
          log_member("projects.member_role_changed", project_uuid, updated, actor_uuid, %{
            "from" => member.role,
            "to" => updated.role
          })

          PubSub.broadcast_project(:project_members_changed, %{uuid: project_uuid})
        end)
    end
  end

  @doc "Removes a member. The last owner cannot be removed (`{:error, :last_owner}`)."
  @spec remove_member(map() | binary(), binary(), keyword()) ::
          {:ok, ProjectMember.t()} | {:error, term()}
  def remove_member(project_or_uuid, user_uuid, opts \\ [])

  def remove_member(%{uuid: uuid}, user_uuid, opts), do: remove_member(uuid, user_uuid, opts)

  def remove_member(project_uuid, user_uuid, opts) when is_binary(user_uuid) do
    actor_uuid = Keyword.get(opts, :actor_uuid)

    case get_member(project_uuid, user_uuid) do
      nil ->
        {:error, :not_a_member}

      %ProjectMember{role: "owner"} = member ->
        if owner_count(project_uuid) <= 1 do
          {:error, :last_owner}
        else
          delete_member(project_uuid, member, actor_uuid)
        end

      member ->
        delete_member(project_uuid, member, actor_uuid)
    end
  end

  @doc """
  Ensures the project creator holds the owner seat — called by
  `Projects.create_project/2` when it knows the actor. Idempotent;
  best-effort (a failure logs, never aborts the create).
  """
  @spec ensure_creator_owner(binary(), binary() | nil) :: :ok
  def ensure_creator_owner(_project_uuid, nil), do: :ok

  def ensure_creator_owner(project_uuid, actor_uuid) when is_binary(actor_uuid) do
    # Pre-verify the user EXISTS: create_project may run inside a clone
    # transaction, and a user_uuid FK violation aborts the surrounding tx at
    # the Postgres level even though Ecto maps it to a changeset error
    # (caught by the Step 5 full run — a test-scope actor uuid with no users
    # row poisoned the template-clone transaction).
    with %{} <- Auth.get_user(actor_uuid),
         nil <- get_member(project_uuid, actor_uuid) do
      %ProjectMember{}
      |> ProjectMember.changeset(%{
        project_uuid: project_uuid,
        user_uuid: actor_uuid,
        role: "owner"
      })
      |> RepoHelper.repo().insert()
    end

    :ok
  rescue
    e ->
      Logger.warning("[Projects.Members] creator-owner seed failed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  # ── Internals ───────────────────────────────────────────────────────

  defp owner_count(project_uuid) do
    RepoHelper.repo().one(
      from(m in ProjectMember,
        where: m.project_uuid == ^project_uuid and m.role == "owner",
        select: count(m.uuid)
      )
    ) || 0
  end

  defp delete_member(project_uuid, member, actor_uuid) do
    member
    |> RepoHelper.repo().delete()
    |> tap_ok(fn removed ->
      log_member("projects.member_removed", project_uuid, removed, actor_uuid, %{
        "role" => removed.role
      })

      PubSub.broadcast_project(:project_members_changed, %{uuid: project_uuid})
    end)
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(other, _fun), do: other

  # target_uuid = the AFFECTED USER — core's activity→notification bridge
  # keys on it (skips self-actions), so "you were added / your role changed
  # / you were removed" reaches the user's notification channels for free.
  defp log_member(action, project_uuid, member, actor_uuid, extra) do
    Activity.log(action,
      actor_uuid: actor_uuid,
      resource_type: "project",
      resource_uuid: project_uuid,
      target_uuid: member.user_uuid,
      metadata: extra
    )
  end

  @doc """
  The `before_user_delete/1` lifecycle work (core calls the module hook
  BEFORE the user row deletes, while memberships still exist — the
  cascade would otherwise orphan sole-owner projects silently, the final
  panel's ZAI #5):

    * sole owner WITH other members → the most senior remaining member
      (manager > member > viewer, earliest seat wins ties) is promoted
      to owner (`projects.ownership_succeeded`);
    * sole owner with NO other members → an orphan-warning activity row
      (`projects.owner_departed`) — admin-recoverable, never guessed;
    * every membership departure is logged with the deletion reason.

  Best-effort by contract: core logs and continues if this raises.
  """
  @spec handle_user_deletion(binary()) :: :ok
  def handle_user_deletion(user_uuid) do
    memberships =
      RepoHelper.repo().all(from(m in ProjectMember, where: m.user_uuid == ^user_uuid))

    Enum.each(memberships, fn membership ->
      Activity.log("projects.member_removed",
        resource_type: "project",
        resource_uuid: membership.project_uuid,
        metadata: %{"reason" => "user_deleted", "role" => membership.role}
      )

      if membership.role == "owner" do
        handle_owner_departure(membership)
      end
    end)

    :ok
  end

  # Known narrow race (panel find, accepted): two co-owner USERS deleted
  # concurrently each see the other as a surviving owner, both skip
  # succession, and the CASCADE then removes both — an ownerless project
  # with no owner_departed row. Requires simultaneous multi-user deletion;
  # admin-recoverable via the members page.
  defp handle_owner_departure(membership) do
    others =
      RepoHelper.repo().all(
        from(m in ProjectMember,
          where: m.project_uuid == ^membership.project_uuid and m.uuid != ^membership.uuid,
          order_by: [asc: m.inserted_at]
        )
      )

    other_owners = Enum.filter(others, &(&1.role == "owner"))

    cond do
      other_owners != [] ->
        # Not the sole owner — nothing to remediate.
        :ok

      others == [] ->
        Activity.log("projects.owner_departed",
          resource_type: "project",
          resource_uuid: membership.project_uuid,
          metadata: %{"note" => "sole owner deleted; project has no members"}
        )

      true ->
        # to_unix, not the struct: tuple keys term-compare their elements, and
        # DateTime structs term-compare by field name (day before month before
        # year) — not chronologically.
        successor =
          Enum.min_by(others, fn m ->
            {Map.fetch!(%{"manager" => 0, "member" => 1, "viewer" => 2}, m.role),
             DateTime.to_unix(m.inserted_at)}
          end)

        successor
        |> Ecto.Changeset.change(role: "owner")
        |> RepoHelper.repo().update()
        |> case do
          {:ok, promoted} ->
            Activity.log("projects.ownership_succeeded",
              resource_type: "project",
              resource_uuid: membership.project_uuid,
              target_uuid: promoted.user_uuid,
              metadata: %{"from_role" => successor.role}
            )

            PubSub.broadcast_project(:project_members_changed, %{
              uuid: membership.project_uuid
            })

          {:error, _} ->
            Activity.log("projects.owner_departed",
              resource_type: "project",
              resource_uuid: membership.project_uuid,
              metadata: %{"note" => "sole owner deleted; succession failed"}
            )
        end
    end
  end
end
