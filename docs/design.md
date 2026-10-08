# Design and launch

Status: **tested locally and on Avalanche C-Chain and Polygon PoS mainnet
forks. Nothing is deployed, no funded transaction has been made, and no burn
from a forwarder has been attested or minted.**

## Goal

Onramp providers that cannot pay USDC on Sui pay a per-user deposit address on
Avalanche or Polygon instead. Anyone may crank that address; it burns the USDC
through Circle CCTP V2 Standard Transfer to one fixed Sui address. There is no
owner, operator key, upgrade path or Miso fee; the only parties are the source
chain, Circle (burn, attestation, mint) and Sui.

## Hard requirements

1. One deterministic deposit address per (chain, Sui recipient), derivable
   on-chain (`addressOf`) and in TypeScript (`forwarderAddress`), with parity
   tests.
2. Keyless: no owner, admin, upgrade, storage or initializer. Funds at a
   deposit address leave only through a Circle burn whose `mintRecipient` is
   the committed Sui recipient and whose destination domain is 8 (Sui).
3. Permissionless crank; the caller chooses nothing that affects the outcome.
4. Standard transfers only (`minFinalityThreshold` 2000); `maxFee` is never
   above 1% of the burned amount.
5. Chain-bound: an address holds forwarder code only on its own chain, and the
   same recipient has different addresses on different chains.
