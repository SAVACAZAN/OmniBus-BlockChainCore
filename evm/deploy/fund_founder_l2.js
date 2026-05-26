// Transfer 0.01 ETH from slot 6 (deployer) to slot 0 (founder/buyer) on
// Arb Sepolia, OP Sepolia, and Soneium Minato so we can lock escrow.
const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { Wallet, JsonRpcProvider, parseEther, formatEther } = require("ethers");
const fs = require("fs");

const m = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(m));
const slot6 = root.derive("m/44'/60'/0'/0/6");
const FOUNDER = "0x58096A6921774938760a4b00062B92983c1Ca8C7";

const CHAINS = [
  ["Arb Sep",  "https://sepolia-rollup.arbitrum.io/rpc", 421614],
  ["OP Sep",   "https://sepolia.optimism.io",            11155420],
  ["Minato",   "https://rpc.minato.soneium.org",         1946],
];

(async () => {
  for (const [n, url, chainId] of CHAINS) {
    try {
      const p = new JsonRpcProvider(url, chainId);
      const w = new Wallet("0x" + Buffer.from(slot6.privateKey).toString("hex"), p);
      const balDep = await p.getBalance(w.address);
      const balFnd = await p.getBalance(FOUNDER);
      console.log(`${n}: deployer=${formatEther(balDep)}, founder=${formatEther(balFnd)}`);
      if (balFnd >= parseEther("0.005")) {
        console.log(`  founder already funded, skip`);
        continue;
      }
      if (balDep < parseEther("0.012")) {
        console.log(`  deployer too low, skip`);
        continue;
      }
      const tx = await w.sendTransaction({ to: FOUNDER, value: parseEther("0.01") });
      console.log(`  fund tx: ${tx.hash}`);
      await tx.wait();
      const after = await p.getBalance(FOUNDER);
      console.log(`  founder now: ${formatEther(after)}`);
    } catch (e) {
      console.log(`${n}: err ${e.shortMessage || e.message}`);
    }
  }
})();
