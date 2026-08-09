defmodule PhoenixKitProjects.Integration.ExtensionsTest do
  use PhoenixKitProjects.DataCase, async: false

  import PhoenixKitProjects.ActivityLogAssertions

  alias PhoenixKitProjects.Extensions
  alias PhoenixKitProjects.Extensions.Registry
  alias PhoenixKitProjects.Schemas.ProjectModule

  defmodule TestProvider do
    def phoenix_kit_project_extensions do
      [
        %{
          key: "ext_test",
          name: "Ext Test",
          config_schema: [
            %{key: "company_uuid", type: :string, label: "Company"},
            %{key: "mode", type: :select, label: "Mode", options: ["a", "b"]}
          ],
          on_enable: {PhoenixKitProjects.Integration.ExtensionsTest, :record_enable},
          on_disable: {PhoenixKitProjects.Integration.ExtensionsTest, :record_disable}
        },
        %{key: "ext_default_on", name: "Default On", default_enabled: true},
        %{
          key: "ext_raising",
          name: "Raising callbacks",
          on_enable: {PhoenixKitProjects.Integration.ExtensionsTest, :raise_boom}
        }
      ]
    end
  end

  def record_enable(project_uuid, config),
    do: send(self(), {:on_enable, project_uuid, config})

  def record_disable(project_uuid, config),
    do: send(self(), {:on_disable, project_uuid, config})

  def raise_boom(_project_uuid, _config), do: raise("boom")

  setup do
    Application.put_env(:phoenix_kit_projects, :extension_providers, [TestProvider])
    Registry.refresh()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_projects, :extension_providers)
      Registry.refresh()
    end)

    {:ok, project: fixture_project()}
  end

  describe "enable/3 + enabled?/3" do
    test "explicit enable creates the row, logs, and fires the callback", %{project: project} do
      refute Extensions.enabled?(project, "ext_test")

      assert {:ok, %ProjectModule{enabled: true, instance_key: "default"}} =
               Extensions.enable(project, "ext_test",
                 actor_uuid: nil,
                 config: %{"company_uuid" => "abc", "evil_key" => "dropped"}
               )

      assert Extensions.enabled?(project, "ext_test")
      assert_receive {:on_enable, project_uuid, config}
      assert project_uuid == project.uuid
      # The whitelist admits only config_schema keys.
      assert config == %{"company_uuid" => "abc"}

      assert_activity_logged("projects.module_enabled",
        resource_uuid: project.uuid,
        metadata_has: %{"ext_key" => "ext_test"}
      )
    end

    test "unknown extension keys are rejected", %{project: project} do
      assert {:error, :unknown_extension} = Extensions.enable(project, "no_such_ext")
      refute Extensions.enabled?(project, "no_such_ext")
    end

    test "catalog default_enabled applies with no row; explicit disable overrides it",
         %{project: project} do
      assert Extensions.enabled?(project, "ext_default_on")

      assert {:ok, %ProjectModule{enabled: false}} =
               Extensions.disable(project, "ext_default_on")

      refute Extensions.enabled?(project, "ext_default_on")

      assert_activity_logged("projects.module_disabled",
        resource_uuid: project.uuid,
        metadata_has: %{"ext_key" => "ext_default_on"}
      )
    end

    test "a raising lifecycle callback never aborts the toggle", %{project: project} do
      assert {:ok, _} = Extensions.enable(project, "ext_raising")
      assert Extensions.enabled?(project, "ext_raising")
    end
  end

  describe "disable/3 preserves config; re-enable restores it" do
    test "round trip", %{project: project} do
      {:ok, _} = Extensions.enable(project, "ext_test", config: %{"company_uuid" => "abc"})
      {:ok, disabled} = Extensions.disable(project, "ext_test")
      assert disabled.config == %{"company_uuid" => "abc"}
      refute Extensions.enabled?(project, "ext_test")

      {:ok, reenabled} = Extensions.enable(project, "ext_test")
      assert reenabled.config == %{"company_uuid" => "abc"}
      assert Extensions.enabled?(project, "ext_test")
      assert_receive {:on_disable, _, %{"company_uuid" => "abc"}}
    end
  end

  describe "update_config/4" do
    test "whitelists keys and merges over stored config", %{project: project} do
      {:ok, _} = Extensions.enable(project, "ext_test", config: %{"company_uuid" => "abc"})

      assert {:ok, row} =
               Extensions.update_config(project, "ext_test", %{
                 "mode" => "b",
                 "injection" => "dropped"
               })

      assert row.config == %{"company_uuid" => "abc", "mode" => "b"}
    end

    test "requires an existing row", %{project: project} do
      assert {:error, :not_enabled} = Extensions.update_config(project, "ext_test", %{})
    end
  end

  describe "enabled_for_project/1" do
    test "returns explicit and default-enabled extensions, skips disabled ones",
         %{project: project} do
      {:ok, _} = Extensions.enable(project, "ext_test")

      keys =
        project.uuid |> Extensions.enabled_for_project() |> Enum.map(fn {ext, _} -> ext.key end)

      assert "ext_test" in keys
      # Implicit via default_enabled — row is nil.
      assert "ext_default_on" in keys
      assert "tasks" in keys

      {:ok, _} = Extensions.disable(project, "ext_default_on")

      keys =
        project.uuid |> Extensions.enabled_for_project() |> Enum.map(fn {ext, _} -> ext.key end)

      refute "ext_default_on" in keys
    end
  end

  describe "the built-in tasks extension" do
    test "is enabled by default on any project (behavior-preserving)", %{project: project} do
      assert Extensions.enabled?(project, "tasks")
    end

    test "can be turned off per project — the Jira-project scenario", %{project: project} do
      {:ok, _} = Extensions.disable(project, "tasks")
      refute Extensions.enabled?(project, "tasks")

      # Another project is untouched.
      other = fixture_project(%{"name" => "Other #{System.unique_integer([:positive])}"})
      assert Extensions.enabled?(other, "tasks")
    end
  end
end
