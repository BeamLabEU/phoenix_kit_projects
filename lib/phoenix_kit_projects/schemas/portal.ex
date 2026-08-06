defmodule PhoenixKitProjects.Schemas.Portal do
  @moduledoc """
  One row per project with the portal extension enabled (chain V10): the
  random `slug` IS the public access grant (possession of the link), so
  it is generated from CSPRNG bytes and regenerable ("rotate link") to
  revoke. `settings` is reserved for future per-portal knobs.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKitProjects.Schemas.Project

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "phoenix_kit_project_portals" do
    field(:slug, :string)
    field(:settings, :map, default: %{})

    belongs_to(:project, Project, foreign_key: :project_uuid, references: :uuid)

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset — slug/project are server-generated, never user input."
  def changeset(portal, attrs) do
    portal
    |> cast(attrs, [:project_uuid, :slug, :settings])
    |> validate_required([:project_uuid, :slug])
    |> unique_constraint(:slug)
    |> unique_constraint(:project_uuid)
    |> foreign_key_constraint(:project_uuid)
  end

  @doc """
  A fresh access slug: 16 CSPRNG bytes, url-base64 (~22 chars) — the
  entropy floor from the portal security panel (find #9).
  """
  @spec generate_slug() :: String.t()
  def generate_slug do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
