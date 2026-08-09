defmodule PhoenixKitProjects.Web.PortalHeadersTest do
  @moduledoc """
  The plug that decides, before a byte of the page is written, whether this
  URL is a secret or a published address.

  Everything here is about the restrictive branch being the default: an OG
  preview or a relaxed robots policy on a capability link would hand that
  link to every chat service that unfurls it.
  """
  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{Extensions, Portal, Projects}
  alias PhoenixKitProjects.Web.PortalHeaders

  defp uniq, do: System.unique_integer([:positive])

  defp call(slug) do
    :get
    |> Plug.Test.conn("/portal/#{slug}")
    |> Map.put(:path_params, %{"slug" => slug})
    |> PortalHeaders.call([])
  end

  setup do
    PhoenixKitProjects.Extensions.Registry.refresh()

    {:ok, project} =
      Projects.create_project(%{
        "name" => "Board #{uniq()}",
        "description" => "How we track work",
        "start_mode" => "immediate"
      })

    {:ok, _} = Extensions.enable(project, "portal")
    {:ok, project: project, portal: Portal.get_portal(project.uuid)}
  end

  describe "a capability link" do
    test "is kept out of search and out of Referer headers", %{portal: portal} do
      conn = call(portal.slug)

      assert Plug.Conn.get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
      assert Plug.Conn.get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    end

    test "gets NO social preview", %{portal: portal} do
      # The OG image endpoint is unauthenticated by design, and an unfurl
      # hands the secret URL to whichever service did it.
      refute call(portal.slug).assigns[:og]
    end
  end

  describe "a members board" do
    test "is still kept out of search", %{project: project} do
      {:ok, portal} = Portal.set_access_mode(project.uuid, "members")
      conn = call(portal.slug)

      assert Plug.Conn.get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
      refute conn.assigns[:og]
    end
  end

  describe "a public board" do
    setup %{project: project} do
      {:ok, portal} = Portal.set_access_mode(project.uuid, "public", slug: "board-#{uniq()}")
      {:ok, portal: portal}
    end

    test "may be indexed — being found is the point", %{portal: portal} do
      conn = call(portal.slug)

      assert Plug.Conn.get_resp_header(conn, "x-robots-tag") == []
    end

    test "keeps a sane referrer policy anyway", %{portal: portal} do
      # Relaxing this leaks full URLs into third-party access logs and buys
      # nothing: only the robots directives need to change.
      assert Plug.Conn.get_resp_header(call(portal.slug), "referrer-policy") ==
               ["strict-origin-when-cross-origin"]
    end

    test "carries a social preview", %{portal: portal, project: project} do
      og = call(portal.slug).assigns[:og]

      assert og.title == project.name
      assert og.description == "How we track work"
      assert og.url =~ portal.slug
      assert og.type == "website"
    end
  end

  describe "anything unconfirmable" do
    test "an unknown slug gets the restrictive treatment" do
      conn = call("no-such-board-#{uniq()}")

      assert Plug.Conn.get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
      refute conn.assigns[:og]
    end

    test "a portal whose extension was turned off stops being public", %{
      project: project,
      portal: _portal
    } do
      {:ok, portal} = Portal.set_access_mode(project.uuid, "public", slug: "gone-#{uniq()}")
      {:ok, _} = Extensions.disable(project, "portal")

      conn = call(portal.slug)

      assert Plug.Conn.get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
      refute conn.assigns[:og]
    end
  end
end
