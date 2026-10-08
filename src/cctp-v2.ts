import { bytesToHex, hexToBytes } from "@noble/hashes/utils"
import { evmChain, fixedHex, type EvmChain } from "./evm-forwarder.js"

/**
 * CCTP V2 burns by forwarders: discovery on the source chain, attested
 * messages from Circle's Iris API, and validation.
 *
 * Minting on Sui is permissionless and Sui verifies Circle's attestation,
 * so nothing here can redirect funds. Validation only binds a message to a
 * forwarder for bookkeeping; Sui enforces the attester-filled bounds itself.
 */

export const SUI_DOMAIN = 8
/** keccak256 of `<token_messenger_minter_v2 id>::message_transmitter_authenticator::MessageTransmitterAuthenticator`: the header recipient of every Sui-bound burn. */
export const SUI_MESSAGE_RECIPIENT =
  "0xf47842a2b5ac4483731927a7500175a9354d2eccd94312aa591ec50b9e8657e6"
const DEPOSIT_FOR_BURN_TOPIC0 =
  "0x0c8c1cbdc5190613ebd485511d4e2812cfa45eecb79d845893331fedad5130a5"
/** 148-byte header + 228-byte burn body without hookData. */
const BURN_MESSAGE_LENGTH = 376

const hex = (bytes: Uint8Array) => "0x" + bytesToHex(bytes)
const bytes32 = (address: string) =>
  "0x" + bytesToHex(fixedHex(address, 20)).padStart(64, "0")

/**
 * The forwarder's `DepositForBurn` logs on `chain` in a block range, from
 * the chain's TokenMessengerV2. Bound `toBlock` by "finalized": Polygon PoS
 * can reorg until then.
 */
export async function findForwarderBurns(
  rpc: {
    request(args: { method: string; params: unknown[] }): Promise<unknown>
  },
  args: {
    chain: EvmChain
    forwarder: string
    fromBlock: bigint | number
    toBlock: bigint | number | "finalized"
  }
): Promise<
  Array<{ transactionHash: string; blockNumber: bigint; amount: bigint }>
> {
  const c = evmChain(args.chain)
  const block = (b: unknown) => {
    if (b === "finalized") return b
    if ((typeof b === "bigint" || Number.isSafeInteger(b)) && Number(b) >= 0)
      return "0x" + (b as bigint | number).toString(16)
    throw new Error(`invalid block ${String(b)}`)
  }
  const topics = [
    DEPOSIT_FOR_BURN_TOPIC0,
    bytes32(c.usdc),
    bytes32(args.forwarder),
  ]
  const filter = {
    address: c.tokenMessenger,
    topics,
    fromBlock: block(args.fromBlock),
    toBlock: block(args.toBlock),
  }
  // Both chains share TokenMessengerV2's address: a wrong RPC must fail loudly.
  const chainId = await rpc.request({ method: "eth_chainId", params: [] })
  if (typeof chainId !== "string" || BigInt(chainId) !== BigInt(c.chainId))
    throw new Error(`RPC chain id ${chainId}, expected ${c.chainId}`)
  const logs = await rpc.request({ method: "eth_getLogs", params: [filter] })
  if (!Array.isArray(logs)) throw new Error("eth_getLogs returned a non-array")
  return logs.map((log) => {
    if (
      log.removed === true ||
      String(log.address).toLowerCase() !== c.tokenMessenger ||
      topics.some((t, i) => String(log.topics?.[i]).toLowerCase() !== t) ||
      !/^0x[0-9a-fA-F]{64}/.test(log.data)
    )
      throw new Error(`log does not match the filter: ${JSON.stringify(log)}`)
    return {
      transactionHash: hex(fixedHex(log.transactionHash, 32)),
      blockNumber: BigInt(log.blockNumber),
      amount: BigInt(log.data.slice(0, 66)),
    }
  })
}

export type IrisMessage =
  | { status: "complete"; message: Uint8Array; attestation: Uint8Array }
  | { status: "pending" }

/**
 * Iris's messages for a source transaction, or null when Iris has not
 * indexed it yet (404). Throws on any other non-200 status or a malformed
 * body; the caller retries with backoff. An entry that is not a complete,
 * well-formed message and attestation is "pending": it is polled again, and
 * monitoring alerts on burns not minted within a deadline.
 */
