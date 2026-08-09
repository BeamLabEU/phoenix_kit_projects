defmodule PhoenixKitProjects.Web.PortalHeaders do
  @moduledoc """
  Privacy headers for the portal, chosen from the portal's access mode.

  For a `link` portal the slug in the URL is a capability — `no-referrer`
  keeps it out of outbound Referer headers and `X-Robots-Tag` keeps the
  page out of search indexes (the LiveView adds a meta-robots belt to this
  suspender). A `members` portal keeps both: the slug stops being the
  check, but nothing is gained by making it guessable or indexable.

  A `public` board drops only the ROBOTS directives — being found is the
  point. It keeps a referrer policy, because relaxing that leaks full URLs
  into third-party access logs and buys nothing.

  Fail-closed by construction: the restrictive headers are the default, and
  only an explicit, resolvable `public` portal relaxes them. An unknown
  slug, a database blip, a disabled extension — anything at all that isn't
  a confirmed public board — is treated as secret.
  """

  @behaviour Plug

  import Plug.Conn

  alias PhoenixKit.Utils.Routes

  # phoenix_kit_og is an OPTIONAL dep and may not be compiled into a given
  # host, so the guarded remote call needs this to stay quiet — the same
  # seam publishing uses for the same module.
  @og_module PhoenixKitOG
  @compile {:no_warn_undefined, PhoenixKitOG}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case portal_for(conn) do
      {:ok, portal, project} ->
        conn
        |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
        |> assign_og(portal, project)

      :none ->
        conn
        |> put_resp_header("referrer-policy", "no-referrer")
        |> put_resp_header("x-robots-tag", "noindex, nofollow")
    end
  end

  # Social previews for PUBLIC boards only, and the restriction is not
  # cosmetic. The OG image endpoint is unauthenticated by design — Facebook
  # and Slack carry no session — so generating one for a capability portal
  # would publish that project's name to a URL anybody can fetch, and hand
  # the secret link itself to every chat service that unfurls it.
  #
  # The root layout reads `assigns[:og]` from the CONN, so this has to
  # happen here rather than in the LiveView: a mount-time assign never
  # reaches the document head.
  defp assign_og(conn, portal, project) do
    og = %{
      type: "website",
      title: project.name,
      description: board_description(project),
      url: Routes.url("/portal/#{portal.slug}")
    }

    assign(conn, :og, maybe_put_image(og, project, conn))
  rescue
    # A preview is decoration. It must never be able to stop the page.
    _ -> conn
  end

  defp maybe_put_image(og, project, conn) do
    mod = @og_module

    if Code.ensure_loaded?(mod) and function_exported?(mod, :og_image_url, 5) do
      case mod.og_image_url(
             "projects",
             [{"project", project.uuid}, {"default", nil}],
             project,
             conn,
             []
           ) do
        {:ok, url} -> Map.put(og, :image, url)
        _ -> og
      end
    else
      og
    end
  end

  defp board_description(project) do
    case project.description do
      desc when is_binary(desc) and desc != "" ->
        desc |> String.slice(0, 200)

      _ ->
        "Public issue board"
    end
  end

  # One indexed lookup by slug. The LiveView resolves the portal again for
  # its own reasons; doing it here too is what lets the header decision be
  # made before a byte of the page is written.
  #
  # Returns the portal ONLY when it is a confirmed public board. Everything
  # else — unknown slug, database blip, a link or members portal — is
  # `:none`, which is the restrictive branch.
  defp portal_for(%Plug.Conn{path_params: %{"slug" => slug}}) when is_binary(slug) do
    case PhoenixKitProjects.Portal.get_public_board(slug) do
      {:ok, portal, project} -> {:ok, portal, project}
      _ -> :none
    end
  end

  defp portal_for(_conn), do: :none
end
