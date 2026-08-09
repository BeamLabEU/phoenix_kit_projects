defmodule PhoenixKitProjects.People.Department do
  @moduledoc """
  READ-ONLY shadow schema over the core-owned
  `phoenix_kit_staff_departments` table (core V100). See
  `PhoenixKitProjects.People.Person` for the seam's rules.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: false}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_staff_departments" do
    field(:name, :string)
    field(:translations, :map, default: %{})
  end
end
