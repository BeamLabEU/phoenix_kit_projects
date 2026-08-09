defmodule PhoenixKitProjects.PortalLinks do
  @moduledoc """
  Makes a PUBLISHED portal issue mentionable — as its public URL.

  ## Why this is not just another type on `ResourceLinks`

  A portal issue IS an assignment, so it shares its uuid with the
  `project_task` type. The handler callback receives a flat uuid list with
  no type attached, so one module answering for both would resolve the same
  uuid twice and the merge would decide which link won — silently, and in
  favour of whichever branch ran last. Splitting the type onto its own
  module is what keeps "the admin page for staff" and "the public page for
  everyone" from collapsing into each other.

  ## The link has to be the public one

  `project_task` resolves to `/admin/projects/list/<project>`, which an
  anonymous reader cannot open. Linking a portal issue to that page would
  render every `#` on a public board as a locked chip pointing at an admin
  URL. This resolves to `/portal/<slug>/i/<uuid>` — the page the reader is
  already on the same board as.

  ## Visibility is the board's, not the project's

  `ResourceLinks.visible_resource_uuids/2` answers "may this viewer open
  the project", which is the wrong question here: portal readers are
  usually anonymous and belong to nothing. The right question is "is this
  issue published on a board this viewer may reach", and that is exactly
  what `Portal.resolve/2` plus the board's own scoping already decide — so
  this defers to them rather than reimplementing the rule.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Portal
  alias PhoenixKitProjects.Schemas.Assignment

  @type_key "portal_issue"

  @doc "The single type this module owns, for the `resource_links/0` callback."
  @spec types() :: %{String.t() => module()}
  def types, do: %{@type_key => __MODULE__}

  @doc false
  @spec type_key() :: String.t()
  def type_key, do: @type_key

  @doc """
  Titles and RAW public paths for published portal issues.

  Raw because `ResourceLinks` applies the url prefix once at render.
  A uuid that is not a published issue on a live portal simply isn't in the
  result — the caller renders that as missing, which is the correct answer
  for an issue that was unpublished after someone linked it.
  """
  @spec resolve_comment_resources([String.t()]) :: map()
  def resolve_comment_resources(uuids) when is_list(uuids) do
    uuids
    |> published_rows()
    |> Map.new(fn {assignment, slug} ->
      title = Assignment.label(assignment)

      {assignment.uuid,
       %{title: title, full_title: title, path: "/portal/#{slug}/i/#{assignment.uuid}"}}
    end)
  rescue
    e ->
      Logger.warning("[Projects.PortalLinks] resolve failed: #{Exception.message(e)}")
      %{}
  end

  def resolve_comment_resources(_), do: %{}

  @doc """
  Which of these issues this viewer may actually read.

  Deliberately re-runs the board check per issue rather than trusting that
  a published row is universally readable: `link` and `members` boards
  publish too, and their audiences are not the open web. `Portal.resolve/2`
  is the same doorway the page itself uses, so a board that goes private,
  rotates its slug or loses the extension takes its mentions with it.
  """
  @spec visible_resource_uuids([String.t()], keyword()) :: [String.t()]
  def visible_resource_uuids(uuids, opts) when is_list(uuids) do
    viewer = Keyword.get(opts, :scope)

    rows = published_rows(uuids)

    # One resolve per DISTINCT board, not per row. A discussion that links
    # twenty issues from the same board asked the same question twenty
    # times, and `resolve/2` is several queries deep.
    admitted =
      rows
      |> Enum.map(fn {_assignment, slug} -> slug end)
      |> Enum.uniq()
      |> Enum.filter(fn slug -> Portal.resolve(slug, viewer) != :error end)
      |> MapSet.new()

    rows
    |> Enum.filter(fn {_assignment, slug} -> MapSet.member?(admitted, slug) end)
    |> Enum.map(fn {assignment, _slug} -> assignment.uuid end)
  rescue
    e ->
      Logger.warning("[Projects.PortalLinks] visibility failed: #{Exception.message(e)}")
      []
  end

  def visible_resource_uuids(_uuids, _opts), do: []

  @doc """
  Not globally searchable, on purpose.

  Core asks every registered type for `#` results, and a portal issue
  offered from an ADMIN composer would be the wrong record to link: staff
  writing internally want the task, which `project_task` already provides,
  and a public URL pasted into an internal note invites exactly the mixup
  this module exists to prevent. The portal composer builds its own list,
  scoped to the one board being read — see `Portal.mention_candidates/4`.
  """
  @spec search_resources(String.t(), keyword()) :: []
  def search_resources(_query, _opts), do: []

  # Published rows joined to their portal slug, in ONE query. Anything not
  # currently published — or whose project has no portal row at all — drops
  # out here, which is what makes every caller above fail closed.
  defp published_rows([]), do: []

  defp published_rows(uuids) do
    from(a in Assignment,
      join: p in PhoenixKitProjects.Schemas.Portal,
      on: p.project_uuid == a.project_uuid,
      # The SAME two-part rule the board renders from. `public` alone is
      # not enough on a public board: un-publishing clears
      # `board_published_at` and deliberately LEAVES `public` true, so
      # matching on `public` only meant an issue pulled off the open-web
      # board kept its title alive inside every discussion that had ever
      # linked it — still resolving, still linking, still current.
      where:
        a.uuid in ^uuids and a.public == true and
          (p.access_mode != "public" or not is_nil(a.board_published_at)),
      preload: [:task, :child_project],
      select: {a, p.slug}
    )
    |> RepoHelper.repo().all()
  rescue
    _ -> []
  end
end
