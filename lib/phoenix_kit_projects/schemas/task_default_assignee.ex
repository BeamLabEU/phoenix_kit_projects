defmodule PhoenixKitProjects.Schemas.TaskDefaultAssignee do
  @moduledoc """
  One of a library task's default assignees — who a new task from it
  starts with (chain V30): exactly one staff person, team or department,
  and its place among the chips (`position`). Any number of them, all
  equal — the same as a task's (`AssignmentAssignee`, V29).

  Written only through `PhoenixKitProjects.Schemas.Task.changeset/2` (the
  `"assignees"` param, or the old single-assignee fields), which keeps the
  holder's own columns as the one-assignee mirror. Read through
  `PhoenixKitProjects.AssigneeSet`.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  alias PhoenixKitProjects.People.{Department, Person, Team}

  @type t :: %__MODULE__{}

  schema "phoenix_kit_project_task_assignees" do
    field(:task_uuid, UUIDv7)
    belongs_to(:person, Person, foreign_key: :person_uuid, references: :uuid)
    belongs_to(:team, Team, foreign_key: :team_uuid, references: :uuid)
    belongs_to(:department, Department, foreign_key: :department_uuid, references: :uuid)
    field(:position, :integer, default: 0)
    field(:inserted_at, :utc_datetime, read_after_writes: true)
  end
end
