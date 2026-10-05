defmodule PhoenixKitProjects.Web.Routes do
  @moduledoc """
  Route contributions beyond the admin tabs (which auto-generate from
  `admin_tabs/0` / `user_dashboard_tabs/0`): the PUBLIC portal surface and
  the JSON API (`PhoenixKitProjects.Web.Api`, under `/api/projects/v1`).

  `generate/1` is core's `compile_module_public_routes` hook — the AST
  splices into the host router at top level, before the `/:locale` public
  surface, so the path uses a LITERAL first segment (`/portal/...`), the
  documented safe shape there. No locale segment in v1 (one less
  unvalidated public param — panel #16).
  """

  @doc false
  def generate(url_prefix) do
    quote do
      # Declared at router top level (legal here — the splice point is the
      # router body): privacy headers for the public portal pages. The
      # slug is a capability URL — it must not leak via Referer or
      # search indexing (panel #10).
      pipeline :pk_projects_portal do
        plug(PhoenixKitProjects.Web.PortalHeaders)
      end

      # The JSON API an outside agent drives a project with. Bearer-token
      # auth (`Web.Api.Auth`), no session, no CSRF, no locale segment — a
      # machine contract, and the error messages are English on purpose.
      pipeline :pk_projects_api do
        plug(:accepts, ["json"])
        plug(PhoenixKitProjects.Web.Api.Auth)
      end

      pipeline :pk_projects_api_docs do
        plug(:accepts, ["json", "text", "markdown"])
      end

      scope unquote(url_prefix) <> "/api/projects/v1", PhoenixKitProjects.Web.Api do
        pipe_through([:pk_projects_api_docs])

        get("/llms.txt", DocsController, :llms_txt)
        get("/openapi.json", DocsController, :openapi)
      end

      scope unquote(url_prefix) <> "/api/projects/v1", PhoenixKitProjects.Web.Api do
        pipe_through([:pk_projects_api])

        get("/me", MeController, :show)
        get("/project", ProjectController, :show)
        post("/project/status", ProjectController, :set_status)
        post("/subprojects", ProjectController, :create_subproject)
        get("/tasks", TasksController, :index)
        post("/tasks", TasksController, :create)
        get("/tasks/:id", TasksController, :show)
        patch("/tasks/:id", TasksController, :update)
        post("/tasks/:id/transition", TasksController, :transition)
        get("/tasks/:id/notes", NotesController, :index)
        post("/tasks/:id/notes", NotesController, :create)
        # Records an extension puts on the API (`Extensions.ApiProvider`).
        get("/ext/:resource", ExtController, :index)
        post("/ext/:resource", ExtController, :create)
        get("/ext/:resource/:id", ExtController, :show)
        patch("/ext/:resource/:id", ExtController, :update)
        post("/tasks/:id/start", TasksController, :start)
        post("/tasks/:id/complete", TasksController, :complete)
        post("/tasks/:id/reopen", TasksController, :reopen)
        post("/tasks/:id/time", LedgerController, :task_time)
        post("/tasks/:id/usage", LedgerController, :task_usage)
        post("/time", LedgerController, :project_time)
        post("/usage", LedgerController, :project_usage)
      end

      scope unquote(url_prefix) do
        pipe_through([:browser, :phoenix_kit_auto_setup, :pk_projects_portal])

        # `mount_current_scope` LOADS identity without requiring it: the
        # portal stays reachable to anonymous visitors, and a `members`
        # board can still tell whether someone is signed in. Requiring auth
        # at the router instead would break `link` and `public` boards,
        # which is why the check lives in `Portal.resolve/2`.
        live_session :pk_projects_portal,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
          live("/portal/:slug", PhoenixKitProjects.Web.PortalLive, :show)
          # One issue, with its discussion. Addressed by uuid rather than a
          # per-board number: numbering is a nicety that needs its own
          # column, backfill and uniqueness story, and the identifier is
          # not a secret — everything on this page is already visible to
          # whoever can reach the board.
          live("/portal/:slug/i/:issue", PhoenixKitProjects.Web.PortalLive, :issue)
          # Reporting gets its own page rather than a dialog. A submission
          # is a considered act — people write paragraphs and paste error
          # output — and a backdrop click that eats 300 words is a
          # betrayal. A modal would also be a second copy of an
          # abuse-exposed form to keep in sync.
          #
          # This is a `live` route, so submitting still needs JS: the page
          # renders and reads fine without it, but there is no plain POST
          # endpoint behind the form, and `allow_upload` cannot work at all
          # without the channel. An earlier comment here claimed this route
          # WAS the no-JS path — it never was. A real fallback means a
          # controller action doing its own honeypot/fill-time/rate-limit
          # pass, which is a second abuse-exposed entry point; worth
          # building deliberately, not worth implying we already have.
          live("/portal/:slug/report", PhoenixKitProjects.Web.PortalLive, :report)
        end
      end
    end
  end
end
