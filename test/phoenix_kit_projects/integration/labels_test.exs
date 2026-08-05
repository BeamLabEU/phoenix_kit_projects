defmodule PhoenixKitProjects.Integration.LabelsTest do
  @moduledoc """
  Phase C labels: the V7 registry + join table via `PhoenixKitProjects.Labels`.
  """

  use PhoenixKitProjects.DataCase, async: false

  import PhoenixKitProjects.ActivityLogAssertions

  alias PhoenixKitProjects.{Labels, Projects}

  setup do
    project = fixture_project()

    {:ok, assignment} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => fixture_task().uuid,
        "status" => "todo"
      })

    {:ok, project: project, assignment: assignment}
  end

  test "create / list / delete with activity + per-project name uniqueness", %{project: project} do
    assert {:ok, label} = Labels.create(project, %{name: "frontend", color: "badge-info"})
    assert_activity_logged("projects.label_created", resource_uuid: project.uuid)

    assert {:error, changeset} = Labels.create(project, %{name: "frontend"})
    assert %{project_uuid: _} = errors_on(changeset)

    # Same name in ANOTHER project is fine.
    assert {:ok, _} = Labels.create(fixture_project(), %{name: "frontend"})

    assert [%{name: "frontend"}] = Labels.list_for_project(project.uuid)

    assert :ok = Labels.delete(label)
    assert Labels.list_for_project(project.uuid) == []
    assert_activity_logged("projects.label_deleted", resource_uuid: project.uuid)
  end

  test "color outside the palette is refused", %{project: project} do
    assert {:error, changeset} = Labels.create(project, %{name: "x", color: "badge-rainbow"})
    assert %{color: _} = errors_on(changeset)
  end

  test "set_assignment_labels replaces, whitelists cross-project uuids, cascades on delete",
       %{project: project, assignment: assignment} do
    {:ok, a} = Labels.create(project, %{name: "a"})
    {:ok, b} = Labels.create(project, %{name: "b"})
    {:ok, foreign} = Labels.create(fixture_project(), %{name: "foreign"})

    :ok = Labels.set_assignment_labels(assignment, [a.uuid, foreign.uuid])

    uuid = assignment.uuid
    assert %{^uuid => [%{name: "a"}]} = Labels.labels_for_assignments([assignment.uuid])

    # Replace (not merge).
    :ok = Labels.set_assignment_labels(assignment, [b.uuid])
    assert [%{name: "b"}] = Labels.labels_for_assignments([assignment.uuid])[assignment.uuid]

    # Deleting the label clears the join (cascade).
    :ok = Labels.delete(b)
    assert Labels.labels_for_assignments([assignment.uuid]) == %{}
  end

  test "assignment priority persists with the closed vocabulary", %{project: project} do
    {:ok, assignment} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => fixture_task().uuid,
        "status" => "todo",
        "priority" => "urgent"
      })

    assert assignment.priority == "urgent"

    assert {:error, changeset} =
             Projects.create_assignment(%{
               "project_uuid" => project.uuid,
               "task_uuid" => fixture_task().uuid,
               "status" => "todo",
               "priority" => "whenever"
             })

    assert %{priority: _} = errors_on(changeset)
  end
end
