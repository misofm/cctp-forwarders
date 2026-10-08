import { describe, expect, it } from "vitest"
import {
  create2Address,
  EVM_CHAINS,
  forwarderAddress,
  type EvmChain,
} from "./evm-forwarder"
import vectors from "../forwarders/evm/fixtures/address-vectors.json"

const CHAINS = Object.keys(EVM_CHAINS) as EvmChain[]

describe.each(CHAINS)("%s", (chain) => {
  const v = vectors.chains[chain]

  it("factory is the CREATE2 address of the fixture's init code", () => {
    expect(
      create2Address(vectors.create2Deployer, vectors.salt, v.initCodeHash)
    ).toBe(v.factory)
    expect(EVM_CHAINS[chain].factory).toBe(v.factory)
    expect(EVM_CHAINS[chain].chainId).toBe(v.chainId)
    expect(EVM_CHAINS[chain].usdc).toBe(v.usdc.toLowerCase())
    expect(EVM_CHAINS[chain].tokenMessenger).toBe(v.messenger.toLowerCase())
  })

  it("reproduces every Solidity address vector", () => {
    expect(v.vectors.length).toBeGreaterThan(0)
    for (const { recipient, address } of v.vectors)
      expect(forwarderAddress(chain, recipient)).toBe(address)
  })
})

it("the address differs per chain for the same recipient", () => {
  const r = "0x" + "ab".repeat(32)
  expect(forwarderAddress("avalanche", r)).not.toBe(
    forwarderAddress("polygon", r)
  )
})

it("rejects malformed recipients and unknown chains", () => {
  for (const r of [
    "0x" + "00".repeat(32),
    "0x" + "11".repeat(31),
    "0x" + "11".repeat(33),
    "0x" + "zz".repeat(32),
    "11".repeat(32),
  ])
    expect(() => forwarderAddress("avalanche", r)).toThrow()
  expect(() =>
    forwarderAddress("ethereum" as EvmChain, "0x" + "11".repeat(32))
  ).toThrow(/unknown chain/)
  expect(() =>
    forwarderAddress("toString" as EvmChain, "0x" + "11".repeat(32))
  ).toThrow(/unknown chain/)
})
