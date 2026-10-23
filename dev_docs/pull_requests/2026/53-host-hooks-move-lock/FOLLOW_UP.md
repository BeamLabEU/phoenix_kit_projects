# Follow-up — 2026-10-23

| Finding | Resolution |
|---|---|
| Codex: registry reads miss the configured PostgreSQL prefix | All four readers now use the read-only `Schemas.ProjectKey` with `PhoenixKit.SchemaPrefix`. Existing trigger writes and key-retirement behavior are unchanged. |
| Claude: prefixed registry reads worth a future sweep | Resolved by the same fix. This is a supported-installation bug, not just a cosmetic inconsistency. |

The scratch-schema reproduction failed using the original `ba9b007` context:
lookup joined prefixed projects to the public registry and returned nil. The
same check passed with the current context for lookup, former keys, reserved
keys and suggestions. Both runs rolled their scratch schema back. The
regular registry tests and schema conformance check also pass.
