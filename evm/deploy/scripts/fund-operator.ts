/**
 * fund-operator.ts — one-shot top-up of the DEX operator slot (#2) from
 * the deployer slot (#6). Run after deploy so settle() calls have gas.
 *
 *   npx ts-node scripts/fund-operator.ts --network sepolia --amount 0.05
 */
import { Wallet, JsonRpcProvider, parseEther, formatEther } from "ethers";
import { HDKey } from "@scure/bip32";
import { mnemonicToSeedSync } from "@scure/bip39";
import * as fs from "fs";
import * as path from "path";

const NETWORKS: Record<string, { rpc: string; chainId: number }> = {
  sepolia:     { rpc: "https://sepolia.drpc.org", chainId: 11155111 },
  baseSepolia: { rpc: "https://sepolia.base.org", chainId: 84532 },
};

function arg(name: string, dflt = ""): string {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : dflt;
}

async function main() {
  const netName = arg("--network", "sepolia");
  const amount  = arg("--amount", "0.05");
  const net = NETWORKS[netName];
  if (!net) throw new Error(`Unknown network: ${netName}`);

  const mn = fs.readFileSync(path.join(__dirname, "..", ".mnemonic"), "utf8").trim();
  const seed = mnemonicToSeedSync(mn);
  const root = HDKey.fromMasterSeed(seed);
  const fromLeaf = root.derive(`m/44'/60'/0'/0/6`);
  const toLeaf   = root.derive(`m/44'/60'/0'/0/2`);
  if (!fromLeaf.privateKey) throw new Error("derive from failed");

  const provider = new JsonRpcProvider(net.rpc, net.chainId);
  const wallet = new Wallet("0x" + Buffer.from(fromLeaf.privateKey).toString("hex"), provider);
  const fromAddr = wallet.address;
  const toAddrLeaf = toLeaf.publicKey;
  // Derive address the same way as the rest of the codebase.
  const { secp256k1 } = await import("@noble/curves/secp256k1");
  const { keccak_256 } = await import("@noble/hashes/sha3");
  const point = secp256k1.ProjectivePoint.fromHex(toAddrLeaf!);
  const toAddr = "0x" + Buffer.from(keccak_256(point.toRawBytes(false).slice(1)).slice(12)).toString("hex");

  console.log(`From slot 6: ${fromAddr}`);
  console.log(`To   slot 2: ${toAddr}`);
  console.log(`Amount:      ${amount} ETH`);

  const tx = await wallet.sendTransaction({ to: toAddr, value: parseEther(amount) });
  console.log(`tx: ${tx.hash}`);
  const r = await tx.wait();
  console.log(`✓ mined in block ${r?.blockNumber}`);

  const newBal = await provider.getBalance(toAddr);
  console.log(`slot 2 new balance: ${formatEther(newBal)} ETH`);
}

main().catch((e) => { console.error(e); process.exit(1); });
