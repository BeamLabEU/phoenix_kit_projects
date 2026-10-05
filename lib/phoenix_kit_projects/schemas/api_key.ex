defmodule PhoenixKitProjects.Schemas.ApiKey do
  @moduledoc """
  A project API key (`phoenix_kit_project_api_keys`, chain V17): the credential
  an outside agent presents to drive this project over the JSON API
  (`PhoenixKitProjects.Web.Api`).

  A key is one of two kinds (`kind/1`):

    * **personal** — `user_uuid` names the member the key acts for. What it
      may do is that person's CURRENT membership role, capped by the key's
      stored `role` and never above manager (`ApiKeys.effective_role/2`);
      the activity feed names the person, with the key in the metadata.
      When the person leaves the project the key stops working.
    * **shared** — no person: a project-wide agent (a CI runner). Its stored
      `role` is the authority, never owner, and `created_by_uuid` — the
      person who minted it — is who the feed names as accountable.

  Either way the work ledger names the KEY as the actor of the time and
  usage it reports (`actor_kind: "ai_agent"`). `created_by_uuid` and
  `user_uuid` are provenance, not foreign keys: the row is audit history
  once the person is gone. Revoking is what ends a key.

  The token the agent holds is `pkp_<key_id>_<secret>`: `key_id` is public
  (indexed, shown in the key list) and finds the row; only the secret is
  compared, against its SHA-256. The secret is shown once, at creation and
  at rotation, and never stored.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  # Strongest first, like `Authz.roles/0` minus owner: role management and
  # deleting the project stay with a person.
  @roles ~w(manager member viewer)

  # What a key may do, on top of what its role allows. Default: all of them.
  # `usage:write` alone is the metering-only key an agent runner wants.
  @scopes ~w(tasks:read tasks:write time:write usage:write project:write)

  schema "phoenix_kit_project_api_keys" do
    field(:project_uuid, UUIDv7)
    field(:name, :string)
    field(:role, :string, default: "member")
    field(:key_id, :string)
    field(:secret_hash, :string)
    field(:scopes, {:array, :string}, default: @scopes)
    field(:created_by_uuid, UUIDv7)
    field(:user_uuid, UUIDv7)
    field(:last_used_at, :utc_datetime)
    field(:expires_at, :utc_datetime)
    field(:revoked_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @doc "The roles a key may hold, strongest first."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc "Every scope a key may carry."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes ++ provider_scopes()

  # The scopes extension API providers declare (`interactions:read` …),
  # offered on the key panel and accepted by the changeset. Read at call
  # time: the catalog is discovered at runtime.
  defp provider_scopes do
    PhoenixKitProjects.Extensions.api_providers()
    |> Enum.flat_map(fn %{module: mod} ->
      case mod.scopes() do
        %{read: r, write: w} -> [r, w]
        _ -> []
      end
    end)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  @doc "Creation: name, role, scopes and the owning project; the credential fields are server-set."
  def create_changeset(key, attrs) do
    key
    |> cast(attrs, [
      :project_uuid,
      :name,
      :role,
      :scopes,
      :created_by_uuid,
      :user_uuid,
      :expires_at
    ])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:project_uuid, :name, :role, :key_id, :secret_hash])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_inclusion(:role, @roles)
    |> validate_scopes()
    |> unique_constraint(:key_id, name: :phoenix_kit_project_api_keys_key_id_index)
  end

  @doc "The credential fields, set by `ApiKeys` when minting or rotating."
  def credential_changeset(key, key_id, secret_hash) do
    key
    |> change(key_id: key_id, secret_hash: secret_hash)
    |> validate_required([:key_id, :secret_hash])
  end

  defp validate_scopes(changeset) do
    validate_change(changeset, :scopes, fn :scopes, scopes ->
      known = scopes()

      case {scopes, Enum.reject(scopes, &(&1 in known))} do
        {[], _} -> [scopes: "must name at least one scope"]
        {_, []} -> []
        {_, unknown} -> [scopes: "unknown: #{Enum.join(unknown, ", ")}"]
      end
    end)
  end

  @doc "`:personal` when the key acts for a person, else `:shared`."
  @spec kind(t()) :: :personal | :shared
  def kind(%__MODULE__{user_uuid: uuid}) when is_binary(uuid), do: :personal
  def kind(%__MODULE__{}), do: :shared

  @doc """
  The person the activity feed names for what the key does: the one it
  acts for, else the one who minted it; nil for a shared key minted by a
  script with nobody behind it.
  """
  @spec accountable_uuid(t()) :: String.t() | nil
  def accountable_uuid(%__MODULE__{user_uuid: uuid}) when is_binary(uuid), do: uuid
  def accountable_uuid(%__MODULE__{created_by_uuid: uuid}), do: uuid

  @doc "Whether the key may be used now: not revoked, not past its expiry."
  @spec active?(t(), DateTime.t()) :: boolean()
  def active?(%__MODULE__{revoked_at: nil, expires_at: nil}, _now), do: true
  def active?(%__MODULE__{revoked_at: %DateTime{}}, _now), do: false

  def active?(%__MODULE__{expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  @doc "Whether the key carries `scope`."
  @spec scope?(t(), String.t()) :: boolean()
  def scope?(%__MODULE__{scopes: scopes}, scope), do: scope in (scopes || [])
end
