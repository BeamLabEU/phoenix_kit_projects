defmodule PhoenixKitProjects.AuthzTest do
  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Authz

  import PhoenixKitProjects.LiveCase, only: [fake_scope: 1]

  @project %{uuid: "019f0000-0000-7000-8000-000000000001"}

  describe "vocabulary" do
    test "roles are ordered strongest-first" do
      assert Authz.roles() == [:owner, :manager, :member, :viewer]
    end

    test "the action vocabulary is frozen and includes every enforcement site's atom" do
      for action <- [
            :view,
            :create_tasks,
            :edit_tasks,
            :delete_tasks,
            :assign_tasks,
            :update_status,
            :log_time,
            :comment,
            :upload_files,
            :manage_members,
            :manage_modules,
            :edit_settings,
            :set_health,
            :archive_project,
            :delete_project
          ] do
        assert action in Authz.actions()
      end
    end
  end

  describe "can?/5 admin resolution (the 2026-08-07 permission split)" do
    test "the admin_all sub-permission grants power over a project you don't belong to" do
      scope = fake_scope(permissions: ["projects", "projects.admin_all"])
      assert Authz.can?(scope, @project, :view)
      assert Authz.can?(scope, @project, :manage_modules)
      assert Authz.can?(scope, @project, :update_status, %{uuid: "x"})
    end

    test "the bare module key no longer means 'do everything on every project'" do
      # THE point of the split. Before it, granting a role "projects" — so
      # its people could reach the module and see their own work — silently
      # handed them every project on the site, because the resolver
      # short-circuited on module access before membership was consulted.
      # This is the contractor shape: may enter the module, member of
      # nothing, so may do nothing here.
      scope = fake_scope(permissions: ["projects"])
      refute Authz.can?(scope, @project, :view)
      refute Authz.can?(scope, @project, :manage_modules)
      refute Authz.can?(scope, @project, :delete_project)
    end

    test "Owner's superadmin wildcard still resolves the sub-permission" do
      # Core's "*" covers present and future keys, including dotted ones —
      # an Owner must not need a backfill to keep working.
      scope = fake_scope(permissions: ["*"])
      assert Authz.can?(scope, @project, :view)
      assert Authz.can?(scope, @project, :delete_project)
    end

    test "fails closed: nil subject, missing permission, nil project, junk input" do
      refute Authz.can?(nil, @project, :view)
      refute Authz.can?(fake_scope(permissions: []), @project, :view)
      refute Authz.can?(fake_scope(permissions: ["projects", "projects.admin_all"]), nil, :view)
      refute Authz.can?("not a scope", @project, :view)

      refute Authz.can?(
               fake_scope(permissions: ["projects", "projects.admin_all"]),
               @project,
               "not an atom"
             )
    end

    test "an orphan sub-key without its base grants nothing" do
      # Core's base_held?/2 guard: a dotted key is only effective while its
      # base is held, so a stale row can't outlive a revoked module grant.
      scope = fake_scope(permissions: ["projects.admin_all"])
      refute Authz.can?(scope, @project, :view)
    end

    test "the :public context never honors the admin override (portal pre-wiring)" do
      scope = fake_scope(permissions: ["projects", "projects.admin_all"])
      refute Authz.can?(scope, @project, :view, nil, context: :public)
    end
  end
end
