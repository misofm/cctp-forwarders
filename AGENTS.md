# cctp-forwarders Agent Guide

This repository owns keyless USDC forwarders on Avalanche C-Chain and Polygon
PoS that burn through Circle CCTP V2 to a fixed Sui address, and the off-chain
modules that derive forwarder addresses and complete the Sui mint. Start with README.md and
docs/design.md. Keep app UI and authentication in
misofm/app. Do not introduce app imports here.

Run `bun run format:check`, `bun run lint`, `bun run typecheck`, `bun run test`, and
`bun run build` before pushing. Keep the lockfile committed. Unit tests must not
need funded accounts or submit network transactions. When changing the
forwarders, also run `forge test` (with `REQUIRE_FORK=1`) in
forwarders/evm. Forwarder creation code fixes every deposit address: keep
compiler and toolchain pins unchanged.

Funded execution must be explicit and approved. Never commit private keys,
environment files, transaction journals, or RPC credentials. Do not claim a
funded or deployed flow works based on mocks, forks or read-only checks. House
rule: no on-chain ids in markdown; they live in source constants.

Verify Circle APIs and layouts against Circle's official sources, not analogous
APIs from other chains. When using @mysten packages, read their shipped
docs/llms-index.md and relevant documentation.

Sources:

- https://developers.circle.com/cctp
- https://github.com/circlefin/sui-cctp
- https://github.com/circlefin/evm-cctp-contracts
- https://docs.sui.io/llms.txt
