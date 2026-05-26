const { JsonRpcProvider, Contract, formatUnits } = require("ethers");
const p = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const TX = "0xb5ed8b6a442911dfa8b5c2460754c3a4e184fd21156ed8ade6987fac56bd6957";
const USDC = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";
const DEX = "0xC21fD92e5f568a7981d16b9008E3C190842818aE";
const SELLER = "0x9858effd232b4033e47d90003d41ec34ecaeda94";
const ORDER_ID = 1778864423854121n;
const orderAbi = [{
  name:"getOrder", type:"function", stateMutability:"view",
  inputs:[{name:"orderId",type:"uint256"}],
  outputs:[{type:"tuple",components:[
    {name:"owner",type:"address"},{name:"token",type:"address"},
    {name:"amount",type:"uint256"},{name:"omniRecipient",type:"bytes32"},
    {name:"expiresAt",type:"uint64"},{name:"state",type:"uint8"}
  ]}]
}];
const erc20 = ["function balanceOf(address) view returns (uint256)"];
const STATES = {0:"NONE",1:"OPEN",2:"SETTLED",3:"CANCELLED",4:"EXPIRED"};
(async () => {
  const r = await p.getTransactionReceipt(TX);
  console.log("tx status:", r ? (r.status === 1 ? "SUCCESS" : "FAIL") : "PENDING");
  if (r) console.log("  block:", r.blockNumber, "gas:", r.gasUsed.toString());
  const dex = new Contract(DEX, orderAbi, p);
  const o = await dex.getOrder(ORDER_ID);
  console.log(`escrow state: ${o.state} (${STATES[Number(o.state)] || "?"})`);
  const usdc = new Contract(USDC, erc20, p);
  const sellerBal = await usdc.balanceOf(SELLER);
  const dexBal = await usdc.balanceOf(DEX);
  console.log(`seller USDC balance:  ${formatUnits(sellerBal, 6)} USDC`);
  console.log(`DEX contract USDC:    ${formatUnits(dexBal, 6)} USDC`);
})();
