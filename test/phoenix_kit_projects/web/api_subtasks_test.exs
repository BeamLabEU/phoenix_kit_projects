defmodule PhoenixKitProjects.Web.ApiSubtasksTest do
  @moduledoc """
  Tasks under tasks on the API (V23): `parent` on create and update, the
  move call, many lines at once, the list filter, the tick rules as an agent
  sees them, a delete that needs `cascade`, and the briefing that lists
  top-level tasks with their subtask counts.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, Projects}
  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitProjects.Test.Repo

  @base "/api/projects/v1"

  setup do
    project = fixture_project()

    {:ok, user} =
      Auth.register_user(%{
        email: "subtasks-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, _key, token} =
      ApiKeys.create(project, %{"name" => "Agent", "role" => "manager"}, actor_uuid: user.uuid)

    {:ok, project: project, token: token}
  end

  defp api(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  defp post_json(conn, path, body), do: post(conn, path, Jason.encode!(body))
  defp patch_json(conn, path, body), do: patch(conn, path, Jason.encode!(body))

  defp set_policy(project, policy) do
    settings = Map.put(project.settings || %{}, "agents", policy)
    {:ok, p} = Projects.update_project(project, %{"settings" => settings})
    p
  end

  defp create(c, body) do
    %{"task" => t} = c |> post_json("#{@base}/tasks", body) |> json_response(201)
    t
  end

  defp titles(c, query \\ "") do
    %{"tasks" => tasks} = c |> get("#{@base}/tasks#{query}") |> json_response(200)
    Enum.map(tasks, & &1["title"])
  end

  test "parent on create nests a task, last under its parent; the JSON says where it sits", %{
    conn: conn,
    token: token
  } do
    c = api(conn, token)
    parent = create(c, %{"title" => "Kitchen"})
    _other = create(c, %{"title" => "Bathroom"})
    a = create(c, %{"title" => "Measure", "parent" => parent["ref"]})
    b = create(c, %{"title" => "Order", "parent" => parent["uuid"]})

    assert a["parent_task"] == parent["ref"]
    assert a["depth"] == 1
    assert b["parent_task"] == parent["ref"]

    # depth first: the parent, then what is under it, then the next top-level task
    assert titles(c) == ["Kitchen", "Measure", "Order", "Bathroom"]

    %{"task" => detail} = c |> get("#{@base}/tasks/#{parent["uuid"]}") |> json_response(200)
    assert detail["subtask_refs"] == [a["ref"], b["ref"]]
    assert detail["subtasks"] == %{"done" => 0, "total" => 2}
    assert detail["depth"] == 0
    assert detail["parent_task"] == nil

    assert titles(c, "?parent=none") == ["Kitchen", "Bathroom"]
    assert titles(c, "?parent=#{parent["ref"]}") == ["Measure", "Order"]

    assert %{"error" => %{"code" => "not_found"}} =
             c |> get("#{@base}/tasks?parent=NOPE-1") |> json_response(404)

    assert %{"error" => %{"code" => "not_found"}} =
             c
             |> post_json("#{@base}/tasks", %{"title" => "Orphan", "parent" => "NOPE-1"})
             |> json_response(404)
  end

  test "PATCH parent moves the branch; null brings it to the top; a loop is refused", %{
    conn: conn,
    token: token
  } do
    c = api(conn, token)
    a = create(c, %{"title" => "A"})
    b = create(c, %{"title" => "B"})
    b1 = create(c, %{"title" => "B1", "parent" => b["ref"]})

    %{"task" => moved} =
      c
      |> patch_json("#{@base}/tasks/#{b["uuid"]}", %{"parent" => a["ref"]})
      |> json_response(200)

    assert moved["parent_task"] == a["ref"]
    assert titles(c) == ["A", "B", "B1"]
    assert Repo.get!(Assignment, b1["uuid"]).parent_uuid == b["uuid"]

    # under itself, or under its own subtask
    assert %{"error" => %{"code" => "cycle"}} =
             c
             |> patch_json("#{@base}/tasks/#{a["uuid"]}", %{"parent" => b1["ref"]})
             |> json_response(409)

    %{"task" => top} =
      c |> patch_json("#{@base}/tasks/#{b["uuid"]}", %{"parent" => nil}) |> json_response(200)

    assert top["parent_task"] == nil
    assert top["depth"] == 0
  end

  test "move places a task exactly: after a sibling, first, or last", %{conn: conn, token: token} do
    c = api(conn, token)
    p = create(c, %{"title" => "P"})
    x = create(c, %{"title" => "X", "parent" => p["ref"]})
    y = create(c, %{"title" => "Y", "parent" => p["ref"]})
    z = create(c, %{"title" => "Z"})

    c
    |> post_json("#{@base}/tasks/#{z["uuid"]}/move", %{"parent" => p["ref"], "after" => x["ref"]})
    |> json_response(200)

    assert titles(c, "?parent=#{p["ref"]}") == ["X", "Z", "Y"]

    c
    |> post_json("#{@base}/tasks/#{y["uuid"]}/move", %{"after" => nil})
    |> json_response(200)

    assert titles(c, "?parent=#{p["ref"]}") == ["Y", "X", "Z"]

    assert %{"error" => %{"code" => "not_found"}} =
             c
             |> post_json("#{@base}/tasks/#{y["uuid"]}/move", %{"after" => "NOPE-9"})
             |> json_response(404)
  end

  test "batch creates many lines in one call, nested by depth, under a parent", %{
    conn: conn,
    token: token
  } do
    c = api(conn, token)
    parent = create(c, %{"title" => "Client questions"})
    _after = create(c, %{"title" => "Later"})

    %{"tasks" => tasks, "count" => 4} =
      c
      |> post_json("#{@base}/tasks/batch", %{
        "parent" => parent["ref"],
        "lines" => [
          "Which rooms?",
          "",
          %{"text" => "Delivery", "depth" => 0},
          %{"text" => "Saturdays?", "depth" => 1, "done" => true},
          %{"text" => "Matte or gloss?"}
        ]
      })
      |> json_response(201)

    assert Enum.map(tasks, & &1["title"]) ==
             ["Which rooms?", "Delivery", "Saturdays?", "Matte or gloss?"]

    assert Enum.map(tasks, & &1["depth"]) == [1, 1, 2, 1]
    assert Enum.at(tasks, 2)["status"] == "done"

    assert titles(c) == [
             "Client questions",
             "Which rooms?",
             "Delivery",
             "Saturdays?",
             "Matte or gloss?",
             "Later"
           ]

    assert %{"error" => %{"code" => "validation_failed"}} =
             c |> post_json("#{@base}/tasks/batch", %{"lines" => []}) |> json_response(422)

    assert %{"error" => %{"code" => "validation_failed"}} =
             c |> post_json("#{@base}/tasks/batch", %{"lines" => [42]}) |> json_response(422)

    too_many = for n <- 1..501, do: "line #{n}"

    assert %{"error" => %{"code" => "validation_failed"}} =
             c |> post_json("#{@base}/tasks/batch", %{"lines" => too_many}) |> json_response(422)
  end

  test "the tick rules: a parent ticks what is under it, the last child ticks the parent, reopening climbs",
       %{conn: conn, token: token} do
    c = api(conn, token)
    p = create(c, %{"title" => "P"})
    a = create(c, %{"title" => "A", "parent" => p["ref"]})
    b = create(c, %{"title" => "B", "parent" => p["ref"]})

    # completing the parent completes both children
    %{"task" => done, "also_changed" => 2} =
      c |> post_json("#{@base}/tasks/#{p["uuid"]}/complete", %{}) |> json_response(200)

    assert done["status"] == "done"
    assert Repo.get!(Assignment, a["uuid"]).status == "done"
    assert Repo.get!(Assignment, b["uuid"]).status == "done"

    # reopening a child reopens the parent; the sibling stays done
    %{"also_changed" => 1} =
      c |> post_json("#{@base}/tasks/#{a["uuid"]}/reopen", %{}) |> json_response(200)

    assert Repo.get!(Assignment, p["uuid"]).status != "done"
    assert Repo.get!(Assignment, b["uuid"]).status == "done"

    # the last child done ticks the parent
    %{"also_changed" => 1} =
      c |> post_json("#{@base}/tasks/#{a["uuid"]}/complete", %{}) |> json_response(200)

    assert Repo.get!(Assignment, p["uuid"]).status == "done"

    # reopening the parent leaves the children as they are
    %{"also_changed" => 0} =
      c |> post_json("#{@base}/tasks/#{p["uuid"]}/reopen", %{}) |> json_response(200)

    assert Repo.get!(Assignment, a["uuid"]).status == "done"
    assert Repo.get!(Assignment, b["uuid"]).status == "done"
  end

  test "a project can stop the last subtask from ticking its parent", %{
    conn: conn,
    project: project,
    token: token
  } do
    {:ok, _} =
      Projects.update_project(project, %{
        "settings" => Map.put(project.settings || %{}, "outline", %{"complete_parent" => false})
      })

    c = api(conn, token)
    p = create(c, %{"title" => "P"})
    a = create(c, %{"title" => "A", "parent" => p["ref"]})

    %{"also_changed" => 0} =
      c |> post_json("#{@base}/tasks/#{a["uuid"]}/complete", %{}) |> json_response(200)

    assert Repo.get!(Assignment, p["uuid"]).status == "waiting"
  end

  test "deleting a task with subtasks needs cascade, and the policy covers every row", %{
    conn: conn,
    project: project,
    token: token
  } do
    set_policy(project, %{"delete_tasks" => "any"})
    c = api(conn, token)
    p = create(c, %{"title" => "P"})
    a = create(c, %{"title" => "A", "parent" => p["ref"]})
    a1 = create(c, %{"title" => "A1", "parent" => a["ref"]})

    assert %{"error" => %{"code" => "has_subtasks", "details" => %{"subtasks" => 2}}} =
             c |> delete("#{@base}/tasks/#{p["uuid"]}") |> json_response(409)

    assert Repo.get(Assignment, p["uuid"])

    %{"deleted" => deleted, "also_deleted" => also} =
      c |> delete("#{@base}/tasks/#{p["uuid"]}?cascade=true") |> json_response(200)

    assert deleted == p["uuid"]
    assert Enum.sort(also) == Enum.sort([a["uuid"], a1["uuid"]])
    refute Repo.get(Assignment, a1["uuid"])
  end

  test "a held subtask counts: the delete needs cascade and reports it", %{
    conn: conn,
    project: project,
    token: token
  } do
    set_policy(project, %{"delete_tasks" => "any"})
    c = api(conn, token)
    p = create(c, %{"title" => "P"})
    held = create(c, %{"title" => "Held", "parent" => p["ref"]})

    Repo.get!(Assignment, held["uuid"])
    |> Ecto.Changeset.change(review_status: "removed")
    |> Repo.update!()

    assert %{"error" => %{"code" => "has_subtasks"}} =
             c |> delete("#{@base}/tasks/#{p["uuid"]}") |> json_response(409)

    %{"also_deleted" => also} =
      c |> delete("#{@base}/tasks/#{p["uuid"]}?cascade=true") |> json_response(200)

    assert also == [held["uuid"]]
  end

  test "the briefing lists top-level tasks with their counts, not every subtask", %{
    conn: conn,
    token: token
  } do
    c = api(conn, token)
    p = create(c, %{"title" => "Big parent"})

    c
    |> post_json("#{@base}/tasks/batch", %{
      "parent" => p["ref"],
      "lines" => for(n <- 1..30, do: "Sub #{n}")
    })
    |> json_response(201)

    _solo = create(c, %{"title" => "Solo"})

    %{"tasks" => briefs, "open_total" => 2, "open_with_subtasks" => 32} =
      c |> get("#{@base}/briefing") |> json_response(200)

    assert Enum.map(briefs, & &1["title"]) |> Enum.sort() == ["Big parent", "Solo"]
    big = Enum.find(briefs, &(&1["title"] == "Big parent"))
    assert big["subtasks"] == %{"done" => 0, "total" => 30}
    refute Map.has_key?(big, "checklist")
  end

  test "the checklist API is gone", %{conn: conn, token: token} do
    c = api(conn, token)
    t = create(c, %{"title" => "No list"})
    refute Map.has_key?(t, "checklist")

    gone = c |> patch_json("#{@base}/tasks/#{t["uuid"]}/checklist/x", %{"done" => true})
    assert gone.status == 404
  end
end
