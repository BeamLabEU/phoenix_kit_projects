defmodule PhoenixKitProjects.Schemas.Task do
  @moduledoc """
  Reusable task template with title, description, estimated duration,
  and optional default assignee.
  """

  use Ecto.Schema
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Changeset

  alias PhoenixKitStaff.Schemas.{Department, Person, Team}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @duration_units ~w(minutes hours days weeks fortnights months years)

  @hours_per_weekdays %{
    "minutes" => 1 / 60,
    "hours" => 1,
    "days" => 8,
    "weeks" => 40,
    "fortnights" => 80,
    "months" => 160,
    "years" => 1920
  }

  @hours_per_calendar %{
    "minutes" => 1 / 60,
    "hours" => 1,
    "days" => 24,
    "weeks" => 168,
    "fortnights" => 336,
    "months" => 720,
    "years" => 8760
  }

  @doc "Converts a duration to hours under a given calendar mode."
  def to_hours(nil, _, _), do: 0
  def to_hours(_, nil, _), do: 0

  def to_hours(n, unit, true = _counts_weekends),
    do: n * Map.get(@hours_per_calendar, unit, 1)

  def to_hours(n, unit, _counts_weekends),
    do: n * Map.get(@hours_per_weekdays, unit, 1)

  @typedoc """
  JSONB map of secondary-language overrides for translatable fields.
  Same shape as `Project.translations_map` — primary stays in the
  dedicated columns, this map only carries non-primary overrides.
  """
  @type translations_map :: %{optional(String.t()) => %{optional(String.t()) => String.t()}}

  # Cross-module assoc fields use `struct()` rather than the precise
  # `PhoenixKitStaff.Schemas.<X>.t()` because phoenix_kit_staff Hex
  # 0.1.0 doesn't ship `@type t` declarations on its schemas (the
  # workspace version does — once it publishes 0.1.1, tighten these
  # back to the named types).
  # Tracking: BeamLabEU/phoenix_kit_staff#3.
  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          estimated_duration: integer() | nil,
          estimated_duration_unit: String.t() | nil,
          translations: translations_map(),
          default_assigned_team_uuid: UUIDv7.t() | nil,
          default_assigned_team: struct() | Ecto.Association.NotLoaded.t() | nil,
          default_assigned_department_uuid: UUIDv7.t() | nil,
          default_assigned_department: struct() | Ecto.Association.NotLoaded.t() | nil,
          default_assigned_person_uuid: UUIDv7.t() | nil,
          default_assigned_person: struct() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @translatable_fields ~w(title description)

  schema "phoenix_kit_project_tasks" do
    field(:title, :string)
    field(:description, :string)
    field(:estimated_duration, :integer)
    field(:estimated_duration_unit, :string, default: "hours")
    field(:translations, :map, default: %{})

    belongs_to(:default_assigned_team, Team,
      foreign_key: :default_assigned_team_uuid,
      references: :uuid
    )

    belongs_to(:default_assigned_department, Department,
      foreign_key: :default_assigned_department_uuid,
      references: :uuid
    )

    belongs_to(:default_assigned_person, Person,
      foreign_key: :default_assigned_person_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @required ~w(title)a
  @optional ~w(description estimated_duration estimated_duration_unit translations
               default_assigned_team_uuid default_assigned_department_uuid
               default_assigned_person_uuid)a

  def changeset(task, attrs) do
    task
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:title, min: 1, max: 255)
    |> validate_number(:estimated_duration, greater_than: 0)
    |> validate_inclusion(:estimated_duration_unit, @duration_units)
    |> validate_single_default_assignee()
    |> check_constraint(:default_assigned_team_uuid,
      name: :phoenix_kit_project_tasks_single_default_assignee,
      message: gettext("only one default assignee (team, department, or person) allowed")
    )
  end

  # Mirrors the DB-level CHECK constraint on the default-assignee triple
  # so changesets fail fast with a friendly message.
  defp validate_single_default_assignee(changeset) do
    set =
      Enum.count(
        [
          :default_assigned_team_uuid,
          :default_assigned_department_uuid,
          :default_assigned_person_uuid
        ],
        &(get_field(changeset, &1) != nil)
      )

    if set > 1 do
      add_error(
        changeset,
        :default_assigned_team_uuid,
        gettext("only one default assignee (team, department, or person) allowed")
      )
    else
      changeset
    end
  end

  def duration_units, do: @duration_units

  @doc "DB-column field names that participate in the `translations` JSONB."
  @spec translatable_fields() :: [String.t()]
  def translatable_fields, do: @translatable_fields

  @doc """
  Returns the task's title in the requested language, falling back to
  the primary `title` column when the language has no override (or the
  override is empty/nil).
  """
  @spec localized_title(t(), String.t() | nil) :: String.t() | nil
  def localized_title(%__MODULE__{} = t, lang), do: localized_field(t, "title", lang)

  @doc "Same fallback semantics as `localized_title/2` — for `description`."
  @spec localized_description(t(), String.t() | nil) :: String.t() | nil
  def localized_description(%__MODULE__{} = t, lang), do: localized_field(t, "description", lang)

  defp localized_field(t, field, lang) do
    primary = Map.get(t, String.to_existing_atom(field))

    case lookup_translation(t.translations, lang, field) do
      nil -> primary
      "" -> primary
      val -> val
    end
  end

  defp lookup_translation(translations, lang, field)
       when is_map(translations) and is_binary(lang) do
    case Map.get(translations, lang) do
      %{} = lang_map -> Map.get(lang_map, field)
      _ -> nil
    end
  end

  defp lookup_translation(_translations, _lang, _field), do: nil

  def format_duration(nil, _), do: "—"
  def format_duration(_, nil), do: "—"

  def format_duration(n, unit) when is_integer(n) do
    case unit do
      "minutes" -> ngettext("%{count} min", "%{count} mins", n)
      "hours" -> ngettext("%{count} hr", "%{count} hrs", n)
      "days" -> ngettext("%{count} d", "%{count} ds", n)
      "weeks" -> ngettext("%{count} wk", "%{count} wks", n)
      "fortnights" -> ngettext("%{count} fortnight", "%{count} fortnights", n)
      "months" -> ngettext("%{count} mo", "%{count} mos", n)
      "years" -> ngettext("%{count} yr", "%{count} yrs", n)
      _other -> "#{n} #{unit}"
    end
  end
end
