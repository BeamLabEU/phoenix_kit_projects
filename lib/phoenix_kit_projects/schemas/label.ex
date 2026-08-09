defmodule PhoenixKitProjects.Schemas.Label do
  @moduledoc """
  A per-project label (`phoenix_kit_project_labels`, chain V7): a named,
  colored tag assignments wear via the `phoenix_kit_project_assignment_labels`
  join table (join rows cascade with either side). Names are unique per
  project; `color` is a daisyUI badge class from the closed palette.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  @colors ~w(badge-neutral badge-primary badge-secondary badge-accent badge-info badge-success badge-warning badge-error)

  schema "phoenix_kit_project_labels" do
    field(:project_uuid, UUIDv7)
    field(:name, :string)
    field(:color, :string, default: "badge-neutral")
    field(:position, :integer, default: 0)

    timestamps(type: :utc_datetime)
  end

  def changeset(label, attrs) do
    label
    |> cast(attrs, [:project_uuid, :name, :color, :position])
    |> validate_required([:project_uuid, :name])
    |> update_change(:name, &trim/1)
    |> validate_length(:name, min: 1, max: 60)
    |> validate_inclusion(:color, @colors)
    |> foreign_key_constraint(:project_uuid)
    |> unique_constraint([:project_uuid, :name],
      name: :phoenix_kit_project_labels_name_index,
      message: "already exists in this project"
    )
  end

  defp trim(v) when is_binary(v), do: String.trim(v)
  defp trim(v), do: v

  def colors, do: @colors
end
