defmodule PhoenixKitProjects.Schemas.ApiKeyGrant do
  @moduledoc """
  What one API key may do in one project (chain V24): its scopes there (per
  area, `PhoenixKitProjects.ApiAccess`), its role cap there, and whether it
  covers the project's sub-projects (`inherit`). An empty scope list is
  "no access": it stops a parent project's grant at this project.

  The nearest grant up a project's tree decides (`ApiKeys.access_for/2`).
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  use Gettext, backend: PhoenixKitProjects.Gettext
  import Ecto.Changeset

  alias PhoenixKitProjects.Schemas.ApiKey

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_project_api_key_grants" do
    field(:api_key_uuid, UUIDv7)
    field(:project_uuid, UUIDv7)
    field(:scopes, {:array, :string}, default: [])
    field(:role, :string, default: "member")
    field(:inherit, :boolean, default: true)

    timestamps(type: :utc_datetime)
  end

  @doc "A grant's project, scopes, role cap and inheritance; the key is set by `ApiKeys`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:api_key_uuid, :project_uuid, :scopes, :role, :inherit])
    |> validate_required([:api_key_uuid, :project_uuid, :role])
    |> validate_inclusion(:role, ApiKey.roles())
    |> validate_change(:scopes, fn :scopes, scopes ->
      known = ApiKey.scopes()

      case Enum.reject(scopes, &(&1 in known)) do
        [] -> []
        unknown -> [scopes: "unknown: #{Enum.join(unknown, ", ")}"]
      end
    end)
    |> unique_constraint([:api_key_uuid, :project_uuid],
      name: :phoenix_kit_project_api_key_grants_key_project_index,
      message: gettext("this key already has access set for that project")
    )
    |> foreign_key_constraint(:project_uuid)
  end
end
