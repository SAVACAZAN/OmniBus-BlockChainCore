// Verify LINK balance at slot 6 across every chain you faucet'd today.
const { JsonRpcProvider, Contract, formatUnits } = require("ethers");
const ADDR = "0xc5A63d78B451768Ba1dc799Fb08Ad41c6b37C938";
const ERC20 = ["function balanceOf(address) view returns (uint256)"];

const CHAINS = {
  "Sepolia":         { rpc: "https://ethereum-sepolia-rpc.publicnode.com",  link: "0x779877A7B0D9E8603169DdbD7836e478b4624789" },
  "Base Sep":        { rpc: "https://sepolia.base.org",                     link: "0xE4aB69C077896252FAFBD49EFD26B5D171A32410" },
  "Arb Sep":         { rpc: "https://sepolia-rollup.arbitrum.io/rpc",       link: "0xb1D4538B4571d411F07960EF2838Ce337FE1E80E" },
  "OP Sep":          { rpc: "https://sepolia.optimism.io",                  link: "0xE4aB69C077896252FAFBD49EFD26B5D171A32410" },
  "Polygon Amoy":    { rpc: "https://rpc-amoy.polygon.technology",          link: "0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904" },
  "Avax Fuji":       { rpc: "https://api.avax-test.network/ext/bc/C/rpc",   link: "0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846" },
  "BNB Testnet":     { rpc: "https://data-seed-prebsc-1-s1.binance.org:8545", link: "0x84b9B910527Ad5C03A9Ca831909E21e236EA7b06" },
  "Scroll Sepolia":  { rpc: "https://sepolia-rpc.scroll.io",                link: "0x231d45b53C905c3d6201318156BDC725c9c3B9B1" },
  "Gnosis Chiado":   { rpc: "https://rpc.chiadochain.net",                  link: "0xDCA67FD8324990792C0bfaE95903B8A64097754F" },
};

(async () => {
  for (const [name, cfg] of Object.entries(CHAINS)) {
    try {
      const p = new JsonRpcProvider(cfg.rpc);
      const c = new Contract(cfg.link, ERC20, p);
      const b = await c.balanceOf(ADDR);
      console.log(`${name.padEnd(16)}: ${formatUnits(b, 18)} LINK`);
    } catch (e) {
      console.log(`${name.padEnd(16)}: err`);
    }
  }
})();
