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
  alias PhoenixKitProjects.GanttDisplay
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

      view
      |> element(~s(form[phx-change="select_default_status_entity"]))
      |> render_change(%{"entity_uuid" => ""})

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

      view
      |> element(~s(form[phx-change="select_default_status_entity"]))
      |> render_change(%{"entity_uuid" => entity.uuid})

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

  # The settings panel carries the embed-state plumbing (`assign_embed_state`)
  # and logs every mutation by `Activity.actor_uuid/1`, so when a host renders
  # it off-router via `live_render` it must also reconstruct the acting user
  # from `session["current_user_uuid"]` — otherwise the audit row records a nil
  # actor (the embed bug PR #22 fixed for the other LVs but missed here).
  describe "embedded off-router (current_user_uuid contract)" do
    setup do
      entity = seed_shared_status_entity!()
      {:ok, entity: entity}
    end

    test "embedded mutation attributes the activity to current_user_uuid", %{
      conn: conn,
      entity: entity,
      actor_uuid: actor_uuid
    } do
      # `live_isolated` mounts without the router's `:phoenix_kit_ensure_admin`
      # on_mount, so the scope is absent unless the host bridges it. Pre-fix the
      # activity logged actor_uuid: nil; the `assign_embed_user/2` wiring
      # reconstructs the real viewer from the session uuid.
      Statuses.set_default_status_entity(nil)

      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectsSettingsLive,
          session: %{"current_user_uuid" => actor_uuid}
        )

      view
      |> element(~s(form[phx-change="select_default_status_entity"]))
      |> render_change(%{"entity_uuid" => entity.uuid})

      assert Statuses.global_default_status_entity_uuid() == entity.uuid

      assert_activity_logged("projects.default_status_entity_set", actor_uuid: actor_uuid)
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

  # The Timeline-labels card is independent of the entities module — it's always
  # present, with a live demo chart driven by the same settings.
  describe "timeline chart settings" do
    test "renders the Timeline chart card + the live demo chart", %{conn: conn} do
      {:ok, _view, html} = live(conn, @path)
      assert html =~ "Timeline chart"
      assert html =~ ~s(name="label_position")
      assert html =~ ~s(name="row_height")
      assert html =~ ~s(id="gantt-settings-demo")
    end

    test "changing the label style persists the setting + logs it", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      GanttDisplay.put("label_position", "fit")
      {:ok, view, _html} = live(conn, @path)

      view
      |> element("#gantt-labels-form")
      |> render_change(%{"_target" => ["label_position"], "label_position" => "watermark"})

      assert GanttDisplay.read().label_position == :watermark

      await_display_log_flush(view)

      assert_activity_logged("projects.gantt_display_changed",
        actor_uuid: actor_uuid,
        metadata_has: %{"field" => "label_position"}
      )
    end

    test "the new chart controls persist + log (row height select + smart-routing toggle)", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      # ensure the dependency-arrows section (and its toggle) renders
      GanttDisplay.put_flag("show_connectors", true)
      {:ok, view, _html} = live(conn, @path)

      view
      |> element("#gantt-bars-form")
      |> render_change(%{"_target" => ["row_height"], "row_height" => "comfortable"})

      assert GanttDisplay.read().row_height == "3rem"

      await_display_log_flush(view)

      assert_activity_logged("projects.gantt_display_changed",
        actor_uuid: actor_uuid,
        metadata_has: %{"field" => "row_height"}
      )

      view
      |> element(~s(input[phx-value-field="avoid_collisions"]))
      |> render_click()

      refute GanttDisplay.read().avoid_collisions

      assert_activity_logged("projects.gantt_display_changed",
        actor_uuid: actor_uuid,
        metadata_has: %{"field" => "avoid_collisions"}
      )
    end

    test "reset to defaults restores settings + logs it", %{conn: conn, actor_uuid: actor_uuid} do
      GanttDisplay.put("label_position", "watermark")
      GanttDisplay.put("row_height", "comfortable")
      {:ok, view, _html} = live(conn, @path)

      view |> element(~s(button[phx-click="reset_gantt_display"])) |> render_click()

      d = GanttDisplay.read()
      assert d.label_position == :fit
      assert d.row_height_choice == :normal

      assert_activity_logged("projects.gantt_display_reset", actor_uuid: actor_uuid)
    end
  end

  describe "late-task marker + stripe opacity" do
    test "both previews render; marker + opacity persist (clamped/validated)", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/settings/projects")

      # Two demo strips: the overdue stretch + the late-task chips.
      assert html =~ "calendar-anim-preview"
      assert html =~ "calendar-late-preview"
      # Default marker: the late chips carry the overdue pattern — synced
      # with the Projects-mode look out of the box.
      assert has_element?(view, "#calendar-late-preview .pk-overdue")

      render_change(view, "set_calendar_anim", %{
        "_target" => ["late_marker"],
        "late_marker" => "ring"
      })

      assert PhoenixKitProjects.CalendarDisplay.read_animation().late_marker == "ring"
      assert has_element?(view, "#calendar-late-preview .ring-error")

      # An unknown marker value is ignored, not persisted.
      render_change(view, "set_calendar_anim", %{
        "_target" => ["late_marker"],
        "late_marker" => "sparkles"
      })

      assert PhoenixKitProjects.CalendarDisplay.read_animation().late_marker == "ring"

      # Opacity persists and clamps into its range.
      render_change(view, "set_calendar_anim", %{"_target" => ["opacity"], "opacity" => "0.3"})
      assert PhoenixKitProjects.CalendarDisplay.read_animation().opacity == 0.3

      render_change(view, "set_calendar_anim", %{"_target" => ["opacity"], "opacity" => "9"})
      assert PhoenixKitProjects.CalendarDisplay.read_animation().opacity == 1.0
    end
  end

  describe "coalesced slider audit logs" do
    test "a slider burst settles into ONE row carrying the final value", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, view, _html} = live(conn, @path)

      for v <- ~w(0.2 0.3 0.5) do
        view
        |> element("#gantt-labels-form")
        |> render_change(%{"_target" => ["label_fit_ratio"], "label_fit_ratio" => v})
      end

      await_display_log_flush(view)

      # assert_activity_logged flunks on MORE than one matching row, so this
      # also pins that the three ticks didn't each write their own.
      assert_activity_logged("projects.gantt_display_changed",
        actor_uuid: actor_uuid,
        metadata_has: %{"field" => "label_fit_ratio", "value" => "0.5"}
      )
    end

    test "a reset supersedes queued change rows", %{conn: conn, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, @path)

      view
      |> element("#gantt-labels-form")
      |> render_change(%{"_target" => ["label_fit_ratio"], "label_fit_ratio" => "0.9"})

      # Reset lands INSIDE the quiet window — the queued change row must not
      # flush after it (a pre-reset value after the reset reads backwards).
      view |> element(~s(button[phx-click="reset_gantt_display"])) |> render_click()

      await_display_log_flush(view)

      assert_activity_logged("projects.gantt_display_reset", actor_uuid: actor_uuid)

      refute_activity_logged("projects.gantt_display_changed",
        metadata_has: %{"field" => "label_fit_ratio"}
      )
    end

    test "calendar animation sliders coalesce the same way", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, view, _html} = live(conn, @path)

      for v <- ~w(3 9 12) do
        view
        |> element("#calendar-anim-form")
        |> render_change(%{"_target" => ["speed"], "speed" => v})
      end

      await_display_log_flush(view)

      assert_activity_logged("projects.calendar_display_changed",
        actor_uuid: actor_uuid,
        metadata_has: %{"field" => "speed"}
      )
    end
  end

  # Outwait the (test-shortened, 30ms) coalescing window, then sync with the
  # LV so the flush handle_info has been processed before asserting.
  defp await_display_log_flush(view) do
    Process.sleep(80)
    render(view)
  end
end
