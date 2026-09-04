defmodule PhoenixKitProjects.Web.ListRedirectLive do
  @moduledoc """
  The project list used to live at `/admin/projects/list`; since the list
  became the module's landing page (2026-09) that bare path only redirects
  there. Every project page still lives under `list/:id/…` — this LiveView
  is mounted on the exact legacy path only, so nothing else is affected.

  A full redirect rather than `push_navigate/2`: it also works from the
  disconnected (HTTP) mount, which is what a bookmark or an old
  `redirect_to` hits first.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKitProjects.Paths

  @impl true
  def mount(_params, _session, socket) do
    {:ok, redirect(socket, to: Paths.projects())}
  end

  @impl true
  def render(assigns) do
    ~H""
  end
end
