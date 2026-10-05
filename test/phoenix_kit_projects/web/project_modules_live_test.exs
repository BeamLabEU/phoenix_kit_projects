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

  describe "API access" do
    alias PhoenixKitProjects.ApiKeys

    test "a key made from the panel with the Read-only preset and a 30-day expiry, then the token modal",
         %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}/modules")
      assert html =~ "No keys yet"
      assert html =~ "/api/projects/v1/llms.txt"
      assert html =~ "/api/projects/v1/openapi.json"
      refute html =~ "project-api-key-add-"

      html = render_click(view, "toggle_api_key_form", %{})
      assert html =~ "project-api-key-add-"
      assert html =~ "Full access"

      render_change(view, "api_key_form_change", %{"name" => "Reader", "preset" => "read"})

      html =
        render_submit(view, "create_api_key", %{
          "name" => "Reader",
          "role" => "member",
          "preset" => "read",
          "expires" => "30"
        })

      assert [key] = ApiKeys.list_for_project(project.uuid)
      assert key.name == "Reader"
      assert key.scopes == Enum.filter(key.scopes, &String.ends_with?(&1, ":read"))
      assert key.scopes != []
      assert DateTime.diff(key.expires_at, DateTime.utc_now(), :day) in 29..30

      # the modal: token, the prompt with the token embedded, the links
      assert html =~ "Key created — copy it now"
      assert html =~ ~s(id="api-token-value")
      assert html =~ "pkp_#{key.key_id}_"
      assert html =~ ~s(id="api-token-prompt")
      assert html =~ "Agent guide (read it first)"
      assert html =~ "Done — I saved it"

      html = render_click(view, "dismiss_api_token", %{})
      refute html =~ "api-token-value"

      # the row: the ID without an ellipsis, the preset word, no stacked scopes
      assert html =~ "ID pkp_#{key.key_id}"
      refute html =~ "pkp_#{key.key_id}_…"
      assert html =~ "Read-only ·"
      assert html =~ "Never used"
      assert html =~ "Expires"
      # the row's own prompt, token's place held
      assert html =~ ~s(id="api-key-prompt-#{key.uuid}")
      assert html =~ "Copy setup prompt"
      # the panel closed on success
      refute html =~ "project-api-key-add-"
    end

    test "a key minted for a member acts for them; the row says so", %{
      conn: conn,
      project: project
    } do
      alias PhoenixKit.Users.Auth
      alias PhoenixKitProjects.Members

      {:ok, user} =
        Auth.register_user(%{
          email: "for-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!",
          first_name: "Maria",
          last_name: "Kottel"
        })

      {:ok, _} = Members.add_member(project, user.uuid, role: "member")

      {:ok, view, _} = live(conn, "/en/admin/projects/#{project.uuid}/modules")
      html = render_click(view, "toggle_api_key_form", %{})
      assert html =~ "Nobody — a shared agent"
      # the person's NAME is what the select shows; the uuid is what it posts
      assert html =~ ~s(<option value="#{user.uuid}">Maria Kottel</option>)

      html =
        render_submit(view, "create_api_key", %{
          "name" => "Maria's AI",
          "user" => user.uuid,
          "role" => "member",
          "preset" => "full",
          "expires" => "never"
        })

      assert [key] = ApiKeys.list_for_project(project.uuid)
      assert key.user_uuid == user.uuid
      assert html =~ "Personal · acts for Maria Kottel"
      assert html =~ "You act for Maria Kottel on this project"

      # a uuid that is not a member's is ignored: the key is a shared agent
      render_submit(view, "create_api_key", %{
        "name" => "Bot",
        "user" => Ecto.UUID.generate(),
        "role" => "member",
        "preset" => "full",
        "expires" => "never"
      })

      assert bot = Enum.find(ApiKeys.list_for_project(project.uuid), &(&1.name == "Bot"))
      assert bot.user_uuid == nil
      assert render(view) =~ "Shared agent"
    end

    test "revoked keys are hidden until asked for", %{conn: conn, project: project} do
      {:ok, live_key, _} = ApiKeys.create(project, %{"name" => "Live one"})
      {:ok, gone, _} = ApiKeys.create(project, %{"name" => "Old one"})
      {:ok, _} = ApiKeys.revoke(gone, [])

      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}/modules")
      assert html =~ "Live one"
      refute html =~ "Old one"
      assert html =~ "Show revoked keys (1)"
      assert html =~ ~s(id="api-key-menu-#{live_key.uuid}")

      html = render_click(view, "toggle_revoked_keys", %{})
      assert html =~ "Old one"
      assert html =~ "Hide revoked keys"
      refute html =~ ~s(id="api-key-menu-#{gone.uuid}")
    end
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
