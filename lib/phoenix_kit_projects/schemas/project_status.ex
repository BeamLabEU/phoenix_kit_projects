defmodule PhoenixKitProjects.Schemas.ProjectStatus do
  @moduledoc """
  A project's **cemented** workflow status — a local snapshot of a catalog
  status row, copied from the `phoenix_kit_entities` vocabulary when the
  project starts.

  Once cemented, a project's statuses live here and are edited
  independently of the catalog entity (mirrors the way an `Assignment`
  copies its `Task` template's fields at creation, then diverges). The
  `current_status_slug` column on `phoenix_kit_projects` selects one of
  these rows by `slug`.

  `source_entity_data_uuid` is provenance only (which catalog row this was
  copied from) — intentionally not a foreign key, since the catalog lives
  in the optional `phoenix_kit_entities` package and the snapshot must
  outlive its source.

  Table created by core migration V125.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKitProjects.Schemas.Project

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          project_uuid: UUIDv7.t() | nil,
          label: String.t() | nil,
          slug: String.t() | nil,
          position: integer() | nil,
          data: map(),
          translations: map(),
          source_entity_data_uuid: UUIDv7.t() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_project_statuses" do
    field(:label, :string)
    field(:slug, :string)
    field(:position, :integer, default: 0)
    # `data` holds per-status attributes (e.g. %{"color" => "#34d399"}) —
    # JSONB so colour + future fields ride along without a migration.
    # `translations` holds secondary-language label overrides in the
    # workspace shape %{"es-ES" => %{"label" => "…"}} (empty for now).
    field(:data, :map, default: %{})
    field(:translations, :map, default: %{})
    field(:source_entity_data_uuid, UUIDv7)

    belongs_to(:project, Project, foreign_key: :project_uuid, references: :uuid)

    timestamps(type: :utc_datetime)
  end

  @required ~w(project_uuid label)a
  @optional ~w(slug position data translations source_entity_data_uuid)a

  @doc """
  Changeset for a cemented status row. Requires `project_uuid` + `label`;
  derives a URL-safe `slug` from the label when one isn't supplied; and
  enforces slug uniqueness within the project (the
  `(project_uuid, slug)` unique index from V125).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(status, attrs) do
    status
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:label, min: 1, max: 255)
    |> maybe_derive_slug()
    |> validate_length(:slug, min: 1, max: 255)
    |> unique_constraint([:project_uuid, :slug],
      name: :phoenix_kit_project_statuses_project_slug_index
    )
  end

  defp maybe_derive_slug(changeset) do
    case get_field(changeset, :slug) do
      slug when is_binary(slug) and slug != "" ->
        put_change(changeset, :slug, slugify(slug))

      _ ->
        case get_field(changeset, :label) do
          label when is_binary(label) and label != "" ->
            put_change(changeset, :slug, slugify(label))

          _ ->
            changeset
        end
    end
  end

  @doc """
  Lower-cases and hyphenates an arbitrary string into a stable slug
  (`[a-z0-9]` runs joined by single hyphens, no leading/trailing hyphen).
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  @doc "Colour for this status, read from the `data` JSONB (`nil` if unset)."
  @spec color(t()) :: String.t() | nil
  def color(%__MODULE__{data: data}) when is_map(data), do: Map.get(data, "color")
  def color(_), do: nil

  @doc """
  Label in the requested language, falling back to the primary `label`
  column when the language has no override (or the override is empty).
  `lang` may be `nil` (multilang disabled) → the primary label.
  Future-proofs status-label i18n; `translations` is empty until wired.
  """
  @spec localized_label(t(), String.t() | nil) :: String.t() | nil
  def localized_label(%__MODULE__{translations: t, label: label}, lang)
      when is_map(t) and is_binary(lang) do
    case t do
      %{^lang => %{"label" => override}} when is_binary(override) and override != "" -> override
      _ -> label
    end
  end

  def localized_label(%__MODULE__{label: label}, _lang), do: label
end
