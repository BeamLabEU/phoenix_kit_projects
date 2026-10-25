defmodule PhoenixKitProjects.Actor do
  @moduledoc """
  Who is acting in this process: the user a change is attributed to when the
  code that reacts to it is not the code that knows the person.

  The hand-off rules (`PhoenixKitProjects.Handoffs`) run after ANY path's
  status write — a click, the API, the tick rules — and need to know whose
  click it was, to say "Kadri reopened…" and to leave Kadri out of her own
  notice. The LiveViews declare their viewer once per mount
  (`Web.Helpers.assign_embed_user/2`) and the API its key's accountable
  person (`Web.Api.Auth`), like `RefText`'s writer. A process that declared
  nobody (a job, a script) acts as nobody.
  """

  @key :phoenix_kit_projects_actor

  @doc "Declares the acting user for this process (`nil` for nobody)."
  @spec put(binary() | nil) :: :ok
  def put(uuid) when is_binary(uuid) or is_nil(uuid) do
    Process.put(@key, uuid)
    :ok
  end

  @doc "The acting user's uuid, or `nil`."
  @spec get() :: binary() | nil
  def get, do: Process.get(@key)
end
