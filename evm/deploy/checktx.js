const { JsonRpcProvider, formatEther } = require("ethers");
const p = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
(async () => {
  // User A dev EVM slot 0 (where settler should deliver ETH)
  const userA = "0x9858effd232b4033e47d90003d41ec34ecaeda94";
  const userB = "0x58096a6921774938760a4b00062b92983c1ca8c7"; // savacazan slot 0
  const dex = "0xC21fD92e5f568a7981d16b9008E3C190842818aE";
  console.log("User A (seller, dev) Sepolia balance:", formatEther(await p.getBalance(userA)), "ETH");
  console.log("User B (buyer, savacazan):           ", formatEther(await p.getBalance(userB)), "ETH");
  console.log("OmnibusDEX contract:                 ", formatEther(await p.getBalance(dex)), "ETH (escrowed)");
})();
