import { describe, expect, it } from "vitest"
import { keccak_256 } from "@noble/hashes/sha3"
import { bcs } from "@mysten/sui/bcs"
import { normalizeSuiObjectId } from "@mysten/sui/utils"
import {
  buildReceiveMessageTransaction,
  isNonceUsed,
  SUI_MAINNET_CCTP_V2,
} from "./cctp-v2-sui"
import { decodeBurnMessage, SUI_MESSAGE_RECIPIENT } from "./cctp-v2"
import receiveAvalanche from "../fixtures/cctp-v2-sui/mainnet-receive-avalanche.json"
import receivePolygon from "../fixtures/cctp-v2-sui/mainnet-receive-polygon.json"
import simulations from "../fixtures/cctp-v2-sui/simulations.json"

const CFG = SUI_MAINNET_CCTP_V2
const hexToBytes = (hex: string) =>
  Uint8Array.from(Buffer.from(hex.slice(2), "hex"))

type Arg = {
  $kind: string
  Input?: number
  Result?: number
  NestedResult?: [number, number]
}
type Call = {
  MoveCall: {
    package: string
    module: string
    function: string
    typeArguments: string[]
    arguments: Arg[]
  }
}

/** Commands with packages normalized and `Result n` spelled as `NestedResult [n, 0]`. */
const canonical = (commands: unknown[]) =>
  (commands as Call[]).map(({ MoveCall: c }) => ({
    ...c,
    package: normalizeSuiObjectId(c.package),
    arguments: c.arguments.map((a) =>
      a.$kind === "Input"
        ? `input:${a.Input}`
        : `result:${a.Result ?? a.NestedResult![0]}:${a.NestedResult?.[1] ?? 0}`
    ),
  }))

describe.each([
  ["avalanche", receiveAvalanche],
  ["polygon", receivePolygon],
] as const)("%s", (_chain, fixture) => {
  const message = hexToBytes(fixture.message)
  const attestation = hexToBytes(fixture.attestation)

  it("builds the real mainnet receive command for command, input for input", () => {
    const data = buildReceiveMessageTransaction(message, attestation).getData()
    expect(data.sender).toBeFalsy()
    expect(canonical(data.commands)).toEqual(canonical(fixture.commands))
    const inputs = data.inputs as Array<{
      $kind: string
      Pure?: { bytes: string }
      UnresolvedObject?: { objectId: string }
    }>
    const pure = inputs
      .filter((i) => i.$kind === "Pure")
      .map((i) => Uint8Array.from(Buffer.from(i.Pure!.bytes, "base64")))
    expect(pure).toEqual(
      [message, attestation].map((b) =>
        bcs.vector(bcs.u8()).serialize(b).toBytes()
      )
    )
    expect(
      inputs.map((i) =>
        i.UnresolvedObject
          ? normalizeSuiObjectId(i.UnresolvedObject.objectId)
          : `pure:${Buffer.from(i.Pure!.bytes, "base64").length}`
      )
    ).toEqual(
      (
        fixture.inputs as Array<{
          length?: number
          Object?: { SharedObject: { objectId: string } }
        }>
      ).map((i) =>
        i.Object ? i.Object.SharedObject.objectId : `pure:${i.length}`
      )
    )
  })

  it("is addressed to SUI_MESSAGE_RECIPIENT", () => {
    expect("0x" + fixture.message.slice(2 + 152, 2 + 216)).toBe(
      SUI_MESSAGE_RECIPIENT
    )
  })

  it("the captured is_nonce_used simulation reports this nonce used", () => {
    const nonce = decodeBurnMessage(message).nonce
    const raw =
      simulations.isNonceUsed[nonce as keyof typeof simulations.isNonceUsed]
    expect(raw.expected).toBe(true)
  })
})

it("SUI_MESSAGE_RECIPIENT is the MessageTransmitterAuthenticator caller id", () => {
  const typeName = `${CFG.tokenMessengerMinterPackage.slice(2)}::message_transmitter_authenticator::MessageTransmitterAuthenticator`
  expect("0x" + Buffer.from(keccak_256(typeName)).toString("hex")).toBe(
    SUI_MESSAGE_RECIPIENT
  )
})

it("rejects a short message or a malformed attestation", () => {
  const message = hexToBytes(receiveAvalanche.message)
  expect(() =>
    buildReceiveMessageTransaction(message.subarray(1), new Uint8Array(65))
  ).toThrow()
  expect(() =>
    buildReceiveMessageTransaction(message, new Uint8Array(64))
  ).toThrow()
  expect(() =>
    buildReceiveMessageTransaction(message, new Uint8Array(0))
  ).toThrow()
})

describe("isNonceUsed", () => {
  it.each(Object.entries(simulations.isNonceUsed))(
    "%s matches the live simulation",
    async (nonce, c) => {
      let tx:
        | {
            getData(): {
              sender?: string | null
              commands: unknown[]
              inputs: unknown[]
            }
          }
        | undefined
      const client = {
        simulateTransaction: async (args: { transaction: typeof tx }) => {
          tx = args.transaction
          return {
            Transaction: c.rawResult.Transaction,
            commandResults: c.rawResult.commandResults.map((r) => ({
              returnValues: r.returnValues.map((v) => ({
                bcs: hexToBytes(v.bcs),
              })),
            })),
          }
        },
      }
      expect(await isNonceUsed(client, nonce)).toBe(c.expected)
      const data = tx!.getData()
      const [call] = canonical(data.commands)
      expect(`${call.package}::${call.module}::${call.function}`).toBe(
        `${CFG.messageTransmitterPackage}::state::is_nonce_used`
      )
      const pure = (
        data.inputs as Array<{ $kind: string; Pure?: { bytes: string } }>
      ).find((i) => i.$kind === "Pure")!
      expect(Uint8Array.from(Buffer.from(pure.Pure!.bytes, "base64"))).toEqual(
        bcs.u256().serialize(BigInt(nonce)).toBytes()
      )
    }
  )

  it("throws on a failed simulation or a non-boolean result", async () => {
    const nonce = "0x" + "11".repeat(32)
    const failed = {
      simulateTransaction: async () => ({
        FailedTransaction: { status: { success: false, error: "boom" } },
      }),
    }
    await expect(isNonceUsed(failed, nonce)).rejects.toThrow(
      /simulation failed/
    )
    const empty = {
      simulateTransaction: async () => ({
        Transaction: { status: { success: true, error: null } },
      }),
    }
    await expect(isNonceUsed(empty, nonce)).rejects.toThrow(/boolean/)
    await expect(isNonceUsed(empty, "0x01")).rejects.toThrow(/64 hex/)
  })
})
