defmodule PhoenixKitProjects.Web.ProjectModulesLiveTest do
  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Extensions
  alias PhoenixKitProjects.Extensions.Registry
  alias PhoenixKitProjects.Features

  setup %{conn: conn} do
    Registry.refresh()
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    project = fixture_project()
    {:ok, conn: conn, project: project, scope: scope}
  end

  test "renders the panel: built-in tasks toggle, flags, presets", %{conn: conn, project: project} do
    {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/modules")

    assert html =~ "Modules &amp; features"
    assert html =~ "Tasks"
    assert html =~ "Workflow statuses"
    assert html =~ "Simple to-do list"
  end

  test "toggle_ext flips the tasks extension off and back", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}/modules")

    assert Extensions.enabled?(project, "tasks")

    view |> element("input[phx-value-key='tasks'][phx-click='toggle_ext']") |> render_click()
    refute Extensions.enabled?(project, "tasks")

    view |> element("input[phx-value-key='tasks'][phx-click='toggle_ext']") |> render_click()
    assert Extensions.enabled?(project, "tasks")
  end

  test "toggle_flag writes an explicit value", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}/modules")

    assert Features.on?(project, "assignees")
    view |> element("input[phx-value-key='assignees'][phx-click='toggle_flag']") |> render_click()
    refute Features.on?(project.uuid, "assignees")
  end

  test "dependency matrix disables dependents and explains", %{conn: conn, project: project} do
    {:ok, _} = Features.set_flags(project, %{"scheduling" => false})

    {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/modules")

    # view_timeline's toggle is disabled with the explanation visible.
    assert html =~ "Requires:"

    assert [_ | _] =
             Regex.scan(
               ~r/<input[^>]*phx-value-key="view_timeline"[^>]*disabled[^>]*>|<input[^>]*disabled[^>]*phx-value-key="view_timeline"[^>]*>/,
               html
             )
  end

  test "apply_preset simple flips the feature set", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}/modules")

    view |> element("button[phx-value-key='simple'][phx-click='apply_preset']") |> render_click()

    refute Features.on?(project.uuid, "assignees")
    refute Features.on?(project.uuid, "view_calendar")
  end

  test "a scope without the projects permission is bounced", %{project: project} do
    conn =
      Phoenix.ConnTest.build_conn()
      |> put_test_scope(fake_scope(permissions: []))

    {:error, {:live_redirect, %{to: to}}} =
      live(conn, "/en/admin/projects/#{project.uuid}/modules")

    assert to =~ "/admin/projects"
  end

  test "unknown project bounces with a flash", %{conn: conn} do
    {:error, {:live_redirect, %{to: to}}} =
      live(conn, "/en/admin/projects/#{Ecto.UUID.generate()}/modules")

    assert to =~ "/admin/projects"
  end

  defmodule SelectProvider do
    def phoenix_kit_project_extensions do
      [
        %{
          key: "select_ext",
          name: "Select Ext",
          default_enabled: false,
          config_schema: [
            %{key: "picked", type: :select, label: "Pick one", options: {__MODULE__, :options}},
            %{key: "plain", type: :string, label: "Plain"}
          ]
        }
      ]
    end

    def options do
      [%{value: "uuid-a", label: "Board A"}, %{value: "uuid-b", label: "Board B"}]
    end
  end

  describe ":select config fields" do
    setup %{project: project} do
      Application.put_env(:phoenix_kit_projects, :extension_providers, [SelectProvider])
      Registry.refresh()

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_projects, :extension_providers)
        Registry.refresh()
      end)

      {:ok, _} = Extensions.enable(project, "select_ext")
      :ok
    end

    test "renders a <select> with the provider's lazy options (and text for the rest)",
         %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/modules")

      assert html =~ ~s(<select)
      assert html =~ "Board A"
      assert html =~ "Board B"
      # The sibling non-select field still renders a text input.
      assert html =~ ~s(name="config[plain]")
    end

    test "save_config round-trips the picked value", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}/modules")

      view
      |> form("#ext-config-select_ext", %{"config" => %{"picked" => "uuid-b"}})
      |> render_submit()

      assert {_ext, %{config: %{"picked" => "uuid-b"}}} =
               project.uuid
               |> Extensions.enabled_for_project()
               |> Enum.find(fn {ext, _row} -> ext.key == "select_ext" end)
    end

    test "a stored value the provider no longer offers stays visible",
         %{conn: conn, project: project} do
      {:ok, _} = Extensions.update_config(project, "select_ext", %{"picked" => "uuid-gone"})

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/modules")

      assert html =~ "uuid-gone"
      assert html =~ "Current value (unavailable)"
    end
  end
end
