defmodule PhoenixKitProjects.Web.PortalHeaders do
  @moduledoc """
  Privacy headers for the public portal (security panel #10): the slug in
  the URL is a capability — `Referrer-Policy: no-referrer` keeps it out
  of outbound Referer headers and `X-Robots-Tag` keeps the pages out of
  search indexes (the LV adds the meta-robots belt to this suspender).
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
  end
end
