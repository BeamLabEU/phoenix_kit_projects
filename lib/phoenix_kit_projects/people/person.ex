defmodule PhoenixKitProjects.People.Person do
  @moduledoc """
  READ-ONLY shadow schema over the core-owned `phoenix_kit_staff_people`
  table (created by core migration V100 — present on every install,
  whether or not the `phoenix_kit_staff` package is). Part of the
  staff-optional seam (see `PhoenixKitProjects.People`): projects' own
  bounded read model of a person, mapping ONLY the columns this module
  reads. No changesets — people are managed by the staff module's admin;
  projects never writes these rows.

  Struct identity: this is `%PhoenixKitProjects.People.Person{}`, never
  interchangeable with `%PhoenixKitStaff.Schemas.Person{}` — do not pass
  it into staff functions.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitProjects.People.Department

  @primary_key {:uuid, UUIDv7, autogenerate: false}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_staff_people" do
    field(:name, :string)
    field(:status, :string)

    belongs_to(:user, User, foreign_key: :user_uuid, references: :uuid, define_field: true)

    belongs_to(:primary_department, Department,
      foreign_key: :primary_department_uuid,
      references: :uuid,
      define_field: true
    )
  end
end
