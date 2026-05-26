const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { Wallet, JsonRpcProvider, parseEther, formatEther } = require("ethers");
const fs = require("fs");

const m = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(m));
const slot6 = root.derive("m/44'/60'/0'/0/6");
const OPERATOR = "0xA66235662c363e9915b6353f79df309F67D146A6";

const CHAINS = [
  ["Arb Sep", "https://sepolia-rollup.arbitrum.io/rpc", 421614],
  ["OP Sep",  "https://sepolia.optimism.io",            11155420],
  ["Minato",  "https://rpc.minato.soneium.org",         1946],
];

(async () => {
  for (const [n, url, chainId] of CHAINS) {
    try {
      const p = new JsonRpcProvider(url, chainId);
      const w = new Wallet("0x" + Buffer.from(slot6.privateKey).toString("hex"), p);
      const balOp = await p.getBalance(OPERATOR);
      if (balOp >= parseEther("0.005")) { console.log(`${n}: operator funded, skip`); continue; }
      const tx = await w.sendTransaction({ to: OPERATOR, value: parseEther("0.02") });
      console.log(`${n}: fund tx ${tx.hash}`);
      await tx.wait();
      console.log(`${n}: operator now ${formatEther(await p.getBalance(OPERATOR))} ETH`);
    } catch (e) { console.log(`${n}: err ${e.shortMessage||e.message}`); }
  }
})();
