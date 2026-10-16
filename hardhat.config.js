import "dotenv/config";

// Three keys, never one. The audited config loaded a single PRIVATE_KEY that
// held both owner and agent authority, which is finding F1. Scripts pick the
// account for the role they act as; nothing defaults to "the" key.
const accounts = [
  process.env.OWNER_PRIVATE_KEY,
  process.env.AGENT_PRIVATE_KEY,
  process.env.GUARDIAN_PRIVATE_KEY,
].filter(Boolean);

export default {
  solidity: {
    version: "0.8.25",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: "cancun",
    },
  },
  paths: {
    sources: "contracts",
    tests: { solidity: "test" },
  },
  networks: {
    baseSepolia: {
      type: "http",
      url: process.env.ALCHEMY_RPC_URL || "https://sepolia.base.org",
      accounts,
      chainId: 84532,
    },
  },
};
