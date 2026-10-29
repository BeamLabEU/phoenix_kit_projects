defmodule PhoenixKitProjects.Web.WriteGateTest do
  @moduledoc """
  The assignment, project and template forms re-check the right their mount
  needed on every write, against the scope the socket holds when the write
  arrives (`Web.WriteGate`) and the record as stored now — a role that loses
  the grant while the form is open writes nothing. The template form also
  checks the module key at mount itself, and edits only templates.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects

  @refusal "You don&#39;t have permission to do that here."

  # Kept the module, lost everything the forms need: no admin override, no
  # membership in any project.
  defp revoked, do: fake_scope(roles: [], permissions: ["projects"])
  defp nothing, do: fake_scope(roles: [], permissions: [])

  # What core's live scope refresh does when a role loses a grant while the
  # page is open.
  defp swap_scope(view, scope) do
    :sys.replace_state(view.pid, fn %{socket: socket} = state ->
      %{state | socket: Phoenix.Component.assign(socket, :phoenix_kit_current_scope, scope)}
    end)

    view
  end

  defp open_as_admin(conn, path) do
    {:ok, view, _html} = live(put_test_scope(conn, fake_scope()), path)
    view
  end

  defp assignment! do
    project = fixture_project()
    task = fixture_task(%{"title" => "Step"})

    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => task.uuid,
        "estimated_duration" => 2
      })

    {project, a}
  end

  describe "the assignment form" do
    test "a crafted save after the project's edit right is gone writes nothing", %{conn: conn} do
      {project, a} = assignment!()
      view = open_as_admin(conn, "/en/admin/projects/#{project.uuid}/assignments/#{a.uuid}/edit")
      swap_scope(view, revoked())

      html = render_click(view, "save", %{"assignment" => %{"estimated_duration" => "9"}})

      assert html =~ @refusal
      assert Projects.get_assignment(a.uuid).estimated_duration == a.estimated_duration
    end

    test "an autosave queued before the revoke writes nothing", %{conn: conn} do
      {project, a} = assignment!()
      view = open_as_admin(conn, "/en/admin/projects/#{project.uuid}/assignments/#{a.uuid}/edit")

      # A change schedules the autosave; the right goes before its timer.
      render_change(view, "validate", %{"assignment" => %{"estimated_duration" => "9"}})
      swap_scope(view, revoked())
      send(view.pid, :autosave)

      assert render(view) =~ @refusal
      assert Projects.get_assignment(a.uuid).estimated_duration == a.estimated_duration
    end

    test "a crafted delete after the revoke removes nothing", %{conn: conn} do
      {project, a} = assignment!()
      view = open_as_admin(conn, "/en/admin/projects/#{project.uuid}/assignments/#{a.uuid}/edit")
      swap_scope(view, revoked())

      assert render_click(view, "delete_task", %{}) =~ @refusal
      assert Projects.get_assignment(a.uuid)
    end

    test "a holder's save still writes", %{conn: conn} do
      {project, a} = assignment!()
      view = open_as_admin(conn, "/en/admin/projects/#{project.uuid}/assignments/#{a.uuid}/edit")

      render_click(view, "save", %{"assignment" => %{"estimated_duration" => "9"}})
      assert Projects.get_assignment(a.uuid).estimated_duration == 9
    end
  end

  describe "the project form" do
    test "a crafted save after :edit_settings is gone writes nothing", %{conn: conn} do
      project = fixture_project(%{"name" => "Before"})
      view = open_as_admin(conn, "/en/admin/projects/#{project.uuid}/edit")
      swap_scope(view, revoked())

      assert render_click(view, "save", %{"project" => %{"name" => "After"}}) =~ @refusal
      assert Projects.get_project(project.uuid).name == "Before"
    end
  end

  describe "the template form" do
    test "a crafted save after the module key is gone writes nothing", %{conn: conn} do
      template = fixture_template(%{"name" => "Before"})
      view = open_as_admin(conn, "/en/admin/projects/templates/#{template.uuid}/edit")
      swap_scope(view, nothing())

      assert render_click(view, "save", %{"project" => %{"name" => "After"}}) =~ @refusal
      assert Projects.get_project(template.uuid).name == "Before"
    end

    test "a scope without the module key is refused at mount", %{conn: conn} do
      template = fixture_template()

      assert {:error, {:live_redirect, %{flash: flash}}} =
               live(
                 put_test_scope(conn, nothing()),
                 "/en/admin/projects/templates/#{template.uuid}/edit"
               )

      assert flash["error"] =~ "permission"
    end

    test "a real project's id opens nothing, so the module key cannot edit it", %{conn: conn} do
      project = fixture_project(%{"name" => "Real"})

      assert {:error, {:live_redirect, %{flash: flash}}} =
               live(
                 put_test_scope(conn, revoked()),
                 "/en/admin/projects/templates/#{project.uuid}/edit"
               )

      assert flash["error"] =~ "Template not found"
      assert Projects.get_project(project.uuid).name == "Real"
    end
  end
end
