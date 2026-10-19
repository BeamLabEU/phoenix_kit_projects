defmodule PhoenixKitProjects.ApiKeys do
  @moduledoc """
  API keys (chain V17, made global in V24): the credentials an outside
  agent presents to work over the JSON API (`PhoenixKitProjects.Web.Api`).

  A key has a `name` (what the agent is called) and reaches projects
  through GRANTS (`ApiKeyGrant`, one per key and project): what it may do
  there per area (`PhoenixKitProjects.ApiAccess`), a role cap, and whether
  the grant covers the project's sub-projects. `access_for/2` is THE rule —
  the nearest grant up a project's tree decides, an empty one means no
  access — and `view/2` is the key as it acts in one project. The key's
  own `project_uuid` is its HOME: where a call that names no project acts.
  The token `pkp_<key_id>_<secret>` is shown once and only the secret's
  SHA-256 is stored; `authenticate/1` finds the row by the public `key_id`,
  compares the secret in constant time, and refuses a revoked or expired
  key.

  A key is **personal** or **shared** (`ApiKey.kind/1`). A personal key acts
  for a person (`user_uuid`): in each project its role is that person's
  current role on the grant's project, capped by the grant's role and never
  above manager — `{:error, :membership_ended}` once they are off it (and
  `Members.remove_member/3` deletes that project's grant). A shared key has
  no person — each grant's role is the authority. Either way the ledger
  names the key as the actor of the usage it reports, and the activity log
  names `ApiKey.accountable_uuid/1` (the person acted for, else the minter)
  with the key in the metadata. `revoke/2` ends a key everywhere;
  `rotate/2` replaces the secret on the same row so its history stays one
  agent. Keys are managed on Projects → API keys (`Web.ApiKeysLive`): a
  person their own, administrators everyone's.

  `idempotent/3` is the retry guard for the API's appends: a response stored
  under (key, `Idempotency-Key`) is answered again on replay.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKitProjects.{Activity, Authz, Projects}
  alias PhoenixKitProjects.Schemas.{ApiIdempotency, ApiKey, ApiKeyGrant}

  # Strongest first; anything unrecognised ranks as the weakest.
  @role_rank %{"owner" => 0, "manager" => 1, "member" => 2, "viewer" => 3}

  @token_prefix "pkp"
  @key_id_bytes 9
  @secret_bytes 32
  # `last_used_at` moves at most this often, so a busy agent is not a write
  # on the key row per request.
  @touch_interval_seconds 60
  # How long one idempotent request may hold its connection (and so its lock).
  @lock_timeout :timer.minutes(10)

  @type token :: String.t()

  @doc "Every key with access set on a project, newest first, revoked ones included."
  @spec list_for_project(binary()) :: [ApiKey.t()]
  def list_for_project(project_uuid) when is_binary(project_uuid) do
    RepoHelper.repo().all(
      from(k in ApiKey,
        join: g in ApiKeyGrant,
        on: g.api_key_uuid == k.uuid,
        where: g.project_uuid == ^project_uuid,
        distinct: k.uuid,
        order_by: [desc: k.uuid]
      )
    )
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  @doc "The live keys acting for `user_uuid` with access set on a project, newest first."
  @spec list_for_user(binary(), binary()) :: [ApiKey.t()]
  def list_for_user(project_uuid, user_uuid)
      when is_binary(project_uuid) and is_binary(user_uuid) do
    project_uuid
    |> list_for_project()
    |> Enum.filter(&(&1.user_uuid == user_uuid and is_nil(&1.revoked_at)))
  end

  def list_for_user(_, _), do: []

  @doc "Every key acting for `user_uuid`, newest first, revoked ones included."
  @spec list_mine(binary()) :: [ApiKey.t()]
  def list_mine(user_uuid) when is_binary(user_uuid) do
    RepoHelper.repo().all(
      from(k in ApiKey, where: k.user_uuid == ^user_uuid, order_by: [desc: k.inserted_at])
    )
  end

  def list_mine(_), do: []

  @doc "Every key on the site, newest first — for administrators."
  @spec list_all() :: [ApiKey.t()]
  def list_all, do: RepoHelper.repo().all(from(k in ApiKey, order_by: [desc: k.inserted_at]))

  @doc """
  The keys that reach a project — a grant on it or on a project above it
  that covers its sub-projects — newest first, revoked ones left out. What
  a project's own pages show.
  """
  @spec list_reaching(binary()) :: [ApiKey.t()]
  def list_reaching(project_uuid) when is_binary(project_uuid) do
    chain = [project_uuid | project_uuid |> Projects.parent_chain() |> Enum.map(& &1.uuid)]

    from(k in ApiKey,
      join: g in ApiKeyGrant,
      on: g.api_key_uuid == k.uuid,
      where: g.project_uuid in ^chain and is_nil(k.revoked_at),
      distinct: true,
      select: k
    )
    |> RepoHelper.repo().all()
    |> Enum.filter(&match?({:ok, _}, access_for(&1, project_uuid)))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  rescue
    _ -> []
  end

  # ── Grants: what a key may do, per project (V24) ──────────────────

  @doc "A key's grants, oldest first."
  @spec grants(ApiKey.t() | binary()) :: [ApiKeyGrant.t()]
  def grants(%ApiKey{uuid: uuid}), do: grants(uuid)

  def grants(key_uuid) when is_binary(key_uuid) do
    RepoHelper.repo().all(
      from(g in ApiKeyGrant, where: g.api_key_uuid == ^key_uuid, order_by: g.inserted_at)
    )
  end

  @doc """
  Sets what a key may do in a project: `attrs` carries `"scopes"` (an empty
  list is "no access" — it stops a parent's grant there), `"role"` (the
  cap) and `"inherit"`. Creates the grant or replaces it. A key without a
  home gets this project as its home. Options: `:actor_uuid`.
  """
  @spec put_grant(ApiKey.t(), binary(), map(), keyword()) ::
          {:ok, ApiKeyGrant.t()} | {:error, Ecto.Changeset.t()}
  def put_grant(%ApiKey{} = key, project_uuid, attrs, opts \\ []) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("api_key_uuid", key.uuid)
      |> Map.put("project_uuid", project_uuid)
      |> Map.put_new("role", key.role || "member")

    existing =
      RepoHelper.repo().one(
        from(g in ApiKeyGrant,
          where: g.api_key_uuid == ^key.uuid and g.project_uuid == ^project_uuid
        )
      )

    result =
      (existing || %ApiKeyGrant{})
      |> ApiKeyGrant.changeset(attrs)
      |> RepoHelper.repo().insert_or_update()

    with {:ok, grant} <- result do
      if is_nil(key.project_uuid) do
        from(k in ApiKey, where: k.uuid == ^key.uuid and is_nil(k.project_uuid))
        |> RepoHelper.repo().update_all(set: [project_uuid: project_uuid])
      end

      Activity.log("projects.api_key_access_set",
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: "project",
        resource_uuid: project_uuid,
        metadata: %{
          "api_key" => key.uuid,
          "name" => key.name,
          "scopes" => grant.scopes,
          "role" => grant.role,
          "inherit" => grant.inherit
        }
      )

      {:ok, grant}
    end
  end

  @doc """
  Takes a key's access to a project away (the grant row goes; a parent's
  grant may then reach the project again). The key's home moves to another
  of its grants, or none. Options: `:actor_uuid`.
  """
  @spec delete_grant(ApiKey.t(), binary(), keyword()) :: :ok
  def delete_grant(%ApiKey{} = key, project_uuid, opts \\ []) do
    {n, _} =
      from(g in ApiKeyGrant,
        where: g.api_key_uuid == ^key.uuid and g.project_uuid == ^project_uuid
      )
      |> RepoHelper.repo().delete_all()

    if key.project_uuid == project_uuid do
      next = key |> grants() |> List.first()

      from(k in ApiKey, where: k.uuid == ^key.uuid)
      |> RepoHelper.repo().update_all(set: [project_uuid: next && next.project_uuid])
    end

    if n > 0 do
      Activity.log("projects.api_key_access_removed",
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: "project",
        resource_uuid: project_uuid,
        metadata: %{"api_key" => key.uuid, "name" => key.name}
      )
    end

    :ok
  end

  @doc "Makes `project_uuid` — one the key has a grant on — its home (where a call without `project` acts)."
  @spec set_home(ApiKey.t(), binary()) :: {:ok, ApiKey.t()} | {:error, :no_grant}
  def set_home(%ApiKey{} = key, project_uuid) do
    if Enum.any?(grants(key), &(&1.project_uuid == project_uuid and &1.scopes != [])) do
      key |> Ecto.Changeset.change(project_uuid: project_uuid) |> RepoHelper.repo().update()
    else
      {:error, :no_grant}
    end
  end

  @doc """
  What `key` may do in a project right now: `{:ok, %{scopes, role, grant}}`,
  or `{:error, :no_access}` / `{:error, :membership_ended}`.

  The NEAREST grant up the project's tree decides — the project's own, else
  its parent's, and so on. A grant on a project above that does not cover
  sub-projects (`inherit: false`), or a nearest grant with no scopes ("no
  access"), means no access; nothing further up is consulted. The role is
  the grant's cap for a shared key; for a personal key the weakest of the
  cap, the person's current role on the GRANT's project and manager — the
  grant's project, because sub-projects usually have no members of their
  own. A person no longer on that project ends the grant
  (`:membership_ended`), not the key.
  """
  @spec access_for(ApiKey.t(), binary() | map()) ::
          {:ok, %{scopes: [String.t()], role: String.t(), grant: ApiKeyGrant.t()}}
          | {:error, :no_access | :membership_ended}
  def access_for(%ApiKey{} = key, %{uuid: uuid}), do: access_for(key, uuid)

  def access_for(%ApiKey{uuid: key_uuid} = key, project_uuid) when is_binary(project_uuid) do
    case Projects.get_project(project_uuid) do
      # Templates are not worked in; no grant reaches one.
      %{is_template: false} -> nearest_grant(key, key_uuid, project_uuid)
      _ -> {:error, :no_access}
    end
  end

  def access_for(_key, _project), do: {:error, :no_access}

  defp nearest_grant(key, key_uuid, project_uuid) do
    by_project = Map.new(grants(key_uuid), &{&1.project_uuid, &1})

    chain = [
      project_uuid
      | project_uuid |> Projects.parent_chain() |> Enum.reverse() |> Enum.map(& &1.uuid)
    ]

    case Enum.find_value(chain, fn uuid -> by_project[uuid] end) do
      nil ->
        {:error, :no_access}

      %ApiKeyGrant{scopes: []} ->
        {:error, :no_access}

      %ApiKeyGrant{project_uuid: ^project_uuid} = grant ->
        grant_role(key, grant)

      %ApiKeyGrant{inherit: false} ->
        {:error, :no_access}

      grant ->
        grant_role(key, grant)
    end
  rescue
    _ -> {:error, :no_access}
  end

  defp grant_role(%ApiKey{user_uuid: nil}, grant),
    do: {:ok, %{scopes: grant.scopes, role: grant.role, grant: grant}}

  defp grant_role(%ApiKey{user_uuid: user_uuid}, grant) do
    case Projects.get_project(grant.project_uuid) do
      nil ->
        {:error, :no_access}

      project ->
        case Authz.effective_role(project, user_uuid) do
          nil ->
            {:error, :membership_ended}

          role ->
            {:ok,
             %{scopes: grant.scopes, role: weaker(Atom.to_string(role), grant.role), grant: grant}}
        end
    end
  end

  @doc "Whether `key` may use `scope` in a project right now."
  @spec allows?(ApiKey.t(), binary(), String.t()) :: boolean()
  def allows?(%ApiKey{} = key, project_uuid, scope) do
    case access_for(key, project_uuid) do
      {:ok, %{scopes: scopes}} -> scope in scopes
      _ -> false
    end
  end

  @doc """
  The key as it acts in `project`: its `role` and `scopes` set to that
  project's access (`access_for/2`). What every API check reads, so a key
  never carries one project's rights into another.
  """
  @spec view(ApiKey.t(), map() | binary()) ::
          {:ok, ApiKey.t()} | {:error, :no_access | :membership_ended}
  def view(%ApiKey{} = key, project) do
    with {:ok, %{scopes: scopes, role: role}} <- access_for(key, project),
         do: {:ok, %{key | role: role, scopes: scopes}}
  end

  @doc """
  Every project the key reaches, with its access there: the projects it has
  grants on, and — for grants that cover sub-projects — everything under
  them. `[%{project, scopes, role, source}]`, `source` `:direct` or
  `{:inherited, from_project_uuid}`. What `GET /me` lists.
  """
  @spec reachable(ApiKey.t()) :: [map()]
  def reachable(%ApiKey{} = key) do
    key
    |> grants()
    |> Enum.flat_map(fn g ->
      below =
        if g.inherit, do: Projects.subtree_uuids(g.project_uuid) -- [g.project_uuid], else: []

      [g.project_uuid | below]
    end)
    |> Enum.uniq()
    |> Enum.flat_map(fn uuid ->
      with %{} = project <- Projects.get_project(uuid),
           {:ok, access} <- access_for(key, uuid) do
        source =
          if access.grant.project_uuid == uuid,
            do: :direct,
            else: {:inherited, access.grant.project_uuid}

        [%{project: project, scopes: access.scopes, role: access.role, source: source}]
      else
        _ -> []
      end
    end)
  rescue
    _ -> []
  end

  @doc """
  The key as it acts in `project` for one request (`view/2`). A
  personal key also needs its person's ACCOUNT to be live and to hold the
  `projects` permission: a deactivated or deleted user's key, or one whose
  person lost Projects, is `{:error, :account_inactive}` (the API answers
  it with the one 401), whatever the project's "everyone" visibility or a
  lingering membership would still hand them.
  """
  @spec resolve(ApiKey.t(), map()) ::
          {:ok, ApiKey.t()} | {:error, :membership_ended | :account_inactive | :no_access}
  def resolve(%ApiKey{} = key, project) do
    with :ok <- account_live(key), do: view(key, project)
  end

  defp account_live(%ApiKey{user_uuid: nil}), do: :ok

  # A personal key works only while its person could reach the Projects
  # module themselves: an active account holding the `projects` permission
  # (or everything, "*"). Taking Projects away from someone stops their keys
  # even where they are still a member.
  defp account_live(%ApiKey{user_uuid: user_uuid}) do
    case Auth.get_user(user_uuid) do
      %{is_active: true} = user ->
        perms = Permissions.get_permissions_for_user(user)
        if "projects" in perms or "*" in perms, do: :ok, else: {:error, :account_inactive}

      _ ->
        {:error, :account_inactive}
    end
  end

  # The weakest of the three: owner is not a key role, so the strongest a
  # key acts with is manager.
  defp weaker(role, cap) do
    Enum.max_by(["manager", cap, role], &Map.get(@role_rank, &1, 3))
  end

  @doc """
  Takes the project away from every key acting for `user_uuid` — when they
  leave it. The keys themselves stay: what they reach elsewhere is not
  this project's to end (V24; before it a key had one project and was
  revoked).
  """
  @spec revoke_for_user(binary(), binary(), keyword()) :: :ok
  def revoke_for_user(project_uuid, user_uuid, opts \\ []) do
    project_uuid
    |> list_for_user(user_uuid)
    |> Enum.each(&delete_grant(&1, project_uuid, opts))

    :ok
  rescue
    e ->
      Logger.warning("ApiKeys.revoke_for_user failed: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Revokes every live personal key acting for `user_uuid`, on every project —
  the account is being deleted. `revoke_for_user/3` is the per-project form
  for leaving one project.
  """
  @spec revoke_all_for_user(binary()) :: :ok
  def revoke_all_for_user(user_uuid) when is_binary(user_uuid) do
    RepoHelper.repo().all(
      from(k in ApiKey, where: k.user_uuid == ^user_uuid and is_nil(k.revoked_at))
    )
    |> Enum.each(&revoke(&1, reason: "user_deleted"))

    :ok
  rescue
    e ->
      Logger.warning("ApiKeys.revoke_all_for_user failed: #{Exception.message(e)}")
      :ok
  end

  def revoke_all_for_user(_), do: :ok

  @doc "A key by uuid, or nil."
  @spec get(binary()) :: ApiKey.t() | nil
  def get(uuid) when is_binary(uuid), do: RepoHelper.repo().get(ApiKey, uuid)
  def get(_), do: nil

  @doc """
  Mints a key for `project`. `attrs`: `"name"` (required), `"role"` (default
  `"member"`; for a personal key the cap), `"scopes"` (default every scope),
  `"expires_at"`, `"user_uuid"` (the member the key acts for — absent for a
  shared agent). Options: `:actor_uuid` — the person minting it, recorded
  as `created_by_uuid` and as the activity's actor.

  Returns `{:ok, key, token}`; the token is the only time the secret exists
  in the clear.
  """
  @spec create(map() | binary(), map(), keyword()) ::
          {:ok, ApiKey.t(), token()} | {:error, Ecto.Changeset.t()}
  def create(project_or_uuid, attrs, opts \\ []) do
    project_uuid = project_uuid(project_or_uuid)
    actor_uuid = Keyword.get(opts, :actor_uuid)
    {key_id, secret, token} = generate_token()

    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("project_uuid", project_uuid)
      |> Map.put("created_by_uuid", actor_uuid)
      |> Map.put_new("scopes", ApiKey.scopes())
      |> default_cap()

    changeset =
      %ApiKey{}
      |> ApiKey.credential_changeset(key_id, hash(secret))
      |> ApiKey.create_changeset(attrs)

    case insert_with_grant(changeset, attrs) do
      {:ok, key} ->
        Activity.log("projects.api_key_created",
          actor_uuid: actor_uuid,
          resource_type: "project",
          resource_uuid: project_uuid,
          metadata: %{
            "api_key" => key.uuid,
            "name" => key.name,
            "role" => key.role,
            "user" => key.user_uuid
          }
        )

        {:ok, key, token}

      {:error, _} = error ->
        error
    end
  end

  # The key and, when it has a project, its grant there — the scopes and
  # the role it was minted with. One transaction: no key without its access.
  defp insert_with_grant(changeset, attrs) do
    RepoHelper.repo().transaction(fn ->
      with {:ok, key} <- RepoHelper.repo().insert(changeset),
           :ok <- first_grant(key, attrs) do
        key
      else
        {:error, cs} -> RepoHelper.repo().rollback(cs)
      end
    end)
  end

  defp first_grant(%ApiKey{project_uuid: nil}, _attrs), do: :ok

  defp first_grant(%ApiKey{} = key, attrs) do
    %ApiKeyGrant{}
    |> ApiKeyGrant.changeset(%{
      "api_key_uuid" => key.uuid,
      "project_uuid" => key.project_uuid,
      "scopes" => Map.get(attrs, "scopes", key.scopes),
      "role" => key.role,
      "inherit" => Map.get(attrs, "inherit", true)
    })
    |> RepoHelper.repo().insert()
    |> case do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, cs}
    end
  end

  # A personal key's stored role is a cap: left unsaid, it caps at nothing
  # below manager. A shared key's stored role is its authority: member.
  defp default_cap(%{"user_uuid" => uuid} = attrs) when is_binary(uuid) and uuid != "",
    do: Map.put_new(attrs, "role", "manager")

  defp default_cap(attrs), do: Map.put_new(attrs, "role", "member")

  @doc """
  Replaces the key's secret on the same row and returns the new token; the
  old token stops working at once. The key keeps its uuid, so the ledger
  rows it wrote stay one agent's. Refused for a revoked key.
  """
  @spec rotate(ApiKey.t(), keyword()) :: {:ok, ApiKey.t(), token()} | {:error, term()}
  def rotate(%ApiKey{revoked_at: %DateTime{}}, _opts), do: {:error, :revoked}

  def rotate(%ApiKey{} = key, opts) do
    {key_id, secret, token} = generate_token()

    case RepoHelper.repo().update(ApiKey.credential_changeset(key, key_id, hash(secret))) do
      {:ok, key} ->
        Activity.log("projects.api_key_rotated",
          actor_uuid: Keyword.get(opts, :actor_uuid),
          resource_type: "project",
          resource_uuid: key.project_uuid,
          metadata: %{"api_key" => key.uuid, "name" => key.name}
        )

        {:ok, key, token}

      {:error, _} = error ->
        error
    end
  end

  @doc "Revokes the key: every later call with it answers 401. Idempotent."
  @spec revoke(ApiKey.t(), keyword()) :: {:ok, ApiKey.t()} | {:error, term()}
  def revoke(%ApiKey{revoked_at: %DateTime{}} = key, _opts), do: {:ok, key}

  def revoke(%ApiKey{} = key, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case RepoHelper.repo().update(Ecto.Changeset.change(key, revoked_at: now)) do
      {:ok, key} ->
        Activity.log("projects.api_key_revoked",
          actor_uuid: Keyword.get(opts, :actor_uuid),
          resource_type: "project",
          resource_uuid: key.project_uuid,
          metadata:
            %{"api_key" => key.uuid, "name" => key.name}
            |> Map.merge(
              case Keyword.get(opts, :reason) do
                nil -> %{}
                reason -> %{"reason" => reason}
              end
            )
        )

        {:ok, key}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Copies a live key's grant on `from_uuid` to `to_uuid`, for a project
  moved out from under `from_uuid` (`ProjectMove`): the token its agent
  holds keeps reaching it with the same access. A grant the key already
  has on `to_uuid` is kept as it is (`{:ok, :kept}`) — it was set on
  purpose, and may be stricter. Refused for a revoked key, or one with no
  grant on `from_uuid`. Options: `:actor_uuid`.
  """
  @spec carry_grant(ApiKey.t(), binary(), binary(), keyword()) ::
          {:ok, ApiKeyGrant.t() | :kept} | {:error, :revoked | :no_grant | Ecto.Changeset.t()}
  def carry_grant(key, from_uuid, to_uuid, opts \\ [])

  def carry_grant(%ApiKey{revoked_at: %DateTime{}}, _from, _to, _opts), do: {:error, :revoked}

  def carry_grant(%ApiKey{} = key, from_uuid, to_uuid, opts) do
    by_project = Map.new(grants(key), &{&1.project_uuid, &1})

    cond do
      Map.has_key?(by_project, to_uuid) ->
        {:ok, :kept}

      grant = by_project[from_uuid] ->
        put_grant(
          key,
          to_uuid,
          %{"scopes" => grant.scopes, "role" => grant.role, "inherit" => grant.inherit},
          opts
        )

      true ->
        {:error, :no_grant}
    end
  end

  @doc """
  The key a presented token belongs to, if it is well-formed, known, not
  revoked and not expired. Every refusal is the same `{:error, reason}`
  shape; the API answers all of them with one 401, so a caller cannot tell
  an unknown key from a revoked one.
  """
  @spec authenticate(term()) ::
          {:ok, ApiKey.t()} | {:error, :malformed | :unknown | :revoked | :expired}
  def authenticate(token) when is_binary(token) do
    with {:ok, key_id, secret} <- parse_token(token),
         %ApiKey{} = key <- RepoHelper.repo().one(from(k in ApiKey, where: k.key_id == ^key_id)),
         true <- Plug.Crypto.secure_compare(hash(secret), key.secret_hash || "") do
      cond do
        not is_nil(key.revoked_at) -> {:error, :revoked}
        not ApiKey.active?(key, DateTime.utc_now()) -> {:error, :expired}
        true -> {:ok, key}
      end
    else
      {:error, :malformed} -> {:error, :malformed}
      _ -> {:error, :unknown}
    end
  rescue
    _ -> {:error, :unknown}
  end

  def authenticate(_), do: {:error, :malformed}

  @doc """
  Marks the key as used now — at most once per #{@touch_interval_seconds}
  seconds, so a chatty agent is not a write on the key row per call.
  """
  @spec touch_last_used(ApiKey.t()) :: ApiKey.t()
  def touch_last_used(%ApiKey{} = key) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    stale? =
      is_nil(key.last_used_at) or
        DateTime.diff(now, key.last_used_at, :second) >= @touch_interval_seconds

    if stale? do
      case RepoHelper.repo().update(Ecto.Changeset.change(key, last_used_at: now)) do
        {:ok, key} -> key
        _ -> key
      end
    else
      key
    end
  rescue
    _ -> key
  end

  @doc """
  Runs `fun` once per (key, `idempotency_key`): the first call runs it and
  stores its `{status, body}`; a replay answers `{:replay, status, body}`
  without running it. With no idempotency key the call just runs.

  **Who is running it is a database fact, not a clock.** The call pins one
  connection (`Repo.checkout/2`) and takes a Postgres SESSION advisory lock
  named by (key, header) for as long as the work runs. A second request for
  the same pair that cannot take the lock knows the first is alive — a slow
  call and a dead one look alike to a timer, never to the lock — and answers
  409 `in_progress`. When the first request's process dies (a crash, a
  kill, a node going down) its connection closes and Postgres drops the
  lock, so the next retry finds a pending row and a free lock: the owner is
  provably gone, and the retry takes the reservation over and runs the work.
  Never two runs side by side, never a key stuck for ever.

  What remains is the one window no scheme closes: a request that died
  AFTER its work committed and BEFORE its answer was stored is run again by
  the retry. Needs session-stable connections — a transaction-pooling proxy
  (PgBouncer's transaction mode) between the app and Postgres would make
  the lock meaningless.
  """
  @spec idempotent(ApiKey.t(), String.t() | nil, (-> {integer(), map()})) ::
          {:ok, integer(), map()} | {:replay, integer(), map()}
  def idempotent(%ApiKey{}, nil, fun), do: wrap(fun.())

  def idempotent(%ApiKey{uuid: key_uuid}, idempotency_key, fun)
      when is_binary(idempotency_key) do
    # The checkout is the lease: it must outlive any request, and the pool's
    # default 15 s would drop a slow one's connection (and lock) mid-work.
    RepoHelper.repo().checkout(
      fn ->
        case advisory_lock(key_uuid, idempotency_key) do
          :locked ->
            try do
              locked(key_uuid, idempotency_key, fun)
            after
              advisory_unlock(key_uuid, idempotency_key)
            end

          :busy ->
            {:ok, 409,
             %{
               error: %{
                 code: "in_progress",
                 message:
                   "A request with this Idempotency-Key is still running; retry in a moment."
               }
             }}

          :unavailable ->
            wrap(fun.())
        end
      end,
      timeout: @lock_timeout
    )
  end

  # Holding the lock, no other live request has this pair. The key is
  # RESERVED before the work runs (a pending row, status 0); a pending row
  # found here belongs to a request that died (it would hold the lock
  # otherwise), so it is taken over. A 5xx frees the key again so a retry
  # may run the work.
  defp locked(key_uuid, idempotency_key, fun) do
    case reserve(key_uuid, idempotency_key) do
      {:reserved, row} -> run_reserved(row, fun)
      {:stored, %ApiIdempotency{status: status, body: body}} -> {:replay, status, body}
      :unavailable -> wrap(fun.())
    end
  end

  @doc false
  # The lock's name; public so the tests can hold it from another session.
  @spec lock_name(binary(), String.t()) :: String.t()
  def lock_name(key_uuid, idempotency_key), do: "pkp_idem:#{key_uuid}:#{idempotency_key}"

  defp advisory_lock(key_uuid, idempotency_key) do
    case RepoHelper.repo().query("SELECT pg_try_advisory_lock(hashtextextended($1, 0))", [
           lock_name(key_uuid, idempotency_key)
         ]) do
      {:ok, %{rows: [[true]]}} -> :locked
      {:ok, %{rows: [[false]]}} -> :busy
      _ -> :unavailable
    end
  rescue
    e ->
      Logger.warning("[Projects.ApiKeys] idempotency lock unavailable: #{Exception.message(e)}")
      :unavailable
  end

  # Best effort: if the connection is gone the lock went with it.
  defp advisory_unlock(key_uuid, idempotency_key) do
    RepoHelper.repo().query("SELECT pg_advisory_unlock(hashtextextended($1, 0))", [
      lock_name(key_uuid, idempotency_key)
    ])
  rescue
    _ -> :ok
  end

  defp reserve(key_uuid, idempotency_key) do
    # `insert_all` with `on_conflict: :nothing` says how many rows it
    # wrote: one means the key is ours, zero means a row is there already.
    row = %{api_key_uuid: key_uuid, idempotency_key: idempotency_key, status: 0, body: %{}}

    case RepoHelper.repo().insert_all(ApiIdempotency, [row], on_conflict: :nothing) do
      {1, _} -> {:reserved, pending_row(key_uuid, idempotency_key)}
      _ -> existing(key_uuid, idempotency_key)
    end
  rescue
    e ->
      Logger.warning("[Projects.ApiKeys] idempotency store unavailable: #{Exception.message(e)}")
      :unavailable
  end

  defp existing(key_uuid, idempotency_key) do
    case RepoHelper.repo().get_by(ApiIdempotency,
           api_key_uuid: key_uuid,
           idempotency_key: idempotency_key
         ) do
      # Pending, and we hold the lock: the request that reserved it is gone.
      %ApiIdempotency{status: 0} -> {:reserved, pending_row(key_uuid, idempotency_key)}
      %ApiIdempotency{} = stored -> {:stored, stored}
      # Freed between the conflict and the read (a 5xx released it): ours now.
      nil -> reserve(key_uuid, idempotency_key)
    end
  end

  defp pending_row(key_uuid, idempotency_key),
    do: %ApiIdempotency{api_key_uuid: key_uuid, idempotency_key: idempotency_key, status: 0}

  # The work runs exactly once; what it answered is stored under the
  # reservation. A 5xx or a crash frees the reservation and the answer
  # (or the raise) goes out as it is — never a second run.
  defp run_reserved(row, fun) do
    {status, body} = fun.()

    if status < 500 do
      RepoHelper.repo().update_all(
        from(i in ApiIdempotency,
          where: i.api_key_uuid == ^row.api_key_uuid and i.idempotency_key == ^row.idempotency_key
        ),
        set: [status: status, body: body]
      )
    else
      release(row)
    end

    {:ok, status, body}
  rescue
    e ->
      release(row)
      reraise e, __STACKTRACE__
  end

  defp release(row) do
    RepoHelper.repo().delete_all(
      from(i in ApiIdempotency,
        where: i.api_key_uuid == ^row.api_key_uuid and i.idempotency_key == ^row.idempotency_key
      )
    )
  rescue
    _ -> :ok
  end

  defp wrap({status, body}), do: {:ok, status, body}

  @doc "The public id, the secret and the token the agent holds."
  @spec generate_token() :: {String.t(), String.t(), token()}
  def generate_token do
    # Base32-hex, lower case: 0-9 and a-v only, so neither half can contain
    # the `_` that separates the token's parts.
    key_id =
      @key_id_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.hex_encode32(case: :lower, padding: false)

    secret =
      @secret_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.hex_encode32(case: :lower, padding: false)

    {key_id, secret, Enum.join([@token_prefix, key_id, secret], "_")}
  end

  @doc "The display form of a key's public id: the token's start, never its secret."
  @spec display_prefix(ApiKey.t()) :: String.t()
  def display_prefix(%ApiKey{key_id: key_id}), do: "#{@token_prefix}_#{key_id}_…"

  defp parse_token(token) do
    case String.split(token, "_", parts: 3) do
      [@token_prefix, key_id, secret] when byte_size(key_id) > 0 and byte_size(secret) > 0 ->
        {:ok, key_id, secret}

      _ ->
        {:error, :malformed}
    end
  end

  defp hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

  defp project_uuid(%{uuid: uuid}) when is_binary(uuid), do: uuid
  defp project_uuid(uuid) when is_binary(uuid), do: uuid

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
