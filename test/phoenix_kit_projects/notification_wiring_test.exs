defmodule PhoenixKitProjects.NotificationWiringTest do
  @moduledoc """
  Step 7: the notification seams — the `notification_types/0` declaration
  core's prefs UI consumes, and the assignee→target_uuid resolver that
  makes task activity reach core's activity→notification bridge.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.Activity

  describe "notification_types/0" do
    test "declares the projects type with dotted-composable sub-types" do
      assert [type] = PhoenixKitProjects.notification_types()
      assert type.key == "projects"
      assert type.default == true

      subs = Map.new(type.sub_types, &{&1.key, &1})

      assert "projects.member_added" in subs["membership"].actions
      assert "projects.assignment_completed" in subs["tasks"].actions
      assert "projects.health_updated" in subs["health"].actions

      # Sub keys are declared BARE (core's Types.normalize/1 composes the
      # dotted form) and contain no dots themselves.
      refute Enum.any?(type.sub_types, &String.contains?(&1.key, "."))
    end

    test "every declared action is one this module actually emits" do
      # The declared actions must stay in sync with the emitting call sites
      # — a renamed action would silently orphan the preference toggle.
      [type] = PhoenixKitProjects.notification_types()
      declared = Enum.flat_map(type.sub_types, & &1.actions)

      source =
        [
          "lib/phoenix_kit_projects/members.ex",
          "lib/phoenix_kit_projects/health.ex",
          "lib/phoenix_kit_projects/web/project_show_live.ex",
          "lib/phoenix_kit_projects/web/assignment_form_live.ex",
          "lib/phoenix_kit_projects/project_events.ex"
        ]
        |> Enum.map_join("\n", &File.read!/1)

      for action <- declared do
        assert source =~ ~s("#{action}") or source =~ ~s(#{action}"),
               "declared action #{action} has no emitting call site"
      end
    end
  end

  describe "assignee_target_uuid/1" do
    test "resolves a preloaded person's linked user" do
      assert Activity.assignee_target_uuid(%{assigned_person: %{user_uuid: "u-1"}}) == "u-1"
    end

    test "nil-safe on every degraded shape" do
      assert Activity.assignee_target_uuid(nil) == nil
      assert Activity.assignee_target_uuid(%{}) == nil
      assert Activity.assignee_target_uuid(%{assigned_person: nil}) == nil
      assert Activity.assignee_target_uuid(%{assigned_person: %{user_uuid: nil}}) == nil
      # Unknown person uuid: lookup path degrades to nil, never raises.
      assert Activity.assignee_target_uuid(%{assigned_person_uuid: Ecto.UUID.generate()}) == nil
    end
  end
end
