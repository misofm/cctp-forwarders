# Fork gas

Gas per crank against Circle's real contracts on Avalanche and Polygon forks
at the blocks pinned in `script/Chains.sol`, burning to Sui (domain 8). Both
chains run the same Circle code, so the figures are identical. "Before" is
commit 42fef39 (chain-bound instance with `(usdc, messenger, chainId)`
arguments, `cancun` target); "after" is the argument-free instance here,
compiled for `cancun`.

## Transaction gasUsed

Receipts of real transactions on an anvil fork of each chain at the pinned
block: the contract deployed through the keyless CREATE2 deployer, USDC minted
through FiatToken's `masterMinter`, each crank sent from a fresh account. This
includes intrinsic and calldata gas and the refunds of the consumed allowance
and the emptied balances (refunds are capped at a fifth of the gas used).
Reproduce with `results/tx-gas.sh <project-dir> new|baseline <chain>`, where
`baseline` takes a checkout of commit 42fef39's `forwarders/evm`.

| Crank                                  | Avalanche before → after | Polygon before → after |
| -------------------------------------- | ------------------------ | ---------------------- |
| Deploy + first forward (25 USDC)       | 173354 → 173344          | 173354 → 173344        |
| Later forward via `forward(recipient)` | 135364 → 135355          | 135364 → 135355        |
| Later forward direct, `forward()`      | 133906 → 133896          | 133906 → 133896        |

The constant messenger saves 10 gas per crank. A `paris` build, which
replaces `PUSH0` with `PUSH1 0`, measured 343 to 353 more per crank.
The constructor's Circle checks run once, at
deployment.

## Execution gas in the fork tests

`gasleft()` deltas around the call in `test/fork/Fork.t.sol` (run
`REQUIRE_FORK=1 forge test --match-path "test/fork/*" -vv`). They exclude
intrinsic gas and refunds, and state touched earlier in the same test is warm.

| Crank                                  | Avalanche before → after | Polygon before → after |
| -------------------------------------- | ------------------------ | ---------------------- |
| Deploy + first forward                 | 224177 → 224165          | 224177 → 224165        |
| Later forward via `forward(recipient)` | 176669 → 176657          | 176669 → 176657        |
| Later forward direct, `forward()`      | 170225 → 170213          | 170225 → 170213        |

Against the earlier separate factory, implementation and clone (commit
65e2799, measured on the chain-bound build): the clone delegates to the contract the crank
transaction already called (no cold implementation account on the
`forward(recipient)` path), and there are no events, no `NotClone` code-size
check, no chain-id re-check, no return values and no separate `recipient()`
call. The best-effort Circle reads cost 665 gasUsed of that back (hard reads
would strand every address if Circle renamed a getter). Once a deposit address
has code, crank it directly: the `forward(recipient)` path recomputes the
address for 1469 gasUsed more (table above).

Measured and not adopted, on the chain-bound build: transaction gasUsed of
the first crank on Avalanche, each a one-line edit of `forward()` measured with `tx-gas.sh`
against the same contract with hard `localMinter()` and `burnLimitsPerMessage`
calls (172689):

| Variant                                         | Change | Why not                                                                                       |
| ----------------------------------------------- | ------ | --------------------------------------------------------------------------------------------- |
| Minimum-fee `staticcall` in assembly            | −245   | Not worth hand-written assembly.                                                              |
| No minimum-fee lookup                           | −1034  | Funds would wait forever under an on-chain Standard minimum fee.                              |
| No burn-limit clamp                             | +1883  | Costs more: the reverting fee lookup then cold-loads the messenger and rolls the warmth back. |
| Minter as a constant instead of `localMinter()` | +2591  | Same effect, and a changed `localMinter` would strand funds.                                  |
