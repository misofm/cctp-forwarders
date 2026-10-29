# cctp-forwarders

Keyless forwarders that move native USDC from Avalanche C-Chain and Polygon
PoS to a user's Sui account through Circle CCTP V2. They are built for onramp
providers that cannot pay USDC on Sui directly: the provider pays a per-user
deposit address on Avalanche or Polygon, and anyone can crank that address to
burn its USDC to one fixed Sui address.

Each deposit address is derived from the user's 32-byte Sui address alone,
both on-chain and in TypeScript, and is the same on every chain. Every burn uses Circle's Standard
Transfer, with no fee beyond any minimum Circle enforces on-chain and never
more than 1%. A forwarder has no owner, no upgrade path, no Miso fee, and no
way to send funds anywhere but the committed Sui address. Design, safety
argument, failure modes, launch gates and the user disclosure:
[docs/design.md](docs/design.md).

**The ownerless instances are deployed on Avalanche and Polygon mainnet and
source-verified on Sourcify.** Deployment transactions and blocks live in
`MAINNET_DEPLOYMENTS` in `src/evm-forwarder.ts`. Both runtimes and an address
vector were checked against the pinned build. A funded Stripe-hosted Polygon
pilot delivered 10 native USDC through a forwarder, Circle attestation and the
Sui mint module; the recipient received all 10 USDC. Avalanche forwarding and
other onramp providers still need their own funded tests. Circle's sandbox has
no Sui V2 route.

Crank services must estimate gas for each transaction and add headroom. The
pilot's first 250,000-gas attempt reverted; the successful retry used a live
estimate plus 30%. Receipt gas used is after refunds and is not a safe gas limit.

## Layout

- `forwarders/evm/`: the Avalanche and Polygon contract, Foundry
  ([README](forwarders/evm/README.md)).
- `src/evm-forwarder.ts`: chain constants, the pinned contract address and
  `forwarderAddress(suiAddress)`.
- `src/cctp-v2.ts`: burn discovery, Iris attestation and message validation.
- `src/cctp-v2-sui.ts`: the Sui `receive_message` PTB and nonce check.
- `fixtures/`: real Iris responses, burns and Sui mints used by the tests.

## Limitations

- No recovery path: USDC that Circle will not burn stays at the address;
  other tokens (including bridged USDC.e) and native AVAX or POL are
  unrecoverable. Native USDC sent to the address on another EVM chain is
  forwarded once anyone deploys the contract there, which works wherever the
  keyless CREATE2 deployer exists and Circle's standard messenger routes USDC
  to Sui; elsewhere it waits or is stranded.
- Sui does not validate the recipient; it must be bound to the user's
  authenticated Sui account before an address is shown.
- Onramp acceptance of an Avalanche or Polygon contract address is not yet
  shown in live mode.

## Development

```sh
bun install --frozen-lockfile
bun run format:check
bun run lint
bun run typecheck
bun run test
bun run build
(cd forwarders/evm && REQUIRE_FORK=1 forge test)
```

This package is private and is not published to a registry. Build and pack it
for API consumers; the exported subpaths are `evm-forwarder`, `cctp-v2` and
`cctp-v2-sui`. App UI and
authentication live in `misofm/app`.
