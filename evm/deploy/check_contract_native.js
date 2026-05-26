const { JsonRpcProvider, Contract, parseEther, Interface } = require("ethers");
const p = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
const DEX = "0xC21fD92e5f568a7981d16b9008E3C190842818aE";

// Selector for placeBuyOrderNative(uint256,bytes32,uint64)
const iface = new Interface([
  "function placeBuyOrderNative(uint256 orderId, bytes32 omniRecipient, uint64 expiresAt) payable",
  "function placeBuyOrder(uint256 orderId, address token, uint256 amount, bytes32 omniRecipient, uint64 expiresAt)"
]);
const selectorNative = iface.getFunction("placeBuyOrderNative").selector;
const selectorERC20 = iface.getFunction("placeBuyOrder").selector;
console.log("placeBuyOrderNative selector:", selectorNative);
console.log("placeBuyOrder selector:      ", selectorERC20);

(async () => {
  const code = await p.getCode(DEX);
  console.log("contract bytecode length:", code.length);
  console.log("has placeBuyOrderNative selector:", code.includes(selectorNative.slice(2)));
  console.log("has placeBuyOrder selector:      ", code.includes(selectorERC20.slice(2)));
})();
