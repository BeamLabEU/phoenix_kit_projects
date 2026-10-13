defmodule PhoenixKitProjects.Web.OngoingEndTest do
  @moduledoc """
  Ending ongoing work: nothing on a project's page ends it, the one way is
  in its settings form, beside "Ends". Plus what changing "Ends" does to a
  project whose tasks are already done, and where an ongoing sub-project
  and a lifecycle-less scheduled project are listed.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.Project

  @ongoing %{"completion" => "manual"}

  defp link_of(child),
    do:
      Enum.find(
        Projects.list_assignments(parent_of(child)),
        &(&1.child_project_uuid == child.uuid)
      )

  defp parent_of(child), do: List.last(Projects.parent_chain(child.uuid)).uuid

  defp done_task(project) do
    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => fixture_task().uuid
      })

    {:ok, a} = Projects.complete_assignment(a, nil)
    Projects.recompute_project_completion(project.uuid)
    a
  end

  describe "end_project/1 and resume_project/1" do
    test "end ongoing work and take it back; the parent's row follows" do
      parent = fixture_project()

      {:ok, %{child_project: child, assignment: link}} =
        Projects.create_subproject(parent.uuid, %{"name" => "Upkeep", "settings" => @ongoing})

      # Under way from the day it is made, with no task begun.
      assert link.status == "in_progress"

      assert {:ok, ended} = Projects.end_project(child)
      assert %DateTime{} = ended.completed_at
      assert Project.derived_status(ended) == :completed
      assert link_of(child).status == "done"
      assert Projects.end_project(ended) == {:error, :already_ended}

      assert {:ok, resumed} = Projects.resume_project(ended)
      assert resumed.completed_at == nil
      assert Project.derived_status(resumed) == :ongoing
      assert link_of(child).status == "in_progress"
      assert Projects.resume_project(resumed) == {:error, :not_ended}
    end

    test "a project that ends with its last task is not ended by hand" do
      assert Projects.end_project(fixture_project()) == {:error, :not_ongoing}
    end
  end

  describe "the settings form" do
    test "offers the end beside Ends, asks first, and offers the way back", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      project = fixture_project(%{"settings" => @ongoing})

      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}/edit")
      assert html =~ "End this project"

      # The page of the project itself has no such thing.
      {:ok, _show, show_html} = live(conn, "/en/admin/projects/#{project.uuid}")
      refute show_html =~ "End this project"

      # A forged, unconfirmed push of any other event is not put behind the dialog.
      render_hook(view, "request_confirm", %{"event" => "cancel"})
      refute has_element?(view, "#project-end button", "Reopen it")

      view |> element("#project-end button", "End this project") |> render_click()
      assert Projects.get_project(project.uuid).completed_at == nil

      html = render_hook(view, "confirm_action_ok", %{})
      assert html =~ "Reopen it"
      assert %DateTime{} = Projects.get_project(project.uuid).completed_at

      view |> element("#project-end button", "Reopen it") |> render_click()
      assert Projects.get_project(project.uuid).completed_at == nil
    end

    test "not for a project that ends on its own; a forged event without the right is refused",
         %{conn: conn} do
      finite = fixture_project()

      {:ok, _view, html} =
        live(put_test_scope(conn, fake_scope()), "/en/admin/projects/#{finite.uuid}/edit")

      refute html =~ "End this project"

      # Someone who may edit the project but not manage its settings.
      ongoing = fixture_project(%{"settings" => @ongoing})
      editor = fake_scope(user_uuid: embed_user_uuid!(), permissions: ["projects"])

      {:ok, _} =
        PhoenixKitProjects.Members.add_member(ongoing.uuid, editor.user.uuid, role: "member")

      case live(put_test_scope(conn, editor), "/en/admin/projects/#{ongoing.uuid}/edit") do
        {:ok, view, html} ->
          refute html =~ "End this project"
          render_hook(view, "end_project", %{})

        _redirected ->
          :ok
      end

      assert Projects.get_project(ongoing.uuid).completed_at == nil
    end
  end

  describe "changing Ends" do
    test "back to the last task: a project with every task done completes on the spot" do
      project = fixture_project(%{"settings" => @ongoing})
      _ = done_task(project)
      assert Projects.get_project(project.uuid).completed_at == nil

      {:ok, updated} =
        Projects.update_project(Projects.get_project(project.uuid), %{
          "settings" => %{"completion" => "auto"}
        })

      assert %DateTime{} = updated.completed_at
    end
  end

  describe "lists" do
    test "a scheduled project with no lifecycle is active, not upcoming as well" do
      later = DateTime.add(DateTime.utc_now(), 86_400, :second)

      project =
        fixture_project(%{
          "start_mode" => "scheduled",
          "scheduled_start_date" => later,
          "settings" => %{"features" => %{"lifecycle" => false}}
        })

      assert Enum.any?(Projects.list_active_projects(), &(&1.uuid == project.uuid))
      refute Enum.any?(Projects.list_upcoming_projects(), &(&1.uuid == project.uuid))
    end
  end
end
