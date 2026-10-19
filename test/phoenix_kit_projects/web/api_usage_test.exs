defmodule PhoenixKitProjects.Web.ApiUsageTest do
  @moduledoc """
  Usage per API key (chain V25): every authenticated call is counted per
  key, project and day, with its failures and refusals; the AI time,
  tokens and cost a key reports are summed beside them; the API keys page
  draws both.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, ApiUsage, Members}

  @base "/api/projects/v1"

  setup do
    home = fixture_project(%{"name" => "Home #{System.unique_integer([:positive])}"})
    other = fixture_project(%{"name" => "Other #{System.unique_integer([:positive])}"})

    {:ok, user} =
      Auth.register_user(%{
        email: "usage-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, _} = Members.add_member(home, user.uuid, role: "manager")

    {:ok, key, token} =
      ApiKeys.create(home, %{"name" => "Counter", "user_uuid" => user.uuid},
        actor_uuid: user.uuid
      )

    {:ok, home: home, other: other, key: key, token: token, user: user}
  end

  defp api(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  test "calls are counted per project with their failures; reported usage sits beside them",
       %{token: token, key: key, home: home, other: other} do
    api(token) |> get("#{@base}/me") |> json_response(200)
    api(token) |> get("#{@base}/tasks") |> json_response(200)
    # a project the key cannot reach: a 404 at home
    api(token) |> get("#{@base}/tasks?project=#{other.uuid}") |> json_response(404)

    api(token)
    |> put_req_header("idempotency-key", "u1")
    |> post("#{@base}/usage", Jason.encode!(%{tokens: 1500, cost_cents: 4}))
    |> json_response(201)

    # a refusal: the key's access no longer covers tasks there
    {:ok, _} = ApiKeys.put_grant(key, home.uuid, %{"scopes" => ["project:read"]})
    api(token) |> get("#{@base}/tasks") |> json_response(403)

    [row] = ApiUsage.rows([key.uuid])
    assert row.project == home.uuid
    assert row.day == Date.utc_today()
    assert %{requests: 5, errors: 2, denied: 1} = row
    assert row.tokens == 1500.0
    assert row.cost_cents == 4.0

    days = ApiUsage.days([row], :requests)
    assert length(days) == 30
    assert List.last(days).parts == [{home.uuid, 5}]
  end

  test "the Keys tab shows each key's last 30 days in one line, linking to its usage",
       %{conn: conn, token: token, key: key, user: user} do
    api(token) |> get("#{@base}/me") |> json_response(200)

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, permissions: ["projects"]))
    {:ok, view, html} = live(conn, "/en/admin/projects/api-keys")

    assert html =~ ~r/1 request\b/
    assert has_element?(view, "#usage-#{key.uuid} a[href*='api-keys/usage?key=#{key.uuid}']")
  end

  test "the Usage tab draws the period, compares it, and narrows to one key",
       %{conn: conn, token: token, key: key, user: user, home: home} do
    {:ok, %{assignment: a}} =
      PhoenixKitProjects.Projects.create_task_with_assignment(
        home.uuid,
        %{"title" => "Costly task", "ad_hoc" => true},
        %{}
      )

    api(token) |> get("#{@base}/me") |> json_response(200)

    api(token)
    |> put_req_header("idempotency-key", "t1")
    |> post("#{@base}/tasks/#{a.uuid}/usage", Jason.encode!(%{tokens: 900, cost_cents: 12}))
    |> json_response(201)

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, permissions: ["projects"]))
    {:ok, view, html} = live(conn, "/en/admin/projects/api-keys/usage")

    assert html =~ "usage-figures"
    assert has_element?(view, "#usage-main-chart")
    assert has_element?(view, "#usage-by-key a", "Counter")
    assert has_element?(view, "#usage-by-task", "Costly task")
    assert html =~ "New in this period"

    view |> element("a", "AI cost") |> render_click()
    assert_patch(view, "/en/admin/projects/api-keys/usage?days=30&metric=cost_cents")

    view |> form("#usage-filters", %{"days" => "7", "key" => key.uuid}) |> render_change()

    assert_patch(
      view,
      "/en/admin/projects/api-keys/usage?days=7&key=#{key.uuid}&metric=cost_cents"
    )

    assert render(view) =~ "per day, by project"

    # someone else's key in the address is ignored, not shown
    {:ok, _view, html} =
      live(conn, "/en/admin/projects/api-keys/usage?key=#{Ecto.UUID.generate()}")

    assert html =~ "per day, by key"
  end

  test "a viewer hides AI cost with Columns, and it stays hidden", %{
    conn: conn,
    token: token,
    user: user
  } do
    api(token) |> get("#{@base}/me") |> json_response(200)

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, permissions: ["projects"]))
    {:ok, view, html} = live(conn, "/en/admin/projects/api-keys/usage")
    assert html =~ "AI cost"

    render_click(view, "open_column_modal", %{})
    render_click(view, "remove_column", %{"column_id" => "cost_cents", "section" => "figures"})
    render_click(view, "remove_column", %{"column_id" => "cost_cents", "section" => "tasks"})
    render_click(view, "hide_column_modal", %{})
    refute render(view) =~ "AI cost"

    {:ok, _view, html} = live(conn, "/en/admin/projects/api-keys/usage?metric=cost_cents")
    refute html =~ "AI cost"

    {:ok, _view, html} = live(conn, "/en/admin/projects/api-keys")
    refute html =~ "$0.00"
  end

  test "an administrator sees every key's usage, with no switch", %{
    conn: conn,
    user: user,
    home: home
  } do
    {:ok, _shared, shared_token} =
      ApiKeys.create(home, %{"name" => "Shared bot", "role" => "member"})

    api(shared_token) |> get("#{@base}/me") |> json_response(200)

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))
    {:ok, _view, html} = live(conn, "/en/admin/projects/api-keys/usage")
    assert html =~ "Shared bot"
    refute html =~ "Whose keys"
  end

  test "a key nobody has used says so", %{conn: conn, user: user} do
    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, permissions: ["projects"]))
    {:ok, _view, html} = live(conn, "/en/admin/projects/api-keys")
    assert html =~ "No use in the last 30 days."

    {:ok, _view, html} = live(conn, "/en/admin/projects/api-keys/usage")
    assert html =~ "Nothing yet in the last 30 days."
  end
end
