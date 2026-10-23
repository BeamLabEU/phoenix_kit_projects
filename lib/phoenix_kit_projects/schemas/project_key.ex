defmodule PhoenixKitProjects.Schemas.ProjectKey do
  @moduledoc """
  Read-only registry of every key a project has held (chain V22).

  Database triggers own these rows. A deleted project leaves its key
  reserved with a nil `project_uuid`. Using a schema keeps registry reads
  on the same configured PostgreSQL prefix as the projects themselves.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:key, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "phoenix_kit_project_keys" do
    field(:project_uuid, UUIDv7)
    field(:inserted_at, :utc_datetime_usec)
  end
end