6. Each deposit address is its own depositor (`DepositForBurn` depositor and
   the burn message body's `messageSender`).
7. Avalanche and Polygon; a TypeScript address helper; a Sui mint module.

## Contract

One contract, `forwarders/evm/src/Forwarder.sol`, deployed once per chain
through the keyless CREATE2 deployer with salt 0 and constructor arguments
`(usdc, tokenMessengerV2, chainId)`. The constructor reverts unless `chainId`
is the current chain. This instance is both the factory and the logic every
deposit address runs:

- `addressOf(recipient)` predicts a deposit address.
- `forward(recipient)` deploys the recipient's deposit address if it has no
  code yet, then calls `forward()` on it.
- `forward()`, on a deposit address, burns its USDC.

A deposit address is a 77-byte Solady `LibClone` clone (ERC-1167 with
immutable args, Solady pinned in `forwarders/evm/README.md`) that
`DELEGATECALL`s the instance and carries the 32-byte Sui recipient after its
45 bytes of proxy code:

```
instance = keccak256(0xff ‖ keylessDeployer ‖ 0 ‖ keccak256(creationCode ‖ abi.encode(usdc, messenger, chainId)))[12:]
runtime  = 363d3d373d3d3d363d73 ‖ instance ‖ 5af43d82803e903d91602b57fd5bf3 ‖ recipient   (77 bytes)
initCode = 61004d3d81600a3d39f3 ‖ runtime                                                  (87 bytes)
address  = keccak256(0xff ‖ instance ‖ recipient ‖ keccak256(initCode))[12:]
```

`forward()` runs in the clone's context, so the clone holds, approves and
burns the USDC and is Circle's depositor and `messageSender`. It reads the
recipient from the executing account's own code (`EXTCODECOPY` at offset 45),
never from calldata or storage, and does not read `msg.sender` or `tx.origin`:

1. `amount = min(balance, minter.burnLimitsPerMessage(usdc))`, with the
   minter read from `messenger.localMinter()` on every crank.
2. `maxFee = messenger.getMinFeeAmount(amount)`.

   All three Circle reads are best-effort `staticcall`s: a revert or fewer
   than 32 bytes of returndata means no limit and no minimum (`maxFee` 0).
   Circle's `depositForBurn` enforces its limit and minimum fee
   independently, so a lower value can only make the burn revert, and a
   higher `maxFee` is bounded by the ceiling.

3. Revert `FeeAboveCeiling` if `maxFee > amount / 100`.
4. `approve(messenger, amount)`, then `depositForBurn(amount, 8, recipient,
usdc, destinationCaller 0, maxFee, 2000)`. Circle consumes the allowance.

Every revert, including Circle's, leaves the USDC in place and rolls back a
first-time deployment. The 2000 threshold, domain 8 and the 1% ceiling are
constants in the code; USDC and the messenger are immutables. The instance's
address commits to its code and arguments, so code at the pinned address is
the reviewed build with the reviewed arguments, and so is every clone (its
init code embeds the instance). `src/evm-forwarder.ts` pins both chains'
instance addresses; its test re-derives them from the Solidity-generated
`forwarders/evm/fixtures/address-vectors.json`, and a forge test fails if that
fixture is stale.

Standard only: Circle documents Standard attestation from Avalanche and
Polygon PoS at seconds and offers no Fast Transfer from either, so one
threshold and one address per recipient per chain suffice.

## Safety argument

**Recipient and policy.** The recipient is part of the clone's code and
address; the threshold, domain and ceiling are part of the instance's code and
address. `forward()` has no arguments. A caller controls only the moment, the
gas, the entry point and its own `tx.origin`, and can add USDC; none of these
changes where the USDC goes or the policy. Too little gas reverts the whole
transaction. Each Circle read receives 63/64 of the remaining gas, so starving
one would leave under 1/64 for `depositForBurn`, which needs over 100k; and a
starved read only drops the clamp (Circle then refuses an over-limit amount)
or the minimum (Circle refuses a `maxFee` below it).

**Other ways out.** A deposit address has no function that transfers or
approves USDC except the exact approval consumed by the burn. FiatToken's
`permit` and `transferWithAuthorization` accept contract signers through
ERC-1271, but a clone has no `isValidSignature` (the call reverts), and nobody
holds a key for a deposit address.

**Circle changes.** A pause, a zero burn limit, a minimum fee above 1%, a USDC
blacklist or Circle denylist entry, or a removed Sui route reverts the crank
and the USDC waits; the same crank succeeds once Circle lifts the condition. A
lowered per-message limit is drained over several cranks. A minimum fee up to
1% is paid. If Circle changes `localMinter`, the next crank reads the new one;
if Circle renames or drops `localMinter`, `burnLimitsPerMessage` or
`getMinFeeAmount`, the crank proceeds without that read. Circle's denylist also checks `tx.origin`, so a denylisted
cranker blocks only their own transaction.

**Timing.** Anyone may crank at any time, including right after each small
deposit. That only splits a balance into more burns, each still to the same
recipient, and costs the cranker gas; mint workers keep a minimum amount and do
not subsidize arbitrary addresses. A cranker can pick the moment Circle's
minimum fee is highest, which is bounded by the 1% ceiling.

**Front-running.** The instance's deployment is keyless and its address commits
to its code, so whoever deploys it first deploys the same thing. Any clone
deployment produces the same 77 bytes at the same address; there is no
initializer to race.

**Delegatecall and EIP-7702.** The clone's target is a constant in its code.
The instance has no storage, `selfdestruct`, `delegatecall` or owner. Any
other account that runs `forward()` through `DELEGATECALL` or an EIP-7702
delegation reads its own code at offset 45: an EIP-7702 account's code is the
23-byte delegation designator, so its recipient reads as zero and Circle
refuses the burn (`Mint recipient must be nonzero`, fork-tested for delegation
to the instance and to a clone). A contract that chooses to delegatecall
`forward()` acts only on its own balance. `forward(recipient)` run inside a
clone creates nested clones in the clone's own CREATE2 space, and `addressOf`
called on a clone predicts such a nested address; they are not deposit
addresses and act only on their own balances. Deposit addresses are derived
only from the pinned instance or the TypeScript helper.

**Returndata, approvals, reentrancy.** The only external values the contract
uses are USDC's balance and Circle's limit, minter and minimum fee, all from
contracts the burn already trusts. The approval equals the burned amount and is
consumed by Circle's `transferFrom`; nothing grants a standing allowance.
There is no state to re-enter.

**Chain binding and splits.** The instance's creation code embeds the chain id
and its constructor refuses any other chain, so the instance and every clone
have chain-specific addresses and code exists at them only on that chain. If
the chain splits, both sides already hold the instance and every deployed
clone; whichever side Circle attests keeps working, including new clones on a
side that changes its chain id.

**Unrecoverable by design (no recovery path).** Tokens other than native USDC
(including bridged USDC.e), native AVAX or POL, USDC sent on the wrong chain,
USDC sent to a zero-recipient address, and USDC that Circle refuses forever
(permanent denylist or blacklist, route removed or V2 retired, minimum fee held
above 1%, dust below 100 units under a non-zero minimum fee, or an on-chain
minimum enforced while `getMinFeeAmount` is renamed or removed, since the
forwarder then authorizes no fee). USDC sent to the instance itself can be
burned by anyone to the Sui address formed by bytes 45–77 of the instance's
code, which nobody controls; it is lost either way, and that burn's depositor
is the instance, not a forwarder.

## Negotiable features

Kept:

- **Minimum-fee raise.** Without it, an on-chain Standard minimum fee would
  revert every crank until Circle removes it, and with no recovery path funds
  could wait forever. It costs about 1k gas per crank (transaction gasUsed,
  `forwarders/evm/results/fork-gas.md`). Passing the 1% ceiling
  as `maxFee` instead would survive a change to Circle's fee getter but would
  authorize Circle to charge up to 1% on every transfer; the forwarder
  authorizes only Circle's on-chain minimum.
- **Burn-limit clamp**, made best-effort. Without it, a per-message limit
  lowered below a balance strands that balance; with hard reads, a change to
  Circle's `localMinter` or `burnLimitsPerMessage` getters would strand every
  address (`test_limitLookupFails_burnsWholeBalance`). The best-effort reads
  cost 665 gas per crank over hard calls. Dropping the clamp saves nothing: the
  successful `localMinter()` read warms the messenger's proxy implementation
  and storage before the minimum-fee lookup, which reverts and so keeps none
  of the warm accesses it makes; without the clamp `depositForBurn` pays them
  cold again (1.9k more per crank, measured in `fork-gas.md`).
- **Two crank paths.** `forward(recipient)` is the only way to deploy and
  crank in one transaction; it must call the clone's `forward()`, which is
  therefore callable by anyone, and calling it directly is the cheapest later
  crank. A direct call to an address without code succeeds and does nothing
  (`test_directForwardOnUndeployedAddress_isNoOp`), so the crank service calls
  `forward(recipient)` unless the address has code, and counts a crank as done
  only from a `DepositForBurn` log whose depositor is the address.

Removed, with the risk argument:

- **Separate factory and implementation.** The instance is both. A deposit
  address is still a clone of fixed logic; a direct call to the instance acts
  on the instance's own balance (see "Delegatecall and EIP-7702" and the
  stray-USDC note above).
