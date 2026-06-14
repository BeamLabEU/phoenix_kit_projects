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

      assert html =~ "flex flex-col w-full px-4 py-6 gap-6"
    end

    test "wrapper_class override from session replaces the default", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.OverviewLive,
          session: %{"wrapper_class" => "host-specific-class"}
        )

      assert html =~ "host-specific-class"
      refute html =~ "flex flex-col w-full px-4 py-6 gap-6"
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

      _ = actor_uuid
      {:ok, project: project}
    end

    test "mounts off-router without :phoenix_kit_current_scope in assigns", %{
      conn: conn,
      project: project
    } do
      # `live_isolated` mounts the LV without going through the router,
      # so no `phoenix_kit_routes()` on_mount fires. The LV must render
      # without crashing.
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: %{"id" => project.uuid}
        )

      assert html =~ project.name
    end

    test "opening the comments drawer off-router does not crash", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: %{"id" => project.uuid}
        )

      # Triggers the `comments_drawer_open` render branch that reads the
      # missing-by-design `:phoenix_kit_current_scope` assign. Pre-fix
      # this raised `KeyError`; post-fix the bracket-access pattern
      # tolerates the missing assign and the drawer renders with
      # `current_user: nil`.
      html =
        render_hook(view, "open_comments", %{
          "type" => "project",
          "uuid" => project.uuid,
          "title" => project.name
        })

      # The drawer renders an `<aside aria-label="Comments">` with the
      # resource title in the header. Pre-fix this branch crashed with
      # `KeyError :phoenix_kit_current_scope`; the assertion proves the
      # render path completed.
      assert html =~ ~s|aria-label="Comments"|
      assert html =~ project.name
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

  describe "ProjectsLive embed" do
    test "mounts via live_isolated", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectsLive, session: %{})

      assert html =~ "Projects"
    end

    test "wrapper_class defaults to full-width", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectsLive, session: %{})

      assert html =~ "flex flex-col w-full px-4 py-6 gap-4"
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

      assert html =~ "Templates"
    end

    test "wrapper_class defaults to full-width", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplatesLive, session: %{})

      assert html =~ "flex flex-col w-full px-4 py-6 gap-4"
    end

    test "wrapper_class override replaces the default", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TemplatesLive,
          session: %{"wrapper_class" => "host-specific-class"}
        )

      assert html =~ "host-specific-class"
      refute html =~ "flex flex-col w-full px-4 py-6 gap-4"
    end
  end

  describe "TasksLive embed" do
    test "mounts via live_isolated", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TasksLive, session: %{})

      assert html =~ "Task Library"
    end

    test "wrapper_class defaults to full-width", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.TasksLive, session: %{})

      assert html =~ "flex flex-col w-full px-4 py-6 gap-4"
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
      assert html =~ ~r/phx-value-view="groups"[^>]*tab-active/s
      refute html =~ ~r/phx-value-view="list"[^>]*tab-active/s
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
    test "edits an existing project when id is passed via session", %{conn: conn} do
      project = fixture_project(%{"name" => "Existing"})

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectFormLive,
          session: %{"live_action" => "edit", "id" => project.uuid}
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
    test "mounts via live_isolated with project_id in session", %{conn: conn} do
      project = fixture_project(%{"name" => "Embed Host"})

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.AssignmentFormLive,
          session: %{"project_id" => project.uuid}
        )

      assert html =~ "Add task to Embed Host"
    end

    test "wrapper_class override replaces the default", %{conn: conn} do
      project = fixture_project()

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.AssignmentFormLive,
          session: %{
            "project_id" => project.uuid,
            "wrapper_class" => "flex flex-col w-full px-4 py-6 gap-4"
          }
        )

      assert html =~ "flex flex-col w-full px-4 py-6 gap-4"
      refute html =~ "max-w-xl"
    end

    test "missing project flashes + navigates to embed redirect_to override", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      result =
        live_isolated(conn, PhoenixKitProjects.Web.AssignmentFormLive,
          session: %{
            "project_id" => bogus,
            "redirect_to" => "/host/dashboard"
          }
        )

      assert {:error, {:live_redirect, %{to: "/host/dashboard"}}} = result
    end
  end

  describe "AssignmentFormLive embed (:edit)" do
    test "edits an existing assignment when project_id + id are passed via session", %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})
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
            "id" => assignment.uuid
          }
        )

      # Title references the assignment's task (falls back to "Edit assignment"
      # only when the task can't be resolved).
      assert html =~ "Edit task:"
    end
  end
end
