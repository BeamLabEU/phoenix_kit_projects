defmodule PhoenixKitProjects.Web.ListRedirectLive do
  @moduledoc """
  Redirects the legacy `…/admin/projects/list[/…]` addresses to the same
  path without the `list` segment.

  Until 2026-09 the project list lived at `/admin/projects/list` (the
  Projects tab opened the Overview) and every project page was nested
  under it — `list/new`, `list/:id`, `list/:id/board`,
  `list/:id/assignments/new`… The list is the landing page now and the
  project pages sit directly under `/admin/projects`. Bookmarks, host apps'
  `redirect_to` values and mention links written before the move still
  carry the segment, so two hidden tabs (`projects/list` and
  `projects/list/*rest`) route here and this view drops it: the rest of the
  path, the query string and the locale prefix are kept as they were.

  A full redirect rather than `push_navigate/2`: it also works from the
  disconnected (HTTP) mount, which is what a bookmark hits first.
  """
  use PhoenixKitWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, redirect(socket, to: strip_list_segment(uri))}
  end

  @doc false
  # Pure, so the mapping is unit-testable: the FIRST `/admin/projects/list`
  # segment run becomes `/admin/projects`; everything else (URL prefix,
  # locale, deeper segments, query) is untouched. Anchored on the `admin`
  # segment too (codex, 2026-09-05): the kit's URL prefix is host-chosen,
  # and a prefix that itself contained `/projects/list` would otherwise be
  # the occurrence that gets rewritten.
  @spec strip_list_segment(String.t()) :: String.t()
  def strip_list_segment(uri) do
    %URI{path: path, query: query} = URI.parse(uri)

    stripped =
      Regex.replace(~r{/admin/projects/list(?=/|$)}, path || "/", "/admin/projects",
        global: false
      )

    if query in [nil, ""], do: stripped, else: stripped <> "?" <> query
  end

  @impl true
  def render(assigns) do
    ~H""
  end
end
