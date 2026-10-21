defmodule PhoenixKitProjects.BatchedApiKeysPageTest do
  @moduledoc """
  The API keys page (`Web.ApiKeysLive`) loads on mount and again after every
  change, so what it reads must not grow with the number of keys: one read of
  every key's grants and one of the projects a key may be given, not a pair
  per key.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.{ApiKeys, QueryCounter}

  defp shared_keys!(project, n) do
    for i <- 1..n do
      {:ok, key, _token} = ApiKeys.create(project, %{"name" => "Bot #{i}", "role" => "member"})
      key
    end
  end

  defp mount_reads(conn, user_uuid) do
    conn = put_test_scope(conn, fake_scope(user_uuid: user_uuid))

    {{:ok, _view, html}, count} =
      QueryCounter.count(fn -> live(conn, "/en/admin/projects/api-keys") end)

    {html, count}
  end

  test "an administrator's page reads the same however many keys there are", %{conn: conn} do
    project = fixture_project()
    admin = embed_user_uuid!()

    shared_keys!(project, 2)
    {_, few} = mount_reads(conn, admin)

    shared_keys!(project, 8)
    {html, many} = mount_reads(conn, admin)

    assert html =~ "Bot 1"
    # Four times the keys, the same statements (a little slack for caching).
    assert many <= few + 4
  end
end
