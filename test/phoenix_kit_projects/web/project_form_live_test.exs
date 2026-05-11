defmodule PhoenixKitProjects.Web.ProjectFormLiveTest do
  @moduledoc """
  Smoke tests for `ProjectFormLive`. Original sweep shipped at 0%
  coverage. Pins mount + validate + save flows for `:new` (with and
  without template) and `:edit`, plus the not-found redirect and the
  template-not-found error path.
  """

  use PhoenixKitProjects.LiveCase, async: false

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "new project (no template)" do
    test "mounts and renders the form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/new")
      assert html =~ "project-form"
      assert html =~ "New project"
    end

    test "submit button has phx-disable-with", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/new")
      assert html =~ ~r/phx-disable-with=/
    end

    test "submit with blank name shows inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

      # `validate` deliberately does NOT stamp `:action` (suppresses
      # premature errors when the user toggles the start_mode radio
      # mid-form). Errors only render after a save attempt.
      html =
        view
        |> form("#project-form",
          project: %{name: "", description: "", start_mode: "immediate"}
        )
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "save creates project and logs activity", %{conn: conn, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

      name = "Proj-#{System.unique_integer([:positive])}"

      {:error, {:live_redirect, %{to: redirect_to}}} =
        view
        |> form("#project-form",
          project: %{
            name: name,
            description: "d",
            start_mode: "immediate",
            counts_weekends: "false"
          }
        )
        |> render_submit()

      assert redirect_to =~ "/list/"

      assert_activity_logged("projects.project_created",
        actor_uuid: actor_uuid,
        metadata_has: %{"name" => name}
      )
    end
  end

  describe "new project from template" do
    test "mounts with `?template=<uuid>` query param and pre-selects the template", %{conn: conn} do
      template = fixture_template()

      {:ok, _view, html} =
        live(conn, "/en/admin/projects/list/new?template=#{template.uuid}")

      assert html =~ template.name or html =~ "template"
    end
  end

  describe "edit project" do
    test "renders existing values", %{conn: conn} do
      project = fixture_project(%{"name" => "Existing-#{System.unique_integer([:positive])}"})
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}/edit")
      assert html =~ project.name
    end

    test "save updates and logs activity", %{conn: conn, actor_uuid: actor_uuid} do
      project = fixture_project()

      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}/edit")

      new_name = "Renamed-#{System.unique_integer([:positive])}"

      {:error, {:live_redirect, _}} =
        view
        |> form("#project-form",
          project: %{
            name: new_name,
            description: "d2",
            start_mode: project.start_mode || "immediate",
            counts_weekends: "false"
          }
        )
        |> render_submit()

      assert_activity_logged("projects.project_updated",
        actor_uuid: actor_uuid,
        resource_uuid: project.uuid,
        metadata_has: %{"name" => new_name}
      )
    end

    test "missing project id flashes + redirects to projects list", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      {:error, {:live_redirect, %{to: redirect_to, flash: flash}}} =
        live(conn, "/en/admin/projects/list/#{bogus}/edit")

      assert redirect_to =~ "/list"
      assert flash["error"] =~ "Project not found"
    end
  end

  describe "save errors are surfaced as flashes (not crashes)" do
    test "creating from a non-existent template shows :template_not_found flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

      html =
        view
        |> form("#project-form",
          project: %{
            name: "FromBogusTemplate",
            description: "",
            start_mode: "immediate",
            counts_weekends: "false"
          }
        )
        # Inject a bogus template_uuid via the params alongside the form push.
        |> render_submit(%{"template_uuid" => Ecto.UUID.generate()})

      assert html =~ "Template not found" or
               html =~ "may have been deleted"
    end
  end
end
