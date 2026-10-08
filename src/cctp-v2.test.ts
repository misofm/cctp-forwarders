import { describe, expect, it, vi } from "vitest"
import {
  decodeBurnMessage,
  fetchIrisMessages,
  findForwarderBurns,
  forwarderBurnProblem,
  SUI_MESSAGE_RECIPIENT,
} from "./cctp-v2"
import { EVM_CHAINS, type EvmChain } from "./evm-forwarder"
import irisAvalanche from "../fixtures/cctp-v2/iris-avalanche.json"
import irisPolygon from "../fixtures/cctp-v2/iris-polygon.json"
import burnAvalanche from "../fixtures/cctp-v2/evm-burn-avalanche.json"
import burnPolygon from "../fixtures/cctp-v2/evm-burn-polygon.json"

const hexToBytes = (hex: string) =>
  Uint8Array.from(Buffer.from(hex.slice(2), "hex"))

// Real attested burns by ordinary depositors, standing in for forwarders.
const CASES = [
  ["avalanche", irisAvalanche, burnAvalanche],
  ["polygon", irisPolygon, burnPolygon],
] as const

const response = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status })

describe.each(CASES)("%s", (chain, iris, burn) => {
  const entry = iris.byTransactionHash.body.messages[0]
  const message = hexToBytes(entry.message)
  const decoded = decodeBurnMessage(message)
  const expected = {
    chain: chain as EvmChain,
    forwarder: "0x" + decoded.messageSender.slice(26),
    recipient: decoded.mintRecipient,
  }

  it("fetchIrisMessages parses the captured response", async () => {
    const fetchFn = vi.fn(async () =>
      response(200, iris.byTransactionHash.body)
    )
    const got = await fetchIrisMessages(fetchFn as typeof fetch, {
      chain,
      transactionHash: iris.sourceTxHash.toUpperCase().replace("0X", "0x"),
    })
    expect(fetchFn).toHaveBeenCalledWith(
      `https://iris-api.circle.com/v2/messages/${EVM_CHAINS[chain].domain}?transactionHash=${iris.sourceTxHash}`
    )
    expect(got).toEqual([
      {
        status: "complete",
        message,
        attestation: hexToBytes(entry.attestation),
      },
    ])
  })

  it("decodeBurnMessage reads the fields", () => {
    const d = entry.decodedMessage
    expect(decoded).toEqual({
      sourceDomain: Number(d.sourceDomain),
      nonce: d.nonce,
      mintRecipient: d.decodedMessageBody.mintRecipient,
      messageSender:
        "0x" + d.decodedMessageBody.messageSender.slice(2).padStart(64, "0"),
      amount: BigInt(d.decodedMessageBody.amount),
      maxFee: 0n,
      feeExecuted: 0n,
    })
    expect(expected.forwarder).toBe(burn.depositor)
    expect(() => decodeBurnMessage(message.subarray(0, 375))).toThrow()
  })

  it("forwarderBurnProblem accepts the real message", () => {
    expect(forwarderBurnProblem(message, expected)).toBeNull()
  })

  it("forwarderBurnProblem rejects other forwarders, recipients and chains", () => {
    const other = chain === "avalanche" ? "polygon" : "avalanche"
    for (const e of [
      { ...expected, forwarder: "0x" + "11".repeat(20) },
      { ...expected, recipient: "0x" + "11".repeat(32) },
      { ...expected, chain: other as EvmChain },
    ])
      expect(forwarderBurnProblem(message, e)).toMatch(/differs/)
  })

  it("forwarderBurnProblem rejects any tampered byte outside the attester-filled fields", () => {
    // Attester-filled, or amount/maxFee (taken from the message, tested below).
    const skip = [
      [12, 44],
      [144, 148],
      [216, 248],
      [280, 376],
    ]
    for (let i = 0; i < message.length; i++) {
      if (skip.some(([a, b]) => i >= a && i < b)) continue
      const m = message.slice()
      m[i] ^= 1
      expect(forwarderBurnProblem(m, expected), `byte ${i}`).toMatch(/differs/)
    }
  })

  it("forwarderBurnProblem rejects a zero nonce, a fee above 1%, zero amount and extra bytes", () => {
    const set = (offset: number, value: bigint) => {
      const m = message.slice()
      m.set(hexToBytes("0x" + value.toString(16).padStart(64, "0")), offset)
      return m
    }
    expect(forwarderBurnProblem(set(12, 0n), expected)).toMatch(/nonce/)
    expect(
      forwarderBurnProblem(set(280, decoded.amount / 100n), expected)
    ).toBeNull()
    expect(
      forwarderBurnProblem(set(280, decoded.amount / 100n + 1n), expected)
    ).toMatch(/maxFee/)
    expect(forwarderBurnProblem(set(216, 0n), expected)).toMatch(/amount/)
    const long = new Uint8Array(message.length + 1)
    long.set(message)
    expect(forwarderBurnProblem(long, expected)).toMatch(/length/)
  })

  it("findForwarderBurns checks the chain id and returns the captured burn", async () => {
    const calls: Array<{ method: string; params: unknown[] }> = []
    const rpc = (chainId: string, logs: unknown) => ({
      request: async (args: { method: string; params: unknown[] }) => {
        calls.push(args)
        return args.method === "eth_chainId" ? chainId : logs
      },
    })
    const ok = rpc("0x" + burn.chainId.toString(16), burn.getLogsResult)
    const args = {
      chain,
      forwarder: burn.depositor,
      fromBlock: BigInt(burn.blockNumber),
      toBlock: Number(burn.blockNumber),
    }
    expect(await findForwarderBurns(ok, args)).toEqual([
      {
        transactionHash: burn.transactionHash,
        blockNumber: BigInt(burn.blockNumber),
        amount: BigInt(entry.decodedMessage.decodedMessageBody.amount),
      },
    ])
    expect(calls.at(-1)!.params[0]).toEqual({
      ...burn.getLogsFilter,
      topics: burn.getLogsFilter.topics.slice(0, 3),
    })
    await findForwarderBurns(ok, { ...args, toBlock: "finalized" })
    expect(calls.at(-1)!.params[0]).toMatchObject({ toBlock: "finalized" })

    const other = chain === "avalanche" ? 137 : 43114
    await expect(
      findForwarderBurns(rpc("0x" + other.toString(16), []), args)
    ).rejects.toThrow(/chain id/)
    await expect(
      findForwarderBurns(ok, { ...args, toBlock: "latest" as "finalized" })
    ).rejects.toThrow(/invalid block/)
    for (const log of [
      { ...burn.getLogsResult[0], address: EVM_CHAINS[chain].usdc },
      { ...burn.getLogsResult[0], removed: true },
      {
        ...burn.getLogsResult[0],
        topics: burn.getLogsResult[0].topics.map((t, i) =>
          i === 2 ? "0x" + "11".repeat(32) : t
        ),
      },
    ])
      await expect(
        findForwarderBurns(rpc("0x" + burn.chainId.toString(16), [log]), args)
      ).rejects.toThrow(/does not match/)
  })
})

