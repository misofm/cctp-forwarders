# EVM forwarder: Avalanche and Polygon

**Mainnet instances are deployed and source-verified on Avalanche and Polygon.**
Deployment records are in `MAINNET_DEPLOYMENTS` in `src/evm-forwarder.ts` at the
repository root. A funded Stripe-hosted Polygon pilot has completed the USDC
burn, Circle attestation and Sui mint; Avalanche still needs a funded test. One contract,
`src/Forwarder.sol`, deployed once per chain through the keyless CREATE2
deployer from the same init code, so it has the same address on every chain;
it looks up the chain's native USDC from Circle's messenger at construction.
Each deposit address is a 77-byte clone of it that burns its native
USDC through Circle CCTP V2 Standard Transfer to a fixed 32-byte Sui recipient
(domain 8). Design, safety argument, failure modes and launch gates:
[`docs/design.md`](../../docs/design.md).

| Path                                            | Purpose                                                                                                     |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `src/Forwarder.sol`                             | `addressOf(recipient)`, `forward(recipient)` (deploys if needed), `forward()` on a clone.                   |
| `script/Deploy.s.sol`                           | Deploys the instance through the keyless deployer; refuses unless the build lands at the pinned instance.   |
| `script/Chains.sol`                             | Circle's addresses and domains, the Sui values and the pinned fork block per chain.                         |
| `script/WriteAddressVectors.s.sol`, `fixtures/` | Instance and deposit-address vectors, the same on every chain, consumed by the TypeScript parity test.      |
| `test/Forwarder.t.sol`                          | Unit tests against mocks that follow Circle's check order; fixture guard.                                   |
| `test/fork/Fork.t.sol`                          | The same scenarios on Avalanche and Polygon forks against Circle's real contracts, and one address on both. |
| `results/`                                      | Gas per crank on both forks and the script that measures transaction gas.                                   |

## Running

```sh
export PATH="$HOME/.foundry/bin:$PATH"            # Foundry v1.8.3
cd forwarders/evm
forge install foundry-rs/forge-std@v1.16.2 --no-git   # once; lib/ is git-ignored
forge install Vectorized/solady@acd959aa4bd04720d640bf4e6a5c71037510cc4b --no-git  # once; v0.1.26
forge test --no-match-path "test/fork/*"          # unit
REQUIRE_FORK=1 forge test --match-path "test/fork/*"  # both forks; fail, don't skip
forge script script/WriteAddressVectors.s.sol     # regenerates fixtures/
forge script script/Deploy.s.sol --rpc-url $RPC   # dry run; add --broadcast and a gas-only key to deploy
(cd ../.. && bunx prettier --write forwarders/evm/fixtures/address-vectors.json)
```

Fork tests skip when no RPC is reachable, so a run only counts with zero
skipped (`REQUIRE_FORK=1` turns a skip into a failure). Each chain's default
public endpoint is in `script/Chains.sol`; set `AVALANCHE_RPC_URL` or
`POLYGON_RPC_URL` to an archive RPC if it stops serving the pinned block.

Compiler settings in `foundry.toml`, the Solady pin and disabled build metadata
fix the creation code, hence the instance address and every deposit address.
The `cancun` EVM target emits PUSH0 and MCOPY, which every EVM chain with
Circle CCTP V2 accepted when checked; recheck any chain Circle adds before
deploying there. `forge coverage` builds without the optimizer, so the fixture
guard fails under it; exclude it there.
