defmodule PhoenixKitProjects.ModuleExtrasTest do
  @moduledoc """
  Coverage extension for the top-level `PhoenixKitProjects` module —
  exercises `enable_system/0` / `disable_system/0` so the
  `update_boolean_setting_with_module/3` paths are covered. Plus
  `permission_metadata/0` and `version/0` shape pinning.

  Uses `DataCase` so the `Settings.update_*` calls have a sandboxed
  DB to write into.
  """

  use PhoenixKitProjects.DataCase, async: false

  describe "permission_metadata/0" do
    test "returns the module key, label, icon, and description" do
      meta = PhoenixKitProjects.permission_metadata()
      assert meta.key == "projects"
      assert meta.label == "Projects"
      assert is_binary(meta.icon)
      assert is_binary(meta.description)
    end
  end

  describe "version/0" do
    test "matches the @version in mix.exs" do
      assert PhoenixKitProjects.version() == Mix.Project.config()[:version]
    end
  end

  describe "enable_system/0 + disable_system/0 round-trip" do
    test "enable_system/0 flips projects_enabled = true" do
      assert {:ok, _} = PhoenixKitProjects.enable_system()
      assert PhoenixKitProjects.enabled?() == true
    end

    test "disable_system/0 flips projects_enabled = false" do
      {:ok, _} = PhoenixKitProjects.enable_system()
      assert {:ok, _} = PhoenixKitProjects.disable_system()
      assert PhoenixKitProjects.enabled?() == false
    end
  end

  describe "admin_tabs/0 hidden subtabs" do
    test "exposes new + edit + show subtabs for tasks/projects/templates/assignments" do
      tabs = PhoenixKitProjects.admin_tabs()

      tab_ids = Enum.map(tabs, & &1.id)

      assert :admin_projects_task_new in tab_ids
      assert :admin_projects_task_edit in tab_ids
      assert :admin_projects_project_new in tab_ids
      assert :admin_projects_project_edit in tab_ids
      assert :admin_projects_project_show in tab_ids
      assert :admin_projects_template_new in tab_ids
      assert :admin_projects_template_edit in tab_ids
      assert :admin_projects_template_show in tab_ids
      assert :admin_projects_assignment_new in tab_ids
      assert :admin_projects_assignment_edit in tab_ids
      # The show page's alternate-view tabs (same LV, different live_action).
      assert :admin_projects_project_gantt in tab_ids
      assert :admin_projects_project_calendar in tab_ids
    end

    test "every hidden subtab has visible: false" do
      tabs = PhoenixKitProjects.admin_tabs()

      hidden =
        Enum.filter(
          tabs,
          &(String.contains?(Atom.to_string(&1.id), "_new") or
              String.contains?(Atom.to_string(&1.id), "_edit") or
              String.contains?(Atom.to_string(&1.id), "_show"))
        )

      assert Enum.all?(hidden, &(&1.visible == false))
    end
  end
end
