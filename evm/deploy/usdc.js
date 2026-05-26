const { JsonRpcProvider, Contract, formatUnits } = require("ethers");
const USDC_ABI = [{name:"balanceOf",type:"function",stateMutability:"view",inputs:[{name:"a",type:"address"}],outputs:[{type:"uint256"}]},{name:"decimals",type:"function",stateMutability:"view",inputs:[],outputs:[{type:"uint8"}]}];
// Circle official USDC on Sepolia
const USDC = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";
const p = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const c = new Contract(USDC, USDC_ABI, p);
(async () => {
  for (const [name, a] of [
    ["User A (dev abandon) slot 0", "0x9858effd232b4033e47d90003d41ec34ecaeda94"],
    ["User B (savacazan) slot 0",   "0x58096a6921774938760a4b00062b92983c1ca8c7"],
  ]) {
    const bal = await c.balanceOf(a);
    console.log(`${name}: ${formatUnits(bal, 6)} USDC`);
  }
})();
