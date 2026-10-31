defmodule PhoenixKitProjects.Web.TaskFilesTest do
  @moduledoc """
  A task holds its own files and images (the boss's list, item 7; chain
  V27): stored in a folder per task inside the project's, recorded as the
  task's, listed on the edit popup's More tab, an image pasted into the
  description stored the same way and kept in the text by its file
  (`pkfile:`, `InlineImages`) — never as a `data:` URL.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitProjects.{Attachments, Projects}
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitProjects.Web.Components.RichText

  # A 1×1 PNG.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup %{conn: conn} do
    me = embed_user_uuid!()
    project = fixture_project(%{"start_mode" => "immediate"})

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Measure the window", "ad_hoc" => true},
        %{}
      )

    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: me)), me: me, project: project, a: a}
  end

  defp tmp(bytes) do
    path = Path.join(System.tmp_dir!(), "pkp-test-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "a stored file is the task's, in the task's folder, and removed again", ctx do
    path = tmp("plan v1 #{System.unique_integer()}")

    assert {:ok, file} =
             Attachments.store_task_file(
               ctx.a,
               path,
               [filename: "plan.txt", content_type: "text/plain", size_bytes: 10],
               ctx.me
             )

    assert [%{file: %{uuid: uuid}, inline: false}] = Attachments.list_task_files(ctx.a.uuid)
    assert uuid == file.uuid

    folder = Repo.get(Folder, Repo.get(PhoenixKit.Modules.Storage.File, file.uuid).folder_uuid)
    assert folder.name == Attachments.task_folder_name(ctx.a.uuid)

    assert :ok = Attachments.remove_task_file(ctx.a, file.uuid, ctx.me)
    assert Attachments.list_task_files(ctx.a.uuid) == []
    assert {:error, :not_found} = Attachments.remove_task_file(ctx.a, file.uuid, ctx.me)
  end

  test "the edit popup lists the task's files on More, and a pasted image is stored", ctx do
    path = tmp("notes #{System.unique_integer()}")

    {:ok, _} =
      Attachments.store_task_file(
        ctx.a,
        path,
        [filename: "notes.txt", content_type: "text/plain", size_bytes: 5],
        ctx.me
      )

    {:ok, view, html} =
      live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

    assert has_element?(
             view,
             "[id^='assignment-'][id$='-pane-more'] #assignment-files",
             "notes.txt"
           )

    refute has_element?(view, "[id^='assignment-'][id$='-pane-task'] #assignment-files")

    [id] =
      Regex.run(~r/data-description-editor="(assignment-description--[^"]+)"/, html,
        capture: :all_but_first
      )

    send(
      view.pid,
      {:leaf_paste_image,
       %{
         editor_id: id,
         data_url: "data:image/png;base64," <> Base.encode64(@png),
         name: "shot.png",
         mime: "image/png"
       }}
    )

    render(view)
    assert [%{inline: true}] = Attachments.list_task_files(ctx.a.uuid, inline: true)
  end

  test "a pasted file that is not an image is refused", ctx do
    {:ok, view, html} =
      live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

    [id] =
      Regex.run(~r/data-description-editor="(assignment-description--[^"]+)"/, html,
        capture: :all_but_first
      )

    send(
      view.pid,
      {:leaf_paste_image,
       %{
         editor_id: id,
         data_url: "data:text/html;base64," <> Base.encode64("<script></script>"),
         name: "x.html",
         mime: "text/html"
       }}
    )

    assert render(view) =~ "Upload failed"
    assert Attachments.list_task_files(ctx.a.uuid) == []
  end

  test "an image pasted into a sub-project not saved yet is answered with a word, not kept as data",
       ctx do
    {:ok, view, html} =
      live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/new?kind=subproject")

    [id] =
      Regex.run(~r/data-description-editor="(subproject-description--[^"]+)"/, html,
        capture: :all_but_first
      )

    send(
      view.pid,
      {:leaf_paste_image,
       %{
         editor_id: id,
         data_url: "data:image/png;base64," <> Base.encode64(@png),
         name: "shot.png",
         mime: "image/png"
       }}
    )

    html = render(view)
    assert html =~ "Save it first to add images."
    refute html =~ "data:image/png"
  end

  # LiveViewTest's upload client needs a PubSub on the test endpoint, which
  # this suite's has not: the input and its drop zone are checked here, the
  # storing path through `store_task_file/4` and the paste above.
  test "the More tab has the upload button and drop zone; the first tab does not", ctx do
    {:ok, view, _} =
      live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

    assert has_element?(
             view,
             "[id^='assignment-'][id$='-pane-more'] #assignment-files[phx-drop-target]"
           )

    assert has_element?(view, "#assignment-files input[type=file][name=task_files]")
    assert has_element?(view, "#assignment-description-image")
  end

  test "removing a file asks first through the shared confirm", ctx do
    path = tmp("drop #{System.unique_integer()}")

    {:ok, file} =
      Attachments.store_task_file(
        ctx.a,
        path,
        [filename: "drop.txt", content_type: "text/plain", size_bytes: 4],
        ctx.me
      )

    {:ok, view, _html} =
      live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

    html =
      view
      |> element(~s(#assignment-file-list [phx-value-event="remove_task_file"]))
      |> render_click()

    assert html =~ "Remove this file from the task?"
    assert [_] = Attachments.list_task_files(ctx.a.uuid)

    render_click(view, "confirm_action_ok", %{})
    assert Attachments.list_task_files(ctx.a.uuid) == []

    assert_activity_logged("projects.task_file_removed",
      resource_uuid: ctx.a.uuid,
      actor_uuid: ctx.me,
      metadata_has: %{"file_uuid" => file.uuid}
    )
  end

  test "a removal that fails is recorded as an attempt", ctx do
    {:ok, view, _html} =
      live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

    stranger = Ecto.UUID.generate()

    assert render_click(view, "remove_task_file", %{"uuid" => stranger}) =~
             "Could not remove the file."

    assert_activity_logged("projects.task_file_removed",
      resource_uuid: ctx.a.uuid,
      actor_uuid: ctx.me,
      metadata_has: %{"file_uuid" => stranger, "db_pending" => true}
    )
  end

  describe "pictures in the description are kept by file" do
    defp image!(ctx, opts \\ []) do
      {:ok, file} =
        Attachments.store_task_file(
          ctx.a,
          tmp(@png <> "#{System.unique_integer()}"),
          [
            filename: "shot.png",
            content_type: "image/png",
            size_bytes: byte_size(@png),
            inline: Keyword.get(opts, :inline, true)
          ],
          ctx.me
        )

      file
    end

    defp private_library!(owner) do
      %PhoenixKit.Modules.Storage.Library{}
      |> Ecto.Changeset.change(%{
        name: "Private",
        key_prefix: "pk-#{System.unique_integer([:positive])}",
        slug: "private-#{System.unique_integer([:positive])}",
        kind: "user",
        visibility: "private",
        owner_uuid: owner
      })
      |> Repo.insert!()
    end

    test "an address the editor wrote is stored as the file's reference", ctx do
      file = image!(ctx)
      url = URLSigner.signed_url(file.uuid, "original", locale: :none)

      {:ok, a} =
        Projects.update_assignment_form(ctx.a, %{
          "description" => "Look ![shot](#{url}) and ![away](https://example.com/x.png)",
          "translations" => %{"et" => %{"description" => "Vaata ![shot](#{url})"}}
        })

      assert a.description ==
               "Look ![shot](pkfile:#{file.uuid}) and ![away](https://example.com/x.png)"

      assert a.translations["et"]["description"] == "Vaata ![shot](pkfile:#{file.uuid})"
    end

    test "a reference is drawn for the viewer: a private file by a time-window address, and not at all for one who may not see it",
         ctx do
      file = image!(ctx)
      library = private_library!(ctx.me)

      Repo.update_all(
        from(f in StorageFile, where: f.uuid == ^file.uuid),
        set: [library_uuid: library.uuid]
      )

      text = "![shot](pkfile:#{file.uuid})"
      owner = Scope.for_user(Auth.get_user(ctx.me))

      html = RichText.to_html(text, owner)
      [token] = Regex.run(~r{/file/[^/]+/original/([^/?"]+)}, html, capture: :all_but_first)
      assert URLSigner.private_token?(token)

      refute RichText.to_html(text, nil) =~ "<img"
    end

    test "removing a picture of the description takes it out of the text", ctx do
      file = image!(ctx)
      other = image!(ctx, inline: false)

      {:ok, _} =
        Projects.update_assignment_form(ctx.a, %{
          "description" => "Before ![shot](pkfile:#{file.uuid}) after"
        })

      {:ok, view, _} =
        live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

      render_click(view, "remove_task_file", %{"uuid" => file.uuid})
      send(view.pid, :autosave)
      render(view)

      assert Projects.get_assignment(ctx.a.uuid).description == "Before  after"

      # a file of the task (not in the text) leaves the text as it is
      render_click(view, "remove_task_file", %{"uuid" => other.uuid})
      send(view.pid, :autosave)
      render(view)
      assert Projects.get_assignment(ctx.a.uuid).description == "Before  after"
    end

    test "an open view of the task hears of a file added or removed", ctx do
      PhoenixKitProjects.PubSub.subscribe(
        PhoenixKitProjects.PubSub.topic_project(ctx.project.uuid)
      )

      uuid = ctx.a.uuid

      file = image!(ctx, inline: false)
      assert_receive {:projects, :assignment_updated, %{uuid: ^uuid}}

      :ok = Attachments.remove_task_file(ctx.a, file.uuid, ctx.me)
      assert_receive {:projects, :assignment_updated, %{uuid: ^uuid}}
    end

    test "a picture pasted into a task not saved yet is answered with a word, not stored",
         ctx do
      {:ok, view, html} =
        live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/new")

      [id] =
        Regex.run(~r/data-description-editor="(assignment-description--[^"]+)"/, html,
          capture: :all_but_first
        )

      send(
        view.pid,
        {:leaf_paste_image,
         %{
           editor_id: id,
           data_url: "data:image/png;base64," <> Base.encode64(@png),
           name: "shot.png",
           mime: "image/png"
         }}
      )

      assert render(view) =~ "Save the task first to add images."
    end
  end
end
