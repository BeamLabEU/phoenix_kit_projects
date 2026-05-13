defmodule PhoenixKitProjects.Schemas.TaskDependency do
  @moduledoc """
  Default dependency between task templates. When both tasks are added
  to the same project, the assignment dependency is auto-created.
  """

  use Ecto.Schema
  use Gettext, backend: PhoenixKitProjects.Gettext

  import Ecto.Changeset

  alias PhoenixKitProjects.Schemas.Task

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          task_uuid: UUIDv7.t() | nil,
          task: Task.t() | Ecto.Association.NotLoaded.t() | nil,
          depends_on_task_uuid: UUIDv7.t() | nil,
          depends_on_task: Task.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "phoenix_kit_project_task_dependencies" do
    belongs_to(:task, Task, foreign_key: :task_uuid, references: :uuid)
    belongs_to(:depends_on_task, Task, foreign_key: :depends_on_task_uuid, references: :uuid)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required ~w(task_uuid depends_on_task_uuid)a

  def changeset(dep, attrs) do
    dep
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> assoc_constraint(:task)
    |> assoc_constraint(:depends_on_task)
    |> unique_constraint([:task_uuid, :depends_on_task_uuid],
      name: :phoenix_kit_project_task_deps_pair_index,
      message: gettext("dependency already exists")
    )
    |> validate_not_self()
  end

  defp validate_not_self(cs) do
    a = get_field(cs, :task_uuid)
    b = get_field(cs, :depends_on_task_uuid)

    if a && b && a == b do
      add_error(cs, :depends_on_task_uuid, gettext("cannot depend on itself"))
    else
      cs
    end
  end
end
