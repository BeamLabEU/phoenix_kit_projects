defmodule PhoenixKitProjects.Schemas.Project do
  @moduledoc """
  A project container. Can start immediately (set up tasks first, then
  mark as started) or be scheduled for a future date.

  ## Soft-hide / archive

  `archived_at` is the soft-hide flag — null = visible, non-null =
  archived. Mirrors the workspace's `trashed_at` convention used by
  publishing posts and core files.

  The legacy `status` string column (V86 / V94) is **kept in the table
  but no longer read or written** by application code. See
  `phoenix_kit_projects/AGENTS.md` for the deprecation note.
  """

  use Ecto.Schema
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Changeset

  alias PhoenixKitProjects.Schemas.Assignment

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @start_modes ~w(immediate scheduled)

  @typedoc """
  JSONB map of secondary-language overrides for translatable fields.

  Shape: `%{"es-ES" => %{"name" => "...", "description" => "..."}}`.
  Primary-language values live in the dedicated `name`/`description`
  columns; this map only carries overrides for non-primary languages.
  Missing/empty overrides fall back to the primary value at render time.
  """
  @type translations_map :: %{optional(String.t()) => %{optional(String.t()) => String.t()}}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          is_template: boolean() | nil,
          counts_weekends: boolean() | nil,
          start_mode: String.t() | nil,
          scheduled_start_date: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          archived_at: DateTime.t() | nil,
          position: integer() | nil,
          translations: translations_map(),
          assignments: [Assignment.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @translatable_fields ~w(name description)

  schema "phoenix_kit_projects" do
    field(:name, :string)
    field(:description, :string)
    field(:is_template, :boolean, default: false)
    field(:counts_weekends, :boolean, default: false)
    field(:start_mode, :string, default: "immediate")
    # Promoted from `:date` to `:utc_datetime` in V112 so the form +
    # start-modal can carry hour-and-minute precision. Column name kept
    # `scheduled_start_date` to avoid a churn pass through every call
    # site; treat the trailing "_date" as historical baggage.
    field(:scheduled_start_date, :utc_datetime)
    field(:started_at, :utc_datetime)
    field(:completed_at, :utc_datetime)
    field(:archived_at, :utc_datetime)
    field(:position, :integer, default: 0)
    field(:translations, :map, default: %{})

    has_many(:assignments, Assignment, foreign_key: :project_uuid, on_delete: :delete_all)

    timestamps(type: :utc_datetime)
  end

  @required ~w(name start_mode)a
  @optional ~w(description is_template counts_weekends scheduled_start_date started_at completed_at archived_at position translations)a

  def changeset(project, attrs, opts \\ []) do
    project
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:start_mode, @start_modes)
    |> maybe_require_date(opts)
  end

  # `enforce_scheduled_date_required: false` lets the form's `phx-change`
  # validate the rest of the changeset without flagging the just-revealed
  # date field as required before the user has had a chance to fill it.
  # The save path passes the default (true) so submitting without a date
  # still surfaces the inline error.
  defp maybe_require_date(changeset, opts) do
    enforce? = Keyword.get(opts, :enforce_scheduled_date_required, true)

    if enforce? and get_field(changeset, :start_mode) == "scheduled" do
      validate_required(changeset, [:scheduled_start_date],
        message: gettext("required for scheduled projects")
      )
    else
      changeset
    end
  end

  def start_modes, do: @start_modes

  @typedoc """
  Human-meaningful lifecycle state derived from the persisted fields.

  Combines the `archived_at` soft-hide flag, completion timestamps,
  start mode, and the scheduled date into the label that's actually
  meaningful in the UI.
  """
  @type derived_state ::
          :archived | :template | :completed | :running | :overdue | :scheduled | :setup

  @doc """
  Lifecycle state for this project, in priority order:

    * `:archived`  — soft-hidden (`archived_at` is set)
    * `:template`  — `is_template: true`
    * `:completed` — `completed_at` is set
    * `:running`   — `started_at` is set and not yet completed
    * `:overdue`   — scheduled, the scheduled_start_date has passed, not started
    * `:scheduled` — scheduled, start date still in the future, not started
    * `:setup`     — immediate start mode, not yet started

  `now` is injected so callers can pin "now" for tests. The
  scheduled-overdue check compares full timestamps, not just dates —
  a project scheduled for today at 09:00 is `:overdue` by 17:00 the
  same day.
  """
  @spec derived_status(t(), DateTime.t()) :: derived_state()
  def derived_status(%__MODULE__{} = p, now \\ DateTime.utc_now()) do
    cond do
      p.archived_at -> :archived
      p.is_template -> :template
      p.completed_at -> :completed
      p.started_at -> :running
      scheduled_overdue?(p, now) -> :overdue
      p.start_mode == "scheduled" -> :scheduled
      true -> :setup
    end
  end

  defp scheduled_overdue?(
         %__MODULE__{start_mode: "scheduled", scheduled_start_date: %DateTime{} = dt},
         %DateTime{} = now
       ),
       do: DateTime.compare(dt, now) == :lt

  defp scheduled_overdue?(_, _), do: false

  @doc """
  Calendar `DateTime` when this project would be done if work consumes
  `total_hours` of estimated work, starting from `started_at`.

  For `counts_weekends: true` projects this is simple calendar add.
  For weekday-only projects (`counts_weekends: false`) weekend days
  contribute zero work hours: the calendar walks forward but only
  weekday hours count toward the budget, scaled at the convention
  `Task.to_hours/3` uses (8 work hours per 24-hour weekday). Starting
  on a weekend skips to Monday before any budget is consumed.

  Returns `nil` when the project hasn't started or has no estimated
  work.
  """
  @spec planned_end_for(t(), number()) :: DateTime.t() | nil
  def planned_end_for(%__MODULE__{started_at: nil}, _hours), do: nil
  def planned_end_for(_, hours) when hours <= 0, do: nil

  def planned_end_for(
        %__MODULE__{started_at: %DateTime{} = start, counts_weekends: true},
        hours
      ),
      do: DateTime.add(start, round(hours * 3600), :second)

  def planned_end_for(
        %__MODULE__{started_at: %DateTime{} = start, counts_weekends: false},
        hours
      ),
      do: consume_weekday_budget(start, hours * 1.0)

  # Walks calendar time forward from `current`, treating 24 calendar
  # hours on a weekday as 8 work hours (a 3:1 calendar-to-work ratio).
  # Weekend days advance the calendar without consuming budget.
  defp consume_weekday_budget(current, hours_remaining) when hours_remaining <= 0,
    do: current

  defp consume_weekday_budget(%DateTime{} = current, hours_remaining) do
    if weekday?(DateTime.to_date(current)) do
      seconds_to_eod = seconds_until_end_of_day(current)
      work_hours_today = seconds_to_eod / 3600 / 3.0

      if hours_remaining <= work_hours_today do
        DateTime.add(current, round(hours_remaining * 3.0 * 3600), :second)
      else
        next_day_start = next_calendar_day_start(current)
        consume_weekday_budget(next_day_start, hours_remaining - work_hours_today)
      end
    else
      consume_weekday_budget(next_calendar_day_start(current), hours_remaining)
    end
  end

  defp weekday?(%Date{} = d), do: Date.day_of_week(d) <= 5

  defp seconds_until_end_of_day(%DateTime{} = dt) do
    time = DateTime.to_time(dt)
    86_400 - (time.hour * 3600 + time.minute * 60 + time.second)
  end

  defp next_calendar_day_start(%DateTime{} = dt) do
    next_date = Date.add(DateTime.to_date(dt), 1)
    DateTime.new!(next_date, ~T[00:00:00.000], dt.time_zone)
  end

  @doc """
  The list of fields that participate in `translations` JSONB storage.

  Used by the form layer to drive `merge_translatable_params/4` and by
  reads to know which keys to look up under each language code.
  """
  @spec translatable_fields() :: [String.t()]
  def translatable_fields, do: @translatable_fields

  @doc """
  Returns the project's name in the requested language, falling back to
  the primary `name` column when the language has no override (or the
  override is empty).

  `lang` may be `nil` (e.g. when multilang is disabled) — in that case
  the primary column is returned directly.
  """
  @spec localized_name(t(), String.t() | nil) :: String.t() | nil
  def localized_name(%__MODULE__{} = p, lang), do: localized_field(p, "name", lang)

  @doc """
  Returns the project's description in the requested language, with the
  same primary-fallback semantics as `localized_name/2`.
  """
  @spec localized_description(t(), String.t() | nil) :: String.t() | nil
  def localized_description(%__MODULE__{} = p, lang), do: localized_field(p, "description", lang)

  defp localized_field(p, field, lang) do
    primary = Map.get(p, String.to_existing_atom(field))

    case lookup_translation(p.translations, lang, field) do
      nil -> primary
      "" -> primary
      val -> val
    end
  end

  defp lookup_translation(translations, lang, field) when is_map(translations) and is_binary(lang) do
    case Map.get(translations, lang) do
      %{} = lang_map -> Map.get(lang_map, field)
      _ -> nil
    end
  end

  defp lookup_translation(_translations, _lang, _field), do: nil
end