- **`NotClone` 77-byte guard.** Only accounts other than deposit addresses
  reach the cases it covered, and each acts on its own balance; an EIP-7702
  account reads a zero recipient and Circle refuses it.
- **Forward-time chain-id re-check.** It could only refuse new clones after a
  chain-id change; if Circle followed that chain, counterfactual deposits
  there would be stranded (`test_chainIdChange_counterfactualDepositStillForwards`).
  Burns on a side Circle does not attest are never minted regardless.
- **Zero-recipient checks.** Circle's `depositForBurn` refuses a zero
  `mintRecipient`, so a zero-recipient address never burns
  (`test_zeroRecipient_circleRefuses_fundsWait`); the TypeScript helper
  refuses to derive one, so it is never shown.
- **Constructor zero-address and local-domain checks, destination-domain
  argument.** The destination is the constant 8, never a source domain. The
  USDC and messenger arguments are fixed per chain in reviewed constants and
  committed into the pinned instance address, so a wrong value cannot produce
  the address the helper uses.
- **Factory views and events** (`initCode`, `initCodeHash`, policy getters,
  `implementation()`, configuration getters, `ForwarderDeployed`,
  `Forwarded`) and `forward()`'s return values. Code identity at the pinned
  address replaces the getter checks; Circle's `DepositForBurn` and
  `MessageSent` already carry the depositor, recipient, amount, `maxFee` and
  threshold.
