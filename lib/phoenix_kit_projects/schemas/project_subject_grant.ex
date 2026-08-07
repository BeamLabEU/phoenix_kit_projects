defmodule PhoenixKitProjects.Schemas.ProjectSubjectGrant do
  @moduledoc """
  A project role held by a GROUP rather than a person: a staff team, a
  staff department, or a site role.

  Direct people stay in `PhoenixKitProjects.Schemas.ProjectMember` — that
  table keeps its real foreign key to `phoenix_kit_users`, the last-owner
  guard, and ownership succession. This one answers the other half: "the
  Design team can work here", "contractors may look".

  `subject_uuid` carries no foreign key on purpose. It points into three
  different tables, two of which (staff teams and departments) live in a
  sibling package that may not be installed at all. Integrity is the
  context's job: `PhoenixKitProjects.Grants` resolves a subject before
  writing, and skips grants whose subject has since vanished when reading.

  `owner` is not an assignable role here — ownership needs an accountable
  person, and a team-owned project would break the last-owner guard the
  moment the team emptied. The database rejects it too.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKitProjects.Schemas.Project

  @subject_types ~w(team department role)
  @roles ~w(manager member viewer)

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_project_subject_grants" do
    field(:subject_type, :string)
    field(:subject_uuid, UUIDv7)
    field(:role, :string, default: "viewer")
    field(:granted_by_uuid, UUIDv7)

    belongs_to(:project, Project, foreign_key: :project_uuid, references: :uuid)

    timestamps(type: :utc_datetime)
  end

  @doc "Assignable subject types."
  @spec subject_types() :: [String.t()]
  def subject_types, do: @subject_types

  @doc "Assignable roles — never `owner`."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:project_uuid, :subject_type, :subject_uuid, :role, :granted_by_uuid])
    |> validate_required([:project_uuid, :subject_type, :subject_uuid, :role])
    |> validate_inclusion(:subject_type, @subject_types)
    |> validate_inclusion(:role, @roles,
      message: "must be manager, member, or viewer — groups cannot own a project"
    )
    |> unique_constraint([:project_uuid, :subject_type, :subject_uuid],
      name: :phoenix_kit_project_subject_grants_identity_index,
      message: "this group already has access to the project"
    )
    |> foreign_key_constraint(:project_uuid)
  end
end
