defmodule PhoenixKitProjects.Web.ApiReopenReasonTest do
  @moduledoc """
  The API's reopen takes a `reason`: it lands on the reopen's row (the
  notice quotes it), and is posted as a comment only by a key that may
  comment — the comments:write scope AND the project's :comment floor.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, Projects}
  alias PhoenixKitProjects.Test.Repo

  @base "/api/projects/v1"

  setup do
    {:ok, _} = Settings.update_setting("comments_enabled", "true")
    on_exit(fn -> Settings.update_setting("comments_enabled", "false") end)

    project = fixture_project()
    # History and the reason's comment need discussions on.
    :ok = PhoenixKitProjects.DataCase.with_comments_module()
    task = fixture_task(%{"title" => "Measure"})

    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => task.uuid,
        "status" => "done"
      })

    {:ok, user} =
      Auth.register_user(%{
        email: "runner-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user = PhoenixKitProjects.Test.Access.grant_projects!(user)
    {:ok, project: project, a: a, user: user}
  end

  defp key!(project, user, scopes) do
    {:ok, _key, token} =
      ApiKeys.create(project, %{"name" => "Runner", "role" => "member", "scopes" => scopes},
        actor_uuid: user.uuid
      )

    token
  end

  defp reopen(conn, token, uuid, body) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("#{@base}/tasks/#{uuid}/reopen", Jason.encode!(body))
  end

  defp reason_comments(uuid) do
    Repo.all(
      from(c in PhoenixKitComments.Comment,
        where: c.resource_type == "assignment" and c.resource_uuid == ^uuid
      )
    )
  end

  test "the reason is on the row and posted as a comment by a key that may comment", ctx do
    token = key!(ctx.project, ctx.user, ["tasks:read", "status:write", "comments:write"])

    assert %{"task" => _} =
             ctx.conn
             |> reopen(token, ctx.a.uuid, %{reason: "  Wall A again.  "})
             |> json_response(200)

    [row] =
      Repo.all(
        from(e in Entry,
          where: e.action == "projects.assignment_reopened" and e.resource_uuid == ^ctx.a.uuid
        )
      )

    assert row.metadata["reason"] == "Wall A again."
    assert [c] = reason_comments(ctx.a.uuid)
    assert c.content == "Wall A again."
    assert c.metadata["reopen_reason"] == true
  end

  test "a key without comments:write reopens with the reason on the row, and posts no comment",
       ctx do
    token = key!(ctx.project, ctx.user, ["tasks:read", "status:write"])
    ctx.conn |> reopen(token, ctx.a.uuid, %{reason: "Wall A again."}) |> json_response(200)

    assert [row] =
             Repo.all(
               from(e in Entry,
                 where:
                   e.action == "projects.assignment_reopened" and e.resource_uuid == ^ctx.a.uuid
               )
             )

    assert row.metadata["reason"] == "Wall A again."
    assert reason_comments(ctx.a.uuid) == []
  end

  test "a reason that is not text is no reason", ctx do
    token = key!(ctx.project, ctx.user, ["tasks:read", "status:write", "comments:write"])
    ctx.conn |> reopen(token, ctx.a.uuid, %{reason: %{"x" => 1}}) |> json_response(200)
    assert reason_comments(ctx.a.uuid) == []
  end
end
