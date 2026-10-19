defmodule PhoenixKitProjects.Test.Access do
  @moduledoc """
  Gives a test user real permissions, through a role, for code that reads
  them from the database rather than from a scope — a personal API key
  works only while its person holds `projects` (`ApiKeys.resolve/2`).

  The superadmin key, not "projects": module keys are validated against the
  registered set, and the projects module is not registered in the test
  environment (see `LiveCase.embed_user_uuid!/0`). The API's check honours
  "*" as core does.
  """

  alias PhoenixKit.Users.{Permissions, Roles}

  @doc "Grants `user` everything (a role holding \"*\"); returns the user."
  def grant_projects!(%{uuid: _} = user) do
    n = System.unique_integer([:positive])

    {:ok, role} =
      Roles.create_role(%{"name" => "ProjectsAccess-#{n}", "description" => "test access"})

    {:ok, _} = Permissions.grant_permission(role.uuid, Permissions.superadmin_key())
    {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  @doc "Takes every role away from `user`."
  def revoke_all!(%{uuid: _} = user) do
    for name <- Roles.get_user_roles(user), do: Roles.remove_role(user, name)
    user
  end
end
