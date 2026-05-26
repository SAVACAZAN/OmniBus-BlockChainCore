// Generic OMNI/ETH end-to-end test on any of the deployed chains.
// Usage: node full_eth_trade.js <network>
//   where <network> is one of: arbSepolia | opSepolia | soneiumMinato
//
// Steps:
//  1. Slot 0 (founder) locks 0.0001 ETH escrow on OmnibusDEX
//  2. Wait for evm_escrow_watcher to detect
//  3. Slot 0 (dev/SELL) places SELL pair_id=6 on OmniBus chain with sellerEvm
//  4. Slot 0 (founder/BUY) places BUY pair_id=6 referencing evmOrderId
//  5. Wait for fill (OMNI moves)
//  6. Wait for settler to call settle() on EVM
//  7. Verify escrow state==2 (SETTLED)

const { HDKey } = require("@scure/bip32");
const { mnemonicToSeedSync } = require("@scure/bip39");
const { secp256k1 } = require("@noble/curves/secp256k1");
const { sha256 } = require("@noble/hashes/sha256");
const { keccak_256 } = require("@noble/hashes/sha3");
const { Wallet, JsonRpcProvider, Contract, keccak256, toUtf8Bytes, parseEther, formatEther } = require("ethers");
const fs = require("fs");
const http = require("http");

const NETWORKS = {
  arbSepolia:    { rpc: "https://sepolia-rollup.arbitrum.io/rpc", chainId: 421614,   explorer: "https://sepolia.arbiscan.io" },
  opSepolia:     { rpc: "https://sepolia.optimism.io",            chainId: 11155420, explorer: "https://sepolia-optimism.etherscan.io" },
  soneiumMinato: { rpc: "https://rpc.minato.soneium.org",         chainId: 1946,     explorer: "https://soneium-minato.blockscout.com" },
  baseSepolia:   { rpc: "https://sepolia.base.org",               chainId: 84532,    explorer: "https://sepolia.basescan.org" },
  liberty:       { rpc: "https://testnet-rpc.lcx.com",            chainId: 76847801, explorer: "https://testnet-explorer.lcx.com", dex: "0xE4a3965C4B5205D28259D1CC82fD54060B0bCd19" },
};

const DEX_DEFAULT = "0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB"; // same on all CREATE-deterministic chains
const DEX = NETWORKS[process.argv[2]]?.dex ?? DEX_DEFAULT;
const DEX_ABI = [
  {name:"placeBuyOrderNative",type:"function",stateMutability:"payable",
    inputs:[{name:"orderId",type:"uint256"},{name:"omniRecipient",type:"bytes32"},{name:"expiresAt",type:"uint64"}],outputs:[]},
  {name:"getOrder", type:"function", stateMutability:"view",
    inputs:[{name:"orderId",type:"uint256"}],
    outputs:[{type:"tuple",components:[
      {name:"owner",type:"address"},{name:"token",type:"address"},
      {name:"amount",type:"uint256"},{name:"omniRecipient",type:"bytes32"},
      {name:"expiresAt",type:"uint64"},{name:"state",type:"uint8"}
    ]}]},
];
const STATES = {0:"NONE",1:"OPEN",2:"SETTLED",3:"CANCELLED",4:"EXPIRED"};

const NET_NAME = process.argv[2];
const cfg = NETWORKS[NET_NAME];
if (!cfg) {
  console.error(`Usage: node full_eth_trade.js <${Object.keys(NETWORKS).join("|")}>`);
  process.exit(1);
}

// Both buyer and seller signing keys derived from founder mnemonic
const founder = fs.readFileSync(".mnemonic", "utf8").trim();
const root = HDKey.fromMasterSeed(mnemonicToSeedSync(founder));
const dev = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const devRoot = HDKey.fromMasterSeed(mnemonicToSeedSync(dev));

// Slot 0 founder OMNI buyer side
const buyerOmni = root.derive("m/44'/777'/0'/0/0");
const buyerAddr = "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0";
// Slot 0 dev EVM = predictable test address
const sellerOmni = devRoot.derive("m/44'/777'/0'/0/0");
const sellerAddr = "ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl";
const sellerEvmLeaf = devRoot.derive("m/44'/60'/0'/0/0");
const sellerEvm = "0x" + Buffer.from(keccak_256(secp256k1.ProjectivePoint.fromHex(sellerEvmLeaf.publicKey).toRawBytes(false).slice(1)).slice(12)).toString("hex");

// EVM signer is founder slot 0 = the buyer locking ETH
const evmLeaf = root.derive("m/44'/60'/0'/0/0");
const provider = new JsonRpcProvider(cfg.rpc, cfg.chainId);
const wallet = new Wallet("0x" + Buffer.from(evmLeaf.privateKey).toString("hex"), provider);

function rpcCall(method, params) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({jsonrpc:"2.0",id:1,method,params});
    const req = http.request({host:"127.0.0.1",port:18333,method:"POST",
      headers:{"Content-Type":"application/json","Content-Length":Buffer.byteLength(body)}},
      r=>{let d="";r.on("data",c=>d+=c);r.on("end",()=>{
        try { const j=JSON.parse(d); if(j.error) reject(j.error); else resolve(j.result);} catch(e){reject(e);}
      });});
    req.on("error",reject); req.write(body); req.end();
  });
}

