const { JsonRpcProvider, Contract, formatUnits } = require("ethers");
const p = new JsonRpcProvider("https://sepolia.base.org", 84532);
const USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const abi = ["function balanceOf(address) view returns (uint256)"];
const c = new Contract(USDC, abi, p);
const buyer = "0x58096A6921774938760a4b00062B92983c1Ca8C7"; // founder slot 0
const dev   = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"; // dev abandon11x slot 0
(async () => {
  console.log(`founder USDC (Base Sepolia): ${formatUnits(await c.balanceOf(buyer), 6)} USDC`);
  console.log(`dev     USDC (Base Sepolia): ${formatUnits(await c.balanceOf(dev), 6)} USDC`);
})();
