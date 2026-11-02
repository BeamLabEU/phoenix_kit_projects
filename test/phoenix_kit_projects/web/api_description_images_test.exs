defmodule PhoenixKitProjects.Web.ApiDescriptionImagesTest do
  @moduledoc """
  A picture in a task's description is kept by its file (`pkfile:<uuid>`,
  `InlineImages`); the JSON API hands it to the caller as an address the
  key's person may open — a private library's a time-window one — and keeps
  the reference for one they may not, so writing the text back keeps every
  picture.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{ApiKeys, Attachments, Members, Projects}
  alias PhoenixKitProjects.Test.Repo

  @base "/api/projects/v1"

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        email: "pics-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    PhoenixKitProjects.Test.Access.grant_projects!(user)
    user
  end

  defp private_library!(owner_uuid) do
    %PhoenixKit.Modules.Storage.Library{}
    |> Ecto.Changeset.change(%{
      name: "Private",
      key_prefix: "pk-#{System.unique_integer([:positive])}",
      slug: "private-#{System.unique_integer([:positive])}",
      kind: "user",
      visibility: "private",
      owner_uuid: owner_uuid
    })
    |> Repo.insert!()
  end

  defp api(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  setup do
    project = fixture_project(%{"start_mode" => "immediate"})
    owner = user!()
    other = user!()
    {:ok, _} = Members.add_member(project, owner.uuid, role: "owner")
    {:ok, _} = Members.add_member(project, other.uuid, role: "member")

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Measure the window", "ad_hoc" => true},
        %{}
      )

    # Stored as plain bytes: the reference names the file, whatever it holds,
    # and an image would start variant jobs this test does not need.
    path = Path.join(System.tmp_dir!(), "pkp-api-pic-#{System.unique_integer([:positive])}")
    Elixir.File.write!(path, "shot #{System.unique_integer()}")
    on_exit(fn -> Elixir.File.rm(path) end)

    {:ok, file} =
      Attachments.store_task_file(
        a,
        path,
        [
          filename: "shot.txt",
          content_type: "text/plain",
          size_bytes: 10,
          inline: true
        ],
        owner.uuid
      )

    # The picture's file lives in the owner's private library: only the
    # owner may open it.
    library = private_library!(owner.uuid)

    Repo.update_all(from(f in StorageFile, where: f.uuid == ^file.uuid),
      set: [library_uuid: library.uuid]
    )

    {:ok, a} =
      Projects.update_assignment_form(a, %{
        "description" => "Before ![shot](pkfile:#{file.uuid}) after"
      })

    {:ok, owner_key, owner_token} =
      ApiKeys.create(project, %{"name" => "Owner's AI", "user_uuid" => owner.uuid})

    {:ok, _, other_token} =
      ApiKeys.create(project, %{"name" => "Member's AI", "user_uuid" => other.uuid})

    {:ok,
     a: a, pic: file, owner_key: owner_key, owner_token: owner_token, other_token: other_token}
  end

  test "a task's picture reaches the key's person as a time-window address", ctx do
    %{"task" => task} =
      ctx.conn
      |> api(ctx.owner_token)
      |> get("#{@base}/tasks/#{ctx.a.uuid}")
      |> json_response(200)

    refute task["description"] =~ "pkfile:"

    [token] =
      Regex.run(~r{/file/#{ctx.pic.uuid}/original/([^/?)\s]+)}, task["description"],
        capture: :all_but_first
      )

    assert URLSigner.private_token?(token)
    assert task["display_summary"]["text"] == task["description"]

    # the list resolves it too
    %{"tasks" => tasks} =
      ctx.conn |> api(ctx.owner_token) |> get("#{@base}/tasks") |> json_response(200)

    listed = Enum.find(tasks, &(&1["uuid"] == ctx.a.uuid))
    assert listed["description"] =~ "/file/#{ctx.pic.uuid}/original/"
  end

  test "a picture the key's person may not open keeps its reference", ctx do
    %{"task" => task} =
      ctx.conn
      |> api(ctx.other_token)
      |> get("#{@base}/tasks/#{ctx.a.uuid}")
      |> json_response(200)

    assert task["description"] == "Before ![shot](pkfile:#{ctx.pic.uuid}) after"
  end

  test "the text written back as it was read keeps the picture by its file", ctx do
    # the key wrote these words last, so it may write them again
    {:ok, _} = Projects.stamp_assignment(ctx.a, %{words_by_key_uuid: ctx.owner_key.uuid})

    %{"task" => task} =
      ctx.conn
      |> api(ctx.owner_token)
      |> get("#{@base}/tasks/#{ctx.a.uuid}")
      |> json_response(200)

    ctx.conn
    |> api(ctx.owner_token)
    |> patch("#{@base}/tasks/#{ctx.a.uuid}", Jason.encode!(%{description: task["description"]}))
    |> json_response(200)

    assert Projects.get_assignment(ctx.a.uuid).description ==
             "Before ![shot](pkfile:#{ctx.pic.uuid}) after"
  end
end
