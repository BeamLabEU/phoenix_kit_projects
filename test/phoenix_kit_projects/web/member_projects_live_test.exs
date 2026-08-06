defmodule PhoenixKitProjects.Web.MemberProjectsLiveTest do
  @moduledoc """
  The member-facing surface at /dashboard/projects: membership-scoped
  listing, the `?open=` membership gate (the authorization boundary for
  the embedded hub LVs), and the anonymous/memberless degradations.
  """
  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Members

  defp user_fixture do
    {:ok, user} =
      Auth.register_user(%{
        email: "member-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  setup %{conn: conn} do
    user = user_fixture()
    mine = fixture_project(%{"name" => "Mine #{System.unique_integer([:positive])}"})
    other = fixture_project(%{"name" => "NotMine #{System.unique_integer([:positive])}"})
    {:ok, _} = Members.add_member(mine, user.uuid, role: "member")

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, permissions: []))
    {:ok, conn: conn, user: user, mine: mine, other: other}
  end

  test "lists ONLY the user's member projects, with the role badge",
       %{conn: conn, mine: mine, other: other} do
    {:ok, _view, html} = live(conn, "/en/dashboard/projects")

    assert html =~ mine.name
    refute html =~ other.name
    assert html =~ "member"
  end

  test "templates never list", %{conn: conn, user: user} do
    template = fixture_project(%{"name" => "Tpl #{System.unique_integer([:positive])}"})

    template
    |> Ecto.Changeset.change(is_template: true)
    |> PhoenixKit.RepoHelper.repo().update!()

    {:ok, _} = Members.add_member(template, user.uuid, role: "member")

    {:ok, _view, html} = live(conn, "/en/dashboard/projects")
    refute html =~ template.name
  end

  test "?open= renders the embedded project host for a MEMBER project",
       %{conn: conn, mine: mine} do
    {:ok, _view, html} = live(conn, "/en/dashboard/projects?open=#{mine.uuid}")

    assert html =~ "member-project-host-#{mine.uuid}"
    # Back link to the list.
    assert html =~ "My Projects"
  end

  test "?open= with a NON-member project does not open (the gate)",
       %{conn: conn, other: other} do
    {:ok, _view, html} = live(conn, "/en/dashboard/projects?open=#{other.uuid}")

    refute html =~ "member-project-host-"
    refute html =~ other.name
  end

  test "no memberships → the empty state", %{conn: conn} do
    lonely = user_fixture()
    conn = put_test_scope(conn, fake_scope(user_uuid: lonely.uuid, permissions: []))

    {:ok, _view, html} = live(conn, "/en/dashboard/projects")
    assert html =~ "not a member of any project"
  end

  test "no authenticated user degrades to the empty state (production redirects upstream)" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, _view, html} = live(conn, "/en/dashboard/projects")
    assert html =~ "not a member of any project"
  end

  test "Members.projects_for_user returns {project, role} pairs, newest membership first",
       %{user: user, mine: mine} do
    # Both rows land in the same second (utc_datetime truncation) — backdate
    # the first membership so the ordering assertion is deterministic.
    Members.get_member(mine.uuid, user.uuid)
    |> Ecto.Changeset.change(inserted_at: ~U[2026-01-01 00:00:00Z])
    |> PhoenixKit.RepoHelper.repo().update!()

    second = fixture_project(%{"name" => "Second #{System.unique_integer([:positive])}"})
    {:ok, _} = Members.add_member(second, user.uuid, role: "owner")

    assert [{p1, "owner"}, {p2, "member"}] = Members.projects_for_user(user.uuid)
    assert p1.uuid == second.uuid
    assert p2.uuid == mine.uuid
  end
end
