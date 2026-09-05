defmodule PhoenixKitProjects.Web.ProjectFormExtrasTest do
  @moduledoc """
  Coverage extension for `ProjectFormLive` — exercises:

  - save :new error branch (invalid attrs)
  - save :edit error branch (invalid attrs)
  - successful `create_project_from_template` path
  - cloned-project changeset-error path (template-clone fails on the
    project changeset itself)
  - `start_mode_value/1` fallback for missing/blank form value
  """

  use PhoenixKitProjects.LiveCase, async: false

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "save :new error branch" do
    test "invalid attrs (blank name) re-renders the form with errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/new")

      html =
        view
        |> form("#project-form",
          project: %{
            name: "",
            description: "",
            start_mode: "immediate",
            counts_weekends: "false"
          }
        )
        |> render_submit()

      # Form re-renders, no redirect, error visible.
      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end
  end

  describe "save :edit error branch" do
    test "invalid attrs re-render the form with errors", %{conn: conn} do
      project = fixture_project()

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}/edit")

      html =
        view
        |> form("#project-form",
          project: %{
            name: "",
            description: "",
            start_mode: "immediate",
            counts_weekends: "false"
          }
        )
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end
  end

  describe "create_project_from_template happy path" do
    test "successful clone redirects + logs `project_created_from_template`",
         %{conn: conn, actor_uuid: actor_uuid} do
      template = fixture_template()
      task = fixture_task()

      {:ok, _} =
        PhoenixKitProjects.Projects.create_assignment(%{
          "project_uuid" => template.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/new?template=#{template.uuid}")

      name = "Cloned-#{System.unique_integer([:positive])}"

      {:error, {:live_redirect, _}} =
        view
        |> form("#project-form",
          project: %{
            name: name,
            description: "",
            start_mode: "immediate",
            counts_weekends: "false"
          }
        )
        |> render_submit(%{"template_uuid" => template.uuid})

      assert_activity_logged("projects.project_created_from_template",
        actor_uuid: actor_uuid,
        metadata_has: %{"name" => name, "template_uuid" => template.uuid}
      )
    end

    test "clone with project changeset error re-renders the form", %{conn: conn} do
      template = fixture_template()

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/new?template=#{template.uuid}")

      # Blank name → the cloned-project changeset itself fails →
      # `{:error, %Ecto.Changeset{data: %Project{}} = cs}` branch.
      html =
        view
        |> form("#project-form",
          project: %{
            name: "",
            description: "",
            start_mode: "immediate",
            counts_weekends: "false"
          }
        )
        |> render_submit(%{"template_uuid" => template.uuid})

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end
  end

  describe "start_mode_value/1 fallback (rendered via start_mode select)" do
    test "renders default 'immediate' when no start_mode in form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/new")
      # The default scaffolded form value is 'immediate' — start_mode_value
      # fallback renders this on the empty-form mount.
      assert html =~ "immediate"
    end

    test "validate event with start_mode=scheduled re-renders with that value",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/new")

      html =
        view
        |> form("#project-form",
          project: %{
            name: "X",
            description: "",
            start_mode: "scheduled",
            counts_weekends: "false"
          }
        )
        |> render_change()

      assert html =~ "scheduled" or html =~ "Scheduled"
    end
  end
end
