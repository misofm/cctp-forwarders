import { keccak_256 } from "@noble/hashes/sha3"
import { bytesToHex, concatBytes, hexToBytes } from "@noble/hashes/utils"

/**
 * Circle CCTP V2 on the EVM source chains, and the forwarder deposit
 * address of a Sui recipient. `factory` is the one `Forwarder` contract per
 * chain (forwarders/evm/src/Forwarder.sol), deployed through the keyless
 * CREATE2 deployer with salt 0; it is both the factory and the clone
 * implementation.
 */
export type EvmChain = "avalanche" | "polygon"

export const EVM_CHAINS: Readonly<
  Record<
    EvmChain,
    {
      readonly chainId: number
      readonly domain: number
      readonly usdc: string
      readonly tokenMessenger: string
      readonly factory: string
    }
  >
> = {
  avalanche: {
    chainId: 43114,
    domain: 1,
    usdc: "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e",
    tokenMessenger: "0x28b5a0e9c621a5badaa536219b3a228c8168cf5d",
    factory: "0x6e693386CD61AD0C68b146EE7e522980b5C6b6F5",
  },
  polygon: {
    chainId: 137,
    domain: 7,
    usdc: "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359",
    tokenMessenger: "0x28b5a0e9c621a5badaa536219b3a228c8168cf5d",
    factory: "0xb72E0FFf191539Fecc22EfC7F4364d679aBc779F",
  },
}

/** The chain's constants; throws on an unknown chain. */
export function evmChain(chain: EvmChain) {
  if (!Object.hasOwn(EVM_CHAINS, chain))
    throw new Error(`unknown chain ${chain}`)
  return EVM_CHAINS[chain]
}

/** `0x` + exactly `length` bytes of hex, as bytes; throws otherwise. */
export function fixedHex(value: string, length: number): Uint8Array {
  if (!new RegExp(`^0x[0-9a-fA-F]{${length * 2}}$`).test(value))
    throw new Error(`expected 0x + ${length} bytes of hex, got ${value}`)
  return hexToBytes(value.slice(2))
}

function checksum(address: Uint8Array): string {
  const lower = bytesToHex(address)
  const hash = bytesToHex(keccak_256(lower))
  let out = "0x"
  for (let i = 0; i < 40; i++)
    out += parseInt(hash[i], 16) >= 8 ? lower[i].toUpperCase() : lower[i]
  return out
}

/** EIP-55 CREATE2 address: keccak256(0xff ‖ deployer ‖ salt ‖ initCodeHash)[12:]. */
export function create2Address(
  deployer: string,
  salt: string,
  initCodeHash: string
): string {
  const preimage = concatBytes(
    new Uint8Array([0xff]),
    fixedHex(deployer, 20),
    fixedHex(salt, 32),
    fixedHex(initCodeHash, 32)
  )
  return checksum(keccak_256(preimage).slice(12))
}

/**
 * The deposit address of `recipient` (a 32-byte Sui address) on `chain`:
 * the factory's Solady `LibClone` clone (ERC-1167 with the recipient
 * appended), created by the factory with salt = recipient.
 */
export function forwarderAddress(chain: EvmChain, recipient: string): string {
  const { factory } = evmChain(chain)
  const r = fixedHex(recipient, 32)
  // Circle rejects a zero mint recipient, so its clone could never forward.
  if (r.every((b) => b === 0)) throw new Error("recipient must be non-zero")
  const initCode = concatBytes(
    hexToBytes("61004d3d81600a3d39f3363d3d373d3d3d363d73"),
    fixedHex(factory, 20),
    hexToBytes("5af43d82803e903d91602b57fd5bf3"),
    r
  )
  return create2Address(
    factory,
    recipient,
    "0x" + bytesToHex(keccak_256(initCode))
  )
}
