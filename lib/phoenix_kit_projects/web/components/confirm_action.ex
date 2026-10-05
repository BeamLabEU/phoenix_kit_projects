defmodule PhoenixKitProjects.Web.Components.ConfirmAction do
  @moduledoc """
  A destructive action that asks first, through core's `confirm_modal/1`
  instead of the browser's `data-confirm` dialog — the shape the catalogue
  uses for its deletes (boss, 2026-10-05: "use the core's confirm modal").

  Three parts, so a page adds one assign-free modal and three short event
  clauses and keeps its existing handlers untouched:

    * In the template, the button that used to carry `data-confirm` takes
      `{ask("delete", title: …, message: …, confirm: …, uuid: p.uuid)}`
      instead of its `phx-click` / `phx-value-*` / `data-confirm`. It then
      pushes `request_confirm` with the action's event name, the words
      for the dialog and every other value as the action's own params.
    * Once per page, `<.confirm_action_modal confirm={assigns[:confirm_action]} />`
      draws the pending question (nothing when there is none).
    * The page answers the three events and dispatches the confirmed one
      to its own `handle_event/3`:

          @confirmable ~w(delete)

          def handle_event("request_confirm", params, socket),
            do: {:noreply, ConfirmAction.request(socket, params, @confirmable)}

          def handle_event("confirm_action_cancel", _params, socket),
            do: {:noreply, ConfirmAction.clear(socket)}

          def handle_event("confirm_action_ok", _params, socket) do
            case ConfirmAction.take(socket) do
              {nil, socket} -> {:noreply, socket}
              {%{event: event, params: params}, socket} -> handle_event(event, params, socket)
            end
          end

  `@confirmable` is the page's own whitelist: a crafted `request_confirm`
  naming any other event is ignored, so the modal can never be a way to
  reach a handler the page did not mean to put behind it. The confirmed
  event runs with the params the button carried (`uuid`, `user`,
  `decision`, …), exactly as the direct click used to.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]

  @control_keys ~w(event title message confirm)

  @typedoc "The pending question, as `request/3` stores it in `:confirm_action`."
  @type pending :: %{
          event: String.t(),
          params: map(),
          title: String.t() | nil,
          message: String.t() | nil,
          confirm: String.t() | nil
        }

  @doc """
  The attributes of a button that must ask first. `event` is the page's own
  event to run on confirmation; `opts` carry `:title`, `:message` and
  `:confirm` (the confirm button's label) for the dialog, and every other
  key becomes a `phx-value-*` the confirmed event receives as a param.
  """
  @spec ask(String.t(), keyword()) :: map()
  def ask(event, opts) when is_binary(event) and is_list(opts) do
    {words, values} = Keyword.split(opts, [:title, :message, :confirm])

    base = %{"phx-click" => "request_confirm", "phx-value-event" => event}

    words
    |> Enum.reduce(base, fn {k, v}, acc -> Map.put(acc, "phx-value-#{k}", v) end)
    |> then(&Enum.reduce(values, &1, fn {k, v}, acc -> Map.put(acc, "phx-value-#{k}", v) end))
  end

  @doc """
  Stores the question a `request_confirm` push carries, if its event is one
  of `allowed`; anything else leaves the socket alone.
  """
  @spec request(Phoenix.LiveView.Socket.t(), map(), [String.t()]) :: Phoenix.LiveView.Socket.t()
  def request(socket, %{"event" => event} = params, allowed) when is_binary(event) do
    if event in allowed do
      pending = %{
        event: event,
        params: Map.drop(params, @control_keys),
        title: string_or_nil(params["title"]),
        message: string_or_nil(params["message"]),
        confirm: string_or_nil(params["confirm"])
      }

      Phoenix.Component.assign(socket, :confirm_action, pending)
    else
      socket
    end
  end

  def request(socket, _params, _allowed), do: socket

  @doc "Drops the pending question (Cancel, Esc, the backdrop)."
  @spec clear(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear(socket), do: Phoenix.Component.assign(socket, :confirm_action, nil)

  @doc "The pending question and the socket without it."
  @spec take(Phoenix.LiveView.Socket.t()) :: {pending() | nil, Phoenix.LiveView.Socket.t()}
  def take(socket), do: {socket.assigns[:confirm_action], clear(socket)}

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil

  attr(:confirm, :map, default: nil, doc: "The pending question (`request/3`), or nil.")

  @doc "Core's confirm modal for the pending question; nothing when there is none."
  def confirm_action_modal(assigns) do
    ~H"""
    <.confirm_modal
      :if={@confirm}
      show={true}
      on_confirm="confirm_action_ok"
      on_cancel="confirm_action_cancel"
      title={@confirm.title || gettext("Are you sure?")}
      title_icon="hero-exclamation-triangle"
      title_icon_class="w-5 h-5 text-error"
      messages={if @confirm.message, do: [{:warning, @confirm.message}], else: []}
      confirm_text={@confirm.confirm || gettext("Confirm")}
      danger={true}
    />
    """
  end
end
