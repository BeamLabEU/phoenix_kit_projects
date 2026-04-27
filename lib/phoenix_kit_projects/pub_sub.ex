defmodule PhoenixKitProjects.PubSub do
  @moduledoc """
  Real-time updates for the projects module, backed by
  `PhoenixKit.PubSub.Manager`.

  ## Topics

    * `"projects:all"` — any project/template/task/assignment mutation
    * `"projects:tasks"` — task library mutations
    * `"projects:templates"` — template project mutations
    * `"projects:project:<uuid>"` — updates scoped to one project

  ## Events

  Messages are `{:projects, event_atom, payload_map}` tuples.

  ## Tenant scoping (deferred)

  Topics are global today. PhoenixKit core does not currently expose
  a per-tenant `Scope.organization_id` or equivalent, and no other
  feature module (`locations`, `staff`, `sync`, …) does multi-tenant
  PubSub partitioning either — so this is a framework-wide gap, not
  a projects-specific one.

  When core grows tenant scoping, the right shape here is to thread
  the org/tenant key into every topic
  (`"projects:org:<org_id>:all"`, etc.) and have `subscribe/1` raise
  if the scope is missing. Until then, the `:project:<uuid>` topic
  is the only one safe against cross-tenant fan-out (you need the
  UUID to subscribe), and the `:all` / `:tasks` / `:templates`
  topics deliberately broadcast across all subscribers.
  """

  alias PhoenixKit.PubSub.Manager

  @doc "Topic for any project, template, task, or assignment mutation."
  def topic_all, do: "projects:all"
  @doc "Topic for task-library mutations."
  def topic_tasks, do: "projects:tasks"
  @doc "Topic for template-project mutations."
  def topic_templates, do: "projects:templates"
  @doc "Topic scoped to a single project."
  def topic_project(uuid), do: "projects:project:#{uuid}"

  @doc "Subscribes the calling process to the given PubSub topic."
  def subscribe(topic), do: Manager.subscribe(topic)

  @doc "Broadcasts a project event. Templates also fan out to the templates topic."
  def broadcast_project(event, %{uuid: uuid, is_template: true} = payload) do
    msg = {:projects, event, payload}
    Manager.broadcast(topic_all(), msg)
    Manager.broadcast(topic_templates(), msg)
    Manager.broadcast(topic_project(uuid), msg)
  end

  def broadcast_project(event, %{uuid: uuid} = payload) do
    msg = {:projects, event, payload}
    Manager.broadcast(topic_all(), msg)
    Manager.broadcast(topic_project(uuid), msg)
  end

  @doc "Broadcasts a task-library event to the all-projects and tasks topics."
  def broadcast_task(event, %{uuid: _uuid} = payload) do
    msg = {:projects, event, payload}
    Manager.broadcast(topic_all(), msg)
    Manager.broadcast(topic_tasks(), msg)
  end

  @doc "Broadcasts an assignment event to the all-projects and the parent project's topic."
  def broadcast_assignment(event, %{project_uuid: project_uuid} = payload) do
    msg = {:projects, event, payload}
    Manager.broadcast(topic_all(), msg)
    Manager.broadcast(topic_project(project_uuid), msg)
  end

  @doc "Broadcasts a dependency event to the all-projects and the parent project's topic."
  def broadcast_dependency(event, %{project_uuid: project_uuid} = payload) do
    msg = {:projects, event, payload}
    Manager.broadcast(topic_all(), msg)
    Manager.broadcast(topic_project(project_uuid), msg)
  end
end
