defmodule PhoenixKitProjects.Schemas.Assignment do
  @moduledoc """
  A task instance within a project. Copies description and duration from
  the task template at creation time — editable independently.

  Tracks who completed the task via `completed_by_uuid` + `completed_at`.
  """

  use Ecto.Schema
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Changeset

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitProjects.Schemas.{Dependency, Project, Task}
  alias PhoenixKitStaff.Schemas.{Department, Person, Team}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(todo in_progress done)
  @duration_units ~w(minutes hours days weeks fortnights months years)

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          project_uuid: UUIDv7.t() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t() | nil,
          task_uuid: UUIDv7.t() | nil,
          task: Task.t() | Ecto.Association.NotLoaded.t() | nil,
          status: String.t() | nil,
          position: integer() | nil,
          description: String.t() | nil,
          estimated_duration: integer() | nil,
          estimated_duration_unit: String.t() | nil,
          counts_weekends: boolean() | nil,
          progress_pct: integer() | nil,
          track_progress: boolean() | nil,
          # Cross-module assoc fields use `struct()` rather than the precise
          # `PhoenixKitStaff.Schemas.<X>.t()` because phoenix_kit_staff
          # Hex 0.1.0 doesn't ship `@type t` declarations on its schemas
          # (the workspace version does — once it publishes 0.1.1, tighten
          # these back to the named types).
          assigned_team_uuid: UUIDv7.t() | nil,
          assigned_team: struct() | Ecto.Association.NotLoaded.t() | nil,
          assigned_department_uuid: UUIDv7.t() | nil,
          assigned_department: struct() | Ecto.Association.NotLoaded.t() | nil,
          assigned_person_uuid: UUIDv7.t() | nil,
          assigned_person: struct() | Ecto.Association.NotLoaded.t() | nil,
          completed_by_uuid: UUIDv7.t() | nil,
          completed_by: User.t() | Ecto.Association.NotLoaded.t() | nil,
          completed_at: DateTime.t() | nil,
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

    belongs_to(:project, Project, foreign_key: :project_uuid, references: :uuid)
    belongs_to(:task, Task, foreign_key: :task_uuid, references: :uuid)

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

  @required ~w(project_uuid task_uuid status)a
  @optional ~w(position description estimated_duration estimated_duration_unit
               counts_weekends progress_pct track_progress
               assigned_team_uuid assigned_department_uuid assigned_person_uuid)a

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
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:estimated_duration, greater_than: 0)
    |> validate_inclusion(:estimated_duration_unit, @duration_units)
    |> validate_number(:progress_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> assoc_constraint(:project)
    |> assoc_constraint(:task)
    |> validate_single_assignee()
    |> check_constraint(:assigned_team_uuid,
      name: :phoenix_kit_project_assignments_single_assignee,
      message: single_assignee_message()
    )
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
end
