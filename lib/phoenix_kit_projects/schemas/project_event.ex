defmodule PhoenixKitProjects.Schemas.ProjectEvent do
  @moduledoc """
  One project event (`phoenix_kit_project_events`, chain V6): a dated
  happening that isn't a task — meeting, milestone, review. Stored UTC;
  `all_day` events ignore the time-of-day component and render as month
  bars, timed events as chips with a time prefix. `created_by_uuid` is
  FK-less provenance (house convention).
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{}

  schema "phoenix_kit_project_events" do
    field(:project_uuid, UUIDv7)
    field(:title, :string)
    field(:description, :string)
    field(:starts_at, :utc_datetime)
    field(:ends_at, :utc_datetime)
    field(:all_day, :boolean, default: true)
    field(:location, :string)
    field(:created_by_uuid, UUIDv7)

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :project_uuid,
      :title,
      :description,
      :starts_at,
      :ends_at,
      :all_day,
      :location,
      :created_by_uuid
    ])
    |> validate_required([:project_uuid, :title, :starts_at])
    |> update_change(:title, &String.trim/1)
    |> validate_length(:title, min: 1, max: 200)
    |> validate_length(:location, max: 200)
    |> validate_range()
    |> foreign_key_constraint(:project_uuid)
    |> check_constraint(:ends_at, name: :phoenix_kit_project_events_range_check)
  end

  defp validate_range(changeset) do
    starts_at = get_field(changeset, :starts_at)
    ends_at = get_field(changeset, :ends_at)

    if starts_at && ends_at && DateTime.compare(ends_at, starts_at) == :lt do
      add_error(changeset, :ends_at, "must not be before the start")
    else
      changeset
    end
  end
end
