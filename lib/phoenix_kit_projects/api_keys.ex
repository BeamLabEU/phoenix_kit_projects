defmodule PhoenixKitProjects.ApiKeys do
  @moduledoc """
  Project API keys (chain V17): the credentials an outside agent presents to
  drive one project over the JSON API (`PhoenixKitProjects.Web.Api`).

  A key is minted on a project with a `name` (what the agent is called), a
  `role` of its own (`manager` / `member` / `viewer` — never owner) and a set
  of scopes; the token `pkp_<key_id>_<secret>` is shown once and only the
  secret's SHA-256 is stored. `authenticate/1` turns a presented token back
  into its key: the public `key_id` finds the row, the secret is compared
  in constant time against the hash, and a revoked or expired key is refused.

  A key is **personal** or **shared** (`ApiKey.kind/1`). A personal key acts
  for a member (`user_uuid`): `effective_role/2` reads that person's current
  membership, capped by the key's stored role and never above manager, and
  refuses the key once the person is off the project (`resolve/2` is what the
  API plug calls; `Members.remove_member/3` also revokes their keys). A
  shared key has no person — its stored role is the authority. Either way
  the ledger names the key as the actor of the usage it reports, and the
  activity log names `ApiKey.accountable_uuid/1` (the person acted for, else
  the minter) with the key in the metadata. `revoke/2` ends a key;
  `rotate/2` replaces the secret on the same row so its history stays one
  agent. Every member may mint, rotate and revoke their own personal keys
  (`list_for_user/2`); the project's whole list is for whoever may
  `manage_modules`.

  `idempotent/3` is the retry guard for the API's appends: a response stored
  under (key, `Idempotency-Key`) is answered again on replay.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Activity, Authz}
  alias PhoenixKitProjects.Schemas.{ApiIdempotency, ApiKey}

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

  @doc "Every key of a project, newest first, revoked ones included."
  @spec list_for_project(binary()) :: [ApiKey.t()]
  def list_for_project(project_uuid) when is_binary(project_uuid) do
    RepoHelper.repo().all(
      from(k in ApiKey, where: k.project_uuid == ^project_uuid, order_by: [desc: k.inserted_at])
    )
  end

  @doc "The live (not revoked) keys acting for `user_uuid` on a project, newest first."
  @spec list_for_user(binary(), binary()) :: [ApiKey.t()]
  def list_for_user(project_uuid, user_uuid)
      when is_binary(project_uuid) and is_binary(user_uuid) do
    RepoHelper.repo().all(
      from(k in ApiKey,
        where:
          k.project_uuid == ^project_uuid and k.user_uuid == ^user_uuid and
            is_nil(k.revoked_at),
        order_by: [desc: k.inserted_at]
      )
    )
  end

  def list_for_user(_, _), do: []

  @doc """
  The role a key acts with on `project` right now. A shared key: its stored
  role. A personal key: the person's current membership (`Authz.effective_role/2`),
  capped by the stored role and by manager — `{:error, :membership_ended}`
  when they are no longer on the project.
  """
  @spec effective_role(ApiKey.t(), map()) :: {:ok, String.t()} | {:error, :membership_ended}
  def effective_role(%ApiKey{user_uuid: nil, role: role}, _project), do: {:ok, role}

  def effective_role(%ApiKey{user_uuid: user_uuid, role: cap}, project) do
    case Authz.effective_role(project, user_uuid) do
      nil -> {:error, :membership_ended}
      role -> {:ok, weaker(Atom.to_string(role), cap)}
    end
  end

  @doc """
  The key with its `role` set to `effective_role/2`, for one request. A
  personal key also needs its person's ACCOUNT to be live: a deactivated or
  deleted user's key is `{:error, :account_inactive}` (the API answers it
  with the one 401), whatever the project's "everyone" visibility would
  still hand an arbitrary uuid.
  """
  @spec resolve(ApiKey.t(), map()) ::
          {:ok, ApiKey.t()} | {:error, :membership_ended | :account_inactive}
  def resolve(%ApiKey{} = key, project) do
    with :ok <- account_live(key),
         {:ok, role} <- effective_role(key, project),
         do: {:ok, %{key | role: role}}
  end

  defp account_live(%ApiKey{user_uuid: nil}), do: :ok

  defp account_live(%ApiKey{user_uuid: user_uuid}) do
    case Auth.get_user(user_uuid) do
      %{is_active: true} -> :ok
      _ -> {:error, :account_inactive}
    end
  end

  # The weakest of the three: owner is not a key role, so the strongest a
  # key acts with is manager.
  defp weaker(role, cap) do
    Enum.max_by(["manager", cap, role], &Map.get(@role_rank, &1, 3))
  end

  @doc "Revokes every live key acting for `user_uuid` on the project — when they leave it."
  @spec revoke_for_user(binary(), binary(), keyword()) :: :ok
  def revoke_for_user(project_uuid, user_uuid, opts \\ []) do
    project_uuid
    |> list_for_user(user_uuid)
    |> Enum.each(&revoke(&1, Keyword.put(opts, :reason, "membership_ended")))

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

  @doc "A key by uuid that belongs to `project_uuid`, or nil."
  @spec get_for_project(binary(), binary()) :: ApiKey.t() | nil
  def get_for_project(project_uuid, uuid) when is_binary(project_uuid) and is_binary(uuid) do
    RepoHelper.repo().one(
      from(k in ApiKey, where: k.uuid == ^uuid and k.project_uuid == ^project_uuid)
    )
  end

  def get_for_project(_, _), do: nil

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

    case RepoHelper.repo().insert(changeset) do
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
