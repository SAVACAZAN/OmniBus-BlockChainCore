const { JsonRpcProvider, Contract, formatEther } = require("ethers");
const OPERATOR = "0xA66235662c363e9915b6353f79df309F67D146A6";
const DEX = "0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB";
const abi = ["function operator() view returns (address)"];

const CHAINS = [
  ["Arb Sep", "https://sepolia-rollup.arbitrum.io/rpc"],
  ["OP Sep",  "https://sepolia.optimism.io"],
  ["Minato",  "https://rpc.minato.soneium.org"],
];

(async () => {
  for (const [n, u] of CHAINS) {
    try {
      const p = new JsonRpcProvider(u);
      const bal = await p.getBalance(OPERATOR);
      const c = new Contract(DEX, abi, p);
      const op = await c.operator();
      const match = op.toLowerCase() === OPERATOR.toLowerCase();
      console.log(`${n.padEnd(8)}: operator_balance=${formatEther(bal)} ETH, contract_operator=${op} ${match?"OK":"MISMATCH"}`);
    } catch(e) { console.log(`${n}: err ${e.shortMessage||e.message}`); }
  }
})();
