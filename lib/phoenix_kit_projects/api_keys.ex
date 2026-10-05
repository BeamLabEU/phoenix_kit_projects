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

  The key is its own principal: `Authz.can_role?/3` answers what it may do
  from its stored role, the ledger names it as the actor of the usage it
  reports, and the activity log names the person who minted it
  (`created_by_uuid`) as accountable, with the key in the metadata. A key
  does not depend on that person's membership — revoking is how it ends
  (`revoke/2`); `rotate/2` replaces the secret on the same row so the key's
  history stays one agent.

  `idempotent/3` is the retry guard for the API's appends: a response stored
  under (key, `Idempotency-Key`) is answered again on replay.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.Schemas.{ApiIdempotency, ApiKey}

  @token_prefix "pkp"
  @key_id_bytes 9
  @secret_bytes 32
  # `last_used_at` moves at most this often, so a busy agent is not a write
  # on the key row per request.
  @touch_interval_seconds 60

  @type token :: String.t()

  @doc "Every key of a project, newest first, revoked ones included."
  @spec list_for_project(binary()) :: [ApiKey.t()]
  def list_for_project(project_uuid) when is_binary(project_uuid) do
    RepoHelper.repo().all(
      from(k in ApiKey, where: k.project_uuid == ^project_uuid, order_by: [desc: k.inserted_at])
    )
  end

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
  `"member"`), `"scopes"` (default every scope), `"expires_at"`. Options:
  `:actor_uuid` — the person minting it, recorded as `created_by_uuid` and
  as the activity's actor.

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
          metadata: %{"api_key" => key.uuid, "name" => key.name, "role" => key.role}
        )

        {:ok, key, token}

      {:error, _} = error ->
        error
    end
  end

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
          metadata: %{"api_key" => key.uuid, "name" => key.name}
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
  """
  @spec idempotent(ApiKey.t(), String.t() | nil, (-> {integer(), map()})) ::
          {:ok, integer(), map()} | {:replay, integer(), map()}
  def idempotent(%ApiKey{}, nil, fun), do: wrap(fun.())

  def idempotent(%ApiKey{uuid: key_uuid}, idempotency_key, fun)
      when is_binary(idempotency_key) do
    case RepoHelper.repo().get_by(ApiIdempotency,
           api_key_uuid: key_uuid,
           idempotency_key: idempotency_key
         ) do
      %ApiIdempotency{status: status, body: body} ->
        {:replay, status, body}

      nil ->
        {status, body} = fun.()

        if status < 500 do
          %ApiIdempotency{}
          |> ApiIdempotency.changeset(%{
            api_key_uuid: key_uuid,
            idempotency_key: idempotency_key,
            status: status,
            body: body
          })
          |> RepoHelper.repo().insert(on_conflict: :nothing)
        end

        {:ok, status, body}
    end
  rescue
    e ->
      Logger.warning("[Projects.ApiKeys] idempotency store failed: #{Exception.message(e)}")
      wrap(fun.())
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
