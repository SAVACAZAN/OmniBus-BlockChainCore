/**
 * derive-and-deploy.ts — one-shot deploy that derives slot-6 privkey from
 * the OmniBus mnemonic at runtime, then deploys OmnibusDEX without ever
 * writing the privkey to disk.
 *
 * Reads the mnemonic from one of (in order):
 *   1. OMNIBUS_MNEMONIC env var
 *   2. evm/deploy/.mnemonic file (gitignored)
 *   3. prompts the operator on stdin
 *
 * Run:
 *   cd evm/deploy
 *   npm install
 *   npm run compile
 *   npx ts-node scripts/derive-and-deploy.ts --network sepolia
 *
 * (No need to edit .env at all — the mnemonic is derived once in-memory.)
 */

import { Wallet, JsonRpcProvider, ContractFactory, formatEther, parseEther } from "ethers";
import { HDKey } from "@scure/bip32";
import { mnemonicToSeedSync } from "@scure/bip39";
import * as fs from "fs";
import * as path from "path";
import * as readline from "readline";

const NETWORKS: Record<string, { rpc: string; chainId: number; explorer: string }> = {
  sepolia:     { rpc: "https://sepolia.drpc.org",   chainId: 11155111, explorer: "https://sepolia.etherscan.io" },
  baseSepolia: { rpc: "https://sepolia.base.org",   chainId: 84532,    explorer: "https://sepolia.basescan.org" },
  liberty:     { rpc: "https://rpc.testnet.lcx.com", chainId: 76847801, explorer: "" },
  arbSepolia:  { rpc: "https://sepolia-rollup.arbitrum.io/rpc", chainId: 421614,   explorer: "https://sepolia.arbiscan.io" },
  opSepolia:   { rpc: "https://sepolia.optimism.io",            chainId: 11155420, explorer: "https://sepolia-optimism.etherscan.io" },
  polygonAmoy: { rpc: "https://rpc-amoy.polygon.technology",    chainId: 80002,    explorer: "https://amoy.polygonscan.com" },
  avaxFuji:    { rpc: "https://api.avax-test.network/ext/bc/C/rpc", chainId: 43113, explorer: "https://testnet.snowtrace.io" },
};

const OPERATOR = "0xA66235662c363e9915b6353f79df309F67D146A6"; // slot 2 exchange.omnibus (EIP-55)
const DEPLOYER_SLOT = 6; // tornetwork.omnibus (1.7 ETH on Sepolia)

function parseNetworkArg(): string {
  const i = process.argv.indexOf("--network");
  if (i < 0 || !process.argv[i + 1]) return "sepolia";
  return process.argv[i + 1];
}

async function readMnemonic(): Promise<string> {
  if (process.env.OMNIBUS_MNEMONIC) {
    console.log("[deploy] mnemonic loaded from OMNIBUS_MNEMONIC env var");
    return process.env.OMNIBUS_MNEMONIC.trim();
  }
  const filePath = path.join(__dirname, "..", ".mnemonic");
  if (fs.existsSync(filePath)) {
    const m = fs.readFileSync(filePath, "utf8").trim();
    console.log(`[deploy] mnemonic loaded from ${filePath}`);
    return m;
  }
  // Fallback: ask on stdin. Hidden echo on TTYs that support it.
  return await new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question("Paste OmniBus founder mnemonic (12 or 24 words, space-separated): ", (ans) => {
      rl.close();
      resolve(ans.trim());
    });
  });
}

function loadArtifact(): { abi: any; bytecode: string } {
  const p = path.join(__dirname, "..", "artifacts", "contracts", "OmnibusDEX.sol", "OmnibusDEX.json");
  if (!fs.existsSync(p)) {
    throw new Error(`Artifact missing: ${p}\nRun 'npm run compile' first.`);
  }
  const j = JSON.parse(fs.readFileSync(p, "utf8"));
  return { abi: j.abi, bytecode: j.bytecode };
}

