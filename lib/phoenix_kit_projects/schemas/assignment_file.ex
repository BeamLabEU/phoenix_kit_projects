defmodule PhoenixKitProjects.Schemas.AssignmentFile do
  @moduledoc """
  A file a task holds (chain V27): the core Storage file, and whether it is
  an image placed in the task's description (`inline`) or a file of the
  task. Written by `PhoenixKitProjects.Attachments` only.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_project_assignment_files" do
    field(:assignment_uuid, UUIDv7)
    field(:file_uuid, UUIDv7)
    field(:inline, :boolean, default: false)
    field(:added_by_uuid, UUIDv7)
    field(:inserted_at, :utc_datetime, read_after_writes: true)
  end
end
