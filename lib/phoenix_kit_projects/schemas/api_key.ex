defmodule PhoenixKitProjects.Schemas.ApiKey do
  @moduledoc """
  A project API key (`phoenix_kit_project_api_keys`, chain V17): the credential
  an outside agent presents to drive this project over the JSON API
  (`PhoenixKitProjects.Web.Api`).

  A key is its own principal in the project — it holds a `role` of its own
  (never owner) and a set of `scopes`, and it is what the work ledger names
  as the actor of the usage it reports. `created_by_uuid` is provenance: the
  person who minted it, who the activity log names as accountable for what
  the key does. Removing that person does not stop the key; revoking does.

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
    |> cast(attrs, [:project_uuid, :name, :role, :scopes, :created_by_uuid, :expires_at])
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
