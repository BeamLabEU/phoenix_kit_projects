defmodule PhoenixKitProjects.People.Team do
  @moduledoc """
  READ-ONLY shadow schema over the core-owned `phoenix_kit_staff_teams`
  table (core V100). See `PhoenixKitProjects.People.Person` for the
  seam's rules: minimal columns, no changesets, local struct identity.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  alias PhoenixKitProjects.People.Department

  @primary_key {:uuid, UUIDv7, autogenerate: false}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_staff_teams" do
    field(:name, :string)
    field(:translations, :map, default: %{})

    belongs_to(:department, Department,
      foreign_key: :department_uuid,
      references: :uuid,
      define_field: true
    )
  end
end
