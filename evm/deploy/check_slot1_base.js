const { JsonRpcProvider, Contract, formatUnits, formatEther } = require("ethers");
const p = new JsonRpcProvider("https://sepolia.base.org", 84532);
const USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const SLOT1 = "0x2680Cf2201300F4eCF3fd8a592D9aA760122C3E0";
const erc = ["function balanceOf(address) view returns (uint256)"];
const c = new Contract(USDC, erc, p);
(async () => {
  console.log(`slot 1 ${SLOT1}`);
  console.log(`  ETH:  ${formatEther(await p.getBalance(SLOT1))} ETH`);
  console.log(`  USDC: ${formatUnits(await c.balanceOf(SLOT1), 6)} USDC`);
})();
