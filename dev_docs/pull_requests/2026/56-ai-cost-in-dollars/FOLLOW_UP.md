# PR #56 follow-up (2026-10-24)

- Claude's **IMPROVEMENT - MEDIUM** (non-finite costs dropping valid
  tokens) was fixed in `ea2d788`. Codex independently reproduced the NaN
  failure against the preceding ledger and verified the fixed behavior.
- Codex's **NITPICK** (missing mixed-field precedence coverage) is
  addressed by supplying both dollar and legacy amounts, including zero.
- The recheck also adds real-request callback coverage and completes
  NaN/±Infinity coverage for Decimal and string inputs. Production code
  remains as fixed by Claude.

See [CODEX_REVIEW.md](CODEX_REVIEW.md) for scope, evidence and validation.
