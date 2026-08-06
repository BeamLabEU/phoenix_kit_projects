defmodule PhoenixKitProjects.Web.ProjectFormCreationTest do
  @moduledoc """
  The reworked New-project page (the 2026-08-06 five-AI redesign):
  archetype cards seeding preset + extensions, the union rule with
  templates, inert-unless-on extension config, create-time invites, and
  the no-tabs language treatment.
  """
  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Extensions, Features, Members, Projects}

  defmodule ConfigProvider do
    def phoenix_kit_project_extensions do
      [
        %{
          key: "cfg_ext",
          name: "Config Ext",
          default_enabled: false,
          config_schema: [%{key: "target", type: :string, label: "Target"}]
        }
      ]
    end
  end

  setup %{conn: conn} do
    Application.put_env(:phoenix_kit_projects, :extension_providers, [ConfigProvider])
    PhoenixKitProjects.Extensions.Registry.refresh()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_projects, :extension_providers)
      PhoenixKitProjects.Extensions.Registry.refresh()
    end)

    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope), scope: scope}
  end

  defp created(prefix) do
    Projects.list_projects() |> Enum.find(&String.starts_with?(&1.name, prefix))
  end

  test "renders the multilang card, the archetype cards, and the receipt line", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/projects/list/new")

    assert html =~ "Choose a starting point"
    assert html =~ "Public intake"
    # The chips are gone — plain-language outcome lines replace them; and
    # a card whose required extensions aren't installed (CRM/billing are
    # absent in this env) hides entirely rather than making a promise it
    # can't keep.
    refute html =~ "Client project"
    assert html =~ "Public submission form"
    # The HOUSE multilang pattern: the same translatable name/description
    # card every other create form uses (all languages from the start).
    assert html =~ ~s(name="project[name]")
    # The summary receipt renders.
    assert html =~ "Statuses: site default"
  end

  test "the public_intake archetype enables the portal on create", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

    render_change(view, "validate", %{
      "project" => %{"name" => ""},
      "archetype" => "public_intake"
    })

    render_submit(view, "save", %{
      "project" => %{"name" => "Intake #{System.unique_integer([:positive])}"}
    })

    project = created("Intake")
    assert project
    assert Extensions.enabled?(project, "portal")
    # The portal's on_enable provisioned the slug row.
    assert PhoenixKitProjects.Portal.get_portal(project.uuid)
  end

  test "an explicit extension uncheck overrides the default (files off)", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

    render_change(view, "validate", %{
      "project" => %{"name" => ""},
      "ext" => %{"files" => "false"}
    })

    render_submit(view, "save", %{
      "project" => %{"name" => "NoFiles #{System.unique_integer([:positive])}"}
    })

    project = created("NoFiles")
    assert project
    refute Extensions.enabled?(project, "files")
    # Untouched defaults stay on (tasks is not part of the checklist).
    assert Extensions.enabled?(project, "tasks")
  end

  test "extension overrides survive an archetype switch; flags soft-reset", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

    # Explicitly enable the config extension, then switch archetype.
    render_change(view, "validate", %{
      "project" => %{"name" => ""},
      "ext" => %{"cfg_ext" => "true"}
    })

    render_change(view, "validate", %{"project" => %{"name" => ""}, "archetype" => "quick_todo"})

    render_submit(view, "save", %{
      "project" => %{"name" => "Switcher #{System.unique_integer([:positive])}"}
    })

    project = created("Switcher")
    assert project
    # The explicit extension choice survived the switch...
    assert Extensions.enabled?(project, "cfg_ext")
    # ...while flags took the new archetype's preset (simple = assignees off).
    refute Features.on?(project, "assignees")
  end

  test "inert-unless-on: config applies only when the extension is checked", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

    render_change(view, "validate", %{
      "project" => %{"name" => ""},
      "ext" => %{"cfg_ext" => "true"},
      "ext_config" => %{"cfg_ext" => %{"target" => "abc-123"}}
    })

    render_submit(view, "save", %{
      "project" => %{"name" => "Cfg #{System.unique_integer([:positive])}"}
    })

    project = created("Cfg")
    assert project

    assert {_ext, %{config: %{"target" => "abc-123"}}} =
             project.uuid
             |> Extensions.enabled_for_project()
             |> Enum.find(fn {ext, _row} -> ext.key == "cfg_ext" end)
  end

  test "invites seat members with their role after create", %{conn: conn} do
    invitee = user_fixture()

    {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

    render_change(view, "validate", %{
      "project" => %{"name" => ""},
      "invite_email" => invitee.email,
      "invite_role" => "manager"
    })

    html = render_click(view, "add_invite", %{})
    assert html =~ invitee.email

    render_submit(view, "save", %{
      "project" => %{"name" => "Seats #{System.unique_integer([:positive])}"}
    })

    project = created("Seats")
    assert project
    assert Members.role_of(project, invitee.uuid) == :manager
  end

  test "an unknown invite email flashes and seats nobody", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

    render_change(view, "validate", %{
      "project" => %{"name" => ""},
      "invite_email" => "ghost-#{System.unique_integer([:positive])}@example.com"
    })

    html = render_click(view, "add_invite", %{})
    assert html =~ "No account with that email"
  end

  test "template capabilities carry, and the form's explicit choices win", %{conn: conn} do
    # Author a template with an enabled extension + a pinned flag.
    template = fixture_project(%{"name" => "Tpl #{System.unique_integer([:positive])}"})

    template
    |> Ecto.Changeset.change(is_template: true)
    |> PhoenixKit.RepoHelper.repo().update!()

    {:ok, _} = Extensions.enable(template, "cfg_ext", config: %{"target" => "tpl-cfg"})
    {:ok, _} = Features.set_flags(template, %{"labels" => false})

    {:ok, task} = Projects.create_task(%{"title" => "Tpl task"})

    {:ok, _} =
      Projects.create_assignment(%{"project_uuid" => template.uuid, "task_uuid" => task.uuid})

    {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

    # Selecting the template shows the preview + carried extension.
    html =
      render_change(view, "validate", %{
        "project" => %{"name" => ""},
        "template_uuid" => template.uuid
      })

    assert html =~ "1 tasks from this template" or html =~ "tasks from this template"
    assert html =~ "Config Ext"

    # An unrelated validate cycle between selection and submit (the user
    # typing the name) must NOT clobber the carried config with the blank
    # inline field (panel find #2).
    render_change(view, "validate", %{
      "project" => %{"name" => "FromTpl"},
      "template_uuid" => template.uuid,
      "ext_config" => %{"cfg_ext" => %{"target" => ""}}
    })

    render_submit(view, "save", %{
      "project" => %{"name" => "FromTpl #{System.unique_integer([:positive])}"},
      "template_uuid" => template.uuid
    })

    project = created("FromTpl")
    assert project
    # Template extension carried (form rendered it checked; reconcile kept it).
    assert Extensions.enabled?(project, "cfg_ext")
    # Template config carried too.
    assert {_ext, %{config: %{"target" => "tpl-cfg"}}} =
             project.uuid
             |> Extensions.enabled_for_project()
             |> Enum.find(fn {ext, _row} -> ext.key == "cfg_ext" end)

    # The template's FLAG pin carried (panel find #1: the settings
    # whitelist + full-map flag write used to kill it).
    refute Features.on?(project, "labels")

    # Tasks cloned.
    assert length(Projects.list_assignments(project.uuid)) == 1
  end

  test "a non-template project cannot be cloned via a crafted template_uuid", %{conn: _conn} do
    victim = fixture_project(%{"name" => "Victim #{System.unique_integer([:positive])}"})

    assert {:error, :template_not_found} =
             Projects.create_project_from_template(victim.uuid, %{"name" => "Steal"})
  end

  test "a bogus template uuid does not kill checkbox tracking", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

    # Select a template uuid that doesn't resolve (deleted mid-session).
    render_change(view, "validate", %{
      "project" => %{"name" => ""},
      "template_uuid" => Ecto.UUID.generate()
    })

    # The next toggle must still track (the stuck-switched? panel find).
    render_change(view, "validate", %{
      "project" => %{"name" => ""},
      "ext" => %{"cfg_ext" => "true"}
    })

    render_submit(view, "save", %{
      "project" => %{"name" => "Tracked #{System.unique_integer([:positive])}"}
    })

    project = created("Tracked")
    assert project
    assert Extensions.enabled?(project, "cfg_ext")
  end

  test "re-enabling an unchanged extension is side-effect quiet", %{conn: _conn} do
    project = fixture_project(%{"name" => "Quiet #{System.unique_integer([:positive])}"})

    {:ok, _} = Extensions.enable(project, "cfg_ext", config: %{"target" => "x"})
    {:ok, _} = Extensions.enable(project, "cfg_ext")

    import Ecto.Query

    enable_logs =
      PhoenixKit.RepoHelper.repo().all(
        from(a in "phoenix_kit_activities",
          where:
            a.action == "projects.module_enabled" and
              a.resource_uuid == type(^project.uuid, Ecto.UUID),
          select: count()
        )
      )

    assert enable_logs == [1]
  end

  test "template + explicit uncheck: the user's disable wins over the carry", %{conn: conn} do
    template = fixture_project(%{"name" => "Tpl2 #{System.unique_integer([:positive])}"})

    template
    |> Ecto.Changeset.change(is_template: true)
    |> PhoenixKit.RepoHelper.repo().update!()

    {:ok, _} = Extensions.enable(template, "cfg_ext")

    {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

    render_change(view, "validate", %{
      "project" => %{"name" => ""},
      "template_uuid" => template.uuid
    })

    render_change(view, "validate", %{
      "project" => %{"name" => ""},
      "ext" => %{"cfg_ext" => "false"}
    })

    render_submit(view, "save", %{
      "project" => %{"name" => "TplOff #{System.unique_integer([:positive])}"},
      "template_uuid" => template.uuid
    })

    project = created("TplOff")
    assert project
    refute Extensions.enabled?(project, "cfg_ext")
  end

  defp user_fixture do
    {:ok, user} =
      Auth.register_user(%{
        email: "invitee-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  describe "promotable layout blocks (Settings -> New project page)" do
    setup do
      # The template block only renders when templates exist.
      template = fixture_project(%{"name" => "LayoutTpl #{System.unique_integer([:positive])}"})

      template
      |> Ecto.Changeset.change(is_template: true)
      |> PhoenixKit.RepoHelper.repo().update!()

      :ok
    end

    test "default: template + start live inside the Setup options accordion", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/new")

      assert html =~ ~s(id="create-setup")
      assert html =~ "From template (optional)"
      refute html =~ ~s(id="create-top-template")
      refute html =~ ~s(id="create-top-start")
      # Statuses fold in too (Max: essentials only by default).
      refute html =~ ~s(id="create-top-statuses")
    end

    test "a promoted block renders as its own top-level card", %{conn: conn} do
      {:ok, _} = Features.set_creation_top_blocks(["template", "start"])
      on_exit(fn -> Features.set_creation_top_blocks([]) end)

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/new")

      assert html =~ ~s(id="create-top-template")
      assert html =~ ~s(id="create-top-start")
      refute html =~ ~s(id="create-top-people")
    end

    test "unknown block keys are dropped at write time" do
      {:ok, _} = Features.set_creation_top_blocks(["template", "evil", "start"])
      on_exit(fn -> Features.set_creation_top_blocks([]) end)

      assert Enum.sort(Features.creation_top_blocks()) == ["start", "template"]
    end
  end
end
