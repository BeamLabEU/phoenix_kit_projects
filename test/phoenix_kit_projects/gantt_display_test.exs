defmodule PhoenixKitProjects.GanttDisplayTest do
  @moduledoc """
  The global Gantt-label display settings (read/validate/persist).

  `async: false` — settings live in the process-wide `PhoenixKit.Settings`
  ETS cache, which isn't sandbox-isolated.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.GanttDisplay

  test "read/0 returns the full attr map with sane types" do
    d = GanttDisplay.read()

    assert d.label_position in [:none, :inside, :outside, :fit, :watermark]
    assert d.label_side in [:auto, :left, :right]
    assert d.label_overflow in [:truncate, :clip, :visible]
    assert is_float(d.label_fit_ratio)
    assert is_float(d.label_watermark_opacity)
    assert is_boolean(d.show_progress)
    assert is_boolean(d.show_connectors)
    assert is_boolean(d.show_today)
    assert is_boolean(d.tiny_markers)
    # tiny_markers and the px attr the gantt takes stay in sync
    assert d.tiny_bar_px == if(d.tiny_markers, do: 5, else: 0)
    assert is_integer(d.min_bar_px)
    assert d.row_height_choice in [:compact, :normal, :comfortable]
    assert d.row_height in ["2rem", "2.5rem", "3rem"]
    assert is_boolean(d.avoid_collisions)
    assert d.bus_attach_mode in [:smart, :type_zoned, :center]
  end

  test "min_bar_px is parsed as an int and clamped to 0..max" do
    GanttDisplay.put("min_bar_px", "4")
    assert GanttDisplay.read().min_bar_px == 4

    GanttDisplay.put("min_bar_px", "999")
    assert GanttDisplay.read().min_bar_px == GanttDisplay.min_bar_max()

    GanttDisplay.put("min_bar_px", "-2")
    assert GanttDisplay.read().min_bar_px == 0

    assert GanttDisplay.put("min_bar_px", "abc") == :ignore
  end

  test "row_height maps the choice to a CSS dimension; attach mode round-trips" do
    GanttDisplay.put("row_height", "comfortable")
    d = GanttDisplay.read()
    assert d.row_height_choice == :comfortable
    assert d.row_height == "3rem"

    GanttDisplay.put("bus_attach_mode", "center")
    assert GanttDisplay.read().bus_attach_mode == :center
  end

  test "put_flag toggles a display boolean (and keeps tiny_bar_px in sync)" do
    GanttDisplay.put_flag("show_progress", false)
    refute GanttDisplay.read().show_progress

    GanttDisplay.put_flag("show_progress", true)
    assert GanttDisplay.read().show_progress

    GanttDisplay.put_flag("tiny_markers", false)
    d = GanttDisplay.read()
    refute d.tiny_markers
    assert d.tiny_bar_px == 0

    assert GanttDisplay.put_flag("bogus_flag", true) == :ignore
  end

  test "put/read round-trips a valid enum value (as an atom)" do
    GanttDisplay.put("label_position", "watermark")
    assert GanttDisplay.read().label_position == :watermark

    GanttDisplay.put("label_position", "outside")
    assert GanttDisplay.read().label_position == :outside
  end

  test "an invalid enum value is ignored, keeping the prior valid one" do
    GanttDisplay.put("label_position", "fit")
    assert GanttDisplay.put("label_position", "bogus") == :ignore
    assert GanttDisplay.read().label_position == :fit
  end

  test "ratios are clamped to 0.0..1.0" do
    GanttDisplay.put("label_fit_ratio", "1.5")
    assert GanttDisplay.read().label_fit_ratio == 1.0

    GanttDisplay.put("label_fit_ratio", "-0.3")
    assert GanttDisplay.read().label_fit_ratio == 0.0

    GanttDisplay.put("label_fit_ratio", "0.35")
    assert GanttDisplay.read().label_fit_ratio == 0.35
  end

  test "an unparseable ratio and an unknown field are ignored" do
    assert GanttDisplay.put("label_watermark_opacity", "abc") == :ignore
    assert GanttDisplay.put("not_a_field", "x") == :ignore
  end

  test "reset/0 restores every field to its default" do
    # move everything off its default
    GanttDisplay.put("label_position", "watermark")
    GanttDisplay.put("label_side", "left")
    GanttDisplay.put("label_overflow", "clip")
    GanttDisplay.put("label_fit_ratio", "0.9")
    GanttDisplay.put("label_watermark_opacity", "0.1")
    GanttDisplay.put("min_bar_px", "8")
    GanttDisplay.put("row_height", "comfortable")
    GanttDisplay.put("bus_attach_mode", "center")
    GanttDisplay.put_flag("show_progress", false)
    GanttDisplay.put_flag("avoid_collisions", false)

    assert GanttDisplay.reset() == :ok

    d = GanttDisplay.read()
    assert d.label_position == :fit
    assert d.label_side == :auto
    assert d.label_overflow == :truncate
    assert d.label_fit_ratio == 0.4
    assert d.label_watermark_opacity == 0.5
    assert d.min_bar_px == 0
    assert d.row_height_choice == :normal
    assert d.bus_attach_mode == :smart
    assert d.show_progress
    assert d.show_connectors
    assert d.show_today
    assert d.tiny_markers
    assert d.avoid_collisions
  end
end
