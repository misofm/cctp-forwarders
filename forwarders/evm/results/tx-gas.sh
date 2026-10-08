#!/usr/bin/env bash
# Transaction gasUsed of three cranks on a local anvil fork at the pinned block
# (see fork-gas.md). Read-only against the RPC; transactions stay local.
# usage: results/tx-gas.sh <forge-project-dir> <new|baseline> <avalanche|polygon> [port]
# "baseline" deploys the earlier ForwarderFactory(usdc, messenger, 8, chainId).
set -euo pipefail
export PATH=$HOME/.foundry/bin:$PATH
DIR=$1; VARIANT=$2; CHAIN=$3; PORT=${4:-8601}
if [ "$CHAIN" = avalanche ]; then RPC=${AVALANCHE_RPC_URL:-https://api.avax.network/ext/bc/C/rpc}; BLOCK=97000000; CID=43114; USDC=0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
else RPC=${POLYGON_RPC_URL:-https://polygon.drpc.org}; BLOCK=95150000; CID=137; USDC=0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359; fi
TM=0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d
DEPLOYER=0x4e59b44847b379578588920cA78FbF26c0B4956C
anvil --fork-url "$RPC" --fork-block-number $BLOCK --port $PORT --auto-impersonate --block-base-fee-per-gas 0 --silent >/dev/null 2>&1 &
APID=$!; trap "kill $APID 2>/dev/null" EXIT
E=http://127.0.0.1:$PORT
for i in $(seq 1 120); do cast chain-id --rpc-url $E >/dev/null 2>&1 && break; sleep 0.5; done
ADMIN=0x00000000000000000000000000000000000a11CE
CRANK=0x000000000000000000000000000000000000C0DE
MINTER=0x00000000000000000000000000000000000F00D0
for a in $ADMIN $CRANK $MINTER; do cast rpc --rpc-url $E anvil_setBalance $a 0x56BC75E2D63100000 >/dev/null; done
cd "$DIR"
if [ "$VARIANT" = baseline ]; then
  CC=$(forge inspect ForwarderFactory bytecode)
  ARGS=$(cast abi-encode 'c(address,address,uint32,uint256)' $USDC $TM 8 $CID)
else
  CC=$(forge inspect Forwarder bytecode)
  ARGS=$(cast abi-encode 'c(address,address,uint256)' $USDC $TM $CID)
fi
INIT=${CC}${ARGS#0x}
SALT=0x0000000000000000000000000000000000000000000000000000000000000000
FACTORY=$(cast create2 --deployer $DEPLOYER --salt $SALT --init-code $INIT | awk "{print \$1}")
cast send --rpc-url $E --legacy --gas-price 1000000000 --unlocked --from $ADMIN $DEPLOYER ${SALT}${INIT#0x} >/dev/null
[ "$(cast code --rpc-url $E $FACTORY)" != 0x ] || { echo "factory deploy failed"; exit 1; }
MM=$(cast call --rpc-url $E $USDC 'masterMinter()(address)')
cast rpc --rpc-url $E anvil_setBalance $MM 0x56BC75E2D63100000 >/dev/null
cast send --rpc-url $E --legacy --gas-price 1000000000 --unlocked --from $MM $USDC 'configureMinter(address,uint256)' $MINTER 1000000000000000 >/dev/null
R=0xa7c1e5d2f40b9e6c3d8a1b2c4e6f80913a5b7c9d1e2f40618293a4b5c6d7e8f9
FWD=$(cast call --rpc-url $E $FACTORY 'addressOf(bytes32)(address)' $R)
gas() { cast send --rpc-url $E --legacy --gas-price 1000000000 --unlocked --from $CRANK "$@" --json | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["status"]=="0x1", r; print(int(r["gasUsed"],16))'; }
cast send --rpc-url $E --legacy --gas-price 1000000000 --unlocked --from $MINTER $USDC 'mint(address,uint256)' $FWD 25000000 >/dev/null
G1=$(gas $FACTORY 'forward(bytes32)' $R)
cast send --rpc-url $E --legacy --gas-price 1000000000 --unlocked --from $MINTER $USDC 'mint(address,uint256)' $FWD 1000000 >/dev/null
G2=$(gas $FACTORY 'forward(bytes32)' $R)
cast send --rpc-url $E --legacy --gas-price 1000000000 --unlocked --from $MINTER $USDC 'mint(address,uint256)' $FWD 10000000 >/dev/null
G3=$(gas $FWD 'forward()')
[ "$(cast call --rpc-url $E $USDC 'balanceOf(address)(uint256)' $FWD)" = 0 ] || { echo "not swept"; exit 1; }
echo "$VARIANT $CHAIN first=$G1 laterViaInstance=$G2 laterDirect=$G3"