describe("fetchIrisMessages", () => {
  const call = (status: number, body: unknown) =>
    fetchIrisMessages(async () => response(status, body), {
      chain: "polygon",
      transactionHash: "0x" + "ab".repeat(32),
    })

  it("reports pending entries, 404 as null, and throws on other errors", async () => {
    expect(
      await call(200, {
        messages: [
          {
            status: "pending_confirmations",
            message: "0x",
            attestation: "PENDING",
          },
          { status: "complete", message: "0x00", attestation: "PENDING" },
        ],
      })
    ).toEqual([{ status: "pending" }, { status: "pending" }])
    expect(await call(404, { error: "Message not found" })).toBeNull()
    await expect(call(500, {})).rejects.toThrow(/500/)
    await expect(call(429, {})).rejects.toThrow(/429/)
    await expect(call(200, {})).rejects.toThrow()
    await expect(call(200, { messages: [null] })).rejects.toThrow()
    await expect(
      fetchIrisMessages(async () => new Response("not json"), {
        chain: "polygon",
        transactionHash: "0x" + "ab".repeat(32),
      })
    ).rejects.toThrow()
  })
})

it("every real message is addressed to SUI_MESSAGE_RECIPIENT", () => {
  for (const [, iris] of CASES)
    expect(
      iris.byTransactionHash.body.messages[0].decodedMessage.recipient
    ).toBe(SUI_MESSAGE_RECIPIENT)
})
