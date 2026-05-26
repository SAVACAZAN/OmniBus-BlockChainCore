const { JsonRpcProvider, formatEther } = require("ethers");
const p = new JsonRpcProvider("https://sepolia.base.org", 84532);
const DEPLOYER = "0xc5A63d78B451768Ba1dc799Fb08Ad41c6b37C938"; // slot 6 tornetwork
const OPERATOR = "0xA66235662c363e9915b6353f79df309F67D146A6"; // slot 2 exchange
(async () => {
  console.log("Base Sepolia balances:");
  console.log(`  deployer (slot 6): ${formatEther(await p.getBalance(DEPLOYER))} ETH`);
  console.log(`  operator (slot 2): ${formatEther(await p.getBalance(OPERATOR))} ETH`);
})();
