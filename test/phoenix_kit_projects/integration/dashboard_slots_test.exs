defmodule PhoenixKitProjects.Integration.DashboardSlotsTest do
  @moduledoc """
  The DB-backed half of the dashboard-slots contract (see
  `PhoenixKitProjects.DashboardSlotsTest` for the pure shape checks).

  `phoenix_kit_dashboard_viewer_context/2` is the "mine" resolver behind the
  `projects.project` slot: a drift between the kind it matches on and the
  kind `phoenix_kit_dashboard_slots/0` declares in `provides` would make
  every viewer bind fall through to the catch-all and silently resolve to
  `nil` for everyone — these tests exercise the actual resolve path with
  real membership rows, not just the clause head.
  """
  use PhoenixKitProjects.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{DashboardWidgets, Members}

  @record_slot "projects.project"

  defp user_fixture do
    {:ok, user} =
      Auth.register_user(%{
        email: "dash-viewer-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  test "a viewer who belongs to exactly one project resolves to it" do
    project = fixture_project()
    other = fixture_project()
    user = user_fixture()

    {:ok, _} = Members.add_member(project, user.uuid, role: "member")

    scope =
      PhoenixKitProjects.LiveCase.fake_scope(user_uuid: user.uuid, permissions: ["projects"])

    assert PhoenixKitProjects.phoenix_kit_dashboard_viewer_context(@record_slot, scope) ==
             project.uuid

    refute PhoenixKitProjects.phoenix_kit_dashboard_viewer_context(@record_slot, scope) ==
             other.uuid
  end

  test "a viewer who belongs to more than one project resolves to nil, not a guess" do
    project_a = fixture_project()
    project_b = fixture_project()
    user = user_fixture()

    {:ok, _} = Members.add_member(project_a, user.uuid, role: "member")
    {:ok, _} = Members.add_member(project_b, user.uuid, role: "member")

    scope =
      PhoenixKitProjects.LiveCase.fake_scope(user_uuid: user.uuid, permissions: ["projects"])

    assert PhoenixKitProjects.phoenix_kit_dashboard_viewer_context(@record_slot, scope) == nil
  end

  test "an admin scope resolves to nil once more than one project exists site-wide" do
    fixture_project()
    fixture_project()

    scope = PhoenixKitProjects.LiveCase.fake_scope()

    assert PhoenixKitProjects.phoenix_kit_dashboard_viewer_context(@record_slot, scope) == nil
  end

  test "the project widget field still declares the context kind it binds to" do
    field =
      DashboardWidgets.all()
      |> Enum.flat_map(&(&1[:settings_schema] || []))
      |> Enum.find(&(&1[:context] == @record_slot))

    assert field,
           "no widget settings field declares context: #{inspect(@record_slot)} — without " <>
             "it the host stops offering \"the one this page is about\" as a bind source " <>
             "and one shared board silently reverts to a copy per project"
  end
end