async function main() {
  const netName = parseNetworkArg();
  const net = NETWORKS[netName];
  if (!net) throw new Error(`Unknown network "${netName}". Use one of: ${Object.keys(NETWORKS).join(", ")}`);

  const mnemonic = await readMnemonic();
  const words = mnemonic.split(/\s+/).filter(Boolean);
  if (words.length !== 12 && words.length !== 24) {
    throw new Error(`Mnemonic must be 12 or 24 words; got ${words.length}`);
  }

  // Derive slot 6 (tornetwork.omnibus) at m/44'/60'/0'/0/6 using
  // @scure/bip32+39 — the SAME derivation the OmniBus wallet uses
  // (frontend/src/api/wallet-keystore.ts). ethers' HDNodeWallet gives
  // different addresses for non-zero indices, so we must match scure.
  const seed = mnemonicToSeedSync(words.join(" "));
  const root = HDKey.fromMasterSeed(seed);
  const leaf = root.derive(`m/44'/60'/0'/0/${DEPLOYER_SLOT}`);
  if (!leaf.privateKey) throw new Error("Failed to derive privkey");
  const privHex = "0x" + Buffer.from(leaf.privateKey).toString("hex");
  const provider = new JsonRpcProvider(net.rpc, net.chainId);
  const deployer = new Wallet(privHex, provider);

  console.log(`Network:        ${netName} (chainId ${net.chainId})`);
  console.log(`Deployer:       ${deployer.address}  (slot ${DEPLOYER_SLOT})`);
  const bal = await provider.getBalance(deployer.address);
  console.log(`Deployer bal:   ${formatEther(bal)} ETH`);
  console.log(`Operator (arg): ${OPERATOR}                  (slot 2)`);

  const MIN_BAL = parseEther("0.003");
  if (bal < MIN_BAL) {
    throw new Error(`Deployer balance too low: ${formatEther(bal)} ETH < ${formatEther(MIN_BAL)} ETH`);
  }

  // Quick sanity: derived deployer must match the hardcoded slot-6 EVM
  // address. Otherwise something's wrong with the mnemonic and we should
  // bail before broadcasting a deploy from an unknown key.
  const EXPECTED = "0xc5A63d78B451768Ba1dc799Fb08Ad41c6b37C938";
  if (deployer.address.toLowerCase() !== EXPECTED.toLowerCase()) {
    throw new Error(
      `Derived slot-6 address ${deployer.address} ≠ expected ${EXPECTED}.\n` +
      `Wrong mnemonic or derivation path — aborting before broadcast.`,
    );
  }

  const { abi, bytecode } = loadArtifact();
  const factory = new ContractFactory(abi, bytecode, deployer);
  console.log("Submitting deploy tx…");
  const contract = await factory.deploy(OPERATOR);
  const deployTx = contract.deploymentTransaction();
  console.log(`tx hash: ${deployTx?.hash}`);
  if (net.explorer && deployTx?.hash) console.log(`         ${net.explorer}/tx/${deployTx.hash}`);

  await contract.waitForDeployment();
  const address = await contract.getAddress();
  console.log(`\n✓ OmnibusDEX deployed at: ${address}`);
  if (net.explorer) console.log(`         ${net.explorer}/address/${address}`);

  // Persist into evm/deployed_addresses.json under the chain id.
  const registryPath = path.join(__dirname, "..", "..", "deployed_addresses.json");
  let registry: any = {};
  try { registry = JSON.parse(fs.readFileSync(registryPath, "utf8")); } catch {}
  registry.OmnibusDEX = registry.OmnibusDEX ?? {};
  registry.OmnibusDEX[String(net.chainId)] = {
    network: netName,
    address,
    deployer: deployer.address,
    operator: OPERATOR,
    tx: deployTx?.hash ?? null,
    deployed: new Date().toISOString().slice(0, 10),
    compiler: "solc 0.8.24 optimizer 200 runs",
  };
  fs.writeFileSync(registryPath, JSON.stringify(registry, null, 2) + "\n");
  console.log(`✓ Address persisted to ${registryPath}`);
  console.log(`\nNext: update frontend/src/api/chains.ts with dexContract: "${address}"`);
}

main().catch((err) => { console.error("FAILED:", err.message ?? err); process.exit(1); });
