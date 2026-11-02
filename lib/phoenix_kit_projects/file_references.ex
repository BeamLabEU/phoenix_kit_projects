defmodule PhoenixKitProjects.FileReferences do
  @moduledoc """
  The places in this module's tables that point at a stored file, for the
  orphan-file check of core's storage (`PhoenixKit.Module.file_references/0`).

  A file one of these rows names is in use and must never be read as an orphan:
  core would queue it for `DeleteOrphanedFileJob`. Each pair is a table and the
  condition "this table does not reference the file"; core leaves the pair out
  when the table does not exist.

  Moved here verbatim from core's `PhoenixKit.Modules.Storage`, which keeps its
  own copy for module versions that predate the callback. A table of this
  module that holds a file reference belongs in this list: while this module
  supplies one, core's copy of its tables steps aside.
  """

  import Ecto.Query, only: [dynamic: 2]

  @spec pairs() :: [{String.t(), Ecto.Query.dynamic_expr()}]
  def pairs do
    [
      # A task's files (V27): a file one holds is the task's, however else
      # it is filed.
      {"phoenix_kit_project_assignment_files",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_project_assignment_files af WHERE af.file_uuid = ?)",
           f.uuid
         )
       )},
      # Portal submissions hold their attachments in a JSONB array rather
      # than an FK column, so the reference is invisible to a plain join —
      # which would make every PUBLISHED issue image look like an orphan
      # and hand it to the delete job. `?` is the file uuid as text; the
      # `jsonb` cast is what lets `?` match an element of the array.
      {"phoenix_kit_project_portal_submissions",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_project_portal_submissions ps WHERE ps.file_uuids @> to_jsonb(ARRAY[?::text]))",
           f.uuid
         )
       )}
    ]
  end
end
