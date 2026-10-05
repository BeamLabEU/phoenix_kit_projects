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

  alias PhoenixKitProjects.{Labels, Projects, TaskNotes}
  alias PhoenixKitProjects.Schemas.{Assignment, Project}
  alias PhoenixKitProjects.Web.Api.{Json, NotesController}

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

      open =
        project.uuid
        |> Projects.list_assignments()
        |> Enum.reject(&(&1.status == "done"))

      shown =
        open
        |> Enum.sort_by(&{Map.get(@priority_rank, &1.priority, 2), &1.position})
        |> Enum.take(limit)

      labels = Labels.labels_for_assignments(Enum.map(shown, & &1.uuid))

      notes =
        if TaskNotes.available?(),
          do: project.uuid |> TaskNotes.list_for_project(since) |> Enum.take(-@max_notes),
          else: []

      json(conn, %{
        now: DateTime.utc_now(),
        since: since,
        project: %{
          uuid: project.uuid,
          name: project.name,
          completion: Project.completion(project),
          caught_up: Projects.caught_up?(project),
          completed_at: project.completed_at,
          workflow_status: project.current_status_slug,
          agent_policy: Project.agent_policy(project)
        },
        open_total: length(open),
        truncated: length(open) > length(shown),
        tasks: Enum.map(shown, &brief_task(&1, labels[&1.uuid] || [])),
        subprojects: Enum.map(Projects.child_projects(project.uuid), &brief_subproject/1),
        project_notes: Enum.map(notes, &brief_note/1)
      })
    else
      {:halt, conn} -> conn
    end
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
            summary: agent["summary"],
            outcome: agent["outcome"],
            next_steps: agent["next_steps"],
            at: latest.agent.inserted_at
          },
      updated_at: a.updated_at
    }
  end

  defp brief_subproject(%Project{} = p) do
    open = p.uuid |> Projects.list_assignments() |> Enum.count(&(&1.status != "done"))

    %{
      uuid: p.uuid,
      name: p.name,
      completion: Project.completion(p),
      caught_up: Projects.caught_up?(p),
      completed_at: p.completed_at,
      open_count: open
    }
  end

  defp brief_note(note) do
    m = note.metadata || %{}

    %{
      uuid: note.uuid,
      kind: m["kind"] || "note",
      summary: m["summary"] || String.slice(note.content || "", 0, 240),
      outcome: m["outcome"],
      next_steps: m["next_steps"],
      at: note.inserted_at
    }
  end
end
