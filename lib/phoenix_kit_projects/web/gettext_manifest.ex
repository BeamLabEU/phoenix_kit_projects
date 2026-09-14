defmodule PhoenixKitProjects.Web.GettextManifest do
  @moduledoc false

  # Lists the static Tab labels declared in
  # `phoenix_kit_projects.ex` (`permission_metadata/0` + `admin_tabs/0`) so
  # that `mix gettext.extract` records them into this module's
  # `priv/gettext/default.pot`. The labels themselves are not gettext call
  # sites — they're static strings inside `%Tab{}` structs that core's
  # dashboard renderer translates at display time via
  # `gettext_backend: PhoenixKitProjects.Gettext`. Without this manifest the
  # extractor wouldn't see them and the sidebar would render the raw
  # English strings.
  #
  # Mirrors the `legal_gettext_manifest.ex` and `projects_gettext_manifest.ex`
  # pattern in core. This module is never called at runtime.
  #
  # ## Refreshing the list
  #
  # When a Tab label is added or renamed in `phoenix_kit_projects.ex`,
  # append/update the corresponding `gettext("...")` here, then run
  # `mix gettext.extract && mix gettext.merge priv/gettext --no-fuzzy`.
  #
  # ⚠️ A label missing from this list is invisible to EVERY completeness
  # check: the catalogues stay in perfect parity with each other and report
  # zero empty `msgstr`, because a string that reached no catalogue at all is
  # in none of them to be counted. The only check that sees it is a diff of
  # the literals in `lib/` against `default.pot`.

  use Gettext, backend: PhoenixKitProjects.Gettext

  @doc false
  def __extract__ do
    [
      # `permission_metadata/0` label, description, and sub-permission.
      # These are what a viewer reads in the admin permission matrix.
      gettext("Projects"),
      gettext("Reach the Projects module — see the projects you belong to"),
      gettext("Administer all projects"),
      gettext(
        "See and manage every project on the site, including ones this user is not a member of"
      ),

      # Top-level + visible subtab labels (`admin_tabs/0`).
      gettext("Overview"),
      gettext("Templates"),
      gettext("Tasks"),

      # Per-project subtabs. Listed even where the same literal happens to
      # appear in an ordinary `gettext/1` call elsewhere in the module: that
      # coverage is coincidental and one unrelated refactor away from
      # vanishing, which would drop the label out of every catalogue without
      # a single test going red.
      gettext("Board"),
      gettext("Timeline"),
      gettext("Calendar"),
      gettext("Comments"),
      gettext("My Projects"),
      gettext("Project Files"),
      gettext("Project Activity"),
      gettext("Project Members"),
      gettext("Project Modules"),

      # Hidden subtabs (used for routing + page-header crumbs).
      gettext("New Task"),
      gettext("Edit Task"),
      gettext("New Project"),
      gettext("Edit Project"),
      gettext("Project"),
      gettext("New Template"),
      gettext("Edit Template"),
      gettext("Template"),
      gettext("Add Task"),
      gettext("Edit Assignment")
    ]
  end
end
