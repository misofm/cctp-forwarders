import { Transaction } from "@mysten/sui/transactions"

/**
 * The Sui side of a CCTP V2 transfer: the receive (mint) PTB and the
 * nonce-used check (github.com/circlefin/sui-cctp @ b23b83b0d957bb9dfd876e6c1aa02dbf89d88eba).
 *
 * `receive_message` marks the nonce used in the same atomic PTB that mints,
 * so a nonce `isNonceUsed` reports used is delivered. After any failed or
 * uncertain submit the worker re-checks `isNonceUsed` and otherwise retries;
 * Iris or Sui errors never cause a validated message to be dropped.
 */

/**
 * Circle's Sui mainnet CCTP V2 ids. After a Circle package upgrade only the
 * `*Package` call targets change; type names keep their defining ids.
 */
export const SUI_MAINNET_CCTP_V2 = Object.freeze({
  messageTransmitterPackage:
    "0x16bcfcfc465f96281663a344641c017de84529370e11aa3879d0dce43ad6db87",
  messageTransmitterState:
    "0x0c067f7d325e5b60e3179712e7783534ba1556cbb3d359d8161497e37689230c",
  tokenMessengerMinterPackage:
    "0xeb14978abfe93a37c5d5bf86a0623b923553a5f0e794daac7724f1e2fdbfb830",
  tokenMessengerMinterState:
    "0x06fb166941cd7bc095edc019d054a753ec3f1e4c25f28f2ecc4a6cfa0a9b1167",
  stablecoinHandlerPackage:
    "0x185ed207c4d64fc594882ab927f9f3c6ff957aad03df8a731ba64378faeeb2bf",
  stablecoinHandlerState:
    "0xa32de8a6dd0178fb05f662929d55cddb69a25c26bde4b83f89e36d17ead94c41",
  handlerAuthType:
    "0x185ed207c4d64fc594882ab927f9f3c6ff957aad03df8a731ba64378faeeb2bf::handler::Auth",
  usdcType:
    "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC",
  usdcTreasury:
    "0x57d6725e7a8b49a7b2a612f6bd66ab5f39fc95332ca48be421c3229d514a6de7",
  denyList: "0x403",
  clock: "0x6",
})

/**
 * Circle's four-call receive: `receive_message` → `prepare_mint` →
 * `handler::mint` → `complete_mint`. Sets no sender or gas.
 */
export function buildReceiveMessageTransaction(
  message: Uint8Array,
  attestation: Uint8Array,
  config = SUI_MAINNET_CCTP_V2
): Transaction {
  if (message.length < 376) throw new Error("message shorter than 376 bytes")
  if (attestation.length === 0 || attestation.length % 65 !== 0)
    throw new Error("attestation must be a positive multiple of 65 bytes")
  const tx = new Transaction()
  const [receipt] = tx.moveCall({
    target: `${config.messageTransmitterPackage}::receive_message::receive_message`,
    arguments: [
      tx.pure.vector("u8", message),
      tx.pure.vector("u8", attestation),
      tx.object(config.messageTransmitterState),
    ],
  })
  const [mintReceipt] = tx.moveCall({
    target: `${config.tokenMessengerMinterPackage}::handle_receive_message::prepare_mint`,
    arguments: [
      receipt,
      tx.object(config.tokenMessengerMinterState),
      tx.object(config.clock),
    ],
    typeArguments: [config.usdcType],
  })
  const [ticket] = tx.moveCall({
    target: `${config.stablecoinHandlerPackage}::handler::mint`,
    arguments: [
      tx.object(config.stablecoinHandlerState),
      mintReceipt,
      tx.object(config.tokenMessengerMinterState),
      tx.object(config.usdcTreasury),
      tx.object(config.denyList),
    ],
  })
  tx.moveCall({
    target: `${config.tokenMessengerMinterPackage}::handle_receive_message::complete_mint`,
    arguments: [
      ticket,
      tx.object(config.tokenMessengerMinterState),
      tx.object(config.messageTransmitterState),
    ],
    typeArguments: [config.usdcType, config.handlerAuthType],
  })
  return tx
}

/**
 * Whether MessageTransmitterV2 already received the message with this
 * bytes32 `nonce`, by simulating `state::is_nonce_used`. Throws on a failed
 * simulation or a non-boolean result, never reporting "unused".
 */
export async function isNonceUsed(
  client: {
    simulateTransaction(args: {
      transaction: Transaction
      include?: { commandResults?: boolean }
    }): Promise<{
      Transaction?: { status: { success: boolean; error: unknown } }
      FailedTransaction?: { status: { success: boolean; error: unknown } }
      commandResults?: ReadonlyArray<{
        returnValues: ReadonlyArray<{ bcs: Uint8Array }>
      }>
    }>
  },
  nonce: string,
  config = SUI_MAINNET_CCTP_V2
): Promise<boolean> {
  if (!/^0x[0-9a-fA-F]{64}$/.test(nonce))
    throw new Error(`nonce must be 0x + 64 hex, got ${nonce}`)
  const tx = new Transaction()
  tx.setSender("0x" + "0".repeat(63) + "2")
  tx.moveCall({
    target: `${config.messageTransmitterPackage}::state::is_nonce_used`,
    arguments: [
      tx.object(config.messageTransmitterState),
      tx.pure.u256(BigInt(nonce)),
    ],
  })
  const response = await client.simulateTransaction({
    transaction: tx,
    include: { commandResults: true },
  })
  const status = (response.Transaction ?? response.FailedTransaction)?.status
  if (!status?.success)
    throw new Error(
      `is_nonce_used simulation failed: ${JSON.stringify(status?.error)}`
    )
  const bcs = response.commandResults?.[0]?.returnValues?.[0]?.bcs
  if (bcs?.length !== 1 || bcs[0] > 1)
    throw new Error("is_nonce_used returned no boolean")
  return bcs[0] === 1
}
