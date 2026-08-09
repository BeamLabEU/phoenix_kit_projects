defmodule PhoenixKitProjects.Integration.FeaturesTest do
  use PhoenixKitProjects.DataCase, async: false

  import PhoenixKitProjects.ActivityLogAssertions

  alias PhoenixKitProjects.Extensions
  alias PhoenixKitProjects.Extensions.Registry
  alias PhoenixKitProjects.Features
  alias PhoenixKitProjects.Projects

  defmodule FlagProvider do
    def phoenix_kit_project_extensions do
      [
        %{
          key: "flag_ext",
          name: "Flag Ext",
          default_enabled: true,
          feature_flags: [
            %{key: "flag_a", label: "A", default: true},
            %{key: "flag_b", label: "B", default: false, requires: ["flag_a"]},
            # A requires-cycle — provider data is input, the resolver guards.
            %{key: "cyc_x", label: "X", default: true, requires: ["cyc_y"]},
            %{key: "cyc_y", label: "Y", default: true, requires: ["cyc_x"]}
          ]
        }
      ]
    end
  end

  setup do
    Application.put_env(:phoenix_kit_projects, :extension_providers, [FlagProvider])
    Registry.refresh()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_projects, :extension_providers)
      Registry.refresh()
    end)

    {:ok, project: fixture_project()}
  end

  describe "catalog/0" do
    test "carries the frozen tasks flags stamped with their owner" do
      cat = Features.catalog()

      for key <-
            ~w(assignees estimates progress dependencies statuses scheduling subprojects view_timeline view_calendar) do
        assert %{ext_key: "tasks", default: true} = cat[key], "missing tasks flag #{key}"
      end

      assert %{ext_key: "flag_ext", default: false, requires: ["flag_a"]} = cat["flag_b"]
    end
  end

  describe "on?/2 resolution" do
    test "pre-hub flags default true on a fresh project (behavior-preserving)",
         %{project: project} do
      assert Features.on?(project, "assignees")
      assert Features.on?(project, "view_timeline")
    end

    test "unknown keys are fail-closed", %{project: project} do
      refute Features.on?(project, "no_such_flag")
    end

    test "explicit false wins over the default", %{project: project} do
      {:ok, project} = Features.set_flags(project, %{"assignees" => false})
      refute Features.on?(project, "assignees")
      assert Features.on?(project, "estimates")
    end

    test "requires chain: turning scheduling off kills the views that need it",
         %{project: project} do
      {:ok, project} = Features.set_flags(project, %{"scheduling" => false})
      refute Features.on?(project, "view_timeline")
      refute Features.on?(project, "view_calendar")

      # …even when the dependent flag is explicitly on.
      {:ok, project} = Features.set_flags(project, %{"view_timeline" => true})
      refute Features.on?(project, "view_timeline")
    end

    test "transitive requires: estimates off kills scheduling AND the views",
         %{project: project} do
      {:ok, project} = Features.set_flags(project, %{"estimates" => false})
      refute Features.on?(project, "scheduling")
      refute Features.on?(project, "view_calendar")
    end

    test "a disabled owning extension kills its flags", %{project: project} do
      assert Features.on?(project, "flag_a")
      {:ok, _} = Extensions.disable(project, "flag_ext")
      refute Features.on?(project, "flag_a")

      # The Jira scenario: tasks off ⇒ every task flag off.
      {:ok, _} = Extensions.disable(project, "tasks")
      refute Features.on?(project, "assignees")
    end

    test "requires cycles resolve false, never loop", %{project: project} do
      refute Features.on?(project, "cyc_x")
      refute Features.on?(project, "cyc_y")
    end

    test "uuid input works (loads settings)", %{project: project} do
      {:ok, _} = Features.set_flags(project, %{"statuses" => false})
      refute Features.on?(project.uuid, "statuses")
      assert Features.on?(project.uuid, "dependencies")
    end
  end

  describe "set_flags/3" do
    test "whitelists keys and value types; logs the change", %{project: project} do
      {:ok, updated} =
        Features.set_flags(project, %{
          "assignees" => false,
          "unknown_flag" => false,
          "estimates" => "not a boolean"
        })

      assert updated.settings["features"] == %{"assignees" => false}

      assert_activity_logged("projects.feature_toggled",
        resource_uuid: project.uuid,
        metadata_has: %{"changed" => %{"assignees" => false}}
      )
    end

    test "merges over prior explicit values", %{project: project} do
      {:ok, project} = Features.set_flags(project, %{"assignees" => false})
      {:ok, project} = Features.set_flags(project, %{"statuses" => false})

      assert project.settings["features"] == %{"assignees" => false, "statuses" => false}
    end

    test "an all-rejected write is a no-op without an activity row", %{project: project} do
      {:ok, _} = Features.set_flags(project, %{"junk" => true})
      refute_activity_logged("projects.feature_toggled", resource_uuid: project.uuid)
    end
  end

  describe "presets" do
    test "simple preset flips the task features off explicitly", %{project: project} do
      {:ok, project} = Features.apply_preset(project, "simple")

      refute Features.on?(project, "assignees")
      refute Features.on?(project, "statuses")
      refute Features.on?(project, "view_timeline")
      # The tasks extension itself stays enabled — the LIST remains.
      assert Extensions.enabled?(project, "tasks")
    end

    test "unknown preset keys are a safe no-op", %{project: project} do
      assert {:ok, _} = Features.apply_preset(project, "no_such_preset")
      assert Features.on?(project, "assignees")
    end

    test "default preset key falls back to standard" do
      assert Features.default_preset_key() in ["standard", "simple", "full"]
    end
  end

  describe "set_flags/3 concurrency (final panel, ZAI)" do
    # settings is a shared JSONB: the authz "who can X" floors live in the
    # same column. A whole-map read-merge-write from a STALE struct used to
    # clobber a concurrent authz tightening — security-relevant lost write.
    test "a stale-struct flag write does not clobber a concurrent authz write" do
      project = fixture_project()
      stale = project

      # Another session tightens an authz floor AFTER `stale` was loaded.
      {:ok, _} =
        project
        |> Ecto.Changeset.change(
          settings: Map.put(project.settings || %{}, "authz", %{"update_status" => "managers"})
        )
        |> PhoenixKit.RepoHelper.repo().update()

      # The stale session toggles a flag.
      {:ok, _} = Features.set_flags(stale, %{"statuses" => false})

      reloaded = Projects.get_project(project.uuid)
      assert reloaded.settings["authz"] == %{"update_status" => "managers"}
      assert reloaded.settings["features"]["statuses"] == false
    end
  end
end