- **`NothingToForward` and `ApproveFailed`.** Circle refuses a zero amount;
  FiatToken's `approve` returns true or reverts, and an unset allowance would
  make Circle's `transferFrom` revert.
- **TypeScript deployment-gate helpers** (config, policy and implementation
  assertions). Pinned instance addresses supersede them.
- **TypeScript mint anomaly and failure classification** (abort-code table,
  event matching, burn/message pairing, re-fetch policy, Sui registration
  check). None of it can move funds: Sui verifies Circle's attestation, the
  mint is permissionless and pays the message's own recipient. The delivery
  oracle is Sui's nonce flag, set in the same atomic transaction that mints;
  any failure is retried and alerted on, and a validated message is never
  dropped.
- **Test redundancy.** One unit file with inline mocks that follow Circle's
  check order and one fork file run on both chains replace the separate
  factory, fixture-guard and fork-helper files and six mocks. Every property
  the hard requirements rest on keeps a test: fixture parity with the current
  build, clone layout and fuzzed `addressOf`, the chain-id constructor check,
  caller and calldata independence, the minimum-fee and ceiling rules (fuzzed
  against an independent model), the clamp, no storage access, and on both
  forks every `MessageSent` field, the clone as depositor and each Circle
  restriction leaving funds in place. Tests of removed features (getters,
  events, guards, the anomaly classifier) go with them.

## Address derivation

| Chain               | On-chain                        | TypeScript                           |
| ------------------- | ------------------------------- | ------------------------------------ |
| Avalanche / Polygon | `instance.addressOf(recipient)` | `forwarderAddress(chain, recipient)` |

`forwarders/evm/script/WriteAddressVectors.s.sol` writes the instance's init
code hash, its address and recipient vectors for both chains;
`src/evm-forwarder.test.ts` re-derives the instance addresses and every vector
and checks them against the pinned constants. Compiler settings in
`forwarders/evm/foundry.toml` and the Solady pin are load-bearing: they fix the
creation code and so every address.

## Sui mint

`src/cctp-v2.ts`:

- `findForwarderBurns` scans `DepositForBurn` logs on the chain's
  TokenMessengerV2 by USDC and depositor (the forwarder), up to the
  `"finalized"` block (Polygon PoS can reorg until finalized), after checking
  `eth_chainId` (both chains share Circle's messenger address).
- `fetchIrisMessages` reads Iris V2 messages by source transaction (404 is
  "not indexed yet").
- `forwarderBurnProblem` accepts a message only if, with the four
  attester-filled fields zeroed, it equals byte for byte the message the
  forwarder emits for its amount and `maxFee` (so `minFinalityThreshold` is
  2000), its nonce is set and `maxFee` is within 1%. The attester-filled
  `finalityThresholdExecuted` is left to Sui, which requires at least 500.

`src/cctp-v2-sui.ts` builds the four-call `receive_message` → `prepare_mint`
→ `handler::mint` → `complete_mint` PTB, which matches real Avalanche → Sui and
Polygon → Sui mainnet mints call for call, and reads `is_nonce_used` by
simulation (a failed read throws; it is never "unused"). Worker contract: mint
each validated message once per nonce; after any failed or uncertain
submission re-read the nonce; a used nonce is delivered, anything else is
retried with backoff and alerted on. Destination caller 0 lets anyone mint, so
a stuck worker delays but never loses a transfer.

Sui does not validate `mintRecipient`: an object or package id mints and is
lost. The recipient must be bound to the user's authenticated Sui account
before an address is shown. A recipient on Sui's USDC deny list makes the mint
abort without consuming the nonce; it succeeds once lifted.

## No recovery path

Funds that cannot be burned stay where they are. A Miso-held recovery key
would reintroduce custody; refund-to-sender cannot work because a forwarder
cannot learn a USDC sender and an onramp pays from a pooled wallet; a
user-supplied recovery key bound into the address would need its own
cross-chain signature design. Mitigations: crank right after each deposit
(onramp webhook plus a periodic sweep), alert on any balance left at any
address ever issued and on any burn not minted within a deadline, watch
Circle's notices for V2 and the Sui route, and present each address as
single-use for one top-up.

## Verified and not verified

Verified by read-only checks and fork tests (both chains, pinned blocks):
Sui (domain 8) is registered on both TokenMessengerV2s with the identifier
Sui's `stamp_receipt` checks (re-derived from Circle's Sui package id);
local domains 1 and 7; message and body versions 1; a per-message burn limit
of 10,000,000 USDC; `getMinFeeAmount` absent; the keyless CREATE2 deployer
present; deployment through it lands on the pinned address and fails with
another chain's id; full burns with every `MessageSent` field asserted and the
clone as depositor and `messageSender`; each Circle restriction above leaving
funds in place and the same crank succeeding after it is lifted; the
zero-recipient, EIP-7702 and instance-direct cases. Real Avalanche → Sui and
Polygon → Sui Standard mints exist on mainnet and are captured as fixtures
(each records its source transaction and capture date); the receive PTB equals
them command for command, a structural check, and their attested messages carry
`expirationBlock` 0. Circle's Sui V2 Move source
(`circlefin/sui-cctp` b23b83b) treats `mintRecipient` as raw address bytes,
accepts destination caller 0, requires `finalityThresholdExecuted ≥ 500` and
bounds `feeExecuted ≤ maxFee` and `< amount`.

