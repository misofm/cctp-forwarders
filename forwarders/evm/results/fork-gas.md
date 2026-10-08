# Fork gas

Gas per crank against Circle's real contracts on Avalanche and Polygon forks
at the blocks pinned in `script/Chains.sol`, burning to Sui (domain 8). Both
chains run the same Circle code, so the figures are identical. "Before" is
commit 65e2799 (a separate factory, implementation and clone, with events,
getters and guards); "after" is the single `Forwarder` contract here.

## Transaction gasUsed

Receipts of real transactions on an anvil fork of each chain at the pinned
block: the contract deployed through the keyless CREATE2 deployer, USDC minted
through FiatToken's `masterMinter`, each crank sent from a fresh account. This
includes intrinsic and calldata gas and the refunds of the consumed allowance
and the emptied balances (refunds are capped at a fifth of the gas used).
Reproduce with `results/tx-gas.sh <project-dir> new|baseline <chain>`, where
`baseline` takes a checkout of commit 65e2799's `forwarders/evm`.

| Crank                                  | Avalanche before → after | Polygon before → after |
| -------------------------------------- | ------------------------ | ---------------------- |
| Deploy + first forward (25 USDC)       | 178544 → 173354          | 178544 → 173354        |
| Later forward via `forward(recipient)` | 138951 → 135364          | 138951 → 135364        |
| Later forward direct, `forward()`      | 135149 → 133906          | 135149 → 133906        |

## Execution gas in the fork tests

`gasleft()` deltas around the call in `test/fork/Fork.t.sol` (run
`REQUIRE_FORK=1 forge test --match-path "test/fork/*" -vv`). They exclude
intrinsic gas and refunds, and state touched earlier in the same test is warm.

| Crank                                  | Avalanche before → after | Polygon before → after |
| -------------------------------------- | ------------------------ | ---------------------- |
| Deploy + first forward                 | 230997 → 224177          | 230994 → 224177        |
| Later forward via `forward(recipient)` | 181505 → 176669          | 181500 → 176669        |
| Later forward direct, `forward()`      | 174534 → 170225          | 174534 → 170225        |

Where the savings come from: the clone delegates to the contract the crank
transaction already called (no cold implementation account on the
`forward(recipient)` path), and there are no events, no `NotClone` code-size
check, no chain-id re-check, no return values and no separate `recipient()`
call. The best-effort Circle reads cost 665 gasUsed of that back (hard reads
would strand every address if Circle renamed a getter). Once a deposit address
has code, crank it directly: the `forward(recipient)` path recomputes the
address for 1458 gasUsed more.

Measured and not adopted: transaction gasUsed of the first crank on
Avalanche, each a one-line edit of `forward()` measured with `tx-gas.sh`
against the same contract with hard `localMinter()` and `burnLimitsPerMessage`
calls (172689):

| Variant                                         | Change | Why not                                                                                       |
| ----------------------------------------------- | ------ | --------------------------------------------------------------------------------------------- |
| Minimum-fee `staticcall` in assembly            | −245   | Not worth hand-written assembly.                                                              |
| No minimum-fee lookup                           | −1034  | Funds would wait forever under an on-chain Standard minimum fee.                              |
| No burn-limit clamp                             | +1883  | Costs more: the reverting fee lookup then cold-loads the messenger and rolls the warmth back. |
| Minter as a constant instead of `localMinter()` | +2591  | Same effect, and a changed `localMinter` would strand funds.                                  |