function signOrder(leaf, addr, side, pairId, price, amount, nonce, extra) {
  const msg = `EXCHANGE_ORDER_V1\n${side}\n${pairId}\n${price}\n${amount}\n${nonce}\n${addr}`;
  const h = sha256(sha256(new TextEncoder().encode(msg)));
  const sig = secp256k1.sign(h, leaf.privateKey, { lowS: true });
  return {
    trader: addr, side, pairId, price, amount, nonce,
    signature: Buffer.from(sig.toCompactRawBytes()).toString("hex"),
    publicKey: Buffer.from(leaf.publicKey).toString("hex"),
    ...extra,
  };
}

async function main() {
  console.log(`=== OMNI/ETH end-to-end on ${NET_NAME} (chainId ${cfg.chainId}) ===`);
  console.log(`buyer EVM:  ${wallet.address}  (founder slot 0)`);
  console.log(`buyer OMNI: ${buyerAddr}`);
  console.log(`seller EVM: ${sellerEvm}        (dev abandon11x slot 0)`);
  console.log(`seller OMNI: ${sellerAddr}`);

  const balEth = await provider.getBalance(wallet.address);
  console.log(`buyer ETH: ${formatEther(balEth)}`);

  // === 1. Lock 0.0001 ETH escrow ===
  const ethAmount = parseEther("0.0001");
  const orderId = BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 1000));
  const expiresAt = Math.floor(Date.now() / 1000) + 24 * 3600;
  const omniCommit = keccak256(toUtf8Bytes(buyerAddr));

  console.log(`\n[1] placeBuyOrderNative orderId=${orderId}`);
  const dex = new Contract(DEX, DEX_ABI, wallet);
  const tx = await dex.placeBuyOrderNative(orderId, omniCommit, expiresAt, { value: ethAmount });
  console.log(`    L2 tx: ${tx.hash}`);
  console.log(`    explorer: ${cfg.explorer}/tx/${tx.hash}`);
  await tx.wait();
  console.log(`    locked`);

  // === 2. Wait for watcher ===
  console.log(`\n[2] waiting evm_escrow_watcher to detect…`);
  const start = Date.now();
  while (true) {
    if (Date.now() - start > 120_000) throw new Error("watcher timeout");
    await new Promise(r => setTimeout(r, 5000));
    process.stdout.write(".");
    // Probe by attempting a BUY — the chain will reject if escrow not seen
    try {
      const probe = await rpcCall("exchange_listOrders", { pairId: 6 });
      // Watcher is silent in this script; we just keep polling Sepolia logs
      const logFiles = fs.readdirSync("C:\\Users\\cazan\\AppData\\Local\\Temp\\claude\\C--Kits-work-limaje-de-programare\\b55cdbc9-0592-4444-870c-8536cda89491\\tasks")
        .filter(f => f.endsWith(".output"));
      let found = false;
      for (const f of logFiles) {
        try {
          const log = fs.readFileSync("C:\\Users\\cazan\\AppData\\Local\\Temp\\claude\\C--Kits-work-limaje-de-programare\\b55cdbc9-0592-4444-870c-8536cda89491\\tasks\\" + f,"utf8");
          if (log.includes(`OPEN orderId=${orderId}`)) { found = true; break; }
        } catch(e) {}
      }
      if (found) break;
    } catch (e) {}
  }
  console.log(` detected`);

  // === 3. Place SELL ===
  console.log(`\n[3] place SELL (1 OMNI @ 100000 micro-USD)`);
  const sellPayload = signOrder(sellerOmni, sellerAddr, "sell", 6, 100000, 1000000000, Date.now(), { sellerEvm });
  const sellRes = await rpcCall("exchange_placeOrder", sellPayload);
  console.log(`    SELL orderId=${sellRes.orderId} status=${sellRes.status}`);

  // === 4. Place BUY ===
  console.log(`\n[4] place BUY referencing evmOrderId=${orderId}`);
  const buyPayload = signOrder(buyerOmni, buyerAddr, "buy", 6, 100000, 1000000000, Date.now()+1, { evmOrderId: Number(orderId) });
  const buyRes = await rpcCall("exchange_placeOrder", buyPayload);
  console.log(`    BUY orderId=${buyRes.orderId} status=${buyRes.status} filled=${buyRes.filled}/${buyRes.amount}`);

  if (buyRes.status !== "filled") throw new Error(`expected filled, got ${buyRes.status}`);

  // === 5. Wait for settle ===
  console.log(`\n[5] waiting dex_settler to call settle() on ${NET_NAME}…`);
  const dexRO = new Contract(DEX, DEX_ABI, provider);
  const settleStart = Date.now();
  while (true) {
    if (Date.now() - settleStart > 180_000) throw new Error("settle timeout");
    await new Promise(r => setTimeout(r, 8000));
    const o = await dexRO.getOrder(orderId);
    process.stdout.write(`.state=${o.state}`);
    if (Number(o.state) === 2) break;
  }
  console.log(`\n    SETTLED`);
  console.log(`\n=== ${NET_NAME} trade SUCCESS ===`);
}

main().catch(e => { console.error("FAILED:", e); process.exit(1); });
