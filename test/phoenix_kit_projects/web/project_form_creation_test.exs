defmodule PhoenixKitProjects.Web.ProjectFormCreationTest do
  @moduledoc """
  The reworked New-project page (the 2026-08-06 five-AI redesign):
  archetype cards seeding preset + extensions, the union rule with
  templates, inert-unless-on extension config, create-time invites, and
  the no-tabs language treatment.
  """
  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Authz, Extensions, Features, Members, Projects}

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

  describe "who-can-do-what floors (the 2026-08-07 panel's permissions answer)" do
    test "the section renders the overridable floors, not a scheme editor", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/new")

      assert html =~ "People &amp; permissions"
      assert html =~ "Who can do what"
      assert html =~ "Who can add tasks"
      assert html =~ "Who can assign tasks"
      assert html =~ "Who can change task status"
      # The fixed rules are stated rather than left to be discovered.
      assert html =~ "you own it"
      # No per-extension action matrix — the panel cut that explicitly.
      refute html =~ "upload_files"
    end

    test "taking the defaults stores nothing (the project keeps inheriting)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

      render_submit(view, "save", %{
        "project" => %{"name" => "AuthzDefault #{System.unique_integer([:positive])}"}
      })

      project = created("AuthzDefault")
      assert project
      refute Map.has_key?(project.settings || %{}, "authz")
      # ...and it still resolves to the site defaults.
      assert Authz.current_overrides(project)["create_tasks"] == "members"
      assert Authz.current_overrides(project)["assign_tasks"] == "managers"
    end

    test "a tightened floor is stored and enforced", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

      render_change(view, "validate", %{
        "project" => %{"name" => ""},
        "authz" => %{"create_tasks" => "managers"}
      })

      render_submit(view, "save", %{
        "project" => %{"name" => "AuthzTight #{System.unique_integer([:positive])}"}
      })

      project = created("AuthzTight")
      assert project
      # ONLY the moved floor is written — minimal diff, like the flags.
      assert project.settings["authz"] == %{"create_tasks" => "managers"}

      # And it actually binds: a plain member may no longer add tasks.
      {:ok, member} =
        Auth.register_user(%{
          "email" => "floor-#{System.unique_integer([:positive])}@example.com",
          "password" => "MemberPass123!"
        })

      {:ok, _} = Members.add_member(project, member.uuid, role: "member")
      project = Projects.get_project!(project.uuid)

      refute Authz.can?(member.uuid, project, :create_tasks)
      # A manager still can.
      {:ok, manager} =
        Auth.register_user(%{
          "email" => "floor-mgr-#{System.unique_integer([:positive])}@example.com",
          "password" => "MgrPass123!"
        })

      {:ok, _} = Members.add_member(project, manager.uuid, role: "manager")
      assert Authz.can?(manager.uuid, project, :create_tasks)

      # Control: the SAME member role on a project that took the defaults
      # can create tasks. Without this, the refute above would also pass if
      # member resolution were simply broken.
      {:ok, plain} =
        Projects.create_project(%{"name" => "AuthzPlain #{System.unique_integer([:positive])}"})

      {:ok, _} = Members.add_member(plain, member.uuid, role: "member")
      assert Authz.can?(member.uuid, plain, :create_tasks)
    end

    test "a crafted floor value is ignored rather than stored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

      render_change(view, "validate", %{
        "project" => %{"name" => ""},
        "authz" => %{"create_tasks" => "everyone", "delete_project" => "members"}
      })

      render_submit(view, "save", %{
        "project" => %{"name" => "AuthzEvil #{System.unique_integer([:positive])}"}
      })

      project = created("AuthzEvil")
      assert project
      # Neither the bogus choice nor the non-overridable action lands.
      refute Map.has_key?(project.settings || %{}, "authz")
    end
  end

  describe "public exposure (the portal IS the visibility control)" do
    test "the portal's public capabilities render on the form, not just in Modules", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/new")

      # Enabling the portal publishes a capability URL; what that URL
      # exposes is decided by these three, and every one defaults ON.
      assert html =~ "Public issue submission"
      assert html =~ "Public issue list"
      assert html =~ "Public status summary"
      assert html =~ ~s(name="flag[portal_submit]")
    end

    test "the reveal keys on the extension toggle, not any checked descendant", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/new")

      # The capability toggles inside the reveal are checked by default, so
      # a bare `group-has-[:checked]` made the block reveal ITSELF while the
      # extension was still off. The reveal must key on the extension's own
      # toggle.
      assert html =~ "data-ext-toggle"
      assert html =~ "group-has-[[data-ext-toggle]:checked]/extbox:flex"
      refute html =~ "group-has-[:checked]/extbox:flex"
    end

    test "the permissions section warns once the portal is on", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/projects/list/new")
      refute html =~ "without signing in"

      html =
        render_change(view, "validate", %{
          "project" => %{"name" => ""},
          "archetype" => "public_intake"
        })

      assert html =~ "without signing in"
    end

    test "narrowing a public capability is pinned on create", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

      render_change(view, "validate", %{
        "project" => %{"name" => ""},
        "archetype" => "public_intake"
      })

      # Take the submissions, but keep the issue list private.
      render_change(view, "validate", %{
        "project" => %{"name" => ""},
        "flag" => %{"portal_list" => "false"}
      })

      render_submit(view, "save", %{
        "project" => %{"name" => "PortalNarrow #{System.unique_integer([:positive])}"}
      })

      project = created("PortalNarrow")
      assert project
      assert Extensions.enabled?(project, "portal")
      # Only the narrowed capability is pinned; the others keep inheriting.
      assert project.settings["features"]["portal_list"] == false
      refute Map.has_key?(project.settings["features"], "portal_submit")
      # And it binds on the public surface.
      refute PhoenixKitProjects.Portal.capability?(project, :list)
      assert PhoenixKitProjects.Portal.capability?(project, :submit)
    end

    test "a disabled extension's flags are not pinned", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

      # Portal stays OFF (default archetype); its flags are inert.
      render_change(view, "validate", %{
        "project" => %{"name" => ""},
        "flag" => %{"portal_list" => "false"}
      })

      render_submit(view, "save", %{
        "project" => %{"name" => "PortalOff #{System.unique_integer([:positive])}"}
      })

      project = created("PortalOff")
      assert project
      refute Extensions.enabled?(project, "portal")
      refute Map.has_key?(project.settings["features"] || %{}, "portal_list")
    end
  end

  test "the drawers are grouped, and each header carries its current answer", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/projects/list/new")

    # Four intent-named sections replace the three grab-bags.
    assert html =~ ~s(id="create-start")
    assert html =~ ~s(id="create-people")
    assert html =~ ~s(id="create-features")
    assert html =~ ~s(id="create-extensions")
    refute html =~ ~s(id="create-customize")

    # Task features are grouped, not one flat wall of 13.
    assert html =~ ~s(id="create-flags-work")
    assert html =~ ~s(id="create-flags-time")
    assert html =~ ~s(id="create-flags-views")
    assert html =~ "Working on tasks"

    # Extensions are grouped by the job they do, not by which package
    # shipped them.
    assert html =~ ~s(id="create-exts-collaborate")
    assert html =~ "Files &amp; documents"

    # Headers state the answer, not a count of controls.
    assert html =~ "Starts immediately"
    assert html =~ "Site default statuses"
    assert html =~ "Just you"
  end

  test "an uncategorized extension still appears, under More", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/projects/list/new")

    # ConfigProvider's cfg_ext declares no category and isn't in the
    # fallback map — it must not silently vanish from the form.
    assert html =~ ~s(id="create-exts-more")
    assert html =~ "Config Ext"
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

  describe "adding people and groups (the 2026-08-07 Add-to-project rework)" do
    alias PhoenixKitProjects.Grants
    alias PhoenixKitStaff.{Departments, Teams}

    test "a person is seated as a member with the chosen role", %{conn: conn} do
      invitee = user_fixture()

      {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

      html =
        render_submit(view, "add_participant", %{
          "kind" => "person",
          "email" => invitee.email,
          "role" => "manager"
        })

      assert html =~ invitee.email

      render_submit(view, "save", %{
        "project" => %{"name" => "Seats #{System.unique_integer([:positive])}"}
      })

      project = created("Seats")
      assert project
      assert Members.role_of(project, invitee.uuid) == :manager
    end

    test "MULTIPLE groups can be added, each with its own role", %{conn: conn} do
      # The complaint the rework answers: the old UI's single "Responsible"
      # picker read as though a project could have one department, full stop.
      n = System.unique_integer([:positive])
      {:ok, dept_a} = Departments.create(%{"name" => "AddDeptA-#{n}"})
      {:ok, dept_b} = Departments.create(%{"name" => "AddDeptB-#{n}"})
      {:ok, team} = Teams.create(%{"name" => "AddTeam-#{n}", "department_uuid" => dept_a.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

      render_submit(view, "add_participant", %{
        "kind" => "department",
        "department_uuid" => dept_a.uuid,
        "role" => "member"
      })

      render_submit(view, "add_participant", %{
        "kind" => "department",
        "department_uuid" => dept_b.uuid,
        "role" => "viewer"
      })

      html =
        render_submit(view, "add_participant", %{
          "kind" => "team",
          "team_uuid" => team.uuid,
          "role" => "manager"
        })

      assert html =~ "AddDeptA-#{n}"
      assert html =~ "AddDeptB-#{n}"
      assert html =~ "AddTeam-#{n}"

      render_submit(view, "save", %{
        "project" => %{"name" => "Groups #{System.unique_integer([:positive])}"}
      })

      project = created("Groups")
      assert project

      grants =
        Grants.list_grants(project.uuid)
        |> Map.new(fn g -> {{g.subject_type, g.subject_uuid}, g.role} end)

      assert grants[{"department", dept_a.uuid}] == "member"
      assert grants[{"department", dept_b.uuid}] == "viewer"
      assert grants[{"team", team.uuid}] == "manager"
    end

    test "an unknown email is refused and seats nobody", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

      html =
        render_submit(view, "add_participant", %{
          "kind" => "person",
          "email" => "ghost-#{System.unique_integer([:positive])}@example.com",
          "role" => "member"
        })

      assert html =~ "No account with that email"
    end

    test "a group uuid the form never offered is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

      html =
        render_submit(view, "add_participant", %{
          "kind" => "department",
          "department_uuid" => Ecto.UUID.generate(),
          "role" => "manager"
        })

      assert html =~ "Choose a person, team, or department"
    end

    test "a kind can't be paired with another kind's uuid", %{conn: conn} do
      n = System.unique_integer([:positive])
      {:ok, dept} = Departments.create(%{"name" => "MismatchDept-#{n}"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/list/new")

      # Says "team", supplies a DEPARTMENT uuid in the department field:
      # each kind reads only its own field, so nothing is queued.
      html =
        render_submit(view, "add_participant", %{
          "kind" => "team",
          "department_uuid" => dept.uuid,
          "role" => "manager"
        })

      assert html =~ "Choose a person, team, or department"
    end

    test "the permissions rows read one per line, not a squeezed three-across",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/new")

      # The labels are nowrap, so a 3-column grid overflowed them out of
      # their cells and truncated the selects beside them.
      refute html =~ ~s(grid grid-cols-1 gap-3 sm:grid-cols-3)
      assert html =~ "Who can change task status"
    end
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

    test "default: template + start live inside the Start from accordion", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/new")

      assert html =~ ~s(id="create-start")
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
