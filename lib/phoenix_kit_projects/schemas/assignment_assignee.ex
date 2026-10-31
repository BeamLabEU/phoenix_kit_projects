defmodule PhoenixKitProjects.Schemas.AssignmentAssignee do
  @moduledoc """
  One of a task's assignees (chain V29): exactly one staff person, team or
  department, and its place among the task's chips (`position`). A task
  has any number of them, all equal — one status, everyone told.

  Written only through `Assignment.changeset/2` (the `"assignees"` param,
  or the old single-assignee fields), which keeps the task's own
  `assigned_*` columns as the one-assignee mirror. Read through
  `PhoenixKitProjects.AssigneeSet`.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  alias PhoenixKitProjects.People.{Department, Person, Team}

  @type t :: %__MODULE__{}

  schema "phoenix_kit_project_assignment_assignees" do
    field(:assignment_uuid, UUIDv7)
    belongs_to(:person, Person, foreign_key: :person_uuid, references: :uuid)
    belongs_to(:team, Team, foreign_key: :team_uuid, references: :uuid)
    belongs_to(:department, Department, foreign_key: :department_uuid, references: :uuid)
    field(:position, :integer, default: 0)
    field(:inserted_at, :utc_datetime, read_after_writes: true)
  end
end
