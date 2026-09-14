defmodule PhoenixKitProjects.DashboardSlotsTest do
  @moduledoc """
  The two duck-typed contracts this module offers `phoenix_kit_dashboards`:
  `phoenix_kit_dashboard_slots/0` (the places a dashboard may be shown here)
  and `phoenix_kit_dashboard_viewer_context/2` (which record is "mine").

  Neither package depends on the other, so nothing but a test connects the two
  spellings. Pure shape checks live here (no DB, so plain `ExUnit.Case`); the
  resolver's actual "mine" behaviour and the widget field's `context:` key
  need real project/membership rows and live in
  `PhoenixKitProjects.Integration.DashboardSlotsTest`.
  """
  use ExUnit.Case, async: true

  @module_slot "projects.module"
  @record_slot "projects.project"

  defp slot(key),
    do: Enum.find(PhoenixKitProjects.phoenix_kit_dashboard_slots(), &(&1.key == key))

  test "exactly the two declared places, and no third appears by accident" do
    keys = Enum.map(PhoenixKitProjects.phoenix_kit_dashboard_slots(), & &1.key)
    assert Enum.sort(keys) == Enum.sort([@module_slot, @record_slot])
  end

  test "the sidebar slot hangs under a tab that actually exists" do
    parent = slot(@module_slot).parent_tab
    tab_ids = Enum.map(PhoenixKitProjects.admin_tabs(), & &1.id)

    assert parent in tab_ids,
           "parent_tab #{inspect(parent)} names no tab in admin_tabs/0 — core groups " <>
             "sub-tabs by parent id and drops an unknown parent without an error, so " <>
             "the sub-tab would simply never render"
  end

  test "both slots are gated on this module's own key" do
    assert slot(@module_slot).module_key == PhoenixKitProjects.module_key()
    assert slot(@record_slot).module_key == PhoenixKitProjects.module_key()
  end

  # The module-wide place is context-FREE on purpose: it is about every
  # project, so a widget asking for "the project this page is about" has
  # nothing to read there and must say so rather than pick one.
  test "the module slot provides no context; the record slot provides the project" do
    assert slot(@module_slot).provides == []
    assert slot(@record_slot).provides == [@record_slot]
  end

  test "a nil scope resolves to no project rather than guessing one" do
    assert PhoenixKitProjects.phoenix_kit_dashboard_viewer_context(@record_slot, nil) == nil
  end

  test "an unrecognised context kind resolves to nil rather than raising" do
    assert PhoenixKitProjects.phoenix_kit_dashboard_viewer_context("nonsense.kind", nil) == nil
  end
end
