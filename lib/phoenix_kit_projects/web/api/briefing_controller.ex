defmodule PhoenixKitProjects.Web.Api.BriefingController do
  @moduledoc """
  `GET /briefing` — what an agent needs to pick a project up in one read:
  the project (its completion mode, whether it is caught up, what an agent
  may do here), the open tasks with the direction a person set, the last
  outcome, the latest agent note's summary and next steps, who started
  them, what they wait on, the sub-projects in one line each, and the
  project's own notes since a moment. Bounded: the open tasks are capped
  and the answer says when it was cut.
  """

  use Phoenix.Controller, formats: [:json]

  alias PhoenixKitProjects.{Extensions, Labels, ProjectEvents, Projects, TaskNotes}
  alias PhoenixKitProjects.Schemas.{ApiKey, Assignment, Project}
  alias PhoenixKitProjects.Web.Api.{EventsController, ExtController, Json, NotesController}

  @max_tasks 50
  @max_notes 20
  @priority_rank %{"urgent" => 0, "high" => 1, "normal" => 2, "low" => 3}

  def show(conn, params) do
    with {:ok, conn} <- Json.require_scope(conn, "tasks:read"),
         {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- Json.require_feature(conn, :tasks),
         {:ok, conn} <- Json.require_action(conn, :view) do
      project = conn.assigns.pk_project
      since = NotesController.parse_since(params["since"])
      limit = limit(params["limit"])

      key = conn.assigns.pk_api_key
      all = Projects.list_assignments(project.uuid)
      {done, open} = Enum.split_with(all, &(&1.status == "done"))

      # What to do next, in order: what this key already has in hand, what
      # is ready, what waits on someone — priority then position inside
      # each; done today last, as a tail of ids and titles.
      mine =
        Enum.filter(open, &(&1.status == "in_progress" and &1.started_by_key_uuid == key.uuid))

      waiting = Enum.filter(open, &(is_binary(&1.waiting_on) and &1 not in mine))
      ready = Enum.reject(open, &(&1 in mine or &1 in waiting))

      ordered =
        Enum.sort_by(mine, &rank/1) ++
          Enum.sort_by(ready, &rank/1) ++ Enum.sort_by(waiting, &rank/1)

      shown = Enum.take(ordered, limit)

      labels = Labels.labels_for_assignments(Enum.map(shown, & &1.uuid))
      briefs = Enum.map(shown, &brief_task(&1, labels[&1.uuid] || []))

      notes =
        if TaskNotes.available?(),
          do: project.uuid |> TaskNotes.list_for_project(since) |> Enum.take(-@max_notes),
          else: []

      day_ago = DateTime.add(DateTime.utc_now(), -86_400)

      done_today =
        done
        |> Enum.filter(&(&1.completed_at && DateTime.compare(&1.completed_at, day_ago) == :gt))
        |> Enum.sort_by(& &1.completed_at, {:desc, DateTime})
        |> Enum.take(20)
        |> Enum.map(&%{uuid: &1.uuid, title: Assignment.label(&1), completed_at: &1.completed_at})

      json(conn, %{
        now: DateTime.utc_now() |> DateTime.truncate(:second),
        since: since,
        project: %{
          uuid: project.uuid,
          name: project.name,
          completion: Project.completion(project),
          caught_up: Projects.caught_up?(project),
          caught_up_since: Projects.caught_up_since(project),
          completed_at: project.completed_at,
          workflow_status: project.current_status_slug,
          agent_policy: Project.agent_policy(project)
        },
        open_total: length(open),
        truncated: length(open) > length(shown),
        counts: %{mine: length(mine), ready: length(ready), waiting: length(waiting)},
        resume: resume(briefs, notes, key),
        tasks: briefs,
        done_today: done_today,
        subprojects: brief_subprojects(project),
        project_notes: Enum.map(notes, &brief_note/1),
        client: client_lines(conn, since),
        events: upcoming_events(project)
      })
    else
      {:halt, conn} -> conn
    end
  end

  # The client's latest interactions — the four calls today an agent would
  # otherwise not learn about — through the extension's provider when the
  # Client extension is on and the key may read it; `since` narrows them.
  defp client_lines(conn, since) do
    %{pk_api_key: key, pk_project: project} = conn.assigns

    with %{ext: ext, module: provider} <- Extensions.api_provider("interactions"),
         true <- Extensions.enabled?(project, ext.key),
         true <- ApiKey.scope?(key, provider.scopes().read),
         {:ok, %{interactions: rows}} <- list_interactions(provider, conn, since) do
      # one line each: the bodies are the interaction's own read
      %{interactions: Enum.map(rows, &Map.drop(&1, [:body, "body"]))}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The provider is another application's module, reached by name.
  defp list_interactions(provider, conn, since) do
    params = %{"limit" => "5"}
    params = if since, do: Map.put(params, "since", DateTime.to_iso8601(since)), else: params
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(provider, :list, [ExtController.ctx(conn), params])
  end

  defp upcoming_events(project) do
    if Extensions.enabled?(project, "events") do
      project.uuid
      |> ProjectEvents.list_for_project(from: DateTime.utc_now(), limit: 5)
      |> Enum.map(&EventsController.event_json/1)
    else
      []
    end
  rescue
    _ -> []
  end

  defp rank(a), do: {Map.get(@priority_rank, a.priority, 2), a.position}

  # Where this key left off: its latest note, on a task or on the project —
  # the thing to read first after a context reset.
  defp resume(briefs, project_notes, key) do
    from_tasks =
      briefs
      |> Enum.filter(&(&1.latest_agent_note && &1.latest_agent_note.key == key.uuid))
      |> Enum.map(&Map.put(&1.latest_agent_note, :task_uuid, &1.uuid))

    from_project =
      project_notes
      |> Enum.filter(&((&1.metadata || %{})["api_key"] == key.uuid))
      |> Enum.map(fn n -> n |> brief_note() |> Map.put(:task_uuid, nil) end)

    (from_tasks ++ from_project)
    |> Enum.max_by(& &1.at, DateTime, fn -> nil end)
  end

  # Every child summarised in ONE pass (`project_summaries/1`), not a list
  # of tasks per child; a child that fails to summarise is left out rather
  # than taking the briefing down.
  defp brief_subprojects(project) do
    children = Projects.child_projects(project.uuid)

    summaries =
      children
      |> Projects.project_summaries()
      |> Enum.zip(children)
      |> Map.new(fn {sm, c} -> {c.uuid, sm} end)

    Enum.map(children, fn p ->
      sm = Map.get(summaries, p.uuid) || %{}
      total = Map.get(sm, :total, 0)
      done = Map.get(sm, :done, 0)
      caught_up = Project.ongoing?(p) and total > 0 and done == total

      %{
        uuid: p.uuid,
        name: p.name,
        completion: Project.completion(p),
        caught_up: caught_up,
        completed_at: p.completed_at,
        open_count: total - done
      }
    end)
  rescue
    _ -> []
  end

  defp limit(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n > 0 -> min(n, @max_tasks)
      _ -> @max_tasks
    end
  end

  defp limit(_), do: @max_tasks

  defp brief_task(%Assignment{} = a, labels) do
    latest =
      if TaskNotes.available?(), do: TaskNotes.latest(a.uuid), else: %{redirect: nil, agent: nil}

    agent = latest.agent && latest.agent.metadata

    %{
      uuid: a.uuid,
      kind: if(a.child_project_uuid, do: "subproject", else: "task"),
      title: Assignment.label(a),
      status: a.status,
      priority: a.priority,
      position: a.position,
      waiting_on: a.waiting_on,
      origin: a.origin,
      labels: Enum.map(labels, & &1.name),
      checklist: Assignment.checklist_counts(a),
      created_by: %{person: a.created_by_uuid, key: a.created_by_key_uuid},
      started_by: %{person: a.started_by_uuid, key: a.started_by_key_uuid},
      direction: latest.redirect && brief_note(latest.redirect),
      last_outcome: agent && agent["outcome"],
      latest_agent_note:
        agent &&
          %{
            uuid: latest.agent.uuid,
            key: agent["api_key"],
            summary: agent["summary"],
            outcome: agent["outcome"],
            next_steps: agent["next_steps"],
            at: latest.agent.inserted_at
          },
      updated_at: a.updated_at
    }
  end

  defp brief_note(note) do
    m = note.metadata || %{}

    %{
      uuid: note.uuid,
      kind: m["kind"] || "note",
      key: m["api_key"],
      summary: m["summary"] || String.slice(note.content || "", 0, 240),
      outcome: m["outcome"],
      next_steps: m["next_steps"],
      at: note.inserted_at
    }
  end
end
