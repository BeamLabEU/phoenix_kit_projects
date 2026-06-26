defmodule PhoenixKitProjects.GanttDisplay do
  @moduledoc """
  Global display settings for the projects Gantt/Timeline chart.

  Stored as plain `PhoenixKit.Settings` key/values and read back as the attr map
  `PhoenixLiveGantt.gantt/1` takes (bar labels, what to show, bar sizing, and
  dependency-arrow routing). Configured on `/admin/settings/projects` (with a
  live demo) and consumed by `PhoenixKitProjects.Web.ProjectGanttLive`.

  All settings are presentation-only and validated on the way in (enums against
  an allowed set, ratios/ints clamped to range), so a malformed or unconfigured
  install always resolves to safe defaults that match the behavior that shipped
  before this was configurable.
  """

  @module "projects"

  # Labels
  @position_key "projects_gantt_label_position"
  @side_key "projects_gantt_label_side"
  @overflow_key "projects_gantt_label_overflow"
  @fit_ratio_key "projects_gantt_label_fit_ratio"
  @watermark_opacity_key "projects_gantt_label_watermark_opacity"

  # Display toggles (booleans). `tiny_markers` maps to the lib's `tiny_bar_px`
  # (the down-triangle for too-small-to-see tasks): on = 5px threshold, off = 0.
  @progress_key "projects_gantt_show_progress"
  @connectors_key "projects_gantt_show_connectors"
  @today_key "projects_gantt_show_today"
  @tiny_key "projects_gantt_tiny_markers"

  # Bars + dependency arrows
  @min_bar_key "projects_gantt_min_bar_px"
  @row_height_key "projects_gantt_row_height"
  @avoid_collisions_key "projects_gantt_avoid_collisions"
  @attach_key "projects_gantt_attach_mode"

  @tiny_bar_px 5
  @min_bar_max 8

  @positions ~w(none inside outside fit watermark)
  @sides ~w(auto left right)
  @overflows ~w(truncate clip visible)
  @row_heights ~w(compact normal comfortable)
  @attach_modes ~w(smart type_zoned center)

  # Defaults (match the behavior that shipped before this was configurable).
  # `read/0` falls back to these and `reset/0` writes them.
  @default_position "fit"
  @default_side "auto"
  @default_overflow "truncate"
  @default_fit_ratio 0.4
  @default_watermark_opacity 0.5
  @default_min_bar 0
  @default_row_height "normal"
  @default_attach "smart"
  @bool_flags ~w(show_progress show_connectors show_today tiny_markers avoid_collisions)

  @doc "Allowed string values for each enum field (used to build the settings form)."
  def positions, do: @positions
  def sides, do: @sides
  def overflows, do: @overflows
  def row_heights, do: @row_heights
  def attach_modes, do: @attach_modes
  def min_bar_max, do: @min_bar_max

  @doc """
  All label settings as the attr map `PhoenixLiveGantt.gantt/1` takes
  (`label_position` etc., as atoms/floats).
  """
  @spec read() :: %{
          label_position: atom(),
          label_side: atom(),
          label_overflow: atom(),
          label_fit_ratio: float(),
          label_watermark_opacity: float(),
          show_progress: boolean(),
          show_connectors: boolean(),
          show_today: boolean(),
          tiny_markers: boolean(),
          tiny_bar_px: non_neg_integer(),
          min_bar_px: non_neg_integer(),
          row_height_choice: atom(),
          row_height: String.t(),
          avoid_collisions: boolean(),
          bus_attach_mode: atom()
        }
  def read do
    tiny = flag(@tiny_key, true)
    row_choice = enum(@row_height_key, @row_heights, @default_row_height)

    %{
      label_position: enum(@position_key, @positions, @default_position),
      label_side: enum(@side_key, @sides, @default_side),
      label_overflow: enum(@overflow_key, @overflows, @default_overflow),
      label_fit_ratio: ratio(@fit_ratio_key, @default_fit_ratio),
      label_watermark_opacity: ratio(@watermark_opacity_key, @default_watermark_opacity),
      show_progress: flag(@progress_key, true),
      show_connectors: flag(@connectors_key, true),
      show_today: flag(@today_key, true),
      # `tiny_markers` is the boolean for the form/toggle; `tiny_bar_px` is the
      # px attr the gantt takes (0 = off).
      tiny_markers: tiny,
      tiny_bar_px: if(tiny, do: @tiny_bar_px, else: 0),
      min_bar_px: int_clamped(@min_bar_key, @default_min_bar, 0, @min_bar_max),
      # `row_height_choice` (atom) drives the form select; `row_height` is the CSS
      # dimension the gantt takes.
      row_height_choice: row_choice,
      row_height: row_height_rem(row_choice),
      avoid_collisions: flag(@avoid_collisions_key, true),
      bus_attach_mode: enum(@attach_key, @attach_modes, @default_attach)
    }
  end

  @doc "Restore every Gantt display setting to its default."
  @spec reset() :: :ok
  def reset do
    put("label_position", @default_position)
    put("label_side", @default_side)
    put("label_overflow", @default_overflow)
    put("label_fit_ratio", to_string(@default_fit_ratio))
    put("label_watermark_opacity", to_string(@default_watermark_opacity))
    put("min_bar_px", to_string(@default_min_bar))
    put("row_height", @default_row_height)
    put("bus_attach_mode", @default_attach)
    Enum.each(@bool_flags, &put_flag(&1, true))
    :ok
  end

  @doc """
  Persist one setting from its string form. The field name matches `read/0`'s
  keys (`"label_position"`, `"label_fit_ratio"`, …). Enums must be in the allowed
  set and ratios are clamped to `0.0..1.0`; anything else is ignored (returns
  `:ignore`) so a stray form field can't write garbage.
  """
  @spec put(String.t(), String.t()) :: term()
  def put("label_position", v), do: put_enum(@position_key, v, @positions)
  def put("label_side", v), do: put_enum(@side_key, v, @sides)
  def put("label_overflow", v), do: put_enum(@overflow_key, v, @overflows)
  def put("label_fit_ratio", v), do: put_ratio(@fit_ratio_key, v)
  def put("label_watermark_opacity", v), do: put_ratio(@watermark_opacity_key, v)
  def put("min_bar_px", v), do: put_int(@min_bar_key, v, 0, @min_bar_max)
  def put("row_height", v), do: put_enum(@row_height_key, v, @row_heights)
  def put("bus_attach_mode", v), do: put_enum(@attach_key, v, @attach_modes)
  def put(_field, _value), do: :ignore

  @doc """
  Persist one boolean display toggle (`"show_progress"`, `"show_connectors"`,
  `"show_today"`, `"tiny_markers"`, `"avoid_collisions"`). Anything else is ignored.
  """
  @spec put_flag(String.t(), boolean()) :: term()
  def put_flag("show_progress", on?), do: put_bool(@progress_key, on?)
  def put_flag("show_connectors", on?), do: put_bool(@connectors_key, on?)
  def put_flag("show_today", on?), do: put_bool(@today_key, on?)
  def put_flag("tiny_markers", on?), do: put_bool(@tiny_key, on?)
  def put_flag("avoid_collisions", on?), do: put_bool(@avoid_collisions_key, on?)
  def put_flag(_field, _on?), do: :ignore

  # ── internals ───────────────────────────────────────────────────

  defp enum(key, allowed, default) do
    value = PhoenixKit.Settings.get_setting(key, default)
    valid = if value in allowed, do: value, else: default
    # `valid` is always one of the fixed allowed strings, so `to_atom` is bounded
    # (and safe) — and unlike `to_existing_atom` it doesn't depend on the gantt
    # module already being loaded to have minted the atom.
    String.to_atom(valid)
  end

  defp ratio(key, default) do
    case Float.parse(PhoenixKit.Settings.get_setting(key, to_string(default))) do
      {f, _} -> clamp_ratio(f)
      :error -> default
    end
  end

  defp put_enum(key, value, allowed) do
    if value in allowed,
      do: PhoenixKit.Settings.update_setting_with_module(key, value, @module),
      else: :ignore
  end

  defp put_ratio(key, value) do
    case Float.parse(to_string(value)) do
      {f, _} ->
        PhoenixKit.Settings.update_setting_with_module(key, to_string(clamp_ratio(f)), @module)

      :error ->
        :ignore
    end
  end

  defp clamp_ratio(f), do: f |> max(0.0) |> min(1.0)

  defp int_clamped(key, default, lo, hi) do
    case Integer.parse(PhoenixKit.Settings.get_setting(key, to_string(default))) do
      {n, _} -> n |> max(lo) |> min(hi)
      :error -> default
    end
  end

  defp put_int(key, value, lo, hi) do
    case Integer.parse(to_string(value)) do
      {n, _} ->
        PhoenixKit.Settings.update_setting_with_module(
          key,
          to_string(n |> max(lo) |> min(hi)),
          @module
        )

      :error ->
        :ignore
    end
  end

  defp row_height_rem(:compact), do: "2rem"
  defp row_height_rem(:comfortable), do: "3rem"
  defp row_height_rem(_normal), do: "2.5rem"

  defp flag(key, default), do: PhoenixKit.Settings.get_boolean_setting(key, default)

  defp put_bool(key, on?) when is_boolean(on?),
    do: PhoenixKit.Settings.update_boolean_setting_with_module(key, on?, @module)

  defp put_bool(_key, _other), do: :ignore
end
