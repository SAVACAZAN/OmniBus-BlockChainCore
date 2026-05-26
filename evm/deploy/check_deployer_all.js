const { JsonRpcProvider, formatEther } = require("ethers");
const DEPLOYER = "0xc5A63d78B451768Ba1dc799Fb08Ad41c6b37C938";
const CHAINS = [
  ["Arb Sep",    "https://sepolia-rollup.arbitrum.io/rpc"],
  ["OP Sep",     "https://sepolia.optimism.io"],
  ["Amoy",       "https://rpc-amoy.polygon.technology"],
  ["Fuji",       "https://api.avax-test.network/ext/bc/C/rpc"],
  ["Liberty",    "https://rpc.testnet.lcx.com"],
];
(async () => {
  for (const [name, url] of CHAINS) {
    try {
      const p = new JsonRpcProvider(url);
      const b = await p.getBalance(DEPLOYER);
      console.log(`${name.padEnd(10)}: ${formatEther(b)} native`);
    } catch (e) {
      console.log(`${name.padEnd(10)}: ERROR ${e.shortMessage || e.message}`);
    }
  }
})();
