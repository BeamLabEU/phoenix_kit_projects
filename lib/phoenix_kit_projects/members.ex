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
    |> Enum.sort_by(&{Map.get(role_order, &1.role, 9), &1.inserted_at})
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
end
