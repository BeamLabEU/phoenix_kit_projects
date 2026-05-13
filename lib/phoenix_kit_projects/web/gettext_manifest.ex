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

  use Gettext, backend: PhoenixKitProjects.Gettext

  @doc false
  def __extract__ do
    [
      # `permission_metadata/0` description and label.
      gettext("Manage projects, tasks, and assignments"),

      # Top-level + visible subtab labels (`admin_tabs/0`).
      gettext("Projects"),
      gettext("Overview"),
      gettext("Templates"),
      gettext("Tasks"),

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
