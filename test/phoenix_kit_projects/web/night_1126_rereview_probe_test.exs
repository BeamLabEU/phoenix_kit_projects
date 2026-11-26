defmodule PhoenixKitProjects.Web.Night1126RereviewProbeTest do
  @moduledoc """
  codex's re-review of the night's fixes (2026-11-26): the batched role and
  access reads agree with the single ones (a scope included), a project
  context finds its own sub-projects and never a template, and the briefing
  names the same latest note as a single lookup, ties included.
  """
  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Users.{Auth, RolePermission, Roles}
  alias PhoenixKitComments.Comment
  alias PhoenixKitProjects.{ApiKeys, Authz, Grants, Members, Projects, ResourceLinks, TaskNotes}
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Test.Repo

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        email: "rereview-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp child!(parent, name) do
    {:ok, %{child_project: child}} = Projects.create_subproject(parent.uuid, %{"name" => name})
    child
  end

  defp assignment!(project, title) do
    {:ok, %{assignment: assignment}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        %{}
      )

    assignment
  end

  test "a 16-byte binary cannot invalidate an otherwise good lookup" do
    project = fixture_project()
    {:ok, key, _} = ApiKeys.create(project, %{"name" => "Reader"})
    bad = "not-a-valid-uuid"
    assert byte_size(bad) == 16
    assert {:ok, _} = single = ApiKeys.access_for(key, project.uuid)

    assert ApiKeys.access_map(key, [project.uuid, bad]) ==
             %{project.uuid => single, bad => {:error, :no_access}}
  end

  test "bulk role equals single for direct, group, everyone, overlapping and absent seats" do
    user = user!()

    {:ok, site_role} =
      Roles.create_role(%{"name" => "Probe-#{System.unique_integer([:positive])}"})

    {:ok, _} = Roles.assign_role(user, site_role.name)
    Repo.insert!(%RolePermission{role_uuid: site_role.uuid, module_key: "projects"})
    private = fixture_project()
    direct = fixture_project()
    group = fixture_project()
    overlap = fixture_project(%{"settings" => %{"visibility" => "everyone"}})
    everyone = fixture_project(%{"settings" => %{"visibility" => "everyone"}})
    {:ok, _} = Members.add_member(direct, user.uuid, role: "owner")
    {:ok, _} = Members.add_member(overlap, user.uuid, role: "member")
    {:ok, _} = Grants.grant(group, "role", site_role.uuid, "member")
    {:ok, _} = Grants.grant(overlap, "role", site_role.uuid, "manager")

    projects = [private, direct, group, overlap, everyone]

    expected =
      Map.new(Enum.zip(Enum.map(projects, & &1.uuid), [nil, :owner, :member, :manager, :viewer]))

    assert Map.new(projects, &{&1.uuid, Authz.effective_role(&1, user.uuid)}) == expected
    assert Authz.effective_roles(projects, user.uuid) == expected
  end

  test "bulk role accepts the same scope as single role" do
    user = user!()
    project = fixture_project(%{"settings" => %{"visibility" => "everyone"}})

    scope =
      fake_scope(user_uuid: user.uuid, email: user.email, permissions: ["projects"], roles: [])

    assert Authz.effective_role(project, scope) == :viewer
    assert Authz.effective_roles([project], scope) == %{project.uuid => :viewer}
  end

  test "context finds a directly joined subproject's task and hides a template task" do
    user = user!()
    root = fixture_project()
    child = child!(root, "Joined child")
    template = child!(root, "Template child")
    {:ok, _} = Members.add_member(child, user.uuid, role: "member")
    {:ok, _} = Members.add_member(template, user.uuid, role: "member")
    visible = assignment!(child, "Distinctvisible")
    hidden = assignment!(template, "Distincthidden")
    Repo.update_all(from(p in Project, where: p.uuid == ^template.uuid), set: [is_template: true])

    scope =
      fake_scope(user_uuid: user.uuid, email: user.email, permissions: ["projects"], roles: [])

    assert [%{uuid: uuid, type: "project_task"}] =
             ResourceLinks.search_resources("Distinctvisible",
               scope: scope,
               context: %{"project" => root.uuid}
             )

    assert uuid == visible.uuid

    assert [] ==
             ResourceLinks.search_resources("Distincthidden",
               scope: scope,
               context: %{"project" => root.uuid}
             )

    assert ResourceLinks.visible_resource_uuids([visible.uuid, hidden.uuid], scope: scope) == [
             visible.uuid
           ]
  end

  defp insert_notes!(user, notes) do
    type = TaskNotes.resource_type()

    Repo.insert_all(
      Comment,
      Enum.map(notes, fn {task, summary, kind, status, at} ->
        %{
          uuid: Ecto.UUID.generate(),
          resource_type: type,
          resource_uuid: task.uuid,
          user_uuid: user.uuid,
          status: status,
          content: summary,
          metadata: %{"kind" => kind, "summary" => summary, "outcome" => "partial"},
          inserted_at: at,
          updated_at: at
        }
      end)
    )
  end

  test "briefing retains note fields, ignores hidden notes, and handles empty or disabled notes" do
    user = user!()
    project = fixture_project()
    task = assignment!(project, "Notes")
    empty = assignment!(project, "No notes")
    {:ok, _key, token} = ApiKeys.create(project, %{"name" => "Reader"})
    {:ok, _} = PhoenixKit.Settings.update_setting("comments_enabled", "true")

    insert_notes!(user, [
      {task, "old", "agent_note", "published", ~U[2026-11-26 00:00:00Z]},
      {task, "direction", "redirect", "published", ~U[2026-11-26 00:00:01Z]},
      {task, "current", "agent_note", "published", ~U[2026-11-26 00:00:02Z]},
      {task, "hidden", "agent_note", "hidden", ~U[2026-11-26 00:00:03Z]}
    ])

    uuids = [task.uuid, empty.uuid]
    assert TaskNotes.latest_for_assignments(uuids) == Map.new(uuids, &{&1, TaskNotes.latest(&1)})

    answers = briefing_tasks(token)
    assert answers[task.uuid]["direction"]["summary"] == "direction"
    assert answers[task.uuid]["last_outcome"] == "partial"
    assert answers[task.uuid]["latest_agent_note"]["summary"] == "current"

    for field <- ~w(direction last_outcome latest_agent_note),
        do: assert(Map.fetch!(answers[empty.uuid], field) == nil)

    {:ok, _} = PhoenixKit.Settings.update_setting("comments_enabled", "false")
    disabled = briefing_tasks(token)

    for uuid <- uuids,
        field <- ~w(direction last_outcome latest_agent_note),
        do: assert(Map.fetch!(disabled[uuid], field) == nil)
  end

  test "briefing and single lookup pick the same latest note when timestamps tie" do
    user = user!()
    project = fixture_project()
    {:ok, _key, token} = ApiKeys.create(project, %{"name" => "Reader"})
    {:ok, _} = PhoenixKit.Settings.update_setting("comments_enabled", "true")
    tasks = for n <- 1..12, do: assignment!(project, "Task #{n}")
    at = ~U[2026-11-26 00:00:00Z]

    notes =
      for n <- 1..20,
          {task, i} <- Enum.with_index(tasks),
          do: {task, "#{i}-#{n}", "agent_note", "published", DateTime.add(at, rem(n, 2))}

    insert_notes!(user, notes)
    uuids = Enum.map(tasks, & &1.uuid)
    summary = fn note -> note.agent.metadata["summary"] end
    single = Enum.map(uuids, &summary.(TaskNotes.latest(&1)))
    bulk = briefing_tasks(token)
    assert Enum.map(uuids, &bulk[&1]["latest_agent_note"]["summary"]) == single
  end

  defp briefing_tasks(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json")
    |> get("/api/projects/v1/briefing?limit=12")
    |> json_response(200)
    |> Map.fetch!("tasks")
    |> Map.new(&{&1["uuid"], &1})
  end
end
