import "dotenv/config";

// Two keys, never one (audit finding F1): the owner's, and the agent's
// session key. Only for Base Sepolia; the tests and the local demo use
// Hardhat's public test keys.
const accounts = [process.env.OWNER_PRIVATE_KEY, process.env.AGENT_PRIVATE_KEY].filter(Boolean);

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
