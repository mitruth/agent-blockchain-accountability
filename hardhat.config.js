import "dotenv/config";

export default {
  solidity: "0.8.23",
  networks: {
    baseSepolia: {
      type: "http",
      url: process.env.ALCHEMY_RPC_URL || "https://sepolia.base.org",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      chainId: 84532,
    },
  },
};
