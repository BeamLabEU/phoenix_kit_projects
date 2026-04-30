defmodule PhoenixKitProjects.Schemas.Project do
  @moduledoc """
  A project container. Can start immediately (set up tasks first, then
  mark as started) or be scheduled for a future date.
  """

  use Ecto.Schema
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Changeset

  alias PhoenixKitProjects.Schemas.Assignment

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active archived)
  @start_modes ~w(immediate scheduled)

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          status: String.t() | nil,
          is_template: boolean() | nil,
          counts_weekends: boolean() | nil,
          start_mode: String.t() | nil,
          scheduled_start_date: Date.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          assignments: [Assignment.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_projects" do
    field(:name, :string)
    field(:description, :string)
    field(:status, :string, default: "active")
    field(:is_template, :boolean, default: false)
    field(:counts_weekends, :boolean, default: false)
    field(:start_mode, :string, default: "immediate")
    field(:scheduled_start_date, :date)
    field(:started_at, :utc_datetime)
    field(:completed_at, :utc_datetime)

    has_many(:assignments, Assignment, foreign_key: :project_uuid, on_delete: :delete_all)

    timestamps(type: :utc_datetime)
  end

  @required ~w(name status start_mode)a
  @optional ~w(description is_template counts_weekends scheduled_start_date started_at completed_at)a

  def changeset(project, attrs) do
    project
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:start_mode, @start_modes)
    |> maybe_require_date()
    |> unique_constraint(:name,
      name: name_index_for(project, attrs),
      message: gettext("already taken")
    )
  end

  # V105 split the single `phoenix_kit_projects_name_index` into two
  # partial indexes — one per `is_template` value — so a template
  # named "Onboarding" and a real project named "Onboarding" can
  # coexist. Pick the index whose `WHERE` clause matches the row we're
  # about to write so Ecto attaches the constraint error to the right
  # changeset field.
  defp name_index_for(project, attrs) do
    template? =
      case Map.get(attrs, :is_template, Map.get(attrs, "is_template")) do
        nil -> Map.get(project, :is_template, false)
        # Phoenix forms send `"true"`/`"false"`. Programmatic callers
        # may pass native booleans, the legacy HTML checkbox `"on"`,
        # or `1`/`"1"`. All canonicalised here so the constraint
        # error attaches to the right field regardless of caller shape.
        v -> v in [true, "true", "1", 1, "on"]
      end

    if template?,
      do: :phoenix_kit_projects_name_template_index,
      else: :phoenix_kit_projects_name_project_index
  end

  defp maybe_require_date(changeset) do
    if get_field(changeset, :start_mode) == "scheduled" do
      validate_required(changeset, [:scheduled_start_date],
        message: gettext("required for scheduled projects")
      )
    else
      changeset
    end
  end

  def statuses, do: @statuses
  def start_modes, do: @start_modes
end
