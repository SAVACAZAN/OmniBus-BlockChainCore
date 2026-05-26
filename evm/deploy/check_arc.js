const { JsonRpcProvider, Contract, formatUnits } = require("ethers");
const p = new JsonRpcProvider("https://rpc.testnet.arc.network", 5042002);
const ADDR = "0xc5A63d78B451768Ba1dc799Fb08Ad41c6b37C938";
(async () => {
  try {
    const bal = await p.getBalance(ADDR);
    console.log(`Arc native balance at ${ADDR}: ${bal.toString()} (raw)`);
  } catch (e) {
    console.log(`err: ${e.shortMessage || e.message}`);
  }
})();
