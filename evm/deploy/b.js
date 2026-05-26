const { JsonRpcProvider, Contract, formatEther } = require("ethers");
const p = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const WETH = "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14";
const WETH_ABI = [{name:"balanceOf",type:"function",stateMutability:"view",inputs:[{name:"who",type:"address"}],outputs:[{name:"",type:"uint256"}]}];
(async () => {
  for (const [name, a] of [["User B slot 0", "0x58096a6921774938760a4b00062b92983c1ca8c7"], ["User A slot 0", "0x9858effd232b4033e47d90003d41ec34ecaeda94"]]) {
    const eth = await p.getBalance(a);
    const weth = await new Contract(WETH, WETH_ABI, p).balanceOf(a);
    console.log(`${name}: ${formatEther(eth)} ETH, ${formatEther(weth)} WETH`);
  }
})();
