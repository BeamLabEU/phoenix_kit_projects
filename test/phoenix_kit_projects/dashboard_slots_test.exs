defmodule PhoenixKitProjects.DashboardSlotsTest do
  @moduledoc """
  The two duck-typed contracts this module offers `phoenix_kit_dashboards`:
  `phoenix_kit_dashboard_slots/0` (the places a dashboard may be shown here)
  and `phoenix_kit_dashboard_viewer_context/2` (which record is "mine").

  Neither package depends on the other, so nothing but a test connects the two
  spellings. Three things can therefore vanish in silence, all of them
  user-visible and none of them a compile error: a typo'd `parent_tab` (core
  groups sub-tabs by parent id and drops an unknown one without complaint), a
  `provides` kind that drifts from the `viewer_context` clause head (every
  viewer bind then resolves to `nil` and renders "pick a project"), and the
  `context:` key on the widget's project field (drop it and the field stops
  being offered a bind source, quietly reverting one shared board to a copy
  per project).
  """
  use ExUnit.Case, async: true

  alias PhoenixKitProjects.DashboardWidgets

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

  test "the kind the record slot provides is the kind viewer_context answers for" do
    [kind] = slot(@record_slot).provides

    # Not a value assertion — the point is that the clause HEAD matches. A
    # drift here makes every viewer bind fall through to the catch-all.
    assert PhoenixKitProjects.phoenix_kit_dashboard_viewer_context(kind, nil) == nil
    assert PhoenixKitProjects.phoenix_kit_dashboard_viewer_context("nonsense.kind", nil) == nil
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

  test "a nil scope resolves to no project rather than guessing one" do
    assert PhoenixKitProjects.phoenix_kit_dashboard_viewer_context(@record_slot, nil) == nil
  end
end
