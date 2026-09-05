defmodule PhoenixKitProjects.Web.EmbeddingTest do
  @moduledoc """
  Embed contract tests for every LV in `phoenix_kit_projects`.

  The contract (see `dev_docs/embedding_audit.md`):

  1. Each LV mounts via `live_isolated/3` with `params ==
     :not_mounted_at_router` — i.e. no `FunctionClauseError` from a
     map-destructured `mount/3`, no `ArgumentError` from
     `handle_params/3` being exported.
  2. `session["wrapper_class"]` overrides the default outer-div class.
  3. For form LVs: `session["redirect_to"]` overrides the
     `push_navigate` target on save (and on not-found error paths).

  These tests are the regression gate that stops the embed-blocker
  patterns described in the audit from sneaking back in. If you add a
  new LV that's intended to be embeddable, add a describe block here.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "embed-actor-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    scope = fake_scope(user_uuid: user.uuid)
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: user.uuid}
  end

  # ─────────────────────────────────────────────────────────────────
  # Tier 1 — read-only LVs, high embed value
  # ─────────────────────────────────────────────────────────────────

  describe "OverviewLive embed" do
    test "mounts via live_isolated with no session", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.OverviewLive, session: %{})

      assert html =~ "Projects"
    end

    test "wrapper_class defaults to the full-width standalone layout", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.OverviewLive, session: %{})

      assert html =~ "flex flex-col w-full px-4 pt-2 pb-4 gap-4"
    end

    test "wrapper_class override from session replaces the default", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.OverviewLive,
          session: %{"wrapper_class" => "host-specific-class"}
        )

      assert html =~ "host-specific-class"
      refute html =~ "flex flex-col w-full px-4 pt-2 pb-4 gap-4"
    end

    test "locale from session is applied to embedded mount", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.OverviewLive, session: %{"locale" => "et"})

      assert html =~ "Projektid"
      refute html =~ "Projects"
    end
  end

  describe "ProjectShowLive off-router mount — assigns set by router on_mount" do
    # Regression for the Andi field report (PR #16 follow-up, 2026-05-20):
    # `project_show_live.ex:1820` used bang-form `@phoenix_kit_current_scope`
    # for the comments drawer. The assign is set by phoenix_kit core's
    # router-level `on_mount` callback, so off-router mounts via
    # `live_render/3` skip the on_mount and the assign is absent. HEEx
    # `@x` raises `KeyError` on missing keys (unlike `assigns[:x]` which
    # returns `nil`), so opening the comments drawer crashed the LV.
    #
    # This test pins the contract: every router-on_mount-set assign that
    # PKP reads MUST go through bracket access (`assigns[:key]`) or be
    # initialized via `assign_new/3` at mount time. Adding a new
    # bang-form reference will fail this test.

    setup %{actor_uuid: actor_uuid} do
      {:ok, project} =
        Projects.create_project(%{
          "name" => "Embed scope test #{System.unique_integer([:positive])}",
          "start_mode" => "immediate",
          "started_at" => DateTime.utc_now() |> DateTime.truncate(:second)
        })

      # The embedded viewer must be able to see it — these LVs gate :view.
      {:ok, _} = PhoenixKitProjects.Members.add_member(project, actor_uuid, role: "member")

      {:ok, project: project, viewer_uuid: actor_uuid}
    end

    test "an off-router mount with NO identity is refused", %{conn: conn, project: project} do
      # `live_isolated` mounts without the router, so no on_mount fires and
      # there is no scope. That used to render the project on the promise
      # that the HOST had gated its page. It can't: `handle_open_embed`
      # takes a client-supplied session, so anyone able to open an embed
      # could omit `current_user_uuid` and walk straight past a gate that
      # only applied to identified viewers. No identity now means no
      # access, and a host embedding a project must pass the viewer's
      # `current_user_uuid`.
      assert {:error, {:live_redirect, %{flash: %{"error" => flash}}}} =
               live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
                 session: %{"id" => project.uuid}
               )

      assert flash =~ "not found"
    end

    test "an identified viewer with access mounts and can open comments", %{
      conn: conn,
      project: project
    } do
      # The comments drawer reads :phoenix_kit_current_scope, which an
      # off-router mount does not get from a router hook. It must tolerate
      # the assign being absent — but the mount itself now requires a
      # viewer who can actually see the project, so identify one.
      {:ok, viewer} =
        Auth.register_user(%{
          "email" => "embed-viewer-#{System.unique_integer([:positive])}@example.com",
          "password" => "ViewerPass123!"
        })

      {:ok, _} = PhoenixKitProjects.Members.add_member(project, viewer.uuid, role: "member")

      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: %{"id" => project.uuid, "current_user_uuid" => viewer.uuid}
        )

      html =
        render_hook(view, "open_comments", %{
          "type" => "project",
          "uuid" => project.uuid,
          "title" => project.name
        })

      assert html =~ ~s|aria-label="Comments"|
    end

    test "no other bang-form router-assign refs in PKP source", _context do
      # Process-level guard: grep PKP `lib/` for any `@phoenix_kit_…`
      # bang-form reference. The fix renamed the only such site to a
      # bracket-access pattern; if anyone adds a new one, this test
      # will fail at the next CI run instead of waiting for a host
      # integration to hit it. Mirror the audit pattern documented in
      # the Andi field report.
      offenders =
        :phoenix_kit_projects
        |> :code.priv_dir()
        |> Path.join("../lib")
        |> Path.expand()
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.flat_map(fn file ->
          file
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} ->
            String.match?(line, ~r/@phoenix_kit_[a-z]/) and
              not String.starts_with?(String.trim_leading(line), "#")
          end)
          |> Enum.map(fn {line, n} -> "#{file}:#{n}: #{String.trim(line)}" end)
        end)

      assert offenders == [],
             "Bang-form @phoenix_kit_* references found — use assigns[:key] instead:\n" <>
               Enum.join(offenders, "\n")
    end
  end

  describe "ProjectShowLive embed — current_user_uuid contract" do
    # The fix for the embedded comments drawer (and embed-mode activity
    # actor attribution): an off-router mount runs no on_mount hook, so
    # the host bridges identity by passing `session["current_user_uuid"]`.
    # `WebHelpers.assign_embed_user/2` reloads it into the
    # `:phoenix_kit_current_user` / `:phoenix_kit_current_scope` assigns.
    setup %{actor_uuid: actor_uuid} do
      {:ok, project} =
        Projects.create_project(%{
          "name" => "Embed user test #{System.unique_integer([:positive])}",
          "start_mode" => "immediate",
          "started_at" => DateTime.utc_now() |> DateTime.truncate(:second)
        })

      # The embedded viewer must actually be able to see the project. An
      # off-router mount runs no admin on_mount, so ProjectShowLive gates
      # :view itself — a host embedding a project for a stranger now gets
      # a refusal, which is the point (see the "a stranger is refused"
      # test below).
      {:ok, _} = PhoenixKitProjects.Members.add_member(project, actor_uuid, role: "member")

      {:ok, project: project}
    end

    test "a stranger embedding the project is refused, shaped as not-found", %{
      conn: conn,
      project: project
    } do
      {:ok, other} =
        Auth.register_user(%{
          "email" => "embed-stranger-#{System.unique_integer([:positive])}@example.com",
          "password" => "StrangerPass123!"
        })

      assert {:error, {:live_redirect, %{flash: %{"error" => flash}}}} =
               live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
                 session: %{"id" => project.uuid, "current_user_uuid" => other.uuid}
               )

      # Indistinguishable from a missing project: existence is information.
      assert flash =~ "not found"
    end

    test "current_user_uuid reconstructs the viewer and enables the composer", %{
      conn: conn,
      project: project,
      actor_uuid: actor_uuid
    } do
      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: %{"id" => project.uuid, "current_user_uuid" => actor_uuid}
        )

      # The user is reconstructed at mount, so both the comments-drawer
      # `current_user` and `Activity.actor_uuid/1` see the real viewer.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns[:phoenix_kit_current_user].uuid == actor_uuid
      assert assigns[:phoenix_kit_current_scope].user.uuid == actor_uuid

      html =
        render_hook(view, "open_comments", %{
          "type" => "project",
          "uuid" => project.uuid,
          "title" => project.name
        })

      # `can_post?` is true (current_user present) => the composer renders
      # instead of the sign-in prompt that was the reported bug.
      assert html =~ ~s|aria-label="Comments"|
      refute html =~ "Sign in to post a comment."
    end

    # Every way an embed can fail to prove who the viewer is now ends the
    # same way: refused, shaped as not-found. These used to assert the LV
    # rendered anonymously without crashing — which meant a crafted embed
    # session could reach any project simply by naming nobody.
    for {label, session_extra} <- [
          {"absent", %{}},
          {"empty-string", %{"current_user_uuid" => ""}},
          {"unknown", %{"current_user_uuid" => "00000000-0000-4000-8000-000000000000"}}
        ] do
      @label label
      @session_extra session_extra

      test "#{label} current_user_uuid is refused, not rendered anonymously", %{
        conn: conn,
        project: project
      } do
        assert {:error, {:live_redirect, %{flash: %{"error" => flash}}}} =
                 live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
                   session: Map.merge(%{"id" => project.uuid}, @session_extra)
                 )

        assert flash =~ "not found"
      end
    end

    test "inactive current_user_uuid degrades to anonymous (ensure_active_user)", %{
      conn: conn,
      project: project,
      actor_uuid: actor_uuid
    } do
      # Deactivate the user — `ensure_active_user/1` must drop a revoked account
      # so it can't act through an embed.
      Auth.User
      |> Repo.get!(actor_uuid)
      |> Ecto.Changeset.change(is_active: false)
      |> Repo.update!()

      # A revoked account cannot act through an embed — and now cannot read
      # through one either.
      assert {:error, {:live_redirect, %{flash: %{"error" => flash}}}} =
               live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
                 session: %{"id" => project.uuid, "current_user_uuid" => actor_uuid}
               )

      assert flash =~ "not found"
    end

    test "assign_embed_user is a no-op when a scope is already present (router path)", %{
      actor_uuid: actor_uuid
    } do
      # The router path's on_mount sets the canonical scope before mount/3; the
      # helper must never clobber it with a session uuid. Unit-tested directly so
      # it doesn't depend on simulating on_mount inside live_isolated.
      scope = fake_scope(user_uuid: actor_uuid)

      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(:phoenix_kit_current_scope, scope)
        |> Phoenix.Component.assign(:phoenix_kit_current_user, scope.user)

      result =
        WebHelpers.assign_embed_user(socket, %{
          "current_user_uuid" => Ecto.UUID.generate()
        })

      assert result.assigns.phoenix_kit_current_scope == scope
      assert result.assigns.phoenix_kit_current_user.uuid == actor_uuid
    end
  end

  describe "ProjectGanttLive embed" do
    # The Timeline view is host-insertable just like ProjectShowLive — it
    # mounts off-router, requires session["id"], and reads
    # current_user_uuid / locale / wrapper_class / headless. The regression
    # that prompted this block: ProjectGanttLive shipped embed-ready but was
    # absent from embeddable_lvs/0, so PopupHost / <.smart_link emit> / emit
    # :opened all refused to insert it (the admin Timeline tab renders it via
    # a direct live_render, which never needed the whitelist).
    setup %{actor_uuid: actor_uuid} do
      {:ok, project} =
        Projects.create_project(%{
          "name" => "Embed gantt test #{System.unique_integer([:positive])}",
          "start_mode" => "immediate",
          "started_at" => DateTime.utc_now() |> DateTime.truncate(:second)
        })

      # The embedded viewer must be able to see it — these LVs gate :view.
      {:ok, _} = PhoenixKitProjects.Members.add_member(project, actor_uuid, role: "member")

      {:ok, project: project, viewer_uuid: actor_uuid}
    end

    test "mounts off-router via live_isolated with session id", %{
      conn: conn,
      project: project,
      viewer_uuid: viewer_uuid
    } do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectGanttLive,
          session: %{"id" => project.uuid, "current_user_uuid" => viewer_uuid}
        )

      assert html =~ "flex flex-col w-full px-4 py-6 gap-4"
    end

    test "wrapper_class override replaces the default", %{
      conn: conn,
      project: project,
      viewer_uuid: viewer_uuid
    } do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectGanttLive,
          session: %{
            "id" => project.uuid,
            "current_user_uuid" => viewer_uuid,
            "wrapper_class" => "host-gantt-class"
          }
        )

      assert html =~ "host-gantt-class"
      refute html =~ "flex flex-col w-full px-4 py-6 gap-4"
    end

    test "is registered in the embeddable-LV whitelist so hosts can insert it" do
      assert WebHelpers.embeddable_lv?(PhoenixKitProjects.Web.ProjectGanttLive)

      # Both the Elixir.-prefixed (on-the-wire) and human-friendly forms
      # round-trip through the PopupHost / smart_link decoder.
      assert {:ok, PhoenixKitProjects.Web.ProjectGanttLive} =
               WebHelpers.decode_embeddable_lv("Elixir.PhoenixKitProjects.Web.ProjectGanttLive")

      assert {:ok, PhoenixKitProjects.Web.ProjectGanttLive} =
               WebHelpers.decode_embeddable_lv("PhoenixKitProjects.Web.ProjectGanttLive")
    end
  end

  describe "ProjectCalendarLive embed" do
    # The Calendar tab mirrors the Timeline's embed contract exactly:
    # off-router mount, session["id"], current_user_uuid / locale /
    # wrapper_class / headless. This block exists because the LV shipped
    # without one — absent from this gate, its embed-user branch and
    # whitelist registration went unpinned.
    setup %{actor_uuid: actor_uuid} do
      {:ok, project} =
        Projects.create_project(%{
          "name" => "Embed calendar test #{System.unique_integer([:positive])}",
          "start_mode" => "immediate",
          "started_at" => DateTime.utc_now() |> DateTime.truncate(:second)
        })

      # This LV gates :view too — the embedded viewer must be a member.
      {:ok, _} = PhoenixKitProjects.Members.add_member(project, actor_uuid, role: "member")

      {:ok, project: project, actor_uuid: actor_uuid, viewer_uuid: actor_uuid}
    end

    test "mounts off-router via live_isolated with session id", %{
      conn: conn,
      project: project,
      viewer_uuid: viewer_uuid
    } do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectCalendarLive,
          session: %{"id" => project.uuid, "current_user_uuid" => viewer_uuid}
        )

      assert html =~ "Calendar"
    end

    test "wrapper_class override replaces the default", %{
      conn: conn,
      project: project,
      viewer_uuid: viewer_uuid
    } do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectCalendarLive,
          session: %{
            "id" => project.uuid,
            "current_user_uuid" => viewer_uuid,
            "wrapper_class" => "host-calendar-class"
          }
        )

      assert html =~ "host-calendar-class"
    end

    test "current_user_uuid reconstructs the viewer for the Me filter scope", %{
      conn: conn,
      project: project,
      actor_uuid: actor_uuid
    } do
      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectCalendarLive,
          session: %{"id" => project.uuid, "current_user_uuid" => actor_uuid}
        )

      # The embed-user branch of assign_embed_user/2 rebuilt the viewer:
      # the LV survives a Me-scope resolution round-trip (the actual scope
      # value depends on staff linkage; the pin is "no crash, view alive").
      assert render(view) =~ "Calendar"
    end

    test "is registered in the embeddable-LV whitelist so hosts can insert it" do
      assert WebHelpers.embeddable_lv?(PhoenixKitProjects.Web.ProjectCalendarLive)

      assert {:ok, PhoenixKitProjects.Web.ProjectCalendarLive} =
               WebHelpers.decode_embeddable_lv(
                 "Elixir.PhoenixKitProjects.Web.ProjectCalendarLive"
               )

      assert {:ok, PhoenixKitProjects.Web.ProjectCalendarLive} =
               WebHelpers.decode_embeddable_lv("PhoenixKitProjects.Web.ProjectCalendarLive")
    end
  end

  describe "ProjectsLive embed" do
    test "mounts via live_isolated", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectsLive, session: %{})

      assert html =~ "No projects yet."
    end

    test "wrapper_class defaults to full-width", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectsLive, session: %{})

      assert html =~ "flex flex-col w-full px-4 pt-2 pb-4 gap-4"
    end

    test "wrapper_class override replaces the default", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectsLive,
          session: %{"wrapper_class" => "host-specific-class"}
        )

      assert html =~ "host-specific-class"
      refute html =~ "flex flex-col w-full px-4 py-6 gap-4"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Tier 2 — read-only LVs, medium embed value
  # ─────────────────────────────────────────────────────────────────

  describe "TemplatesLive embed" do
    test "mounts via live_isolated", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplatesLive, session: %{})

      assert html =~ "No templates yet."
    end

    test "wrapper_class defaults to full-width", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplatesLive, session: %{})

      assert html =~ "flex flex-col w-full px-4 pt-2 pb-4 gap-4"
    end

    test "wrapper_class override replaces the default", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplatesLive,
          session: %{"wrapper_class" => "host-specific-class"}
        )

      assert html =~ "host-specific-class"
      refute html =~ "flex flex-col w-full px-4 pt-2 pb-4 gap-4"
    end
  end

  describe "TasksLive embed" do
    test "mounts via live_isolated", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TasksLive, session: %{})

      assert html =~ "No tasks yet."
    end

    test "wrapper_class defaults to full-width", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TasksLive, session: %{})

      assert html =~ "flex flex-col w-full px-4 pt-2 pb-4 gap-4"
    end

    test "wrapper_class override replaces the default", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TasksLive,
          session: %{"wrapper_class" => "host-specific-class"}
        )

      assert html =~ "host-specific-class"
      refute html =~ "flex flex-col w-full px-4 py-6 gap-4"
    end

    test "view preselect via session lands on the groups tab", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TasksLive, session: %{"view" => "groups"})

      # The "groups" button is active, the "list" button is not. Attribute
      # order in rendered HTML is not stable (`phx-click` / `phx-value-*`
      # / `role` / `class` interleave by Phoenix.Component iteration
      # order); scope each assertion to a unique sibling marker.
      # Icon-only join buttons now: active state = btn-active +
      # aria-selected on the button carrying the phx-value-view.
      assert html =~ ~r/phx-value-view="groups"[^>]*aria-selected="true"/s
      refute html =~ ~r/phx-value-view="list"[^>]*aria-selected="true"/s
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Tier 3 — form LVs
  # ─────────────────────────────────────────────────────────────────

  describe "ProjectFormLive embed (:new)" do
    test "mounts via live_isolated and renders the form", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectFormLive, session: %{})

      assert html =~ "New project"
    end

    test "wrapper_class defaults to max-w-xl", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectFormLive, session: %{})

      assert html =~ "mx-auto max-w-xl"
    end

    test "wrapper_class override replaces the default", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectFormLive,
          session: %{"wrapper_class" => "flex flex-col w-full px-4 py-6 gap-4"}
        )

      assert html =~ "flex flex-col w-full px-4 py-6 gap-4"
      refute html =~ "max-w-xl"
    end

    test "redirect_to override fires push_navigate to the host path on save", %{conn: conn} do
      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectFormLive,
          session: %{"redirect_to" => "/host/orders/123"}
        )

      result =
        view
        |> form("#project-form",
          project: %{"name" => "Embedded project", "start_mode" => "immediate"}
        )
        |> render_submit()

      # `render_submit` returns `{:error, {:redirect, %{to: path}}}` when
      # the LV `push_navigate`s during the event handler.
      assert {:error, {:live_redirect, %{to: "/host/orders/123"}}} = result
    end

    # Open-redirect guard: an embedder that naively forwards an
    # unvalidated `params["return_to"]` from a query string must not be
    # able to redirect the user off-site after save. Each of these test
    # cases is a redirect-injection vector that should fall back to the
    # internal default path.
    test "redirect_to override rejects external URLs", %{conn: conn} do
      for malicious <- [
            "https://evil.example.com/phish",
            "//evil.example.com/phish",
            "javascript:alert(1)",
            "/relative/then/scheme://evil.example.com",
            ""
          ] do
        {:ok, view, _html} =
          live_isolated(conn, PhoenixKitProjects.Web.ProjectFormLive,
            session: %{"redirect_to" => malicious}
          )

        result =
          view
          |> form("#project-form",
            project: %{"name" => "Guarded project", "start_mode" => "immediate"}
          )
          |> render_submit()

        # Falls back to the default admin path; never the malicious target.
        assert {:error, {:live_redirect, %{to: to}}} = result
        refute to =~ "evil.example.com"
        refute to =~ "javascript:"
        assert String.starts_with?(to, "/")
      end
    end
  end

  describe "ProjectFormLive embed (:edit)" do
    test "edits an existing project when id is passed via session", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      project = fixture_project(%{"name" => "Existing"})

      # Editing a project's settings is an owner-floor action, so the
      # embedded viewer has to actually hold it — the form used to load any
      # project by uuid.
      {:ok, _} = PhoenixKitProjects.Members.add_member(project, actor_uuid, role: "owner")

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectFormLive,
          session: %{
            "live_action" => "edit",
            "id" => project.uuid,
            "current_user_uuid" => actor_uuid
          }
        )

      assert html =~ "Edit Existing"
    end
  end

  describe "TaskFormLive embed (:new)" do
    test "mounts via live_isolated and renders the form", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TaskFormLive, session: %{})

      assert html =~ "New task"
    end

    test "wrapper_class override replaces the default", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TaskFormLive,
          session: %{"wrapper_class" => "flex flex-col w-full px-4 py-6 gap-4"}
        )

      assert html =~ "flex flex-col w-full px-4 py-6 gap-4"
      refute html =~ "max-w-xl"
    end

    test "redirect_to override fires push_navigate to the host path on save", %{conn: conn} do
      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitProjects.Web.TaskFormLive,
          session: %{"redirect_to" => "/host/library"}
        )

      result =
        view
        |> form("#task-form",
          task: %{
            "title" => "Embedded task",
            "estimated_duration" => "1",
            "estimated_duration_unit" => "hours"
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/host/library"}}} = result
    end
  end

  describe "TemplateFormLive embed (:new)" do
    test "mounts via live_isolated and renders the form", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplateFormLive, session: %{})

      assert html =~ "New template"
    end

    test "wrapper_class override replaces the default", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplateFormLive,
          session: %{"wrapper_class" => "flex flex-col w-full px-4 py-6 gap-4"}
        )

      assert html =~ "flex flex-col w-full px-4 py-6 gap-4"
      refute html =~ "max-w-xl"
    end

    test "redirect_to override fires push_navigate to the host path on save", %{conn: conn} do
      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplateFormLive,
          session: %{"redirect_to" => "/host/templates"}
        )

      result =
        view
        |> form("#template-form", project: %{"name" => "Embedded template"})
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/host/templates"}}} = result
    end
  end

  describe "AssignmentFormLive embed (:new)" do
    # The form WRITES, so the embedded viewer has to be someone the project
    # lets write — same reason `ProjectShowLive` gates :view above. An
    # off-router mount runs no admin on_mount, so the host bridges identity
    # with `current_user_uuid` and the form resolves :create_tasks from it.
    setup %{actor_uuid: actor_uuid} do
      project = fixture_project(%{"name" => "Embed Host"})
      {:ok, _} = PhoenixKitProjects.Members.add_member(project, actor_uuid, role: "member")
      {:ok, project: project}
    end

    test "mounts via live_isolated with project_id in session", %{
      conn: conn,
      project: project,
      actor_uuid: actor_uuid
    } do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.AssignmentFormLive,
          session: %{"project_id" => project.uuid, "current_user_uuid" => actor_uuid}
        )

      assert html =~ ">Add task<"
      assert html =~ "Embed Host"
    end

    test "a stranger embedding the form is refused, shaped as not-found", %{
      conn: conn,
      project: project
    } do
      # Reachable by anyone who can send a mount: the form used to load for
      # any module-reacher on any project uuid, floors unconsulted.
      {:ok, other} =
        Auth.register_user(%{
          "email" => "embed-form-stranger-#{System.unique_integer([:positive])}@example.com",
          "password" => "StrangerPass123!"
        })

      assert {:error, {:live_redirect, %{flash: %{"error" => flash}}}} =
               live_isolated(conn, PhoenixKitProjects.Web.AssignmentFormLive,
                 session: %{"project_id" => project.uuid, "current_user_uuid" => other.uuid}
               )

      # Indistinguishable from a missing project: existence is information.
      assert flash =~ "not found"
    end

    test "wrapper_class override replaces the default", %{
      conn: conn,
      project: project,
      actor_uuid: actor_uuid
    } do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.AssignmentFormLive,
          session: %{
            "project_id" => project.uuid,
            "current_user_uuid" => actor_uuid,
            "wrapper_class" => "flex flex-col w-full px-4 py-6 gap-4"
          }
        )

      assert html =~ "flex flex-col w-full px-4 py-6 gap-4"
      refute html =~ "max-w-xl"
    end

    test "missing project flashes + navigates to embed redirect_to override", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      bogus = Ecto.UUID.generate()

      result =
        live_isolated(conn, PhoenixKitProjects.Web.AssignmentFormLive,
          session: %{
            "project_id" => bogus,
            "current_user_uuid" => actor_uuid,
            "redirect_to" => "/host/dashboard"
          }
        )

      assert {:error, {:live_redirect, %{to: "/host/dashboard"}}} = result
    end
  end

  describe "AssignmentFormLive embed (:edit)" do
    test "edits an existing assignment when project_id + id are passed via session", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _} = PhoenixKitProjects.Members.add_member(project, actor_uuid, role: "member")
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.AssignmentFormLive,
          session: %{
            "live_action" => "edit",
            "project_id" => project.uuid,
            "current_user_uuid" => actor_uuid,
            "id" => assignment.uuid
          }
        )

      # Title references the assignment's task (falls back to "Edit assignment"
      # only when the task can't be resolved).
      assert html =~ "Edit #{task.title}"
    end
  end
end
