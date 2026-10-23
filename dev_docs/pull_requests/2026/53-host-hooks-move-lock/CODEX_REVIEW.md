# Codex review — post-merge recheck (2026-10-23)

PR #53, merge `36e5ac8`; reviewed against `ba9b007` and this pass's fixes.

## BUG - MEDIUM — project-key registry reads ignored the schema prefix

Claude recorded this as a nitpick to revisit if a prefixed install uses
keys. It is a functional issue in an already-supported configuration:
`former_keys/1`, `key_taken?/1` and `suggest_project_key/1` queried the bare
registry table, and `project_by_key/1` joined that bare table to a prefixed
project schema. A host with its project tables outside `public` could read
the wrong registry or raise `undefined_table`; it could also suggest a key
already reserved in its own schema.

Fixed all four readers by introducing `Schemas.ProjectKey`, a read-only
mapping of the existing trigger-maintained registry that uses
`PhoenixKit.SchemaPrefix`. PostgreSQL still owns all writes, reservations
survive deletion, and no database migration is needed. The existing
schema-prefix conformance test now covers this table too. Added a functional
regression checking that all readers agree after renaming and deletion.

## Rechecked, unchanged

- The status-event buffer restores its outer state on exceptions, drops
  rolled-back changes, and hands nested changes to the outer lock.
- Status-only subscriber clauses avoid a second reload for each cascade row.
- The host move lock is checked again on writes, including the nest picker
  and detach path; direct low-level context tools remain policy-free by
  contract. Provider failures still fail open as documented.
- The documented outer-transaction caveat remains: a caller wrapping the
  lock in its own transaction can receive the event before that outer
  transaction commits. This pass does not redesign transaction ownership.

## Validation

See [PR #55's Codex review](../55-neutral-example-key/CODEX_REVIEW.md).
