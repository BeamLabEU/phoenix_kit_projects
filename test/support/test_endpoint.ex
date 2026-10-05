defmodule PhoenixKitProjects.Test.Endpoint do
  @moduledoc """
  Minimal Phoenix.Endpoint used by the LiveView test suite.

  `phoenix_kit_projects` is a library — in production it borrows the
  host app's endpoint and router. For tests we spin up a tiny
  endpoint + router (`PhoenixKitProjects.Test.Router`) so
  `Phoenix.LiveViewTest` can drive our LiveViews through `live/2`
  with real URLs.
  """

  use Phoenix.Endpoint, otp_app: :phoenix_kit_projects

  @session_options [
    store: :cookie,
    key: "_phoenix_kit_projects_test_key",
    signing_salt: "projects-test-salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # The API controllers read JSON bodies; a host endpoint parses them, this one must too.
  plug(Plug.Parsers, parsers: [:urlencoded, :multipart, :json], json_decoder: Jason)
  plug(Plug.Session, @session_options)
  plug(PhoenixKitProjects.Test.Router)
end
