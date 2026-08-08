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

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if public_board?(conn) do
      put_resp_header(conn, "referrer-policy", "strict-origin-when-cross-origin")
    else
      conn
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("x-robots-tag", "noindex, nofollow")
    end
  end

  # One indexed lookup by slug. The LiveView resolves the portal again for
  # its own reasons; doing it here too is what lets the header decision be
  # made before a byte of the page is written.
  defp public_board?(%Plug.Conn{path_params: %{"slug" => slug}}) when is_binary(slug) do
    case PhoenixKitProjects.Portal.access_mode_of(slug) do
      "public" -> true
      _ -> false
    end
  end

  defp public_board?(_conn), do: false
end
