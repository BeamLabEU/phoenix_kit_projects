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

  describe "can?/5 v1 resolution (admin-permission based)" do
    test "a scope holding the projects permission may act" do
      scope = fake_scope(permissions: ["projects"])
      assert Authz.can?(scope, @project, :view)
      assert Authz.can?(scope, @project, :manage_modules)
      assert Authz.can?(scope, @project, :update_status, %{uuid: "x"})
    end

    test "fails closed: nil subject, missing permission, nil project, junk input" do
      refute Authz.can?(nil, @project, :view)
      refute Authz.can?(fake_scope(permissions: []), @project, :view)
      refute Authz.can?(fake_scope(permissions: ["projects"]), nil, :view)
      refute Authz.can?("not a scope", @project, :view)
      refute Authz.can?(fake_scope(permissions: ["projects"]), @project, "not an atom")
    end

    test "the :public context never honors the admin override (portal pre-wiring)" do
      scope = fake_scope(permissions: ["projects"])
      refute Authz.can?(scope, @project, :view, nil, context: :public)
    end
  end
end
