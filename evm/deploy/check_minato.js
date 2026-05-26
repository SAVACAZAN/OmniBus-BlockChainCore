const { JsonRpcProvider, formatEther } = require("ethers");
const p = new JsonRpcProvider("https://rpc.minato.soneium.org", 1946);
const ADDR = "0xc5A63d78B451768Ba1dc799Fb08Ad41c6b37C938";
(async () => {
  console.log(`Minato ETH at ${ADDR}: ${formatEther(await p.getBalance(ADDR))}`);
})();
