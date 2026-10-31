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

  import Phoenix.LiveView, only: [allow_upload: 3, consume_uploaded_entry: 3, put_flash: 3]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitProjects.{Activity, Attachments, InlineImages}
  alias PhoenixKitProjects.Web.Components.DescriptionEditor

  @upload :description_images

  @doc "Turns on the image button's upload; `target` answers `{holder, editor_id}` or nil."
  @spec allow(Phoenix.LiveView.Socket.t(), (Phoenix.LiveView.Socket.t() ->
                                              {struct(), String.t()} | nil)) ::
          Phoenix.LiveView.Socket.t()
  def allow(socket, target) when is_function(target, 1) do
    socket
    |> Phoenix.Component.assign(:description_images_target, target)
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
  def paste_for(socket, target, editor_id, paste) do
    case target do
      {holder, _id} ->
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

      nil ->
        put_flash(socket, :error, gettext("Save it first to add images."))
    end
  end

  @doc false
  def progress(@upload, entry, socket) do
    if entry.done? do
      case target(socket) do
        {holder, editor_id} ->
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

        nil ->
          {:noreply, put_flash(socket, :error, gettext("Save it first to add images."))}
      end
    else
      {:noreply, socket}
    end
  end

  attr(:uploads, :map, required: true)
  attr(:id, :string, required: true)

  @doc "The \"Add an image to the description\" button and its hidden file input."
  def button(assigns) do
    ~H"""
    <label
      for={@uploads.description_images.ref}
      id={@id}
      class="btn btn-ghost btn-xs self-start gap-1 font-normal text-base-content/70"
    >
      <.icon name="hero-photo" class="w-3.5 h-3.5" /> {gettext("Add an image to the description")}
    </label>
    <.live_file_input upload={@uploads.description_images} class="hidden" />
    """
  end

  defp target(socket) do
    case socket.assigns[:description_images_target] do
      fun when is_function(fun, 1) -> fun.(socket)
      _ -> nil
    end
  end

  defp url(socket, file),
    do: to_string(InlineImages.url(file, socket.assigns[:phoenix_kit_current_scope]))
end
