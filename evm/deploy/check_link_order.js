const { JsonRpcProvider, Contract } = require("ethers");
const DEX = "0xC21fD92e5f568a7981d16b9008E3C190842818aE";
const ABI = [
  "function orders(uint256) view returns (address owner, address token, uint256 amount, bytes32 omniRecipient, uint64 expiresAt, uint8 state)",
];
const provider = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const dex = new Contract(DEX, ABI, provider);
(async () => {
  const o = await dex.orders(1778969273121603n);
  const stateMap = ["empty","open","settled","cancelled"];
  console.log(`order 1778969273121603:`);
  console.log(`  owner:  ${o.owner}`);
  console.log(`  token:  ${o.token}`);
  console.log(`  amount: ${o.amount}`);
  console.log(`  expiresAt: ${o.expiresAt} (${new Date(Number(o.expiresAt)*1000).toISOString()})`);
  console.log(`  state:  ${o.state} (${stateMap[Number(o.state)] || "?"})`);
})();
