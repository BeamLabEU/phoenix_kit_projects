defmodule PhoenixKitProjects.Web.Components.TaskFiles do
  @moduledoc """
  The files a task holds (`PhoenixKitProjects.Attachments.list_task_files/2`,
  V27): images as thumbnails, everything else as a row with its icon, each
  opening in a new tab. With `remove_event` each carries a × sending it
  with `uuid` (the task's edit popup); without, it only shows them (the
  task's view).

      <.task_files
        id="task-files"
        files={Attachments.list_task_files(a.uuid)}
        urls={Attachments.download_urls(Enum.map(files, & &1.file))}
      />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitProjects.Attachments
  alias PhoenixKitProjects.Web.Components.ConfirmAction

  attr(:id, :string, required: true)
  attr(:files, :list, required: true, doc: "`[%{file: %File{}, inline: boolean}]`")
  attr(:urls, :map, default: %{}, doc: "`%{file_uuid => url}` (`Attachments.download_urls/1`)")
  attr(:remove_event, :string, default: nil)
  attr(:empty_text, :string, default: nil)

  def task_files(assigns) do
    {images, others} = Enum.split_with(assigns.files, &image?(&1.file))
    assigns = assign(assigns, images: images, others: others)

    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <p :if={@files == [] and @empty_text} class="text-sm text-base-content/50">{@empty_text}</p>
      <div :if={@images != []} class="flex flex-wrap gap-2">
        <div :for={%{file: f} <- @images} id={"#{@id}-#{f.uuid}"} class="relative group">
          <a
            href={@urls[f.uuid]}
            target="_blank"
            rel="noopener"
            class="block"
            title={f.original_file_name}
          >
            <img
              :if={@urls[f.uuid]}
              src={@urls[f.uuid]}
              alt={f.original_file_name || ""}
              loading="lazy"
              class="h-20 w-20 rounded-box border border-base-300 object-cover"
            />
            <span
              :if={is_nil(@urls[f.uuid])}
              class="flex h-20 w-20 items-center justify-center rounded-box border border-base-300 bg-base-200"
            >
              <.icon name="hero-photo" class="w-6 h-6 opacity-50" />
            </span>
          </a>
          <button
            :if={@remove_event}
            type="button"
            {ConfirmAction.ask(@remove_event,
              uuid: f.uuid,
              title: gettext("Remove this file from the task?"),
              confirm: gettext("Remove")
            )}
            class="btn btn-xs btn-circle absolute -top-2 -right-2 opacity-80 hover:opacity-100"
            aria-label={gettext("Remove file")}
          >
            <.icon name="hero-x-mark" class="w-3 h-3" />
          </button>
        </div>
      </div>
      <ul :if={@others != []} class="flex flex-col divide-y divide-base-200 rounded-box border border-base-200">
        <li :for={%{file: f} <- @others} id={"#{@id}-#{f.uuid}"} class="flex items-center gap-2 px-2.5 py-1.5 text-sm">
          <.icon name={Attachments.file_icon(f)} class="w-5 h-5 opacity-60 shrink-0" />
          <a
            :if={@urls[f.uuid]}
            href={@urls[f.uuid]}
            target="_blank"
            rel="noopener"
            class="link link-hover truncate flex-1"
          >
            {f.original_file_name || f.file_name}
          </a>
          <span :if={is_nil(@urls[f.uuid])} class="truncate flex-1">{f.original_file_name || f.file_name}</span>
          <button
            :if={@remove_event}
            type="button"
            {ConfirmAction.ask(@remove_event,
              uuid: f.uuid,
              title: gettext("Remove this file from the task?"),
              confirm: gettext("Remove")
            )}
            class="btn btn-ghost btn-xs btn-circle"
            aria-label={gettext("Remove file")}
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp image?(%{mime_type: "image/" <> _}), do: true
  defp image?(%{file_type: "image"}), do: true
  defp image?(_), do: false
end
