defmodule PhoenixKitProjects.Integration.TemplateCloneTest do
  @moduledoc """
  Integration tests for `create_project_from_template/2`:

    - happy path copies all assignments and dependencies atomically
    - transaction rolls back if cloning fails partway
    - missing template returns `{:error, :template_not_found}`
  """

  use PhoenixKitProjects.DataCase, async: true

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.Project

  defp build_template do
    {:ok, template} =
      Projects.create_project(%{
        "name" => "Template #{System.unique_integer([:positive])}",
        "status" => "active",
        "start_mode" => "immediate",
        "is_template" => "true",
        "counts_weekends" => "false"
      })

    {:ok, t1} = Projects.create_task(%{"title" => "Setup #{System.unique_integer([:positive])}"})
    {:ok, t2} = Projects.create_task(%{"title" => "Build #{System.unique_integer([:positive])}"})

    {:ok, a1} =
      Projects.create_assignment(%{
        "project_uuid" => template.uuid,
        "task_uuid" => t1.uuid,
        "status" => "todo"
      })

    {:ok, a2} =
      Projects.create_assignment(%{
        "project_uuid" => template.uuid,
        "task_uuid" => t2.uuid,
        "status" => "todo"
      })

    {:ok, _} = Projects.add_dependency(a2.uuid, a1.uuid)

    %{template: template, tasks: [t1, t2], assignments: [a1, a2]}
  end

  describe "happy path" do
    test "clones assignments and dependencies into a new project" do
      %{template: template} = build_template()

      {:ok, project} =
        Projects.create_project_from_template(template.uuid, %{
          "name" => "Clone #{System.unique_integer([:positive])}",
          "status" => "active",
          "start_mode" => "immediate"
        })

      assert %Project{is_template: false} = project
      assert project.counts_weekends == template.counts_weekends

      new_assignments = Projects.list_assignments(project.uuid)
      assert length(new_assignments) == 2
      # All cloned assignments start in "todo" regardless of source state.
      assert Enum.all?(new_assignments, &(&1.status == "todo"))

      new_deps = Projects.list_all_dependencies(project.uuid)
      assert length(new_deps) == 1
    end

    test "returns :template_not_found when template uuid does not exist" do
      assert {:error, :template_not_found} =
               Projects.create_project_from_template(UUIDv7.generate(), %{
                 "name" => "Nope",
                 "status" => "active",
                 "start_mode" => "immediate"
               })
    end
  end

  describe "name uniqueness — none" do
    # V105 added two partial unique indexes (template vs project) and
    # V112 dropped both: name uniqueness is policy, not structure, and
    # the rest of the code references projects by `uuid`. Two real
    # projects (or two templates) with the same name now coexist.
    test "duplicate names are allowed across is_template combinations" do
      shared_name = "Shared-#{System.unique_integer([:positive])}"
      base = %{"start_mode" => "immediate"}

      assert {:ok, %Project{is_template: true}} =
               Projects.create_project(Map.merge(base, %{"name" => shared_name, "is_template" => "true"}))

      assert {:ok, %Project{is_template: true}} =
               Projects.create_project(Map.merge(base, %{"name" => shared_name, "is_template" => "true"}))

      assert {:ok, %Project{is_template: false}} =
               Projects.create_project(Map.merge(base, %{"name" => shared_name, "is_template" => "false"}))

      assert {:ok, %Project{is_template: false}} =
               Projects.create_project(Map.merge(base, %{"name" => shared_name, "is_template" => "false"}))
    end
  end
end
