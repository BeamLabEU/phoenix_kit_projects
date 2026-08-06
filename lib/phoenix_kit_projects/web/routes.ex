defmodule PhoenixKitProjects.Web.Routes do
  @moduledoc """
  Route contributions beyond the admin tabs (which auto-generate from
  `admin_tabs/0` / `user_dashboard_tabs/0`): the PUBLIC portal surface.

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

      scope unquote(url_prefix) do
        pipe_through([:browser, :phoenix_kit_auto_setup, :pk_projects_portal])

        live_session :pk_projects_portal do
          live("/portal/:slug", PhoenixKitProjects.Web.PortalLive, :show)
        end
      end
    end
  end
end
