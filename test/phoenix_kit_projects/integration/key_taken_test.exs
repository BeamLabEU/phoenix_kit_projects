defmodule PhoenixKitProjects.Integration.KeyTakenTest do
  @moduledoc """
  `Projects.key_taken?/1`: a key is taken when a live project holds it or
  the registry remembers it (renamed away from, or its project deleted).
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.Projects

  defp project!(name, extra) do
    {:ok, project} =
      Projects.create_project(
        Map.merge(%{"name" => name, "start_mode" => "immediate", "is_template" => "false"}, extra)
      )

    project
  end

  test "a live project's key is taken, whatever the case or padding" do
    project = project!("Taken Live", %{"key" => "TKLV"})

    assert Projects.key_taken?("TKLV")
    assert Projects.key_taken?("tklv")
    assert Projects.key_taken?("  tklv ")
    assert project.key == "TKLV"
  end

  test "a key a project was renamed away from stays taken" do
    project = project!("Renamed Away", %{"key" => "OLDK"})
    assert {:ok, _} = Projects.update_project(project, %{"key" => "NEWK"})

    assert Projects.key_taken?("OLDK")
    assert Projects.key_taken?("NEWK")
  end

  test "a deleted project's key stays taken" do
    project = project!("Deleted Soon", %{"key" => "DELK"})
    assert {:ok, _} = Projects.delete_project(project)

    assert Projects.key_taken?("DELK")
  end

  test "registry readers agree on retired keys, including a deleted project's key" do
    project = project!("Registry Readers", %{"key" => "REG"})
    assert {:ok, renamed} = Projects.update_project(project, %{"key" => "REG2"})

    assert Projects.project_by_key("reg").uuid == project.uuid
    assert Projects.former_keys(renamed) == ["REG"]
    assert Projects.suggest_project_key("REG") == "REG3"

    assert {:ok, _} = Projects.delete_project(renamed)
    assert Projects.project_by_key("REG") == nil
    assert Projects.key_taken?("REG")
    assert Projects.key_taken?("REG2")
    assert Projects.suggest_project_key("REG") == "REG3"
  end

  test "a free key, a blank and a non-string are not taken" do
    refute Projects.key_taken?("FREEK")
    refute Projects.key_taken?("")
    refute Projects.key_taken?("   ")
    refute Projects.key_taken?(nil)
    refute Projects.key_taken?(42)
  end
end
