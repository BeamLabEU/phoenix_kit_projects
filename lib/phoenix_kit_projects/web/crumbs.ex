defmodule PhoenixKitProjects.Web.Crumbs do
  @moduledoc """
  The admin header's breadcrumb trail for this module's pages — one place
  for the rules, so every LiveView reads the same way (panel round with
  codex/grok/zai, 2026-09-05):

      Admin Panel / Projects / …                      every page of the module
      Admin Panel / Projects / Tasks / New task        subtab pages: subtab label as the crumb
      Admin Panel / Projects / Test / Files            sub-pages are crumbs, not "Test · Files"
      Admin Panel / Projects / Parent / Child          sub-projects show their parent chain
      Admin Panel / Projects / Test / Add task         "Add" attaches to the project crumb…
      Admin Panel / Projects / Tasks / New task        …"New" creates a standalone record
      Admin Panel / Projects / Tasks / Edit <name>     edit names its object (core's Users convention)

  The trail is core's contract: `page_section` (+ `page_section_path`) is
  the module tab, `page_crumbs` the linked middle, `page_title` the plain
  leaf. The project's List/Board/Timeline/Calendar tabs are views of one
  place and never appear. Crumb labels reuse the subtab labels verbatim
  so the trail mirrors the sidebar.

  Known limit of the core contract, not fixed here: `page_title` is also
  the browser tab title, so a short leaf ("Files", "Add task") makes a
  weak tab title. Every panel seat flagged it — the fix is a separate
  browser-title assign in core.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKitProjects.{Authz, L10n, Paths, Projects}
  alias PhoenixKitProjects.Schemas.Project

  @doc "The assigns every page of the module starts from: the Projects section."
  @spec section() :: keyword()
  def section, do: [page_section: gettext("Projects"), page_section_path: Paths.projects()]

  @doc "The Tasks subtab as a crumb."
  @spec tasks() :: map()
  def tasks, do: %{label: gettext("Tasks"), path: Paths.tasks()}

  @doc "The Templates subtab as a crumb."
  @spec templates() :: map()
  def templates, do: %{label: gettext("Templates"), path: Paths.templates()}

  @doc """
  A project (or template) as crumbs: the ancestors the viewer may see,
  root first, then the project itself — every one linked. `lang` picks
  the localized name. `scope` is the viewer: an ancestor the viewer holds
  no `:view` on is left out of the trail (its name is information about a
  project this reader was refused — the module answers such a project as
  "not found", and the trail must not say otherwise; the sweep, 2026-09-05).
  A nil scope sees no ancestors.
  """
  @spec project(Project.t(), String.t() | nil, term()) :: [map()]
  def project(%Project{is_template: true} = template, lang, _scope) do
    [
      templates(),
      %{label: Project.localized_name(template, lang), path: Paths.template(template.uuid)}
    ]
  end

  def project(%Project{} = project, lang, scope) do
    (viewable_chain(project, scope) ++ [project])
    |> Enum.map(&%{label: Project.localized_name(&1, lang), path: Paths.project(&1.uuid)})
  end

  @doc "Section + the project's crumbs, ready to `assign/2` before `page_title`."
  @spec under_project(Project.t(), term()) :: keyword()
  def under_project(%Project{} = project, scope) do
    section() ++ [page_crumbs: project(project, L10n.current_content_lang(), scope)]
  end

  @doc "Section + one subtab crumb (`:tasks` | `:templates`)."
  @spec under(:tasks | :templates) :: keyword()
  def under(:tasks), do: section() ++ [page_crumbs: [tasks()]]
  def under(:templates), do: section() ++ [page_crumbs: [templates()]]

  @doc "Section + the project's crumbs MINUS the project itself (for the project page, whose title is the name)."
  @spec above_project(Project.t(), term()) :: keyword()
  def above_project(%Project{is_template: true}, _scope),
    do: section() ++ [page_crumbs: [templates()]]

  def above_project(%Project{} = project, scope) do
    lang = L10n.current_content_lang()

    section() ++
      [
        page_crumbs:
          project
          |> viewable_chain(scope)
          |> Enum.map(&%{label: Project.localized_name(&1, lang), path: Paths.project(&1.uuid)})
      ]
  end

  defp viewable_chain(%Project{uuid: uuid}, scope) do
    uuid
    |> Projects.parent_chain()
    |> Enum.filter(&Authz.can?(scope, &1, :view))
  end
end
