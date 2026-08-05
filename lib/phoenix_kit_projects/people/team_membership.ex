defmodule PhoenixKitProjects.People.TeamMembership do
  @moduledoc """
  READ-ONLY shadow schema over the core-owned
  `phoenix_kit_staff_team_memberships` table (core V100). See
  `PhoenixKitProjects.People.Person` for the seam's rules.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  alias PhoenixKitProjects.People.Person
  alias PhoenixKitProjects.People.Team

  @primary_key {:uuid, UUIDv7, autogenerate: false}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_staff_team_memberships" do
    belongs_to(:team, Team, foreign_key: :team_uuid, references: :uuid, define_field: true)

    belongs_to(:person, Person,
      foreign_key: :staff_person_uuid,
      references: :uuid,
      define_field: true
    )
  end
end
