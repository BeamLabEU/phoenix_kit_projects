defmodule PhoenixKitProjects.Web.SubprojectEditParityTest do
  @moduledoc """
  A sub-project's editor has everything the project's has (the boss,
  2026-11-02): someone who may change its settings gets the project's own
  form — nested in the popup, the project's edit page otherwise — with
  what its row waits on in the parent on the Schedule tab.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    me = embed_user_uuid!()
    conn = put_test_scope(conn, fake_scope(user_uuid: me))
    parent = fixture_project(%{"start_mode" => "immediate"})

    {:ok, %{child_project: child, assignment: link}} =
      Projects.create_subproject(parent.uuid, %{"name" => "Phase"})

    {:ok, %{assignment: task}} =
      Projects.create_task_with_assignment(
        parent.uuid,
        %{"title" => "Measure", "ad_hoc" => true},
        %{}
      )

    {:ok, conn: conn, me: me, parent: parent, child: child, link: link, task: task}
  end

  test "in a popup the sub-project opens in the project's own form, waits-on included", ctx do
    topic = "subproject-parity-#{System.unique_integer([:positive])}"

    {:ok, view, html} =
      live_isolated(ctx.conn, PhoenixKitProjects.Web.AssignmentFormLive,
        session: %{
          "mode" => "emit",
          "pubsub_topic" => topic,
          "frame_ref" => 1,
          "live_action" => "edit",
          "project_id" => ctx.parent.uuid,
          "id" => ctx.link.uuid,
          "current_user_uuid" => ctx.me
        }
      )

    assert html =~ "subproject-project-form-#{ctx.child.uuid}"
    child_view = find_live_child(view, "subproject-project-form-#{ctx.child.uuid}")
    child_html = render(child_view)

    # The project's form: its Settings tab and cover image, the link settings.
    assert child_html =~ ~s(id="project-cover-settings")
    assert child_html =~ ~s(name="header[link_show]")
    assert child_html =~ ~s(id="subproject-waits-on")

    render_click(child_view, "add_link_dep", %{"depends_on_uuid" => ctx.task.uuid})

    assert Enum.any?(
             Projects.list_dependencies(ctx.link.uuid),
             &(&1.depends_on_uuid == ctx.task.uuid)
           )

    render_click(child_view, "remove_link_dep", %{"uuid" => ctx.task.uuid})

    refute Enum.any?(
             Projects.list_dependencies(ctx.link.uuid),
             &(&1.depends_on_uuid == ctx.task.uuid)
           )
  end

  test "a dependency outside the parent's own list is refused", ctx do
    other = fixture_project()

    {:ok, %{assignment: foreign}} =
      Projects.create_task_with_assignment(
        other.uuid,
        %{"title" => "Elsewhere", "ad_hoc" => true},
        %{}
      )

    {:ok, view, _html} =
      live(ctx.conn, "/en/admin/projects/#{ctx.child.uuid}/edit?subproject_link=#{ctx.link.uuid}")

    render_click(view, "add_link_dep", %{"depends_on_uuid" => foreign.uuid})
    assert Projects.list_dependencies(ctx.link.uuid) == []
  end

  test "on its own page the sub-project's edit goes to the project's edit page", ctx do
    assert {:error, {kind, %{to: to}}} =
             live(
               ctx.conn,
               "/en/admin/projects/#{ctx.parent.uuid}/assignments/#{ctx.link.uuid}/edit"
             )

    assert kind in [:live_redirect, :redirect]
    assert to =~ "/projects/#{ctx.child.uuid}/edit"
    assert to =~ "subproject_link=#{ctx.link.uuid}"
  end
end
