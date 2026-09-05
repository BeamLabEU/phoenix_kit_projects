defmodule PhoenixKitProjects.Schemas.Whiteboard do
  @moduledoc """
  One project whiteboard (`phoenix_kit_project_whiteboards`, chain V5,
  file-less since V16): a named drawing surface of `width` × `height`
  canvas pixels whose shapes are core annotation rows anchored to
  `PhoenixKitProjects.Whiteboards.target_type/0` + this row's uuid (core
  V183), drawn by `PhoenixKitWeb.Components.MediaCanvasViewer` in board
  mode. `file_uuid` is nil for such a board; it is set only on boards
  from before V16, which keep their background file and its file-anchored
  shapes (still unique — a board owned its background). `created_by_uuid`
  is FK-less provenance (house convention; activity is the audit trail).
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_project_whiteboards" do
    field(:project_uuid, UUIDv7)
    field(:file_uuid, UUIDv7)
    field(:name, :string)
    field(:width, :integer, default: 1920)
    field(:height, :integer, default: 1080)
    field(:position, :integer, default: 0)
    field(:created_by_uuid, UUIDv7)

    timestamps(type: :utc_datetime)
  end

  def changeset(board, attrs) do
    board
    |> cast(attrs, [
      :project_uuid,
      :file_uuid,
      :name,
      :width,
      :height,
      :position,
      :created_by_uuid
    ])
    |> validate_required([:project_uuid, :name])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 160)
    |> validate_number(:width, greater_than: 0, less_than_or_equal_to: 8000)
    |> validate_number(:height, greater_than: 0, less_than_or_equal_to: 8000)
    |> foreign_key_constraint(:project_uuid)
    |> foreign_key_constraint(:file_uuid)
    |> unique_constraint(:file_uuid,
      name: :phoenix_kit_project_whiteboards_file_index
    )
  end
end
