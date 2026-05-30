defmodule PhoenixKitProjects.Web.ProjectFormLiveTest do
  @moduledoc """
  Smoke tests for `ProjectFormLive`. Original sweep shipped at 0%
  coverage. Pins mount + validate + save flows for `:new` (with and
  without template) and `:edit`, plus the not-found redirect and the
  template-not-found error path.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Projects, Statuses, StatusFixtures}

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

  describe "workflow status picker" do
    setup %{conn: conn} do
      # Generate provisions an entity with `created_by_uuid` = the socket
      # actor, which must be a real user (FK to phoenix_kit_users). Re-scope
      # the conn with a registered user instead of the bare fake_scope.
      {:ok, user} =
        Auth.register_user(%{
          "email" => "form-actor-#{System.unique_integer([:positive])}@example.com",
          "password" => "ActorPass123!"
        })

      conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))
      entity = StatusFixtures.seed_shared_status_entity!()
      {:ok, conn: conn, entity: entity}
    end

    test "saving with a chosen status list persists status_entity_uuid", %{
      conn: conn,
      entity: entity
    } do
      project = fixture_project()
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}/edit")

      {:error, {:live_redirect, _}} =
        view
        |> form("#project-form",
          project: %{
            name: project.name,
            start_mode: project.start_mode || "immediate",
            counts_weekends: "false",
            status_entity_uuid: entity.uuid
          }
        )
        |> render_submit()

      assert Projects.get_project!(project.uuid).status_entity_uuid ==
               entity.uuid
    end

    test "Generate default creates a fresh list and selects it", %{conn: conn} do
      # list_status_source_entities/0 returns grouped options
      # ([{group, [{label, uuid}, ...]}]); flatten to count actual entities.
      count = fn ->
        Statuses.list_status_source_entities()
        |> Enum.flat_map(fn {_group, opts} -> opts end)
        |> length()
      end

      project = fixture_project()
      before = count.()

      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}/edit")

      html = view |> element("button", "Generate default") |> render_click()

      # A fresh catalog entity is created and offered in the picker.
      assert count.() == before + 1
      # The selected list's statuses render in the live preview.
      assert html =~ "Backlog"
    end
  end
end