export async function fetchIrisMessages(
  fetchFn: typeof fetch,
  args: { chain: EvmChain; transactionHash: string },
  baseUrl = "https://iris-api.circle.com"
): Promise<IrisMessage[] | null> {
  // Iris matches the hash case-sensitively, in lowercase.
  const hash = hex(fixedHex(args.transactionHash, 32))
  const url = `${baseUrl}/v2/messages/${evmChain(args.chain).domain}?transactionHash=${hash}`
  const response = await fetchFn(url)
  if (response.status === 404) return null
  if (response.status !== 200) throw new Error(`Iris HTTP ${response.status}`)
  const body = (await response.json()) as { messages?: unknown }
  if (!Array.isArray(body?.messages)) throw new Error("Iris: no messages array")
  return body.messages.map((m) => {
    if (typeof m !== "object" || m === null) throw new Error("Iris: bad entry")
    const { status, message, attestation } = m as Record<string, unknown>
    const isHex = (v: unknown): v is string =>
      typeof v === "string" && /^0x([0-9a-fA-F]{2})+$/.test(v)
    return status === "complete" &&
      isHex(message) &&
      isHex(attestation) &&
      (attestation.length - 2) % 130 === 0
      ? {
          status,
          message: hexToBytes(message.slice(2)),
          attestation: hexToBytes(attestation.slice(2)),
        }
      : { status: "pending" }
  })
}

/** The fields of a CCTP V2 burn message that callers use. */
export function decodeBurnMessage(message: Uint8Array) {
  if (message.length < BURN_MESSAGE_LENGTH)
    throw new Error(`burn message shorter than ${BURN_MESSAGE_LENGTH} bytes`)
  const at = (offset: number, length = 32) =>
    hex(message.subarray(offset, offset + length))
  return {
    sourceDomain: new DataView(message.buffer, message.byteOffset).getUint32(4),
    nonce: at(12),
    mintRecipient: at(184),
    messageSender: at(248),
    amount: BigInt(at(216)),
    maxFee: BigInt(at(280)),
    feeExecuted: BigInt(at(312)),
  }
}

/**
 * Null when `message` is the burn `forwarder` on `chain` emits to
 * `recipient`; otherwise a short reason. Compares the message, with the
 * attester-filled fields (nonce, finalityThresholdExecuted, feeExecuted,
 * expirationBlock) zeroed, byte for byte with the forwarder's burn-time
 * message.
 */
export function forwarderBurnProblem(
  message: Uint8Array,
  expected: { chain: EvmChain; forwarder: string; recipient: string }
): string | null {
  const c = evmChain(expected.chain)
  if (message.length !== BURN_MESSAGE_LENGTH)
    return `length ${message.length}, expected ${BURN_MESSAGE_LENGTH}`
  const want = new Uint8Array(BURN_MESSAGE_LENGTH)
  const view = new DataView(want.buffer)
  view.setUint32(0, 1) // message version
  view.setUint32(4, c.domain)
  view.setUint32(8, SUI_DOMAIN)
  want.set(fixedHex(bytes32(c.tokenMessenger), 32), 44)
  want.set(fixedHex(SUI_MESSAGE_RECIPIENT, 32), 76)
  view.setUint32(140, 2000) // minFinalityThreshold: Standard
  view.setUint32(148, 1) // burn body version
  want.set(fixedHex(bytes32(c.usdc), 32), 152)
  want.set(fixedHex(expected.recipient, 32), 184)
  want.set(message.subarray(216, 248), 216) // amount
  want.set(fixedHex(bytes32(expected.forwarder), 32), 248)
  want.set(message.subarray(280, 312), 280) // maxFee
  const got = message.slice()
  for (const [from, to] of [
    [12, 44],
    [144, 148],
    [312, 376],
  ])
    got.fill(0, from, to)
  const i = got.findIndex((b, j) => b !== want[j])
  if (i >= 0) return `differs from the forwarder's burn at byte ${i}`
  const { nonce, amount, maxFee } = decodeBurnMessage(message)
  if (BigInt(nonce) === 0n) return "zero nonce (not attested)"
  if (amount === 0n) return "zero amount"
  if (maxFee > amount / 100n) return "maxFee above 1% of amount"
  return null
}
