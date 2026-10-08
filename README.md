# cctp-forwarders

Keyless forwarders that move native USDC from Avalanche C-Chain and Polygon
PoS to a user's Sui account through Circle CCTP V2. They are built for onramp
providers that cannot pay USDC on Sui directly: the provider pays a per-user
deposit address on Avalanche or Polygon, and anyone can crank that address to
burn its USDC to one fixed Sui address.

Each deposit address is derived from the user's 32-byte Sui address and the
chain, both on-chain and in TypeScript. Every burn uses Circle's Standard
Transfer, with no fee beyond any minimum Circle enforces on-chain and never
more than 1%. A forwarder has no owner, no upgrade path, no Miso fee, and no
way to send funds anywhere but the committed Sui address. Design, safety
argument, failure modes, launch gates and the user disclosure:
[docs/design.md](docs/design.md).

**Nothing is deployed, nothing has been funded, and no forwarder burn has been
attested or minted.** Circle's sandbox has no Sui V2 route, so the first
end-to-end run must be a bounded mainnet test.

## Layout

- `forwarders/evm/`: the Avalanche and Polygon contract, Foundry
  ([README](forwarders/evm/README.md)).
- `src/evm-forwarder.ts`: chain constants, pinned contract addresses and
  `forwarderAddress(chain, suiAddress)`.
- `src/cctp-v2.ts`: burn discovery, Iris attestation and message validation.
- `src/cctp-v2-sui.ts`: the Sui `receive_message` PTB and nonce check.
- `fixtures/`: real Iris responses, burns and Sui mints used by the tests.

## Limitations

- No recovery path: USDC that Circle will not burn stays at the address;
  other tokens (including bridged USDC.e), native AVAX or POL, and USDC sent on
  the wrong chain are unrecoverable.
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

This package is private and is not published to a registry. App UI and
authentication live in `misofm/app`.
