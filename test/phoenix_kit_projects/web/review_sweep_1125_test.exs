defmodule PhoenixKitProjects.Web.ReviewSweep1125Test do
  @moduledoc """
  The second review sweep's page-level fixes (vibe's and kimi's findings,
  2026-11-24/25):

    * an expanded sub-project's dependency × removes the dependency (the
      handler checked both ends against the PARENT project and did nothing);
    * the task form ignores an event it does not know instead of crashing
      and losing what was typed;
    * an expanded sub-project follows its own topic (a deleted sub-project
      no longer throws the viewer out of the parent);
    * the project calendar asks again on reload whether the viewer may see
      the project.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitProjects.Members
  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    user_uuid = embed_user_uuid!()
    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: user_uuid)), user_uuid: user_uuid}
  end

  defp path(project), do: "/en/admin/projects/#{project.uuid}"

  defp child_task(child, title) do
    task = fixture_task(%{"title" => title})

    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => child.uuid,
        "task_uuid" => task.uuid,
        "status" => "todo"
      })

    a
  end

  defp expand(view, link) do
    view
    |> element(~s([phx-click="toggle_subproject"][phx-value-uuid="#{link.uuid}"]))
    |> render_click()
  end

  test "the × on an expanded sub-project's dependency removes it", %{conn: conn} do
    parent = fixture_project()

    {:ok, %{child_project: child, assignment: link}} =
      Projects.create_subproject(parent.uuid, %{"name" => "Buildout"})

    a = child_task(child, "Pour foundation")
    b = child_task(child, "Frame walls")
    {:ok, _} = Projects.add_dependency(b.uuid, a.uuid)

    {:ok, view, _html} = live(conn, path(parent))
    expand(view, link)

    html =
      render_hook(view, "remove_dependency", %{"assignment" => b.uuid, "depends_on" => a.uuid})

    assert html =~ "Dependency removed."
    assert Projects.list_dependencies(b.uuid) == []
  end

  test "a dependency pair spanning two projects is still refused", %{conn: conn} do
    parent = fixture_project()

    {:ok, %{child_project: child, assignment: link}} =
      Projects.create_subproject(parent.uuid, %{"name" => "Buildout"})

    a = child_task(child, "Pour foundation")
    b = child_task(child, "Frame walls")
    {:ok, _} = Projects.add_dependency(b.uuid, a.uuid)
    own = child_task(parent, "Parent row")

    {:ok, view, _html} = live(conn, path(parent))
    expand(view, link)

    html =
      render_hook(view, "remove_dependency", %{"assignment" => b.uuid, "depends_on" => own.uuid})

    refute html =~ "Dependency removed."
    assert [_] = Projects.list_dependencies(b.uuid)
  end

  test "the task form ignores an event it does not know", %{conn: conn} do
    project = fixture_project()
    {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")

    assert render_hook(view, "no_such_event", %{}) =~ "phx-"
    assert render_hook(view, "switch_language", %{}) =~ "phx-"
    assert Process.alive?(view.pid)
  end

  test "an open sub-project's deletion redraws the parent instead of leaving it", %{conn: conn} do
    parent = fixture_project()

    {:ok, %{child_project: child, assignment: link}} =
      Projects.create_subproject(parent.uuid, %{"name" => "Buildout"})

    {:ok, view, _html} = live(conn, path(parent))
    expand(view, link)

    send(view.pid, {:projects, :project_deleted, %{uuid: child.uuid}})
    assert render(view) =~ parent.name

    send(view.pid, {:projects, :project_deleted, %{uuid: parent.uuid}})
    assert_redirect(view, 3_000)
  end

  test "an open sub-project's topic is listened to while it is open", %{conn: conn} do
    parent = fixture_project()

    {:ok, %{child_project: child, assignment: link}} =
      Projects.create_subproject(parent.uuid, %{"name" => "Buildout"})

    {:ok, view, _html} = live(conn, path(parent))
    topic = PhoenixKitProjects.PubSub.topic_project(child.uuid)
    listening? = fn -> view.pid in subscribers(topic) end

    refute listening?.()
    expand(view, link)
    assert listening?.()
    expand(view, link)
    refute listening?.()
  end

  defp subscribers(topic) do
    :phoenix_kit_internal_pubsub
    |> Registry.lookup(topic)
    |> Enum.map(fn {pid, _} -> pid end)
  end

  test "the calendar leaves a project the viewer no longer may see" do
    # A plain account (embed_user_uuid!/0 holds "*", which sees every
    # project): a direct member needs no module key.
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "cal-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    viewer = user.uuid
    # A plain module user, not the setup's admin (who sees every project).
    conn =
      put_test_scope(
        Phoenix.ConnTest.build_conn(),
        fake_scope(user_uuid: viewer, permissions: ["projects"], roles: [])
      )

    project = fixture_project()
    {:ok, _} = Members.add_member(project, viewer, role: "member")

    {:ok, view, html} =
      live_isolated(conn, PhoenixKitProjects.Web.ProjectCalendarLive,
        session: %{"id" => project.uuid, "current_user_uuid" => viewer}
      )

    assert html =~ "Calendar"

    :ok = remove!(project, viewer)

    send(view.pid, {:projects, :assignment_updated, %{uuid: nil, project_uuid: project.uuid}})

    assert_redirect(view, 3_000)
  end

  defp remove!(project, user_uuid) do
    case Members.remove_member(project, user_uuid) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> flunk("remove_member: #{inspect(other)}")
    end
  end
end
