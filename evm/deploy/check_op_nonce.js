const { JsonRpcProvider } = require("ethers");
const p = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
(async () => {
  const op = "0xA66235662c363e9915b6353f79df309F67D146A6";
  console.log(`nonce latest:  ${await p.getTransactionCount(op, "latest")}`);
  console.log(`nonce pending: ${await p.getTransactionCount(op, "pending")}`);
})();
