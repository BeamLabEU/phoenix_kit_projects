defmodule PhoenixKitProjects.Extensions.RegistryTest do
  # persistent_term is global — refresh/0 collides across async files.
  use ExUnit.Case, async: false

  alias PhoenixKitProjects.Extensions.Extension
  alias PhoenixKitProjects.Extensions.Registry
  alias PhoenixKitProjects.LiveCase

  defmodule HostProvider do
    def phoenix_kit_project_extensions do
      [
        %{key: "host_ext", name: "Host Extension"},
        %{name: "invalid — no key"}
      ]
    end
  end

  defmodule RaisingProvider do
    def phoenix_kit_project_extensions, do: raise("boom")
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_projects, :extension_providers)
      Registry.refresh()
    end)

    :ok
  end

  test "the built-in tasks extension is always in the catalog" do
    Registry.refresh()

    assert %{key: "tasks", default_enabled: true, source: PhoenixKitProjects} =
             Registry.get("tasks")
  end

  test "config providers are discovered; invalid entries dropped; unknown keys nil" do
    Application.put_env(:phoenix_kit_projects, :extension_providers, [HostProvider])
    Registry.refresh()

    assert %{key: "host_ext", name: "Host Extension", source: HostProvider} =
             Registry.get("host_ext")

    assert Registry.get("nope") == nil
    refute Enum.any?(Registry.list(), &(&1.name == "invalid — no key"))
  end

  test "a raising provider is skipped without poisoning the catalog" do
    Application.put_env(:phoenix_kit_projects, :extension_providers, [
      RaisingProvider,
      HostProvider
    ])

    Registry.refresh()
    assert Registry.get("host_ext")
    assert Registry.get("tasks")
  end

  test "duplicate keys keep the first registration" do
    defmodule DupProvider do
      def phoenix_kit_project_extensions, do: [%{key: "tasks", name: "Impostor Tasks"}]
    end

    Application.put_env(:phoenix_kit_projects, :extension_providers, [DupProvider])
    Registry.refresh()

    # PhoenixKitProjects registers first — the impostor is dropped.
    assert Registry.get("tasks").name == "Tasks"
  end

  test "available?/1 — nil module_key is always available" do
    Registry.refresh()
    assert Registry.available?(Registry.get("tasks"))
  end

  test "visible_for_scope?/2 resolves permission -> module_key -> projects" do
    {:ok, base} = Extension.from_map(%{key: "vis_test", name: "Vis"}, __MODULE__)

    projects_scope = LiveCase.fake_scope(permissions: ["projects"])
    both_scope = LiveCase.fake_scope(permissions: ["projects", "crm"])

    # No permission, no module_key: rides the hub's own permission.
    assert Registry.visible_for_scope?(base, projects_scope)

    refute Registry.visible_for_scope?(
             base,
             LiveCase.fake_scope(permissions: [])
           )

    # Explicit permission wins: a projects-only viewer is refused
    # (final panel — sibling tabs must not leak on the hub permission).
    sibling = %{base | permission: "crm"}
    refute Registry.visible_for_scope?(sibling, projects_scope)
    assert Registry.visible_for_scope?(sibling, both_scope)
  end

  test "visible_for_scope?/2 fails closed on nil scope" do
    Registry.refresh()
    refute Registry.visible_for_scope?(Registry.get("tasks"), nil)
  end
end
