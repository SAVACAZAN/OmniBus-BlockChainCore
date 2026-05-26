const { JsonRpcProvider, formatEther } = require("ethers");
const p = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
(async () => {
  const userA = "0x9858effd232b4033e47d90003d41ec34ecaeda94";
  const bal = await p.getBalance(userA);
  console.log("User A:", userA);
  console.log("       balance:", formatEther(bal), "ETH");
  console.log("       wei:", bal.toString());
})();
