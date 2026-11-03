defmodule PhoenixKitProjects.Web.DescriptionImages do
  @moduledoc """
  Pictures in a project's, sub-project's, template's or library task's
  description, as a task's description takes them (the boss, 2026-10-31:
  "can't add image to project or paste into description. Check
  consistency"): pasted into the editor, or chosen with the
  "Add an image" button, stored in the holder's folder
  (`Attachments.store_description_image/4`) and placed at the cursor by an
  address the person may open; the text keeps them by file (`InlineImages`).

  A LiveView calls `allow/2` in mount with a function answering
  `{holder, editor_id}` for the socket (`nil` while there is nowhere to keep
  a picture — a record not saved yet), routes `{:leaf_paste_image, …}` to
  `paste/3`, and draws `button/1` under the editor.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import Phoenix.LiveView,
    only: [allow_upload: 3, cancel_upload: 3, consume_uploaded_entry: 3, put_flash: 3]

  alias PhoenixKitProjects.{Activity, Attachments, InlineImages}
  alias PhoenixKitProjects.Web.Components.DescriptionEditor

  @upload :description_images

  @doc """
  Turns on the image button's upload; `target` answers `{holder, editor_id}`
  or nil, `allowed?` whether the socket may write the holder now — the
  right its own save needs, read from the live scope. A paste is a
  `handle_info` and an upload a progress callback, so neither passes the
  form's `WriteGate` hook: every picture asks `allowed?` before it is
  stored.
  """
  @spec allow(
          Phoenix.LiveView.Socket.t(),
          (Phoenix.LiveView.Socket.t() -> {struct(), String.t()} | nil),
          (Phoenix.LiveView.Socket.t() -> boolean())
        ) :: Phoenix.LiveView.Socket.t()
  def allow(socket, target, allowed?) when is_function(target, 1) and is_function(allowed?, 1) do
    socket
    |> Phoenix.Component.assign(:description_images_target, target)
    |> Phoenix.Component.assign(:description_images_allowed, allowed?)
    |> allow_upload(@upload,
      accept: ~w(image/*),
      max_entries: 5,
      max_file_size: Attachments.description_image_max_mb() * 1_048_576,
      auto_upload: true,
      progress: &progress/3
    )
  end

  @doc "A picture pasted into the editor: stored and placed, or refused with a word."
  @spec paste(Phoenix.LiveView.Socket.t(), String.t(), map()) :: Phoenix.LiveView.Socket.t()
  def paste(socket, editor_id, paste) do
    paste_for(socket, target(socket), editor_id, paste)
  end

  @doc "`paste/3` for a holder named by the caller (`{holder, editor_id}` or nil)."
  @spec paste_for(Phoenix.LiveView.Socket.t(), {struct(), String.t()} | nil, String.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def paste_for(socket, nil, _editor_id, _paste),
    do: put_flash(socket, :error, gettext("Save it first to add images."))

  def paste_for(socket, {holder, _id}, editor_id, paste) do
    if allowed?(socket),
      do: store_paste(socket, holder, editor_id, paste),
      else: refused(socket)
  end

  defp store_paste(socket, holder, editor_id, paste) do
    case Attachments.store_pasted_image(
           holder,
           paste[:data_url] || "",
           paste[:name],
           Activity.actor_uuid(socket)
         ) do
      {:ok, file} ->
        DescriptionEditor.insert_image(editor_id, url(socket, file), "")
        socket

      {:error, :not_an_image} ->
        put_flash(socket, :error, gettext("Only an image can be pasted here."))

      _ ->
        put_flash(socket, :error, gettext("Upload failed. Please try again."))
    end
  end

  @doc false
  def progress(@upload, %{done?: true} = entry, socket) do
    case target(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Save it first to add images."))}

      {holder, editor_id} ->
        if allowed?(socket),
          do: store_upload(socket, holder, editor_id, entry),
          else: {:noreply, socket |> cancel_upload(@upload, entry.ref) |> refused()}
    end
  end

  def progress(@upload, _entry, socket), do: {:noreply, socket}

  defp store_upload(socket, holder, editor_id, entry) do
    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok,
         Attachments.store_description_image(
           holder,
           path,
           [
             filename: entry.client_name,
             content_type: entry.client_type,
             size_bytes: entry.client_size
           ],
           Activity.actor_uuid(socket)
         )}
      end)

    case result do
      {:ok, file} ->
        DescriptionEditor.insert_image(
          editor_id,
          url(socket, file),
          to_string(file.original_file_name)
        )

        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Upload failed. Please try again."))}
    end
  end

  defp refused(socket),
    do: put_flash(socket, :error, gettext("You don't have permission to manage files here."))

  defp allowed?(socket) do
    case socket.assigns[:description_images_allowed] do
      fun when is_function(fun, 1) -> fun.(socket) == true
      _ -> false
    end
  rescue
    _ -> false
  end

  attr(:uploads, :map, required: true)

  @doc """
  The hidden file input behind the editor's own image button: the toolbar
  button sends `{:leaf_insert_request, …}`, the LiveView answers with
  `pick/1`, which opens this input's file chooser. One control for a
  picture in every description, the editor's (the boss, 2026-11-02 — a link
  under the field in some popups, a paperclip in the comments).
  """
  def file_input(assigns) do
    ~H"""
    <.live_file_input upload={@uploads.description_images} class="hidden" />
    """
  end

  @doc "Opens the file chooser of `file_input/1` (the editor's image button was pressed)."
  @spec pick(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def pick(%{assigns: %{uploads: %{description_images: upload}}} = socket),
    do: Phoenix.LiveView.push_event(socket, "pkp:pick-file", %{id: upload.ref})

  def pick(socket), do: socket

  defp target(socket) do
    case socket.assigns[:description_images_target] do
      fun when is_function(fun, 1) -> fun.(socket)
      _ -> nil
    end
  end

  defp url(socket, file),
    do: to_string(InlineImages.url(file, socket.assigns[:phoenix_kit_current_scope]))
end
