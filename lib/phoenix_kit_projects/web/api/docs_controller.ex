defmodule PhoenixKitProjects.Web.Api.DocsController do
  @moduledoc "Serves `llms.txt` and `openapi.json` for the API, without a key."

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  alias PhoenixKitProjects.Web.Api.Docs

  def llms_txt(conn, _params) do
    conn
    |> put_resp_content_type("text/markdown")
    |> send_resp(200, Docs.llms_txt())
  end

  def openapi(conn, _params), do: json(conn, Docs.openapi())
end
