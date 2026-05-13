defmodule PhoenixKitProjects.Errors do
  @moduledoc """
  Atom → translated-string dispatcher for Projects context errors.

  Context functions return `{:error, atom}` (or `{:error, %Ecto.Changeset{}}`
  for changeset errors); LiveViews call `Errors.message/1` at the
  presentation boundary to translate the atom into a flash-ready
  user-facing string.

  Keeping the dispatcher here means:

  1. Translation files only need to know about the literal strings
     in this module — the gettext extractor sees the literals at the
     `gettext(...)` call site of each branch.
  2. Context functions stay storage-agnostic (no `gettext` calls in
     `lib/phoenix_kit_projects/projects.ex`); LiveViews are the one
     place that turns intent into copy.
  3. Future changes to wording happen in one place; new error
     conditions get a new atom + a new branch here.
  """

  use Gettext, backend: PhoenixKitProjects.Gettext

  @typedoc """
  Atoms that the Projects context returns inside `{:error, atom}` tuples.
  Adding a new atom requires adding a `message/1` branch below — the
  generic-fallback then never fires for known shapes.
  """
  @type error_atom ::
          :not_found
          | :template_not_found
          | :task_not_found

  @doc """
  Translates a Projects error atom into a user-facing message.

  Defaults to a generic fallback for unknown atoms so callers always
  get a renderable string (no raised pattern-match) — but a fallback
  that fires in production is a sign that a context fn returned an
  atom this module doesn't know about, and should be added here.
  """
  @spec message(error_atom() | atom()) :: String.t()
  def message(:not_found), do: gettext("Record not found.")

  def message(:template_not_found),
    do: gettext("Template not found — it may have been deleted.")

  def message(:task_not_found),
    do: gettext("Task not found — it may have been deleted.")

  def message(_other), do: gettext("Something went wrong. Please try again.")
end
