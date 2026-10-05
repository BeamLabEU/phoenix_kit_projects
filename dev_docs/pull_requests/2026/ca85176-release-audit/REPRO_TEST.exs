defmodule PhoenixKitProjects.ReleaseReviewReproTest do
  use PhoenixKitProjects.LiveCase, async: false
  import Ecto.Query
  alias PhoenixKitProjects.{ApiKeys, Projects}
  alias PhoenixKitProjects.Schemas.ApiIdempotency
  alias PhoenixKitProjects.Test.Repo

  setup %{conn: conn} do
    project = fixture_project()
    {:ok, key, token} = ApiKeys.create(project, %{"name" => "Review", "role" => "manager"})

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn, project: project, key: key}
  end

  test "a rejected 51-item checklist PATCH still changes the title", %{conn: conn} do
    %{"task" => task} =
      conn
      |> post("/api/projects/v1/tasks", Jason.encode!(%{"title" => "Before"}))
      |> json_response(201)

    items = for n <- 1..51, do: %{"text" => "item #{n}"}

    conn
    |> patch(
      "/api/projects/v1/tasks/#{task["uuid"]}",
      Jason.encode!(%{"title" => "After", "checklist" => items})
    )
    |> json_response(422)

    assert Projects.get_assignment(task["uuid"]).task.title == "After"
  end

  test "a live request can lose its reservation and overwrite its successor's result", %{key: key} do
    parent = self()

    first =
      Task.async(fn ->
        ApiKeys.idempotent(key, "live-slow", fn ->
          send(parent, :reserved)

          receive do
            :finish -> {201, %{"owner" => "first"}}
          after
            5_000 -> raise "review test timed out"
          end
        end)
      end)

    assert_receive :reserved, 1_000

    Repo.update_all(
      from(i in ApiIdempotency,
        where: i.api_key_uuid == ^key.uuid and i.idempotency_key == "live-slow"
      ), set: [inserted_at: DateTime.add(DateTime.utc_now(), -600, :second)])

    assert {:ok, 201, %{"owner" => "second"}} =
             ApiKeys.idempotent(key, "live-slow", fn -> {201, %{"owner" => "second"}} end)

    send(first.pid, :finish)
    assert {:ok, 201, %{"owner" => "first"}} = Task.await(first)

    assert {:replay, 201, %{"owner" => "first"}} =
             ApiKeys.idempotent(key, "live-slow", fn -> raise "must replay" end)
  end

  test "an accepted duration exceeds the parent rollup column", %{conn: conn, project: project} do
    {:ok, %{child_project: child}} =
      Projects.create_subproject(project.uuid, %{"name" => "Child"})

    %{"task" => task} =
      conn
      |> post(
        "/api/projects/v1/tasks",
        Jason.encode!(%{
          "title" => "Huge",
          "project" => child.uuid,
          "estimated_duration" => 1_000_000_000,
          "estimated_duration_unit" => "hours"
        })
      )
      |> json_response(201)

    result = conn |> post("/api/projects/v1/tasks/#{task["uuid"]}/start", "{}")
    assert result.status == 200

    assert_raise DBConnection.EncodeError, fn ->
      Projects.recompute_project_completion(child.uuid)
    end

    assert [row] = Projects.list_assignments(project.uuid)
    assert row.estimated_duration == 0
    assert Projects.get_assignment(task["uuid"]).status == "in_progress"
  end
end
