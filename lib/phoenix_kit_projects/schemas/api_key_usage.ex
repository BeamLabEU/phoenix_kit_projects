defmodule PhoenixKitProjects.Schemas.ApiKeyUsage do
  @moduledoc """
  One API key's requests in one project on one UTC day (chain V25): how
  many, how many failed, how many of those were refused. A counter bumped
  by `PhoenixKitProjects.ApiUsage.record/3`, read by the API keys page.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key false
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_project_api_key_usage" do
    field(:api_key_uuid, UUIDv7, primary_key: true)
    field(:project_uuid, UUIDv7, primary_key: true)
    field(:day, :date, primary_key: true)
    field(:requests, :integer, default: 0)
    field(:errors, :integer, default: 0)
    field(:denied, :integer, default: 0)
  end
end
