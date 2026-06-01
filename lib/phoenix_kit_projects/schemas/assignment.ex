defmodule PhoenixKitProjects.Schemas.Assignment do
  @moduledoc """
  A task instance within a project. Copies description and duration from
  the task template at creation time — editable independently.

  Tracks who completed the task via `completed_by_uuid` + `completed_at`.
  """

  use Ecto.Schema
  use Gettext, backend: PhoenixKitProjects.Gettext

  import Ecto.Changeset

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitProjects.L10n
  alias PhoenixKitProjects.Schemas.{Dependency, Project, Task}
  alias PhoenixKitStaff.Schemas.{Department, Person, Team}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(todo in_progress done)
  @duration_units ~w(minutes hours days weeks fortnights months years)
  @translatable_fields ~w(description)

  @typedoc """
  JSONB map of secondary-language overrides. Same shape as
  `Project.translations_map`/`Task.translations_map`.
  """
  @type translations_map :: %{optional(String.t()) => %{optional(String.t()) => String.t()}}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          project_uuid: UUIDv7.t() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t() | nil,
          task_uuid: UUIDv7.t() | nil,
          task: Task.t() | Ecto.Association.NotLoaded.t() | nil,
          child_project_uuid: UUIDv7.t() | nil,
          child_project: Project.t() | Ecto.Association.NotLoaded.t() | nil,
          status: String.t() | nil,
          position: integer() | nil,
          description: String.t() | nil,
          estimated_duration: integer() | nil,
          estimated_duration_unit: String.t() | nil,
          counts_weekends: boolean() | nil,
          progress_pct: integer() | nil,
          track_progress: boolean() | nil,
          assigned_team_uuid: UUIDv7.t() | nil,
          assigned_team: Team.t() | Ecto.Association.NotLoaded.t() | nil,
          assigned_department_uuid: UUIDv7.t() | nil,
          assigned_department: Department.t() | Ecto.Association.NotLoaded.t() | nil,
          assigned_person_uuid: UUIDv7.t() | nil,
          assigned_person: Person.t() | Ecto.Association.NotLoaded.t() | nil,
          completed_by_uuid: UUIDv7.t() | nil,
          completed_by: User.t() | Ecto.Association.NotLoaded.t() | nil,
          completed_at: DateTime.t() | nil,
          translations: translations_map(),
          dependencies: [Dependency.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_project_assignments" do
    field(:status, :string, default: "todo")
    field(:position, :integer, default: 0)
    field(:description, :string)
    field(:estimated_duration, :integer)
    field(:estimated_duration_unit, :string)
    field(:counts_weekends, :boolean)
    field(:progress_pct, :integer, default: 0)
    field(:track_progress, :boolean, default: false)
    field(:completed_at, :utc_datetime)
    field(:translations, :map, default: %{})

    belongs_to(:project, Project, foreign_key: :project_uuid, references: :uuid)
    belongs_to(:task, Task, foreign_key: :task_uuid, references: :uuid)

    # When set, this assignment IS a sub-project: instead of a reusable task
    # template it points at a child Project embedded in the parent's timeline.
    # Exactly one of `task_uuid` / `child_project_uuid` is set (DB XOR check +
    # `validate_task_xor_child/1`). The child is the source of truth; this
    # assignment's status/progress/duration are denormalized rollup values
    # synced by the context via `subproject_changeset/2`.
    belongs_to(:child_project, Project, foreign_key: :child_project_uuid, references: :uuid)

    belongs_to(:assigned_team, Team, foreign_key: :assigned_team_uuid, references: :uuid)

    belongs_to(:assigned_department, Department,
      foreign_key: :assigned_department_uuid,
      references: :uuid
    )

    belongs_to(:assigned_person, Person, foreign_key: :assigned_person_uuid, references: :uuid)

    belongs_to(:completed_by, User, foreign_key: :completed_by_uuid, references: :uuid)

    has_many(:dependencies, Dependency, foreign_key: :assignment_uuid)
    has_many(:dependents, Dependency, foreign_key: :depends_on_uuid)

    timestamps(type: :utc_datetime)
  end

  # `task_uuid` is no longer unconditionally required (V126): a sub-project
  # assignment carries `child_project_uuid` instead. The XOR is enforced by
  # `validate_task_xor_child/1` + the DB check constraint.
  @required ~w(project_uuid status)a
  @optional ~w(task_uuid child_project_uuid position description estimated_duration
               estimated_duration_unit counts_weekends progress_pct track_progress
               translations assigned_team_uuid assigned_department_uuid assigned_person_uuid)a

  # Server-only fields: set by trusted server code (completion tracking),
  # never cast from untrusted form params. Use `status_changeset/2`.
  @server_only ~w(completed_by_uuid completed_at)a

  @doc """
  Form-facing changeset. Does NOT allow setting `completed_by_uuid` or
  `completed_at` — those are server-owned fields (use `status_changeset/2`).
  """
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, @required ++ @optional)
    |> validate()
  end

  @doc """
  Server-trusted changeset that also allows setting completion fields.
  Use from context functions that own the completion transition, e.g.
  progress updates, explicit `complete_assignment/2`, or `reopen_assignment/1`.
  """
  def status_changeset(assignment, attrs) do
    assignment
    |> cast(attrs, @required ++ @optional ++ @server_only)
    |> validate()
  end

  defp validate(changeset) do
    changeset
    |> validate_required(@required)
    |> validate_task_xor_child()
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:estimated_duration, greater_than: 0)
    |> validate_inclusion(:estimated_duration_unit, @duration_units)
    |> validate_number(:progress_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_translations_shape()
    |> assoc_constraint(:project)
    |> assoc_constraint(:task)
    |> assoc_constraint(:child_project)
    |> validate_single_assignee()
    |> check_constraint(:assigned_team_uuid,
      name: :phoenix_kit_project_assignments_single_assignee,
      message: single_assignee_message()
    )
    |> task_xor_child_constraints()
  end

  @doc """
  Changeset for the parent-side linking assignment of a **sub-project**.

  Used both to create the linking row (`create_subproject/2`) and to sync the
  denormalized rollup fields whenever the child project changes
  (`sync_project_rollup/1`). Unlike `changeset/2` it:

    * casts `child_project_uuid` and the server-owned rollup fields
      (`status` / `progress_pct` / `estimated_duration` / `completed_at` /
      `completed_by_uuid`) but never `task_uuid` — so a sub-project row can't
      be flipped into a task-backed one via this path;
    * does NOT require `estimated_duration > 0` — a child with no tasks rolls
      up to 0 planned hours, which is legitimate.
  """
  @spec subproject_changeset(t(), map()) :: Ecto.Changeset.t()
  def subproject_changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :project_uuid,
      :child_project_uuid,
      :position,
      :status,
      :progress_pct,
      :estimated_duration,
      :estimated_duration_unit,
      :track_progress,
      :completed_at,
      :completed_by_uuid
    ])
    |> validate_required([:project_uuid, :child_project_uuid, :status])
    |> validate_task_xor_child()
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:estimated_duration, greater_than_or_equal_to: 0)
    |> validate_number(:progress_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> assoc_constraint(:project)
    |> assoc_constraint(:child_project)
    |> unique_constraint(:child_project_uuid,
      name: :phoenix_kit_project_assignments_child_project_unique,
      message: gettext("project is already a sub-project of another project")
    )
    |> task_xor_child_constraints()
  end

  # Exactly one of task_uuid / child_project_uuid must be present. Mirrors the
  # DB CHECK so changesets fail fast with a friendly message.
  defp validate_task_xor_child(changeset) do
    task = get_field(changeset, :task_uuid)
    child = get_field(changeset, :child_project_uuid)

    case {task, child} do
      {nil, nil} ->
        add_error(changeset, :task_uuid, gettext("a task or a sub-project is required"))

      {t, c} when not is_nil(t) and not is_nil(c) ->
        add_error(
          changeset,
          :child_project_uuid,
          gettext("an assignment cannot be both a task and a sub-project")
        )

      _ ->
        changeset
    end
  end

  defp task_xor_child_constraints(changeset) do
    check_constraint(changeset, :child_project_uuid,
      name: :phoenix_kit_project_assignments_task_xor_child,
      message: gettext("an assignment must be exactly one of a task or a sub-project")
    )
  end

  # Shape guard for the `translations` JSONB. See `Project` for the
  # rationale; the contract lives on `L10n.valid_translations_shape?/1`.
  defp validate_translations_shape(changeset) do
    case get_change(changeset, :translations) do
      nil ->
        changeset

      val ->
        if L10n.valid_translations_shape?(val) do
          changeset
        else
          add_error(changeset, :translations, "is not a valid translations map")
        end
    end
  end

  # Mirrors the DB-level CHECK constraint on the assignee triple so
  # changesets fail fast with a friendly message instead of a raw
  # Postgrex error on concurrent inserts. Both the validator and the
  # check_constraint surface the same translated message — single
  # source kept here so the wording can't drift.
  defp validate_single_assignee(changeset) do
    set =
      Enum.count(
        [:assigned_team_uuid, :assigned_department_uuid, :assigned_person_uuid],
        &(get_field(changeset, &1) != nil)
      )

    if set > 1 do
      add_error(changeset, :assigned_team_uuid, single_assignee_message())
    else
      changeset
    end
  end

  defp single_assignee_message,
    do: gettext("only one of team, department, or person can be assigned")

  def statuses, do: @statuses

  @doc "True when this assignment embeds a child project (a sub-project row)."
  @spec subproject?(t()) :: boolean()
  def subproject?(%__MODULE__{child_project_uuid: nil}), do: false
  def subproject?(%__MODULE__{child_project_uuid: _}), do: true

  @doc """
  The display label for this assignment, locale-aware: the child project's
  name for a sub-project, otherwise the task template's title. Requires the
  relevant association (`:child_project` or `:task`) to be preloaded — both are
  in `Projects`' `@assignment_preloads`. `lang` may be `nil` (primary value).

  Single source of truth so every render site (timeline title, comment header,
  dependency badge, remove-confirm, activity metadata) handles the sub-project
  case identically instead of dereferencing a `nil` task.
  """
  @spec label(t(), String.t() | nil) :: String.t() | nil
  def label(assignment, lang \\ nil)

  def label(%__MODULE__{child_project_uuid: nil} = a, lang),
    do: Task.localized_title(a.task, lang)

  def label(%__MODULE__{child_project: %Project{} = cp}, lang),
    do: Project.localized_name(cp, lang)

  def label(%__MODULE__{}, _lang), do: nil

  @doc "DB-column field names that participate in the `translations` JSONB."
  @spec translatable_fields() :: [String.t()]
  def translatable_fields, do: @translatable_fields

  @doc """
  Returns the assignment's description in the requested language, with
  primary-fallback semantics: empty/missing override → the primary
  `description` column, which itself may be `nil` (in which case the
  caller's typical pattern is to fall further back to the parent task's
  `localized_description/2`). The double-fallback chain keeps existing
  call sites like `a.description || a.task.description` working
  locale-aware: `Assignment.localized_description(a, lang) ||
  Task.localized_description(a.task, lang)`.
  """
  @spec localized_description(t(), String.t() | nil) :: String.t() | nil
  def localized_description(%__MODULE__{} = a, lang) do
    case lookup_translation(a.translations, lang, "description") do
      nil -> a.description
      "" -> a.description
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
end
