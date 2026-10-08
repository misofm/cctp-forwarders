import { expect, it } from "vitest"
import {
  create2Address,
  evmChain,
  FORWARDER_INSTANCE,
  forwarderAddress,
  type EvmChain,
} from "./evm-forwarder"
import vectors from "../forwarders/evm/fixtures/address-vectors.json"

it("the instance is the CREATE2 address of the fixture's init code", () => {
  expect(
    create2Address(vectors.create2Deployer, vectors.salt, vectors.initCodeHash)
  ).toBe(vectors.instance)
  expect(FORWARDER_INSTANCE).toBe(vectors.instance)
})

it("reproduces every Solidity address vector", () => {
  expect(vectors.vectors.length).toBeGreaterThan(0)
  for (const { recipient, address } of vectors.vectors)
    expect(forwarderAddress(recipient)).toBe(address)
})

it("rejects malformed recipients", () => {
  for (const r of [
    "0x" + "00".repeat(32),
    "0x" + "11".repeat(31),
    "0x" + "11".repeat(33),
    "0x" + "zz".repeat(32),
    "11".repeat(32),
  ])
    expect(() => forwarderAddress(r)).toThrow()
})

it("rejects unknown chains", () => {
  for (const chain of ["ethereum", "toString"])
    expect(() => evmChain(chain as EvmChain)).toThrow(/unknown chain/)
})
