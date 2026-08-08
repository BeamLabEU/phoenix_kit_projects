defmodule PhoenixKitProjects.Schemas.Portal do
  @moduledoc """
  One row per project with the portal extension enabled (chain V10).

  ## Access mode (V12)

  `access_mode` answers who may resolve the page at all, and it is one enum
  rather than a pair of booleans because the quadrants aren't orthogonal —
  "secret slug that search engines index" and "human-readable slug where
  possession is the authorization" are both nonsense, and booleans let an
  admin build them.

    * `link` (default, and what every portal was before this existed) — the
      slug IS the grant: 16 CSPRNG bytes, possession is authorization,
      rotatable to revoke, never indexed.
    * `members` — any signed-in site user. The slug keeps its CSPRNG shape
      because unguessability is free and there is nothing to gain by
      throwing it away; it is simply no longer the thing being checked.
    * `public` — anyone, indexable, human-chosen slug.

  ## Participation

  `submit_access` and `comment_access` are separate because the risks are
  different in kind: a submission is invisible until staff act on it, while
  a comment is live surface area the moment it lands. Collapsing them into
  one control forces a choice between "anonymous comments go live" and
  "anonymous submission is as gated as commenting", and both are wrong.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKitProjects.Schemas.Project

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @access_modes ~w(link members public)
  @participation ~w(anyone members nobody)

  schema "phoenix_kit_project_portals" do
    field(:slug, :string)
    field(:access_mode, :string, default: "link")
    field(:submit_access, :string, default: "anyone")
    field(:comment_access, :string, default: "nobody")
    field(:settings, :map, default: %{})

    belongs_to(:project, Project, foreign_key: :project_uuid, references: :uuid)

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset — slug/project are server-generated, never user input."
  def changeset(portal, attrs) do
    portal
    |> cast(attrs, [
      :project_uuid,
      :slug,
      :access_mode,
      :submit_access,
      :comment_access,
      :settings
    ])
    |> validate_required([:project_uuid, :slug])
    |> validate_inclusion(:access_mode, @access_modes)
    |> validate_inclusion(:submit_access, @participation)
    |> validate_inclusion(:comment_access, @participation)
    |> validate_slug_shape()
    |> unique_constraint(:slug)
    |> unique_constraint(:project_uuid)
    |> foreign_key_constraint(:project_uuid)
  end

  # A public slug is a NAME — it goes in links people type and read, so it
  # gets the shape a name needs. A capability slug is a secret and is
  # generated, never typed, so it only has to be long enough.
  defp validate_slug_shape(changeset) do
    case get_field(changeset, :access_mode) do
      "public" ->
        changeset
        |> validate_length(:slug, min: 3, max: 64)
        |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
          message: "must be lowercase letters, numbers and single hyphens"
        )
        |> validate_exclusion(:slug, reserved_slugs(), message: "is reserved")

      _ ->
        validate_length(changeset, :slug, min: 16, max: 64)
    end
  end

  @doc """
  Slugs a public board may not take, because they collide with paths a
  host is likely to mount beside it or with things a reader would misread
  as system pages.
  """
  @spec reserved_slugs() :: [String.t()]
  def reserved_slugs do
    ~w(admin api new edit login logout signin signup portal assets static
       images uploads health status robots sitemap favicon well-known
       users settings dashboard)
  end

  @doc "The three access modes, most restrictive first."
  @spec access_modes() :: [String.t()]
  def access_modes, do: @access_modes

  @doc "The participation values a write policy may take."
  @spec participation_levels() :: [String.t()]
  def participation_levels, do: @participation

  @doc """
  A fresh access slug: 16 CSPRNG bytes, url-base64 (~22 chars) — the
  entropy floor from the portal security panel (find #9).
  """
  @spec generate_slug() :: String.t()
  def generate_slug do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc """
  A starting public slug derived from a project name — a suggestion for
  the admin to accept or edit, never applied silently.
  """
  @spec suggest_public_slug(String.t() | nil) :: String.t()
  def suggest_public_slug(name) do
    base =
      name
      |> Kernel.to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 48)

    if base in ["" | reserved_slugs()], do: "board-#{:rand.uniform(9999)}", else: base
  end
end