Not verified: any forwarder burn attested or minted; Circle's off-chain fee and
whether Standard stays free; anything executed on Sui by this code; that an
onramp provider pays an Avalanche or Polygon contract address in live mode.
Iris sandbox has no Sui V2 route, so there is no testnet path.

## Launch gates, in order

1. **Bounded mainnet test**: deploy, send a few USDC through a forwarder on
   each chain, crank, mint on Sui with the mint module, reconcile to the unit.
   Needs explicit owner approval, a budget and gas-only keys.
2. **Deployment** on each chain through the keyless CREATE2 deployer with salt
   0 and the reviewed arguments; confirm code at the address pinned in
   `src/evm-forwarder.ts`, verify the source, and cross-check `addressOf` with
   the TypeScript helper for a sample recipient.
3. **Provider acceptance**: a live purchase from each onramp to a forwarder
   address, confirming native USDC (not USDC.e).
4. **Operations**: a crank service per chain and a Sui mint worker with a
   durable journal, scanning only to the finalized block with an RPC whose
   chain id is checked.
5. **Periodic checks**: Circle's burn limits, pause flags and minimum fee on
   both chains, domain-8 registration, Sui's registration of domains 1 and 7,
   Sui deny-list status of each recipient before issuing an address, and
   Circle package upgrades (call targets in `src/cctp-v2-sui.ts`).
6. **Monitoring**: alert on any balance at any issued address and on any burn
   not minted within a deadline.
7. **Bind the recipient** to the user's authenticated Sui account and show the
   address with its chain.
8. **Disclosure** below accepted and shown.

## User disclosure (draft)

> This deposit address works only for native USDC on [Avalanche / Polygon]
> and only ever forwards to your Miso Sui account. Nobody — including
> Miso — can move funds from it any other way. If Circle stops or blocks
> transfers from this address (for example by pausing, retiring or changing its
> bridge, or by blocking the address), USDC sent to it may stay there
> permanently. Other tokens (including bridged USDC.e), native AVAX or POL, and
> USDC sent on any other network cannot be recovered. Use this address for this
> top-up only; do not save it for later payments. Transfers normally arrive
> within seconds to a minute, and Circle charges no fee today. Miso charges no
> fee for this.

The terms must also cover the post-burn case: if the Sui recipient is ever
blocked by Circle on Sui, a burned transfer waits until the block is lifted.
