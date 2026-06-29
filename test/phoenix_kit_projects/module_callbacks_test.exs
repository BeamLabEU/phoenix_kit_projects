defmodule PhoenixKitProjects.ModuleCallbacksTest do
  @moduledoc """
  Pinning tests for the `PhoenixKit.Module` callbacks plus structural
  invariants of the top-level module.
  """

  use ExUnit.Case, async: true

  describe "enabled?/0" do
    test "returns false when settings table is unavailable (rescue branch)" do
      # Standalone unit context — no test repo started. The
      # `Settings.get_boolean_setting/2` call will fail at the DB layer;
      # the `rescue _ -> false` clause must catch it.
      assert PhoenixKitProjects.enabled?() == false
    end

    test "source includes `catch :exit, _ -> false` for sandbox-shutdown trap" do
      # Per workspace AGENTS.md "Known flaky-test traps" — `enabled?/0`
      # must catch `:exit` signals raised when a sandbox owner has just
      # stopped, not just rescue exceptions. The `Settings.get_boolean_setting`
      # path under DB-shutdown surfaces as `{:exit, ...}` from the pool
      # checkout, which `rescue` doesn't catch. Source-pairing test
      # because exercising the runtime `:exit` path requires hooking into
      # core's pool shutdown — the source pin guarantees the safeguard
      # stays in place.
      source = File.read!("lib/phoenix_kit_projects.ex")
      assert source =~ ~r/catch\s*\n\s*:exit,\s*_\s*->\s*false/
    end
  end

  describe "module callbacks" do
    test "module_key/0 returns \"projects\"" do
      assert PhoenixKitProjects.module_key() == "projects"
    end

    test "module_name/0 returns \"Projects\"" do
      assert PhoenixKitProjects.module_name() == "Projects"
    end

    test "version/0 matches @version in mix.exs" do
      mix_version = Mix.Project.config()[:version]
      assert PhoenixKitProjects.version() == mix_version
    end

    test "css_sources/0 includes the module and the chart deps" do
      # :phoenix_live_gantt (Timeline tab) and :phoenix_live_calendar (Overview
      # calendar) are included so the host's Tailwind scans their classes via
      # core's css-sources compiler.
      assert PhoenixKitProjects.css_sources() == [
               :phoenix_kit_projects,
               :phoenix_live_gantt,
               :phoenix_live_calendar
             ]
    end

    test "js_sources/0 declares the gantt + schedule hook bundles" do
      # Pins the bundles core's :phoenix_kit_js_sources compiler wires into
      # the host LiveSocket (gantt Timeline hooks + schedule enhancement hooks).
      assert PhoenixKitProjects.js_sources() == [
               %{
                 app: :phoenix_live_gantt,
                 file: "static/assets/phoenix_live_gantt.js",
                 global: "PhoenixLiveGanttHooks"
               },
               %{
                 app: :phoenix_live_calendar,
                 file: "static/assets/phoenix_live_calendar.js",
                 global: "PhoenixLiveCalendarHooks"
               }
             ]
    end

    test "permission_metadata/0 returns the projects key + label" do
      assert %{key: "projects", label: "Projects"} = PhoenixKitProjects.permission_metadata()
    end

    test "admin_tabs/0 returns a list of tabs all permissioned on \"projects\"" do
      tabs = PhoenixKitProjects.admin_tabs()
      refute Enum.empty?(tabs)
      assert Enum.all?(tabs, &(&1.permission == "projects"))
    end
  end
end
