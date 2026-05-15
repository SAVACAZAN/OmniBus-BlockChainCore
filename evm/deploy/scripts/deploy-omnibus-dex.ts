/**
 * deploy-omnibus-dex.ts — deploy OmnibusDEX.sol on the network Hardhat
 * was invoked with (`--network sepolia`, `--network baseSepolia`, etc.).
 *
 * Reads:
 *   - DEPLOYER_PRIVKEY     from .env  → wallet that pays gas
 *   - OPERATOR_EVM_ADDRESS from .env  → constructor arg `_operator`
 *
 * Writes:
 *   - The deployed address into evm/deployed_addresses.json under the
 *     network's chain id, so chains.ts can pick it up without a manual
 *     copy-paste step.
 *
 * Run:
 *   cd evm/deploy
 *   npm install      # one-time
 *   npm run compile  # one-time
 *   npm run deploy:sepolia
 */

import { ethers, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Default operator = slot 2 (exchange.omnibus) from registrar_addresses.zig.
// Override with OPERATOR_EVM_ADDRESS in .env if testing with a different key.
const DEFAULT_OPERATOR = "0x2680Cf2201300F4eCF3fd8a592D9aA760122C3E0";

async function main() {
  const operator = (process.env.OPERATOR_EVM_ADDRESS ?? DEFAULT_OPERATOR).trim();

  if (!ethers.isAddress(operator)) {
    throw new Error(`OPERATOR_EVM_ADDRESS is not a valid EVM address: ${operator}`);
  }

  const [deployer] = await ethers.getSigners();
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Network:        ${network.name} (chainId ${network.config.chainId})`);
  console.log(`Deployer:       ${deployer.address}`);
  console.log(`Deployer bal:   ${ethers.formatEther(balance)} ETH`);
  console.log(`Operator (arg): ${operator}`);

  // Sanity: deploy needs roughly 0.005 ETH worth of gas on Sepolia. If the
  // deployer has noticeably less, refuse to send — a half-broadcast that
  // runs out of gas mid-deploy is the worst outcome (paid gas, no contract).
  const MIN_BAL = ethers.parseEther("0.003");
  if (balance < MIN_BAL) {
    throw new Error(
      `Deployer balance too low: have ${ethers.formatEther(balance)} ETH, need at least ${ethers.formatEther(MIN_BAL)}`,
    );
  }

  const Factory = await ethers.getContractFactory("OmnibusDEX");
  const dex = await Factory.deploy(operator);
  console.log(`Submitting deploy tx: ${dex.deploymentTransaction()?.hash}`);

  await dex.waitForDeployment();
  const address = await dex.getAddress();
  console.log(`✓ OmnibusDEX deployed at: ${address}`);

  // Persist the address so chains.ts + the Zig settler can read it without
  // a manual edit. File layout follows the existing OmnibusHTLC entry.
  const registryPath = path.join(__dirname, "..", "..", "deployed_addresses.json");
  let registry: any = {};
  try {
    registry = JSON.parse(fs.readFileSync(registryPath, "utf8"));
  } catch {
    // First-time deploy on a fresh checkout — create the file fresh.
  }
  registry.OmnibusDEX = registry.OmnibusDEX ?? {};
  registry.OmnibusDEX[String(network.config.chainId)] = {
    network: network.name,
    address,
    deployer: deployer.address,
    operator,
    tx: dex.deploymentTransaction()?.hash ?? null,
    deployed: new Date().toISOString().slice(0, 10),
    compiler: "solc 0.8.24 optimizer 200 runs",
  };
  fs.writeFileSync(registryPath, JSON.stringify(registry, null, 2) + "\n");
  console.log(`✓ Wrote address to ${registryPath}`);
  console.log(`\nNext steps:`);
  console.log(`  1. Update frontend/src/api/chains.ts → CHAINS[*].dexContract = "${address}"`);
  console.log(`  2. Top up slot 2 (${operator}) with ~0.01 ETH so settle() has gas`);
  console.log(`  3. Restart the node so dex_settler picks up the new contract`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
