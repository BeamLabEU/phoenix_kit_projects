defmodule PhoenixKitProjects.Web.Api.PeopleController do
  @moduledoc """
  `GET /people`: who a task can be for - the staff people, teams and
  departments the task form offers, by uuid and name (no email, no other
  detail), so a key can assign a task to a colleague it was told about by
  name. `q` narrows by name. The list is the site's (who a task may be
  for is not limited to one project); `people:read` is checked on the
  project the call names (`project`, else the key's home).
  """
  use Phoenix.Controller, formats: [:json]

  alias PhoenixKitProjects.People
  alias PhoenixKitProjects.Web.Api.{Assignee, Json}

  @limit 100

  def index(conn, params) do
    with {:ok, conn} <- Json.scope_project(conn, params),
         {:ok, conn} <- Json.require_scope(conn, "people:read"),
         {:ok, conn} <- Json.require_feature(conn, :assignees),
         {:ok, conn} <- Json.require_action(conn, :view) do
      q = params["q"] |> to_string() |> String.trim() |> String.downcase()
      me = Assignee.person_uuid(conn.assigns.pk_api_key)

      people =
        People.list_people()
        |> Enum.map(&%{uuid: &1.uuid, name: Assignee.person_name(&1), me: &1.uuid == me})
        |> matching(q)

      json(conn, %{
        people: Enum.take(people, @limit),
        truncated: length(people) > @limit,
        teams: People.list_teams() |> Enum.map(&%{uuid: &1.uuid, name: &1.name}) |> matching(q),
        departments:
          People.list_departments() |> Enum.map(&%{uuid: &1.uuid, name: &1.name}) |> matching(q)
      })
    else
      {:halt, conn} -> conn
    end
  end

  defp matching(rows, ""), do: rows

  defp matching(rows, q),
    do: Enum.filter(rows, &String.contains?(String.downcase(to_string(&1.name)), q))
end
