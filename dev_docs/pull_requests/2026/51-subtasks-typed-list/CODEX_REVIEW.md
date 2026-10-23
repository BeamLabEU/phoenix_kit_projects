# Codex review — post-merge recheck (2026-10-23)

PR #51, merge `ddd9b08`; reviewed against `ba9b007` and the fixes in this
pass. This is a targeted recheck of the outline and its interaction with
PR #53, rather than a claim to have audited every line of this large PR.

## Rechecked

- The typed-list delete orders detaching retained children before deleting
  their former parents, preventing the FK cascade from deleting kept lines.
  Protected and held children keep their removed parent from being purged.
- Form params cannot cast `parent_uuid`; moves use the project lock and
  validate the parent. Reconciliation settles the resulting tree under that
  lock. The API delete includes held descendants in its policy checks.
- A shared library task can be renamed from the project. This is intentional:
  `AssignmentFormLive` explicitly documents that this changes every project
  using it. The API's refusal to rename a library task is a separate contract.
- Existing completion and PubSub tests exercise the hierarchy after Claude's
  fixes. No additional functional defect confirmed in this targeted pass.

## Fixed

**NITPICK — displaced fixture documentation.** The `fixture_project/1` doc
sat above `admin_projects/0`'s doc, causing a duplicate `@doc` warning and
leaving the fixture undocumented. Moved it to its function.

The live migration overview also still said V22; it now says V25, matching
the current chain. No migration or stored data changed.

## Validation

See the final validation record in [PR #55's Codex review](../55-neutral-example-key/CODEX_REVIEW.md).
