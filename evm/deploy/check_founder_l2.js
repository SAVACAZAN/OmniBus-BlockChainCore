const { JsonRpcProvider, formatEther } = require("ethers");
const FOUNDER = "0x58096A6921774938760a4b00062B92983c1Ca8C7";
const CHAINS = [
  ["Sepolia",  "https://ethereum-sepolia-rpc.publicnode.com"],
  ["Base Sep", "https://sepolia.base.org"],
  ["Arb Sep",  "https://sepolia-rollup.arbitrum.io/rpc"],
  ["OP Sep",   "https://sepolia.optimism.io"],
  ["Minato",   "https://rpc.minato.soneium.org"],
];
(async () => {
  for (const [n, u] of CHAINS) {
    try {
      const p = new JsonRpcProvider(u);
      const b = await p.getBalance(FOUNDER);
      console.log(`${n.padEnd(9)}: ${formatEther(b)} ETH`);
    } catch(e) { console.log(`${n}: err`); }
  }
})();
