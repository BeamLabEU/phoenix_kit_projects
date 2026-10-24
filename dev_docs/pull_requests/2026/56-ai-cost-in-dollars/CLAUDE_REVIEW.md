# Claude (Opus 5.5) review — PR #56, after the merge (2026-10-24)

PR #56 (`mdon/main`, merge `2d48e6b`, Max Don): the AI usage sink
(`Ledger.record_ai_request/1`, behind `handle_ai_usage/1`) reads
phoenix_kit_ai's new `cost` column — US dollars as a `Decimal`, or its string
in a JSON-encoded row — and turns it into the ledger's cents (× 100). An older
phoenix_kit_ai's `cost_cents` (millionths of a dollar) is still read. The cost
is rounded to the ledger's four decimals first, and a cost that rounds to
nothing is left out, so a sub-precision call no longer fails the `amount > 0`
check and rolls the tokens entry back with it. Three commits; the middle
`cost_nanodollars` step was superseded before release.

## Verified, no change needed

- **The emitter matches.** phoenix_kit_ai 0.26.0 (the locked version) has
  `field(:cost, :decimal)` on `%Request{}` and refuses a bare number for it
  (`cost: 5_000_000` is never $5M), and `dispatch_usage_sinks/1` hands the
  struct over; `field/2`'s `Map.get` reads it. A struct without `cost_cents`
  answers nil there, so the fallback only fires for an older package.
- **Precedence.** A present `cost` wins, even at zero, over `cost_cents` —
  right, since a new row never carries both meaningfully.
- **The rounding.** `Decimal.round/2` is half-up: $0.0000005 → 0.0001 cents
  is kept, $0.000000499 → 0 is dropped (both tested). The tokens entry is
  written either way, inside the same all-or-nothing transaction.
- **No stale wording.** No `nanodollar` left in `lib/`, `test/` or the guides.
- **A raising sink is contained** by phoenix_kit_ai's `dispatch_to_sinks/1`
  (rescue + catch), so request logging never breaks.

## IMPROVEMENT - MEDIUM — a non-finite cost lost the tokens entry (fixed)

`Decimal.parse/1` accepts `"NaN"`, `"Infinity"` and `"inf"`; a `%Decimal{}`
can carry them too. `ai_cost_cents/1` multiplied, then `Decimal.round/2` /
`Decimal.compare/2` raised `Decimal.Error` ("operation on NaN", "rounding
±Infinity") before any write, so the sink failed and the call's TOKENS went
unrecorded as well — the very loss the PR set out to prevent for tiny costs.
phoenix_kit_ai's changeset makes such a row unlikely, but the string path
exists precisely for rows that went through JSON, and the sink's contract is
"a bad cost costs only the cost entry".

**Fix:** `dollars/1` treats a NaN or infinite Decimal as no cost, and the
string clause routes its parse result through the same check. The "writes the
tokens only" test now also covers `"NaN"`, `"Infinity"`, `-Infinity` and a
negative cost.

## NITPICK — not changed

- **A float `cost` is dropped silently.** Consistent with phoenix_kit_ai's own
  rule that a bare number is never dollars; nothing in the pipeline produces
  one (Jason encodes a `Decimal` as a string).
- **An absurd exponent** (`"1e999999999"`) would make `Decimal.round/2`
  expand a huge coefficient. Internal data from a validated column; guarding
  it is not worth the code.
- The dollar-string test builds its own `fixture_project()` instead of the
  `describe`'s `%{project: project}` like its neighbours. Harmless.
