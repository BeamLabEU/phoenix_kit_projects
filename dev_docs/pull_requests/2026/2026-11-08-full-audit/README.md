# Full audit of the module — 2026-11-08

**Not a PR folder.** A whole-module audit asked for on 2026-11-08 ("check every
corner and every part … core components and style, translations, error
messages, tests"), run against `main` at `17f47c5` (0.33.1). The fixes it led to
were made on `main` directly.

## How it was done

- **Gate first.** `mix precommit` (format, `compile --force --warnings-as-errors`,
  `deps.unlock --check-unused`, `hex.audit`, `credo --strict`, dialyzer), the
  `WITHOUT_STAFF=1` compile gate, `mix hex.build --unpack` (218 files, 3.7 MB,
  no `priv/media`), `mix hex.outdated`, and the full suite on a scratch database
  (`PGDATABASE=pkp_audit_20261108`): **2803 tests, 0 failures, none excluded.**
- **Ten reviewers in parallel**, each on one slice, read-only, every finding
  checked against the code: the project page and its drawer; the task form and
  its parts; the project/template/library forms and settings pages; the list,
  Hours, Time and API-key pages; the project's chrome tabs, the portal and the
  widgets; the main context, outline, schemas and migration chain; the
  secondary contexts; authorization, the JSON API, the portal and file access;
  translations (catalogue health, code vs catalogue, raw English, quality in
  all seven languages); the test suite.
- Their findings, merged and de-duplicated, are in
  [`CLAUDE_REVIEW.md`](CLAUDE_REVIEW.md); what was done about each is in
  [`FOLLOW_UP.md`](FOLLOW_UP.md).

## Result

- Gate green before and after: `mix precommit` clean, credo `--strict` no
  issues, dialyzer passes (one new, scoped false-positive ignore).
- The suite after the fixes: **2828 tests, 0 failures, none excluded**, against
  the updated lock (`FOLLOW_UP.md` → "Verification").
- Dependencies: the lock moves to `phoenix_kit` 3.4.0, `phoenix_kit_ai` 0.29.1,
  `phoenix_kit_staff` 0.11.2 (and `leaf` 0.10.1 with them) — all inside the
  existing requirements, so no requirement in `mix.exs` changed.
