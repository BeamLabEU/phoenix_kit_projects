defmodule PhoenixKitProjects.Schemas.Dependency do
  @moduledoc """
  A dependency link: `assignment_uuid` cannot start until `depends_on_uuid`
  is done. Both must be in the same project (enforced at the context layer).
  """

  use Ecto.Schema
  use Gettext, backend: PhoenixKitProjects.Gettext

  import Ecto.Changeset

  alias PhoenixKitProjects.Schemas.Assignment

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          assignment_uuid: UUIDv7.t() | nil,
          assignment: Assignment.t() | Ecto.Association.NotLoaded.t() | nil,
          depends_on_uuid: UUIDv7.t() | nil,
          depends_on: Assignment.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "phoenix_kit_project_dependencies" do
    belongs_to(:assignment, Assignment, foreign_key: :assignment_uuid, references: :uuid)
    belongs_to(:depends_on, Assignment, foreign_key: :depends_on_uuid, references: :uuid)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required ~w(assignment_uuid depends_on_uuid)a

  def changeset(dep, attrs) do
    dep
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> assoc_constraint(:assignment)
    |> assoc_constraint(:depends_on)
    |> unique_constraint([:assignment_uuid, :depends_on_uuid],
      name: :phoenix_kit_project_dependencies_pair_index,
      message: gettext("dependency already exists")
    )
    |> validate_not_self_referencing()
  end

  defp validate_not_self_referencing(changeset) do
    a = get_field(changeset, :assignment_uuid)
    b = get_field(changeset, :depends_on_uuid)

    if a && b && a == b do
      add_error(changeset, :depends_on_uuid, gettext("cannot depend on itself"))
    else
      changeset
    end
  end
end
