const { JsonRpcProvider, formatEther } = require("ethers");
(async () => {
  const p = new JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com", 11155111);
  // Try multiple variants of User A address 
  for (const a of [
    "0x9858effd232b4033e47d90003d41ec34ecaeda94",
    "0x9858EFFd232b4033E47d90003D41eC34eCAEdA94",  // checksummed
  ]) {
    const b = await p.getBalance(a);
    console.log(a, "→", formatEther(b), "ETH");
  }
  // Verify the contract really has had a transfer out
  const dex = "0xC21fD92e5f568a7981d16b9008E3C190842818aE";
  console.log("\nDEX:", await p.getBalance(dex).then(formatEther), "ETH");
})();
