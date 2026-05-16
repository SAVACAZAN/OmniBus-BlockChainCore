import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";
import * as path from "path";

// Load .env from this directory (NOT the repo root) so the privkey file
// stays scoped to the deploy harness and the parent gitignore can ignore
// just evm/deploy/.env without touching anything else.
dotenv.config({ path: path.join(__dirname, ".env") });

const DEPLOYER_PRIVKEY = process.env.DEPLOYER_PRIVKEY ?? "";

// Refuse to spin up Hardhat with an empty privkey — better a loud crash
// at config-load than a silent fallback to a default test account that
// has no ETH on the target network.
if (!DEPLOYER_PRIVKEY) {
  // Allow `hardhat compile` (which doesn't need a privkey) without
  // erroring. Compile path doesn't dereference accounts.
  if (!process.argv.some((a) => a === "compile")) {
    throw new Error(
      "DEPLOYER_PRIVKEY missing — create evm/deploy/.env with DEPLOYER_PRIVKEY=0x… (slot 6 = tornetwork.omnibus key)",
    );
  }
}

const accounts = DEPLOYER_PRIVKEY ? [DEPLOYER_PRIVKEY] : [];

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },

  // Contracts live in evm/contracts/. Hardhat refuses sources outside its
  // project root, so we keep a mirror in evm/deploy/contracts/. The
  // canonical source is still evm/contracts/OmnibusDEX.sol — copy on
  // change or use a pre-deploy step to sync.
  paths: {
    sources: "./contracts",
    artifacts: "./artifacts",
    cache: "./cache",
  },

  networks: {
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL ?? "https://sepolia.drpc.org",
      chainId: 11155111,
      accounts,
    },
    baseSepolia: {
      url: process.env.BASE_SEPOLIA_RPC_URL ?? "https://sepolia.base.org",
      chainId: 84532,
      accounts,
    },
    liberty: {
      url: process.env.LIBERTY_RPC_URL ?? "https://rpc.testnet.lcx.com",
      chainId: 76847801,
      accounts,
    },
    arbSepolia: {
      url: process.env.ARB_SEPOLIA_RPC_URL ?? "https://sepolia-rollup.arbitrum.io/rpc",
      chainId: 421614,
      accounts,
    },
    opSepolia: {
      url: process.env.OP_SEPOLIA_RPC_URL ?? "https://sepolia.optimism.io",
      chainId: 11155420,
      accounts,
    },
    polygonAmoy: {
      url: process.env.POLYGON_AMOY_RPC_URL ?? "https://rpc-amoy.polygon.technology",
      chainId: 80002,
      accounts,
    },
    avaxFuji: {
      url: process.env.AVAX_FUJI_RPC_URL ?? "https://api.avax-test.network/ext/bc/C/rpc",
      chainId: 43113,
      accounts,
    },
  },

  // Optional Etherscan/Basescan keys for `npm run verify`. Not required
  // for deploy — only for verifying source on the explorer afterwards.
  etherscan: {
    apiKey: {
      sepolia:     process.env.ETHERSCAN_API_KEY ?? "",
      baseSepolia: process.env.BASESCAN_API_KEY ?? "",
    },
  },
};

export default config;
