defmodule PhoenixKitProjects.ResourceLinks do
  @moduledoc """
  Makes projects and their tasks linkable and mentionable from anywhere.

  Three jobs, all against the same two types (`project`, `project_task`):

    * `resolve_comment_resources/1` — the long-standing contract that lets
      the Activity feed and Comments deep-link a record;
    * `search_resources/2` — what the `#` typeahead offers;
    * `visible_resource_uuids/2` — which of these a given viewer may see.

  ## Permissions are this module's problem, not core's

  Core federates the question and never second-guesses the answer, which
  means a bug here is a leak. Both directions go through `Authz`, the same
  resolver the project pages use, rather than a private query:

    * search narrows to `list_projects_for/2`, so the typeahead cannot
      offer a project the searcher can't open — a picker that lists private
      titles has already leaked them, whatever the renderer does later;
    * visibility answers for the READER, who is usually not the author.

  Tasks inherit their project's answer. A task is not independently
  visible, so asking about the task means asking about its project.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.{Authz, L10n, Projects}
  alias PhoenixKitProjects.Schemas.{Assignment, Project}

  @base "/admin/projects"
  @search_limit 6

  defp repo, do: RepoHelper.repo()

  @doc """
  The types this module owns, for the `resource_links/0` callback.
  """
  @spec types() :: %{String.t() => module()}
  def types do
    %{"project" => __MODULE__, "project_task" => __MODULE__}
  end

  # ── Resolve ─────────────────────────────────────────────────────────

  @doc """
  Titles and RAW deep-links for the given uuids.

  Raw because `ResourceLinks` applies the url prefix once at render — a
  pre-prefixed path double-prefixes under a non-root install.

  Answers for BOTH types in one call: the caller groups by type, so a list
  of task uuids and a list of project uuids arrive separately, and a uuid
  that matches neither simply isn't in the result.
  """
  @spec resolve_comment_resources([String.t()]) :: map()
  def resolve_comment_resources(uuids) when is_list(uuids) do
    lang = L10n.current_content_lang()

    projects =
      Project
      |> where([p], p.uuid in ^uuids)
      |> repo().all()
      |> Map.new(fn project ->
        title = Project.localized_name(project, lang)

        {project.uuid, %{title: title, full_title: title, path: "#{@base}/#{project.uuid}"}}
      end)

    tasks =
      Assignment
      |> where([a], a.uuid in ^uuids)
      |> preload(:task)
      |> repo().all()
      |> Map.new(fn assignment ->
        title = Assignment.label(assignment)

        {assignment.uuid,
         %{
           title: title,
           full_title: title,
           # A task has no page of its own: it lives on its project's hub,
           # so the link goes there rather than nowhere.
           path: "#{@base}/#{assignment.project_uuid}"
         }}
      end)

    Map.merge(projects, tasks)
  rescue
    e ->
      Logger.warning("[Projects.ResourceLinks] resolve failed: #{Exception.message(e)}")
      %{}
  end

  def resolve_comment_resources(_), do: %{}

  # ── Search (the `#` typeahead) ──────────────────────────────────────

  @doc """
  Projects and tasks matching `query`, scoped to the SEARCHER.

  Never offers something the searcher cannot open: the typeahead is the
  first place a leak would appear, and it is the easiest one to miss
  because the result looks correct to whoever is testing it.
  """
  @spec search_resources(String.t(), keyword()) :: [map()]
  def search_resources(query, opts) do
    scope = Keyword.get(opts, :scope) || Keyword.get(opts, :user_uuid)
    lang = L10n.current_content_lang()

    accessible = accessible_project_uuids(scope)

    if accessible == :none, do: [], else: do_search(query, accessible, lang)
  rescue
    e ->
      Logger.warning("[Projects.ResourceLinks] search failed: #{Exception.message(e)}")
      []
  end

  defp do_search(query, accessible, lang) do
    projects = search_projects(query, accessible, lang)
    tasks = search_tasks(query, accessible)

    projects ++ tasks
  end

  defp search_projects(query, accessible, lang) do
    Project
    |> where([p], p.is_template == false and is_nil(p.archived_at))
    |> scope_to(accessible, :uuid)
    |> match_name(query)
    |> limit(@search_limit)
    |> repo().all()
    |> Enum.map(fn project ->
      %{
        type: "project",
        uuid: project.uuid,
        title: Project.localized_name(project, lang),
        subtitle: "Project"
      }
    end)
  end

  defp search_tasks(query, accessible) do
    # Tasks are matched through their library task's name; an assignment
    # has no name of its own.
    Assignment
    |> join(:inner, [a], t in assoc(a, :task))
    # Bindings are explicit past a join: `[a, _t]` says the scope applies to
    # the assignment, not the task. The task's column is `title`, not
    # `name` — an assignment has no name of its own.
    |> where([a, _t], a.project_uuid in ^accessible_list(accessible))
    |> where([_a, t], ilike(t.title, ^"%#{escape_like(query)}%"))
    |> limit(@search_limit)
    |> preload([:task, :project])
    |> repo().all()
    |> Enum.map(fn assignment ->
      %{
        type: "project_task",
        uuid: assignment.uuid,
        title: Assignment.label(assignment),
        # The project, not the word "Task": the same library task is
        # assigned into many projects, so two rows reading "Backend
        # implementation · Task" are indistinguishable at the moment of
        # choosing between them.
        subtitle: task_subtitle(assignment)
      }
    end)
  end

  defp task_subtitle(%{project: %{} = project}) do
    "Task in #{Project.localized_name(project, L10n.current_content_lang())}"
  end

  defp task_subtitle(_), do: "Task"

  defp match_name(queryable, ""), do: queryable

  defp match_name(queryable, query) do
    where(queryable, [p], ilike(p.name, ^"%#{escape_like(query)}%"))
  end

  # `%` and `_` are LIKE wildcards: unescaped, a single `%` matches every
  # row on the site — which is precisely the enumeration this scoping
  # exists to prevent.
  defp escape_like(value) do
    value
    |> Kernel.to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # ── Visibility (the READER's question) ──────────────────────────────

  @doc """
  Of `uuids`, the ones this viewer may see.

  Called at render for someone who is usually not the author. Fails closed:
  an unresolvable viewer sees nothing rather than everything.
  """
  @spec visible_resource_uuids([String.t()], keyword()) :: [String.t()]
  def visible_resource_uuids(uuids, opts) do
    scope = Keyword.get(opts, :scope) || Keyword.get(opts, :user_uuid)

    case accessible_project_uuids(scope) do
      :none ->
        []

      :all ->
        uuids

      allowed ->
        allowed = MapSet.new(allowed)

        # A uuid here is either a project or a task; a task is visible
        # exactly when its project is.
        task_projects =
          Assignment
          |> where([a], a.uuid in ^uuids)
          |> select([a], {a.uuid, a.project_uuid})
          |> repo().all()
          |> Map.new()

        # A SUB-project is a project, but `list_projects_for/2` excludes
        # sub-projects from its listing, so one would resolve as "no
        # access" for someone who can plainly see it on its parent's page.
        # Its visibility is its parent's.
        parents = parent_projects(uuids, allowed)

        Enum.filter(uuids, fn uuid ->
          cond do
            project_uuid = Map.get(task_projects, uuid) -> MapSet.member?(allowed, project_uuid)
            MapSet.member?(allowed, uuid) -> true
            parent = Map.get(parents, uuid) -> MapSet.member?(allowed, parent)
            true -> false
          end
        end)
    end
  rescue
    e ->
      Logger.warning("[Projects.ResourceLinks] visibility failed: #{Exception.message(e)}")
      []
  end

  # For each uuid that is a sub-project, the project it hangs under. Only
  # consulted for uuids that aren't directly accessible, so the common case
  # costs nothing.
  defp parent_projects(uuids, allowed) do
    candidates = Enum.reject(uuids, &MapSet.member?(allowed, &1))

    if candidates == [] do
      %{}
    else
      Assignment
      |> where([a], a.child_project_uuid in ^candidates)
      |> select([a], {a.child_project_uuid, a.project_uuid})
      |> repo().all()
      |> Map.new()
    end
  end

  # `:all` for a site admin, `:none` for someone with no identity, else the
  # concrete set. Returning `:all` rather than every uuid keeps the admin
  # path from loading the whole table to answer "yes".
  defp accessible_project_uuids(nil), do: :none

  defp accessible_project_uuids(scope) do
    if Authz.admin_all?(scope) do
      :all
    else
      case Projects.list_projects_for(scope) do
        [] -> :none
        projects -> Enum.map(projects, & &1.uuid)
      end
    end
  end

  defp scope_to(queryable, :all, _field), do: queryable

  defp scope_to(queryable, uuids, field) when is_list(uuids) do
    where(queryable, [r], field(r, ^field) in ^uuids)
  end

  # `:all` (a site admin) has no uuid list to compare against. Rather than
  # branch the task query twice, hand it every project uuid — bounded, and
  # only on the admin path.
  defp accessible_list(:all) do
    Project |> select([p], p.uuid) |> repo().all()
  end

  defp accessible_list(uuids) when is_list(uuids), do: uuids
end
