// Check LINK balance at slot 6 (0xc5A63d78...) on every chain that has LINK
const { JsonRpcProvider, Contract, formatUnits } = require("ethers");
const ADDR = "0xc5A63d78B451768Ba1dc799Fb08Ad41c6b37C938";
const ERC20_ABI = ["function balanceOf(address) view returns (uint256)"];

// Chainlink LINK token contract addresses per chain (docs.chain.link)
const LINK_TOKENS = {
  "Sepolia (11155111)":     { rpc: "https://ethereum-sepolia-rpc.publicnode.com",  link: "0x779877A7B0D9C06BeA7f2C7B37cc9cbFF0Ca01ff" },
  "Base Sep (84532)":       { rpc: "https://sepolia.base.org",                     link: "0xE4aB69C077896252FAFBD49EFD26B5D171A32410" },
  "Arb Sep (421614)":       { rpc: "https://sepolia-rollup.arbitrum.io/rpc",       link: "0xb1D4538B4571d411F07960EF2838Ce337FE1E80E" },
  "OP Sep (11155420)":      { rpc: "https://sepolia.optimism.io",                  link: "0xe7b3B5B1d2E93cDA5f23f26B9fF5a0cF0e2a1f45" },
  "Polygon Amoy (80002)":   { rpc: "https://rpc-amoy.polygon.technology",          link: "0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904" },  // updated
  "Avax Fuji (43113)":      { rpc: "https://api.avax-test.network/ext/bc/C/rpc",   link: "0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846" },
  "BNB Testnet (97)":       { rpc: "https://data-seed-prebsc-1-s1.binance.org:8545", link: "0x84b9B910527Ad5C03A9Ca831909E21e236EA7b06" },
};

(async () => {
  for (const [name, cfg] of Object.entries(LINK_TOKENS)) {
    try {
      const p = new JsonRpcProvider(cfg.rpc);
      const c = new Contract(cfg.link, ERC20_ABI, p);
      const bal = await c.balanceOf(ADDR);
      console.log(`${name.padEnd(24)}: ${formatUnits(bal, 18)} LINK`);
    } catch (e) {
      console.log(`${name.padEnd(24)}: err ${e.shortMessage || e.message?.slice(0,40)}`);
    }
  }
})();
