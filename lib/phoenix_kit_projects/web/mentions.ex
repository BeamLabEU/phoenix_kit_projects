defmodule PhoenixKitProjects.Web.Mentions do
  @moduledoc """
  `use PhoenixKitProjects.Web.Mentions` in place of core's
  `use PhoenixKit.Mentions.Live`: the same `@`/`#` typeahead and
  request-access events, with one difference — picking a project or a task
  puts its short ref in the text (`#ACME-42`) instead of the long token.

  The field is one whose text is saved through a projects changeset, and
  `RefText.expand_on_write/2` turns the ref into the token there, so what
  is stored is what core's picker would have inserted. Every other result
  (a person, a client interaction) still arrives as its token: only these
  two types have a ref to show.
  """

  alias PhoenixKitProjects.RefText

  # Fully-qualified inside the quote: it expands in the caller's module.
  # credo:disable-for-this-file Credo.Check.Design.AliasUsage
  defmacro __using__(_opts) do
    quote do
      import PhoenixKit.Mentions.Live, only: [access_request_dialog: 1, mention_input: 1]

      @impl true
      def handle_event("pk_mention_search", params, socket) do
        {:reply, PhoenixKitProjects.Web.Mentions.search_reply(socket, params), socket}
      end

      @impl true
      def handle_event("pk_request_access", %{"type" => type, "uuid" => uuid}, socket) do
        {:noreply,
         Phoenix.Component.assign(socket, :pk_access_request, %{
           type: type,
           uuid: uuid,
           note: "",
           state: :open
         })}
      end

      def handle_event("pk_access_request_close", _params, socket) do
        {:noreply, Phoenix.Component.assign(socket, :pk_access_request, nil)}
      end

      def handle_event("pk_access_request_submit", params, socket) do
        {:noreply, PhoenixKit.Mentions.Live.submit(socket, params)}
      end
    end
  end

  @doc """
  Core's search reply, with the `token` of each project and task result
  replaced by its short ref — the client inserts `token` as text, whatever
  it is.
  """
  @spec search_reply(Phoenix.LiveView.Socket.t(), map()) :: map()
  def search_reply(socket, params) do
    reply = PhoenixKit.Mentions.Live.search_reply(socket, params)
    %{reply | results: shorten_results(reply.results)}
  end

  @doc false
  @spec shorten_results([map()]) :: [map()]
  def shorten_results(results), do: Enum.map(results, &shorten/1)

  defp shorten(%{kind: "resource", type: type, uuid: uuid} = result) do
    case RefText.short(type, uuid) do
      nil -> result
      ref -> %{result | token: ref}
    end
  end

  defp shorten(result), do: result
end
