defmodule PhoenixKitProjects.Web.EmbeddingEmitTest do
  @moduledoc """
  Emit-mode contract tests for every embeddable LV in
  `phoenix_kit_projects`.

  Sibling to `embedding_test.exs` (which pins the navigate-mode embed
  contract from PR #6). Each LV gets a describe block with three
  canonical assertions:

  1. **Mounts in emit mode without raising**, subscribed to a host topic.
  2. **Emits `{:projects, :opened, %{lv, session, frame_ref}}`** when an
     in-LV navigation site is clicked (smart_link button or row).
  3. **For form LVs only — emits `{:projects, :saved, %{kind, action,
     record, frame_ref}}` on form save**, with `:create` / `:update`
     actions appropriate to the path.

  Plus per-LV special cases (delete → `:deleted`, cancel/back →
  `:closed`).

  ## What this catches

  - Conversion regressions (a `<.link navigate>` that wasn't switched to
    `<.smart_link>` still fires top-level navigation in emit mode).
  - Missing `WebHelpers.assign_embed_state/2` calls in mount.
  - Missing `WebHelpers.attach_open_embed_hook/1` calls (no `open_embed`
    handler → button click is a no-op).
  - Whitelist drift (the smart_link's target LV must be in
    `Helpers.embeddable_lvs/0`).
  - Mount-time validation regressions (`mode: "emit"` without
    `pubsub_topic` should raise).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "emit-actor-#{System.unique_integer([:positive])}@example.com",
        "password" => "EmitPass123!"
      })

    scope = fake_scope(user_uuid: user.uuid)
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: user.uuid}
  end

  # ─────────────────────────────────────────────────────────────────
  # OverviewLive
  # ─────────────────────────────────────────────────────────────────

  describe "OverviewLive emit mode" do
    test "mounts in emit mode with a topic", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.OverviewLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      assert html =~ "Projects"
      # In emit mode, the action button is a <button phx-click="open_embed">,
      # never an <a href>.
      assert html =~ ~s(phx-click="open_embed")
      refute html =~ ~s(href="/en/admin/projects/list/new")
    end

    test "raises when mode=emit but pubsub_topic is missing", %{conn: conn} do
      assert_raise ArgumentError, ~r/pubsub_topic/, fn ->
        live_isolated(conn, PhoenixKitProjects.Web.OverviewLive, session: %{"mode" => "emit"})
      end
    end

    test "navigate-mode behaviour is unchanged (regression guard)", %{conn: conn} do
      # No `mode` key → default :navigate. Action buttons are real <a> tags.
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.OverviewLive, session: %{})

      refute html =~ ~s(phx-click="open_embed")
    end

    test "clicking 'New project' emits :opened for ProjectFormLive", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.OverviewLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      # The header's "New project" button — `btn-sm` distinguishes it
      # from the empty-state CTA's `btn-xs` variant.
      view
      |> element("button.btn-sm[phx-click=open_embed]", "New project")
      |> render_click()

      assert_receive {:projects, :opened, payload}, 500
      assert payload.lv == PhoenixKitProjects.Web.ProjectFormLive
      assert payload.session == %{"live_action" => "new"}
      assert payload.frame_ref == 0
    end

    test "clicking 'New task' emits :opened for TaskFormLive", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.OverviewLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 7}
        )

      view
      |> element("button[phx-click=open_embed]", "New task")
      |> render_click()

      assert_receive {:projects, :opened, payload}, 500
      assert payload.lv == PhoenixKitProjects.Web.TaskFormLive
      assert payload.session == %{"live_action" => "new"}
      assert payload.frame_ref == 7
    end

    test "frame_ref from session is stamped into every emit", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.OverviewLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 42}
        )

      view
      |> element("button.btn-sm[phx-click=open_embed]", "New project")
      |> render_click()

      assert_receive {:projects, :opened, %{frame_ref: 42}}, 500
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # TasksLive
  # ─────────────────────────────────────────────────────────────────

  describe "TasksLive emit mode" do
    test "mounts in emit mode and renders smart_link buttons", %{conn: conn} do
      topic = unique_topic()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TasksLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      assert html =~ "Task Library"
      assert html =~ ~s(phx-click="open_embed")
    end

    test "clicking 'New task' emits :opened for TaskFormLive", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.TasksLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      view
      |> element("button.btn-sm[phx-click=open_embed]", "New task")
      |> render_click()

      assert_receive {:projects, :opened, payload}, 500
      assert payload.lv == PhoenixKitProjects.Web.TaskFormLive
      assert payload.session == %{"live_action" => "new"}
    end

    test "clicking an Edit pencil emits :opened with the task uuid", %{conn: conn} do
      task = fixture_task(%{"title" => "Reusable"})
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.TasksLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      # The pencil button is the first `open_embed` button in the row.
      # Match by phx-value-lv to disambiguate from the "New task" action.
      view
      |> element(
        ~s(button[phx-click=open_embed][phx-value-lv="Elixir.PhoenixKitProjects.Web.TaskFormLive"][phx-value-session*="#{task.uuid}"])
      )
      |> render_click()

      assert_receive {:projects, :opened, payload}, 500
      assert payload.lv == PhoenixKitProjects.Web.TaskFormLive
      assert payload.session == %{"live_action" => "edit", "id" => task.uuid}
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # ProjectsLive
  # ─────────────────────────────────────────────────────────────────

  describe "ProjectsLive emit mode" do
    test "mounts in emit mode", %{conn: conn} do
      topic = unique_topic()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectsLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      assert html =~ "Projects"
      assert html =~ ~s(phx-click="open_embed")
    end

    test "clicking 'New project' emits :opened for ProjectFormLive", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectsLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      view
      |> element("button.btn-sm[phx-click=open_embed]", "New project")
      |> render_click()

      assert_receive {:projects, :opened, payload}, 500
      assert payload.lv == PhoenixKitProjects.Web.ProjectFormLive
      assert payload.session == %{"live_action" => "new"}
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # TemplatesLive
  # ─────────────────────────────────────────────────────────────────

  describe "TemplatesLive emit mode" do
    test "mounts in emit mode", %{conn: conn} do
      topic = unique_topic()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplatesLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      assert html =~ "Templates"
      assert html =~ ~s(phx-click="open_embed")
    end

    test "clicking 'New template' emits :opened for TemplateFormLive", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplatesLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      view
      |> element("button.btn-sm[phx-click=open_embed]", "New template")
      |> render_click()

      assert_receive {:projects, :opened, payload}, 500
      assert payload.lv == PhoenixKitProjects.Web.TemplateFormLive
      assert payload.session == %{"live_action" => "new"}
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # TemplateFormLive
  # ─────────────────────────────────────────────────────────────────

  describe "TemplateFormLive emit mode (:new)" do
    test "mounts in emit mode with a topic", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplateFormLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      assert html =~ "New template"
      assert html =~ ~s(phx-click="cancel")
    end

    test "clicking Cancel emits :closed", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplateFormLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 9}
        )

      view |> element("button[phx-click=cancel]") |> render_click()

      assert_receive {:projects, :closed, %{frame_ref: 9}}, 500
    end

    test "clicking 'Templates' back link emits :opened for TemplatesLive", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplateFormLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      view
      |> element("button[phx-click=open_embed]", "Templates")
      |> render_click()

      assert_receive {:projects, :opened, payload}, 500
      assert payload.lv == PhoenixKitProjects.Web.TemplatesLive
      assert payload.session == %{}
    end

    test "submitting the form emits :saved with kind=:template, action=:create", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplateFormLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 11}
        )

      view
      |> form("#template-form", project: %{"name" => "Emit Template"})
      |> render_submit()

      assert_receive {:projects, :saved, payload}, 500
      assert payload.kind == :template
      assert payload.action == :create
      assert payload.record.name == "Emit Template"
      assert payload.record.is_template == true
      assert payload.frame_ref == 11
    end
  end

  describe "TemplateFormLive emit mode (:edit)" do
    test "edits an existing template; save emits :saved with action=:update", %{conn: conn} do
      template = fixture_template(%{"name" => "Existing"})
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplateFormLive,
          session: %{
            "mode" => "emit",
            "pubsub_topic" => topic,
            "live_action" => "edit",
            "id" => template.uuid,
            "frame_ref" => 13
          }
        )

      assert html =~ "Edit Existing"

      view
      |> form("#template-form", project: %{"name" => "Renamed"})
      |> render_submit()

      assert_receive {:projects, :saved, payload}, 500
      assert payload.kind == :template
      assert payload.action == :update
      assert payload.record.name == "Renamed"
      assert payload.frame_ref == 13
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # TaskFormLive
  # ─────────────────────────────────────────────────────────────────

  describe "TaskFormLive emit mode" do
    test "mounts (:new) and renders smart_link / cancel button", %{conn: conn} do
      topic = unique_topic()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TaskFormLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      assert html =~ "New task"
      assert html =~ ~s(phx-click="cancel")
    end

    test "clicking Cancel emits :closed", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.TaskFormLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 5}
        )

      view |> element("button[phx-click=cancel]") |> render_click()

      assert_receive {:projects, :closed, %{frame_ref: 5}}, 500
    end

    test "save (:new) emits :saved with kind=:task, action=:create", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.TaskFormLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 8}
        )

      view
      |> form("#task-form",
        task: %{
          "title" => "Emit Task",
          "estimated_duration" => "2",
          "estimated_duration_unit" => "hours"
        }
      )
      |> render_submit()

      assert_receive {:projects, :saved, payload}, 500
      assert payload.kind == :task
      assert payload.action == :create
      assert payload.record.title == "Emit Task"
      assert payload.frame_ref == 8
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # ProjectShowLive
  # ─────────────────────────────────────────────────────────────────

  describe "ProjectShowLive emit mode" do
    test "mounts in emit mode with project id", %{conn: conn} do
      project = fixture_project(%{"name" => "Embed Show"})
      topic = unique_topic()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: %{
            "mode" => "emit",
            "pubsub_topic" => topic,
            "id" => project.uuid,
            "frame_ref" => 0
          }
        )

      assert html =~ "Embed Show"
      assert html =~ ~s(phx-click="open_embed")
    end

    test "project-not-found emits :closed in emit mode", %{conn: conn} do
      bogus = Ecto.UUID.generate()
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
        session: %{
          "mode" => "emit",
          "pubsub_topic" => topic,
          "id" => bogus,
          "frame_ref" => 51
        }
      )

      assert_receive {:projects, :closed, %{frame_ref: 51}}, 500
    end

    test "clicking 'Add task' emits :opened for AssignmentFormLive", %{conn: conn} do
      project = fixture_project()
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: %{
            "mode" => "emit",
            "pubsub_topic" => topic,
            "id" => project.uuid,
            "frame_ref" => 0
          }
        )

      view
      |> element("button.btn-sm[phx-click=open_embed]", "Add task")
      |> render_click()

      assert_receive {:projects, :opened, payload}, 500
      assert payload.lv == PhoenixKitProjects.Web.AssignmentFormLive
      assert payload.session == %{"live_action" => "new", "project_id" => project.uuid}
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # ProjectFormLive
  # ─────────────────────────────────────────────────────────────────

  describe "ProjectFormLive emit mode" do
    test "mounts (:new) and renders cancel button", %{conn: conn} do
      topic = unique_topic()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectFormLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      assert html =~ "New project"
      assert html =~ ~s(phx-click="cancel")
    end

    test "save (:new) emits :saved with kind=:project, action=:create", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectFormLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 31}
        )

      view
      |> form("#project-form",
        project: %{"name" => "Emit Project", "start_mode" => "immediate"}
      )
      |> render_submit()

      assert_receive {:projects, :saved, payload}, 500
      assert payload.kind == :project
      assert payload.action == :create
      assert payload.record.name == "Emit Project"
      assert payload.frame_ref == 31
    end

    test "Cancel emits :closed", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectFormLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 33}
        )

      view |> element("button[phx-click=cancel]") |> render_click()

      assert_receive {:projects, :closed, %{frame_ref: 33}}, 500
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # AssignmentFormLive
  # ─────────────────────────────────────────────────────────────────

  describe "AssignmentFormLive emit mode (:new)" do
    test "mounts with project_id from session", %{conn: conn} do
      project = fixture_project(%{"name" => "Emit Host"})
      topic = unique_topic()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.AssignmentFormLive,
          session: %{
            "mode" => "emit",
            "pubsub_topic" => topic,
            "project_id" => project.uuid,
            "frame_ref" => 0
          }
        )

      assert html =~ "Add task to Emit Host"
      assert html =~ ~s(phx-click="cancel")
    end

    test "missing project emits :closed (not push_navigate)", %{conn: conn} do
      bogus = Ecto.UUID.generate()
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      live_isolated(conn, PhoenixKitProjects.Web.AssignmentFormLive,
        session: %{
          "mode" => "emit",
          "pubsub_topic" => topic,
          "project_id" => bogus,
          "frame_ref" => 14
        }
      )

      assert_receive {:projects, :closed, %{frame_ref: 14}}, 500
    end

    test "clicking Cancel emits :closed", %{conn: conn} do
      project = fixture_project()
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.AssignmentFormLive,
          session: %{
            "mode" => "emit",
            "pubsub_topic" => topic,
            "project_id" => project.uuid,
            "frame_ref" => 22
          }
        )

      view |> element("button[phx-click=cancel]") |> render_click()

      assert_receive {:projects, :closed, %{frame_ref: 22}}, 500
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Codex regression coverage
  # ─────────────────────────────────────────────────────────────────

  describe "Codex H1 regression: ProjectShow Edit button emits in emit mode" do
    test "Edit on a regular project emits :opened for ProjectFormLive", %{conn: conn} do
      project = fixture_project(%{"name" => "H1 Regular"})
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: %{
            "mode" => "emit",
            "pubsub_topic" => topic,
            "id" => project.uuid,
            "frame_ref" => 0
          }
        )

      view
      |> element(
        ~s(button[phx-click=open_embed][phx-value-lv="Elixir.PhoenixKitProjects.Web.ProjectFormLive"])
      )
      |> render_click()

      assert_receive {:projects, :opened, payload}, 500
      assert payload.lv == PhoenixKitProjects.Web.ProjectFormLive
      assert payload.session == %{"live_action" => "edit", "id" => project.uuid}
    end

    test "Edit on a template emits :opened for TemplateFormLive", %{conn: conn} do
      template = fixture_template(%{"name" => "H1 Template"})
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: %{
            "mode" => "emit",
            "pubsub_topic" => topic,
            "id" => template.uuid,
            "frame_ref" => 0
          }
        )

      view
      |> element(
        ~s(button[phx-click=open_embed][phx-value-lv="Elixir.PhoenixKitProjects.Web.TemplateFormLive"])
      )
      |> render_click()

      assert_receive {:projects, :opened, payload}, 500
      assert payload.lv == PhoenixKitProjects.Web.TemplateFormLive
      assert payload.session == %{"live_action" => "edit", "id" => template.uuid}
    end
  end

  describe "Codex H3 regression: form-LV not-found placeholders in emit mode" do
    test "TaskFormLive (:edit) with bogus id renders + emits :closed", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      # If placeholders are missing, the LV crashes at render time before
      # the test's assert_receive can run — `live_isolated` raises.
      live_isolated(conn, PhoenixKitProjects.Web.TaskFormLive,
        session: %{
          "mode" => "emit",
          "pubsub_topic" => topic,
          "live_action" => "edit",
          "id" => Ecto.UUID.generate(),
          "frame_ref" => 71
        }
      )

      assert_receive {:projects, :closed, %{frame_ref: 71}}, 500
    end

    test "TemplateFormLive (:edit) with bogus id renders + emits :closed", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      live_isolated(conn, PhoenixKitProjects.Web.TemplateFormLive,
        session: %{
          "mode" => "emit",
          "pubsub_topic" => topic,
          "live_action" => "edit",
          "id" => Ecto.UUID.generate(),
          "frame_ref" => 72
        }
      )

      assert_receive {:projects, :closed, %{frame_ref: 72}}, 500
    end
  end

  describe "Codex M1 regression: bad open_embed in emit mode halts cleanly" do
    test "non-whitelisted lv value — logged and dropped without crash", %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.OverviewLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      # render_hook bypasses the smart_link's whitelist on the client
      # side; this exercises the server-side fail-closed branch.
      render_hook(view, "open_embed", %{
        "lv" => "Elixir.PhoenixKitProjects.Projects",
        "session" => "{}"
      })

      assert Process.alive?(view.pid)
    end

    test "malformed session JSON — logged and dropped without crash", %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.OverviewLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      render_hook(view, "open_embed", %{
        "lv" => "Elixir.PhoenixKitProjects.Web.ProjectShowLive",
        "session" => "{not json"
      })

      assert Process.alive?(view.pid)
    end
  end

  describe "Codex M3 regression: bad frame_ref strings don't raise" do
    test "non-integer frame_ref string degrades to nil", %{conn: conn} do
      topic = unique_topic()

      # Old code: String.to_integer("not-an-int") raised → mount crashed.
      # New code: Integer.parse path returns nil with a Logger.warning.
      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.OverviewLive,
          session: %{
            "mode" => "emit",
            "pubsub_topic" => topic,
            "frame_ref" => "not-an-int"
          }
        )

      assert Process.alive?(view.pid)
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Codex round-2 regression coverage
  # ─────────────────────────────────────────────────────────────────

  describe "Codex R2-M1 regression: live_action allowlist" do
    test "session live_action='show' falls back to default :new instead of crashing",
         %{conn: conn} do
      topic = unique_topic()

      # Without the allowlist, `String.to_existing_atom("show")` succeeds
      # (`:show` exists from Phoenix LV internals), apply_action(:show, ...)
      # has no matching clause, and the LV crashes at mount.
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectFormLive,
          session: %{
            "mode" => "emit",
            "pubsub_topic" => topic,
            "live_action" => "show",
            "frame_ref" => 91
          }
        )

      # The fallback :new path renders the "New project" heading.
      assert html =~ "New project"
    end

    test "session live_action='delete' (atom may or may not exist) falls back to :new",
         %{conn: conn} do
      topic = unique_topic()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TaskFormLive,
          session: %{
            "mode" => "emit",
            "pubsub_topic" => topic,
            "live_action" => "delete",
            "frame_ref" => 92
          }
        )

      assert html =~ "New task"
    end
  end

  describe "Codex R2-M2 regression: form LVs fail closed on missing required keys" do
    test "AssignmentFormLive :new without project_id emits :closed", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      live_isolated(conn, PhoenixKitProjects.Web.AssignmentFormLive,
        session: %{
          "mode" => "emit",
          "pubsub_topic" => topic,
          "frame_ref" => 81
        }
      )

      assert_receive {:projects, :closed, %{frame_ref: 81}}, 500
    end

    test "AssignmentFormLive :edit without project_id+id emits :closed", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      live_isolated(conn, PhoenixKitProjects.Web.AssignmentFormLive,
        session: %{
          "mode" => "emit",
          "pubsub_topic" => topic,
          "live_action" => "edit",
          "frame_ref" => 82
        }
      )

      assert_receive {:projects, :closed, %{frame_ref: 82}}, 500
    end

    test "ProjectFormLive :edit without id emits :closed", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      live_isolated(conn, PhoenixKitProjects.Web.ProjectFormLive,
        session: %{
          "mode" => "emit",
          "pubsub_topic" => topic,
          "live_action" => "edit",
          "frame_ref" => 83
        }
      )

      assert_receive {:projects, :closed, %{frame_ref: 83}}, 500
    end

    test "ProjectShowLive without id emits :closed", %{conn: conn} do
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
        session: %{
          "mode" => "emit",
          "pubsub_topic" => topic,
          "frame_ref" => 84
        }
      )

      assert_receive {:projects, :closed, %{frame_ref: 84}}, 500
    end
  end

  describe "Codex R2-M3 regression: :deleted emit at delete call sites" do
    test "ProjectsLive delete handler emits :deleted in emit mode", %{conn: conn} do
      project = fixture_project(%{"name" => "Doomed"})
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectsLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      render_hook(view, "delete", %{"uuid" => project.uuid})

      assert_receive {:projects, :deleted, payload}, 500
      assert payload.kind == :project
      assert payload.uuid == project.uuid
    end

    test "TasksLive delete handler emits :deleted in emit mode", %{conn: conn} do
      task = fixture_task(%{"title" => "Doomed task"})
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.TasksLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      render_hook(view, "delete", %{"uuid" => task.uuid})

      assert_receive {:projects, :deleted, payload}, 500
      assert payload.kind == :task
      assert payload.uuid == task.uuid
    end

    test "TemplatesLive delete handler emits :deleted in emit mode", %{conn: conn} do
      template = fixture_template(%{"name" => "Doomed template"})
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplatesLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      render_hook(view, "delete", %{"uuid" => template.uuid})

      assert_receive {:projects, :deleted, payload}, 500
      assert payload.kind == :template
      assert payload.uuid == template.uuid
    end

    test "notify_deleted emits with close: false (informational only)",
         %{conn: conn} do
      project = fixture_project(%{"name" => "Close-flag check"})
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectsLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      render_hook(view, "delete", %{"uuid" => project.uuid})

      # Codex R3-M1: list-LV row deletes must NOT trigger modal pop.
      assert_receive {:projects, :deleted, payload}, 500

      assert payload.close == false,
             "list-LV notify_deleted/3 must emit close: false so PopupHost doesn't pop"
    end

    test "navigate mode is unchanged (no :deleted broadcast)", %{conn: conn} do
      project = fixture_project(%{"name" => "Navigate-mode doomed"})
      topic = unique_topic()
      ProjectsPubSub.subscribe(topic)

      {:ok, view, _} = live_isolated(conn, PhoenixKitProjects.Web.ProjectsLive, session: %{})

      render_hook(view, "delete", %{"uuid" => project.uuid})

      refute_receive {:projects, :deleted, _}, 200
    end
  end

  describe "Codex R5-IM1 regression: close=false + next is rejected at emit time" do
    test "navigate_after_save raises when close: false is paired with next: {...}",
         %{conn: conn} do
      topic = unique_topic()

      {:ok, view, _} =
        live_isolated(conn, PhoenixKitProjects.Web.OverviewLive,
          session: %{"mode" => "emit", "pubsub_topic" => topic, "frame_ref" => 0}
        )

      # We need a socket in emit mode with a record to "save". The
      # simplest reproduction is to invoke navigate_after_save/3 inside
      # the LV process via render_hook on a synthetic event — but
      # OverviewLive doesn't carry that handler. Instead drive it
      # through `:sys.replace_state` to get a socket we can call from
      # inside a controlled test event.
      assert_raise ArgumentError, ~r/close: true.*when.*next/, fn ->
        socket = :sys.get_state(view.pid).socket

        WebHelpers.navigate_after_save(socket, "/fallback",
          kind: :task,
          record: %{uuid: "x"},
          action: :create,
          close: false,
          next: {PhoenixKitProjects.Web.TaskFormLive, %{}}
        )
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # C11 pinning: per-row kebab action menus
  # ─────────────────────────────────────────────────────────────────
  #
  # The Edit + Delete actions on each list/show LV's row were converted
  # to `<.table_row_menu>` (3-dots dropdown) matching the canonical
  # pattern from phoenix_kit_entities/DataNavigator. If someone reverts
  # the conversion (puts inline pencil/trash buttons back in the row),
  # the assertions below fail.

  describe "C11 pinning: row-action kebab menus" do
    test "ProjectsLive rows carry the Actions kebab trigger", %{conn: conn} do
      _project = fixture_project(%{"name" => "Doomed list row"})

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectsLive, session: %{})

      # `data-row-menu-trigger` is the structural attr on the ⋮ button
      # rendered by `<.table_row_menu>`. If row actions revert to inline
      # buttons (raw <.link navigate> / <button phx-click="delete">), no
      # element with this attr ships.
      assert html =~ ~s(data-row-menu-trigger)
    end

    test "TasksLive rows carry the Actions kebab trigger", %{conn: conn} do
      _task = fixture_task(%{"title" => "Doomed task row"})

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TasksLive, session: %{})

      assert html =~ ~s(data-row-menu-trigger)
    end

    test "TemplatesLive rows carry the Actions kebab trigger", %{conn: conn} do
      _template = fixture_template(%{"name" => "Doomed template row"})

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplatesLive, session: %{})

      assert html =~ ~s(data-row-menu-trigger)
    end

    test "ProjectShowLive header + assignments carry kebab triggers", %{conn: conn} do
      project = fixture_project(%{"name" => "Header + row kebab"})

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: %{"id" => project.uuid}
        )

      # The project header has Edit + Archive in a kebab; assignment rows
      # have Edit + Remove. The header always renders, even with no
      # assignments, so a single project_show mount should always have
      # at least the header trigger.
      triggers = Regex.scan(~r/data-row-menu-trigger/, html) |> length()
      assert triggers >= 1, "expected at least the header kebab trigger"
    end
  end

  defp unique_topic do
    "emit-test-#{System.unique_integer([:positive])}"
  end
end
