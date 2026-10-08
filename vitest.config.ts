import { configDefaults, defineConfig } from "vitest/config"

export default defineConfig({
  test: {
    // Foundry dependencies (forwarders/evm/lib, git-ignored) ship their own JS tests.
    exclude: [...configDefaults.exclude, "forwarders/evm/lib/**"],
  },
})
