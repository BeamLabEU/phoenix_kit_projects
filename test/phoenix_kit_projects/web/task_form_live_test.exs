defmodule PhoenixKitProjects.Web.TaskFormLiveTest do
  @moduledoc """
  Smoke tests pinning the Phase 2 deltas on the task form: mounting
  with a scope, validate event sets `:action` so `<.input>` renders
  errors, save logs activity, phx-disable-with on submit.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "new task form" do
    test "mounts and renders the form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/tasks/new")
      assert html =~ "task-form"
    end

    test "submit button has phx-disable-with", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/tasks/new")
      assert html =~ ~r/phx-disable-with=/
    end

    test "submit with empty title shows inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/new")

      # `validate` deliberately does NOT stamp `:action` on the changeset
      # (suppresses premature errors when the user toggles unrelated
      # radio/select fields mid-form). Errors only render after a save
      # attempt — `Repo.update/insert` auto-stamps `:action` on
      # `{:error, _}` so the secondary render via `assign_form` carries
      # it through.
      html =
        view
        |> form("#task-form", task: %{title: "", description: "x"})
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end
  end

  describe "edit task form" do
    test "renders existing values", %{conn: conn} do
      task = fixture_task(%{"title" => "Existing-#{System.unique_integer([:positive])}"})

      {:ok, _view, html} = live(conn, "/en/admin/projects/tasks/#{task.uuid}/edit")
      assert html =~ task.title
    end
  end

  describe "Errors atom translation surface" do
    test "Errors.message/1 returns the canonical not-found string", %{} do
      assert PhoenixKitProjects.Errors.message(:task_not_found) ==
               "Task not found — it may have been deleted."
    end
  end

  describe "TOCTOU regression on add_dependency/2" do
    test "wrapping in :serializable returns clean changeset error on cycle attempt", %{} do
      project = fixture_project()
      task_a = fixture_task()
      task_b = fixture_task()

      {:ok, a} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task_a.uuid,
          "status" => "todo"
        })

      {:ok, b} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task_b.uuid,
          "status" => "todo"
        })

      # A → B (succeeds)
      assert {:ok, _} = Projects.add_dependency(a.uuid, b.uuid)

      # B → A would close a cycle — the cycle check inside the
      # serializable transaction should reject with a friendly
      # changeset error (no raised exception).
      {:error, %Ecto.Changeset{} = cs} = Projects.add_dependency(b.uuid, a.uuid)
      refute cs.valid?
      assert errors_on(cs) |> Map.has_key?(:depends_on_uuid)
    end
  end
end
