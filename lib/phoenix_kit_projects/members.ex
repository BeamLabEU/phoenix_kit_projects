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
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitProjects.{Activity, ApiKeys, AssigneeSet, Notices, People}
  alias PhoenixKitProjects.PubSub
  alias PhoenixKitProjects.Schemas.{Assignment, Project, ProjectMember}

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

    # Projects marked visible to everyone are reachable without any row of
    # their own, so the LIST has to know about them too — otherwise the
    # page gate says yes and the index they came from never showed it.
    open_uuids =
      open_project_uuids(user_uuid)

    granted = Enum.reduce(open_uuids, granted, &Map.put_new(&2, &1, "viewer"))

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

  # The "everyone" projects this user reaches through the open viewer seat —
  # none unless they can enter the module (`Authz.module_reacher?/1`), the
  # same condition `Authz.effective_role/2` puts on that seat. The listing and
  # the page gate must agree, or a list shows a project its page refuses (or
  # the other way round).
  defp open_project_uuids(user_uuid) do
    uuids =
      RepoHelper.repo().all(
        from(p in PhoenixKitProjects.Schemas.Project,
          where:
            p.is_template == false and
              fragment("COALESCE(?->>'visibility', 'private') = 'everyone'", p.settings),
          select: p.uuid
        )
      )

    if uuids != [] and PhoenixKitProjects.Authz.module_reacher?(user_uuid), do: uuids, else: []
  end

  @doc """
  The uuid set behind `accessible_projects/1`, without materialising a
  single `%Project{}` struct.

  For a caller that only needs to scope a `WHERE uuid IN (...)` — the
  narrowing every non-admin listing query does — `accessible_projects/1`
  does needless work: it loads the FULL row for every direct membership
  and every group-granted extra just to discard everything but the uuid a
  moment later. This selects `p.uuid` at each step instead, same three
  sources (direct membership, group grants, "everyone"-visible), same
  non-template filter, same fail-closed `[]` on error.

  Equivalence with `accessible_projects/1` is pinned in
  `test/phoenix_kit_projects/integration/members_test.exs` — the two must
  always agree on WHICH projects, never just on shape.
  """
  @spec accessible_project_uuids(binary()) :: [binary()]
  def accessible_project_uuids(user_uuid) when is_binary(user_uuid) do
    direct_uuids =
      RepoHelper.repo().all(
        from(m in ProjectMember,
          join: p in PhoenixKitProjects.Schemas.Project,
          on: p.uuid == m.project_uuid,
          where: m.user_uuid == ^user_uuid and p.is_template == false,
          select: p.uuid
        )
      )

    granted_keys = user_uuid |> PhoenixKitProjects.Grants.project_roles_for_user() |> Map.keys()

    granted_uuids =
      if granted_keys == [] do
        []
      else
        RepoHelper.repo().all(
          from(p in PhoenixKitProjects.Schemas.Project,
            where: p.uuid in ^granted_keys and p.is_template == false,
            select: p.uuid
          )
        )
      end

    open_uuids =
      open_project_uuids(user_uuid)

    (direct_uuids ++ granted_uuids ++ open_uuids) |> Enum.uniq()
  rescue
    e ->
      Logger.warning(
        "[Projects.Members] accessible_project_uuids failed: #{Exception.message(e)}"
      )

      []
  catch
    :exit, _ -> []
  end

  def accessible_project_uuids(_), do: []

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
  Adds a member. Options: `:role` (default `"member"`), `:actor_uuid`,
  `:log_metadata` (merged under the history entry's own, e.g. the task an
  assignment added them through), `:only_new` (an existing member is left
  as they are: `{:error, :already_member}`). Otherwise adding an existing
  member updates their role through the same guards.
  """
  @spec add_member(map() | binary(), binary(), keyword()) ::
          {:ok, ProjectMember.t()} | {:error, term()}
  def add_member(project_or_uuid, user_uuid, opts \\ [])

  def add_member(%{uuid: uuid}, user_uuid, opts), do: add_member(uuid, user_uuid, opts)

  def add_member(project_uuid, user_uuid, opts)
      when is_binary(project_uuid) and is_binary(user_uuid) do
    role = opts |> Keyword.get(:role, "member") |> to_string()
    actor_uuid = Keyword.get(opts, :actor_uuid)
    only_new? = Keyword.get(opts, :only_new, false)

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
          log_member(
            "projects.member_added",
            project_uuid,
            member,
            actor_uuid,
            Map.merge(Keyword.get(opts, :log_metadata, %{}), %{"role" => member.role})
          )

          PubSub.broadcast_project(:project_members_changed, %{uuid: project_uuid})
        end)

      # An admission (`admit_users/3`) never touches a seat someone gave in
      # the meantime: a manager added between its check and this write would
      # otherwise be demoted to member.
      _existing when only_new? ->
        {:error, :already_member}

      existing ->
        change_role(project_uuid, existing, role, actor_uuid)
    end
  end

  @doc """
  The rule behind "if we can assign them, they can open the project" (Max,
  2026-11-19): after a write that put people on a task — directly, or a
  team or department and so its people — each of them with a login who
  cannot open the task's project becomes a **member** of it. They are told
  (`projects.member_added`, naming the task), with nothing to accept: the
  project is simply in their list from then on, and the history records
  it. They stay members when taken off the task again; removing someone is
  the Members page's.

  `was_keys` are the assignees before the write (`[]` for a new task); only
  the ones added now are looked at. Nobody is added to a template, and a
  deactivated or API-only account never. A staff record with no login has
  nobody to add (`assignee_reach/2` says so to the screens). Called from
  the context's writes (`Projects.create_assignment/2`,
  `create_task_with_assignment/4`, `update_assignment_form/3`), so the
  form, the popup, the API and a template's clone all get it. Never
  raises: an assignment is never lost to this. Answers the users added.
  """
  @spec admit_assignees(Assignment.t(), [AssigneeSet.key()], keyword()) :: [binary()]
  def admit_assignees(%Assignment{} = a, was_keys, opts \\ []) do
    added = AssigneeSet.keys(a) -- List.wrap(was_keys)

    # A task still waiting for review (a portal request) admits nobody until
    # it is accepted (codex, 2026-11-19) — `Projects.review_assignment/3`
    # admits then.
    with false <- Map.get(a, :review_status) == "pending",
         [_ | _] <- added,
         [_ | _] = users <- People.user_uuids_for(added),
         %Project{} = project <- PhoenixKitProjects.Projects.get_project(a.project_uuid) do
      # `source` says where the assigning came from ("api"), when the
      # caller says (the boss's review of #63: API-made rows said nothing).
      meta =
        %{"via" => "assignment", "task" => task_label(a), "task_uuid" => a.uuid}
        |> then(&if(is_binary(opts[:source]), do: Map.put(&1, "source", opts[:source]), else: &1))

      admit_users(project, users, Keyword.put(opts, :log_metadata, meta))
    else
      _ -> []
    end
  rescue
    error ->
      Logger.warning("[Projects] admitting assignees failed: #{inspect(error.__struct__)}")
      []
  catch
    :exit, _ -> []
  end

  @doc """
  Makes each of `user_uuids` who has an active login and cannot open
  `project` a **member** of it (`projects.member_added`, with
  `opts[:log_metadata]` and `opts[:actor_uuid]`). The one admission rule,
  shared by `admit_assignees/3` and the Done / next-up dialogs: never a
  template, never a deactivated or API-only account, and an existing
  member's seat is never changed. The accounts and the seats are read once
  for the whole list. Never raises; answers the users added.

  Writes outside any transaction only: a failed insert would abort the
  caller's, and the notice and broadcast would go out before its commit.
  A caller inside one passes `admit: false` to the context write and
  admits after the commit.
  """
  @spec admit_users(Project.t(), [binary()], keyword()) :: [binary()]
  def admit_users(project, user_uuids, opts \\ [])

  def admit_users(%Project{is_template: false} = project, user_uuids, opts)
      when is_list(user_uuids) do
    users = user_uuids |> Enum.filter(&is_binary/1) |> Enum.uniq()
    active = assignable_users(users)
    seated = seated_users(project.uuid, users)

    for user <- users,
        Map.has_key?(active, user),
        not Map.has_key?(seated, user),
        not Notices.may_view?(user, project),
        match?(
          {:ok, _},
          add_member(project, user,
            role: "member",
            only_new: true,
            actor_uuid: Keyword.get(opts, :actor_uuid),
            log_metadata: Keyword.get(opts, :log_metadata, %{})
          )
        ),
        do: user
  rescue
    error ->
      Logger.warning("[Projects] admitting users failed: #{inspect(error.__struct__)}")
      []
  catch
    :exit, _ -> []
  end

  def admit_users(_project, _user_uuids, _opts), do: []

  # The task's name as audit rows keep it. A row just written has no task
  # loaded, so it is read once.
  defp task_label(%Assignment{} = a) do
    case PhoenixKitProjects.Projects.get_assignment(a.uuid) do
      %Assignment{} = fresh -> Assignment.label(fresh)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The accounts of `users` that may be given a seat: active, not API-only.
  # Plain maps rather than MapSets: dialyzer reads MapSet's opaque type
  # wrongly through `for` filters.
  defp assignable_users([]), do: %{}

  defp assignable_users(users) do
    from(u in User, where: u.uuid in ^users)
    |> RepoHelper.repo().all()
    |> Enum.filter(&People.assignable_user?/1)
    |> Map.new(&{&1.uuid, true})
  end

  defp seated_users(_project_uuid, []), do: %{}

  defp seated_users(project_uuid, users) do
    from(m in ProjectMember,
      where: m.project_uuid == ^project_uuid and m.user_uuid in ^users,
      select: m.user_uuid
    )
    |> RepoHelper.repo().all()
    |> Map.new(&{&1, true})
  end

  @doc """
  Who a list of assignee keys reaches, person by person, for the screens
  that say who will be told: `%{uuid, name, user_uuid, status}`, `status`
  one of

    * `:ok` — has a login and can open `project`;
    * `:cannot_open` — has a login but cannot open it (assigning makes
      them a member; until then nothing reaches them);
    * `:no_login` — a staff record no account is linked to: nothing can
      reach them ("No login yet");
    * `:inactive` — the linked account is deactivated (or API-only): it is
      neither told nor admitted.

  A team or a department is expanded into its people. Never raises.
  """
  @spec assignee_reach([AssigneeSet.key()], Project.t()) :: [
          %{
            uuid: binary(),
            name: String.t(),
            user_uuid: binary() | nil,
            status: :ok | :cannot_open | :no_login | :inactive
          }
        ]
  def assignee_reach(keys, %Project{} = project) when is_list(keys) do
    people = People.people_for(keys)
    active = people |> Enum.map(& &1.user_uuid) |> Enum.filter(&is_binary/1) |> assignable_users()

    Enum.map(people, fn person ->
      status =
        cond do
          is_nil(person.user_uuid) -> :no_login
          not Map.has_key?(active, person.user_uuid) -> :inactive
          Notices.may_view?(person.user_uuid, project) -> :ok
          true -> :cannot_open
        end

      Map.put(person, :status, status)
    end)
  rescue
    _ -> []
  end

  def assignee_reach(_keys, _project), do: []

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

      # Their personal keys would be refused from now on anyway
      # (`ApiKeys.resolve/2`); revoking makes it visible and keeps an old
      # secret from waking up if they are added back.
      ApiKeys.revoke_for_user(project_uuid, removed.user_uuid, actor_uuid: actor_uuid)

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
    # Their personal API keys die with the account: the membership rows
    # cascade away, but on an "everyone" project a bare uuid still resolves
    # to a viewer seat, so the keys must be revoked, not merely orphaned.
    ApiKeys.revoke_all_for_user(user_uuid)

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
