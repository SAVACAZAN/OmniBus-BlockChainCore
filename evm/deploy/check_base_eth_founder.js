const { JsonRpcProvider, formatEther } = require("ethers");
const p = new JsonRpcProvider("https://sepolia.base.org", 84532);
const FOUNDER = "0x58096A6921774938760a4b00062B92983c1Ca8C7";
(async () => {
  console.log(`founder ETH (Base Sepolia): ${formatEther(await p.getBalance(FOUNDER))} ETH`);
})();
