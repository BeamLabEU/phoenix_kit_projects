defmodule PhoenixKitProjects.Test.SchemaMigration do
  @moduledoc """
  Test-boot wrapper around the module-owned migration chain.

  `test_helper.exs` runs this through `Ecto.Migrator` keyed on
  `PhoenixKitProjects.Migrations.Schema.current_version()`, so a chain bump
  re-applies automatically (see the comment there for the staleness trap
  this shape avoids). Mirrors the migration file `mix phoenix_kit.update`
  generates in a host app.
  """

  use Ecto.Migration

  alias PhoenixKitProjects.Migrations.Schema

  def up, do: Schema.up(prefix: "public")
  def down, do: Schema.down(prefix: "public")
end
