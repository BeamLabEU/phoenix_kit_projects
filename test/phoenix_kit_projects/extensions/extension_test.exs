defmodule PhoenixKitProjects.Extensions.ExtensionTest do
  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Extensions.Extension

  defmodule FakeLive do
    use Phoenix.LiveView
    def render(assigns), do: ~H""
  end

  describe "from_map/2" do
    test "normalizes a full descriptor with atom keys" do
      assert {:ok, ext} =
               Extension.from_map(
                 %{
                   key: :demo,
                   name: "Demo",
                   description: "A demo",
                   icon: "hero-star",
                   module_key: :hello_world,
                   permission: "hello_world",
                   tabs: [%{key: "main", label: "Main", lv: FakeLive}],
                   config_schema: [
                     %{key: "company_uuid", type: :string, label: "Company"},
                     %{key: "mode", type: :select, label: "Mode", options: ["a", "b"]}
                   ],
                   feature_flags: [
                     %{key: "timers", label: "Timers", default: true, requires: ["ledger"]}
                   ],
                   permission_actions: [:do_things],
                   on_enable: {__MODULE__, :noop},
                   default_enabled: true
                 },
                 __MODULE__
               )

      assert ext.key == "demo"
      assert ext.name == "Demo"
      assert ext.module_key == "hello_world"
      assert [%{key: "main", label: "Main", lv: FakeLive}] = ext.tabs

      assert [%{key: "company_uuid", type: :string}, %{key: "mode", type: :select}] =
               ext.config_schema

      assert [%{key: "timers", default: true, requires: ["ledger"]}] = ext.feature_flags
      assert ext.on_enable == {__MODULE__, :noop}
      assert ext.default_enabled
      assert ext.data_retention == :keep
      assert ext.source == __MODULE__
    end

    test "string keys work (JSON-shaped providers)" do
      assert {:ok, ext} =
               Extension.from_map(%{"key" => "s", "name" => "S", "icon" => "hero-x"}, __MODULE__)

      assert ext.key == "s"
      assert ext.icon == "hero-x"
    end

    test "missing key or name rejects the whole extension" do
      assert {:error, {:missing_field, :key}} = Extension.from_map(%{name: "X"}, __MODULE__)
      assert {:error, {:missing_field, :name}} = Extension.from_map(%{key: "x"}, __MODULE__)
      assert {:error, :not_a_map} = Extension.from_map([], __MODULE__)
    end

    test "invalid tabs are dropped, not fatal" do
      assert {:ok, ext} =
               Extension.from_map(
                 %{
                   key: "t",
                   name: "T",
                   tabs: [
                     %{key: "ok", label: "Ok", lv: FakeLive},
                     %{key: "no_lv", label: "Broken"},
                     %{key: "ghost", label: "Ghost", lv: Not.A.Real.Module},
                     "not a map"
                   ]
                 },
                 __MODULE__
               )

      assert [%{key: "ok"}] = ext.tabs
    end

    test "a tab whose key is a project-page URL segment is dropped (it would deep-link elsewhere)" do
      assert {:ok, ext} =
               Extension.from_map(
                 %{
                   key: "t",
                   name: "T",
                   tabs: [
                     %{key: "boards", label: "Boards", lv: FakeLive},
                     %{key: "files", label: "Files", lv: FakeLive},
                     %{key: "tasks", label: "Tasks", lv: FakeLive},
                     %{key: "edit", label: "Edit", lv: FakeLive}
                   ]
                 },
                 __MODULE__
               )

      assert [%{key: "boards"}] = ext.tabs
      assert "comments" in Extension.reserved_tab_keys()
    end

    test "invalid schema fields and flags are dropped" do
      assert {:ok, ext} =
               Extension.from_map(
                 %{
                   key: "t",
                   name: "T",
                   config_schema: [
                     %{key: "ok", type: :string},
                     %{type: :string},
                     %{key: "bad", type: :exotic}
                   ],
                   feature_flags: [%{key: "ok"}, %{label: "keyless"}]
                 },
                 __MODULE__
               )

      assert [%{key: "ok"}] = ext.config_schema
      assert [%{key: "ok", default: false, requires: []}] = ext.feature_flags
    end

    test "invalid lifecycle callbacks are dropped with defaults intact" do
      assert {:ok, ext} =
               Extension.from_map(
                 %{key: "t", name: "T", on_enable: "not a tuple", on_disable: {1, 2, 3}},
                 __MODULE__
               )

      assert ext.on_enable == nil
      assert ext.on_disable == nil
    end

    test "unknown string keys never mint atoms" do
      # Assert the property DIRECTLY: after from_map processes an unknown
      # string key, that key must still not exist as an atom. (A previous
      # version measured the GLOBAL atom-count delta, which is order-fragile
      # — any module lazily loaded elsewhere during the window mints its
      # atoms and fails the test under unlucky suite compositions.)
      novel = "totally_novel_key_#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               Extension.from_map(%{"key" => "t", "name" => "T", novel => 1}, __MODULE__)

      assert_raise ArgumentError, fn -> String.to_existing_atom(novel) end
    end
  end

  def noop(_project_uuid, _config), do: :ok
end
