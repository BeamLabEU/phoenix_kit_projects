defmodule PhoenixKitProjects.Integration.EmbeddedPresetTest do
  # The project a host app keeps on one of its own records (an order): the
  # "embedded" preset, and a started, ongoing project from one call
  # (the boss's item 16, 2026-10-31).
  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.Extensions
  alias PhoenixKitProjects.Features
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.Project

  @on ~w(tasks assignees in_progress statuses dates dependencies subtasks library estimates
         scheduling view_timeline subprojects view_board view_calendar ledger all_comments)a
  @off ~w(project_comments priorities labels progress project_time billable waiting)a

  setup do
    with_comments_module()
    :ok
  end

  defp host_attrs(extra \\ %{}) do
    Map.merge(
      %{
        "name" => "Order #{System.unique_integer([:positive])}",
        "key" => unique_key(),
        "preset" => "embedded",
        "ongoing" => true,
        "start_mode" => "immediate"
      },
      extra
    )
  end

  test "the preset is listed, named and described" do
    assert %{name: "Embedded project", description: description} = Features.get_preset("embedded")
    assert description =~ "another record"
    assert "embedded" in Enum.map(Features.presets(), & &1.key)
  end

  describe "create_project/2 with the preset and ongoing" do
    test "one call makes a started, ongoing project with the lean flag set" do
      assert {:ok, %Project{} = project} = Projects.create_project(host_attrs())

      assert Project.ongoing?(project)
      assert project.started_at
      gates = Features.gates(project)

      for gate <- @on, do: assert(gates[gate], "#{gate} should be on")
      for gate <- @off, do: refute(gates[gate], "#{gate} should be off")

      assert Extensions.enabled?(project, "files")
      assert Extensions.enabled?(project, "discussions")
      refute Extensions.enabled?(project, "whiteboards")
      refute Extensions.enabled?(project, "events")
      refute Extensions.enabled?(project, "portal")
    end

    test "flags the caller passes win over the preset's" do
      {:ok, project} =
        Projects.create_project(host_attrs(%{"settings" => %{"features" => %{"labels" => true}}}))

      assert Features.on?(project, "labels")
      refute Features.on?(project, "priorities")
    end

    test "without ongoing it is an ordinary project that waits for its tasks" do
      {:ok, project} = Projects.create_project(Map.delete(host_attrs(), "ongoing"))
      refute Project.ongoing?(project)
      refute Features.on?(project, "priorities")
    end

    test "an unknown preset is ignored" do
      {:ok, project} = Projects.create_project(host_attrs(%{"preset" => "nope"}))
      assert Features.on?(project, "priorities")
      assert project.started_at
    end
  end

  describe "create_project_from_template/3" do
    test "the preset overlays the template's flags and extensions" do
      template = fixture_template()
      {:ok, template} = Features.set_flags(template, %{"priorities" => true, "labels" => true})
      {:ok, _} = Extensions.enable(template, "whiteboards")

      {:ok, project} =
        Projects.create_project_from_template(template.uuid, %{
          "name" => "From template",
          "key" => unique_key(),
          "preset" => "embedded",
          "ongoing" => true,
          "start_mode" => "immediate"
        })

      refute Features.on?(project, "priorities")
      refute Features.on?(project, "labels")
      refute Extensions.enabled?(project, "whiteboards")
      assert Project.ongoing?(project)
      assert project.started_at
    end
  end

  describe "apply_preset/3 on an existing project" do
    test "writes the flags and turns the named extensions on or off" do
      project = fixture_project()
      {:ok, _} = Extensions.enable(project, "events")
      {:ok, _} = Extensions.disable(project, "files")

      {:ok, project} = Features.apply_preset(project, "embedded")

      refute Features.on?(project, "priorities")
      assert Features.on?(project, "all_comments")
      refute Features.on?(project, "project_comments")
      refute Extensions.enabled?(project, "events")
      assert Extensions.enabled?(project, "files")
    end

    test "a preset that names no extensions leaves them alone" do
      project = fixture_project()
      {:ok, _} = Extensions.enable(project, "events")
      {:ok, _} = Features.apply_preset(project, "simple")
      assert Extensions.enabled?(project, "events")
    end
  end
end
