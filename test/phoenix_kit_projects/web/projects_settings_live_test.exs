defmodule PhoenixKitProjects.Web.ProjectsSettingsLiveTest do
  @moduledoc """
  Coverage for the global Projects settings page (`/admin/settings/projects`).

  Pins the three global-config mutations and their activity logging:
  set-default-status-entity, generate-default-list, and toggle-translations.
  `async: false` — `enable_entities!/0` flips a process-wide Settings/ETS cache.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import PhoenixKitProjects.StatusFixtures

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Statuses

  @path "/en/admin/settings/projects"

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "settings-actor-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))
    {:ok, conn: conn, actor_uuid: user.uuid}
  end

  describe "with entities enabled" do
    setup do
      entity = seed_shared_status_entity!()
      {:ok, entity: entity}
    end

    test "renders the workflow-statuses card with the default-list picker", %{conn: conn} do
      {:ok, _view, html} = live(conn, @path)
      assert html =~ "Workflow statuses"
      assert html =~ "Default status list"
      # The Generate button carries phx-disable-with (async UX guard).
      assert html =~ ~r/phx-click="generate_default_status_list"[^>]*phx-disable-with/s
    end

    test "select_default_status_entity clears the default + logs", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, view, _html} = live(conn, @path)

      view |> element("form") |> render_change(%{"entity_uuid" => ""})

      assert Statuses.global_default_status_entity_uuid() == nil

      assert_activity_logged("projects.default_status_entity_set",
        actor_uuid: actor_uuid
      )
    end

    test "select_default_status_entity sets a chosen entity + logs", %{
      conn: conn,
      entity: entity,
      actor_uuid: actor_uuid
    } do
      Statuses.set_default_status_entity(nil)
      {:ok, view, _html} = live(conn, @path)

      view |> element("form") |> render_change(%{"entity_uuid" => entity.uuid})

      assert Statuses.global_default_status_entity_uuid() == entity.uuid

      assert_activity_logged("projects.default_status_entity_set",
        actor_uuid: actor_uuid
      )
    end

    test "generate_default_status_list creates + selects an entity, logs provision", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, view, _html} = live(conn, @path)

      view |> element("button", "Generate default") |> render_click()

      new_uuid = Statuses.global_default_status_entity_uuid()
      assert new_uuid

      assert_activity_logged("projects.status_entity_provisioned",
        actor_uuid: actor_uuid,
        metadata_has: %{"scope" => "global_default"}
      )
    end

    test "toggle_status_translations flips the global flag + logs", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      before = Statuses.global_use_status_translations?()
      {:ok, view, _html} = live(conn, @path)

      view
      |> element("input[phx-click=toggle_status_translations]")
      |> render_click()

      assert Statuses.global_use_status_translations?() == not before

      assert_activity_logged("projects.status_translations_toggled",
        actor_uuid: actor_uuid
      )
    end
  end

  describe "with entities disabled" do
    setup do
      disable_entities!()
      :ok
    end

    test "renders the unavailable hint instead of the picker", %{conn: conn} do
      {:ok, _view, html} = live(conn, @path)
      assert html =~ "entities module is not enabled"
      refute html =~ ~r/name="entity_uuid"/
    end
  end
end
