/**
 * Uniswap V3 AMM Orderbook Panel
 *
 * Reads on-chain state directly via public RPC — no API key, no subgraph.
 * Visualises concentrated liquidity as a bid/ask depth view.
 *
 * Price math:
 *   rawRatio = (sqrtPriceX96 / 2^96)^2  = token1_raw / token0_raw
 *   For token0=USDC(6dec), token1=WETH(18dec):
 *     ethPriceUsd = 1 / (rawRatio * 10^(6-18)) = 1 / (rawRatio * 1e-12)
 *   For token0=WETH(18dec), token1=USDC(6dec):
 *     ethPriceUsd = rawRatio * 10^(18-6) = rawRatio * 1e12  (NOT used — USDC is always lower addr)
 *
 * Token0 determination: lower hex address = token0 (Uniswap sorts deterministically)
 *   USDC  0xa0b8... < WETH 0xc02a... → token0=USDC on all EVM chains
 *   EURC  0x08210F... < WETH → token0=EURC
 *   WETH  < WBTC on some pools → token0=WETH
 *
 * Tick spacing: fee 500 (0.05%) → 10 | fee 3000 (0.3%) → 60 | fee 10000 (1%) → 200
 */

import { useEffect, useRef, useState, useCallback } from "react";

// ── Pool catalogue ────────────────────────────────────────────────────────────

interface PoolDef {
  address: string;
  label: string;
  fee: number;            // 500 | 3000 | 10000 for V3; 3000 (0.3%) fixed for V2
  version: "v2" | "v3";  // Uniswap version — affects RPC call and price calc
  token0Symbol: string;   // lower address token (Uniswap sorted)
  token1Symbol: string;   // higher address token
  token0Dec: number;
  token1Dec: number;
  displayQuote: string;   // unit of displayed price (e.g. "USD", "ETH")
  // showToken0Price: true  → display price of token0 in token1 (e.g. LCX in ETH)
  //                  false → display price of token1 in token0 (e.g. ETH in USDC) [default]
  showToken0Price?: boolean;
}

// V2 pool: getReserves() selector
const GET_RESERVES = "0x0902f1ac";

// Multiple fallback RPCs per chain — tried in order until one succeeds
const CHAIN_RPCS: Record<string, string[]> = {
  "Mainnet":  ["https://eth.drpc.org", "https://eth.llamarpc.com", "https://1rpc.io/eth", "https://ethereum.publicnode.com"],
  "Sepolia":  ["https://sepolia.drpc.org", "https://rpc.sepolia.org", "https://rpc2.sepolia.org"],
  "Base":     ["https://mainnet.base.org", "https://base.drpc.org", "https://base.publicnode.com"],
  "Base Sep": ["https://sepolia.base.org"],
  "Arbitrum": ["https://arb1.arbitrum.io/rpc", "https://arbitrum.drpc.org", "https://arbitrum.publicnode.com"],
  "Arb Sep":  ["https://sepolia-rollup.arbitrum.io/rpc"],
  "Optimism": ["https://mainnet.optimism.io", "https://optimism.drpc.org", "https://optimism.publicnode.com"],
  "OP Sep":   ["https://sepolia.optimism.io"],
  "Polygon":  ["https://polygon-rpc.com", "https://polygon.drpc.org", "https://polygon.publicnode.com"],
  "Amoy":     ["https://rpc-amoy.polygon.technology"],
};

const CHAINS: Array<{
  name: string;
  rpc: string;
  pools: PoolDef[];
}> = [
  {
    name: "Mainnet",
    rpc: "https://eth.drpc.org",
    pools: [
      // ── ETH/USDC pools ───────────────────────────────────────────────
      { version: "v3", address: "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640", label: "ETH/USDC 0.05%",  fee: 500,   token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6,  token1Dec: 18, displayQuote: "USD" },
      { version: "v3", address: "0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8", label: "ETH/USDC 0.3%",   fee: 3000,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6,  token1Dec: 18, displayQuote: "USD" },
      // ── BTC/ETH ──────────────────────────────────────────────────────
      // WBTC 0x2260... < WETH 0xC02a... → token0=WBTC(8dec), token1=WETH(18dec)
      { version: "v3", address: "0xCBCdF9626bC03E24f779434178A73a0B4bad62eD", label: "BTC/ETH 0.3%",    fee: 3000,  token0Symbol: "WBTC", token1Symbol: "WETH", token0Dec: 8,  token1Dec: 18, displayQuote: "ETH", showToken0Price: true },
      // ── LCX pools (all versions) ─────────────────────────────────────
      // LCX 0x037A54... < WETH 0xC02a... → token0=LCX, showToken0Price=true → ETH per LCX
      { version: "v3", address: "0x5aaa28ca43c6646fd1403e508f0fca1d92357dde", label: "LCX/ETH 1%",      fee: 10000, token0Symbol: "LCX",  token1Symbol: "WETH", token0Dec: 18, token1Dec: 18, displayQuote: "ETH", showToken0Price: true },
      { version: "v3", address: "0xc090993fe84b9c0b1baa889b94b5e4bfbb9f13a0", label: "LCX/ETH 0.3%",   fee: 3000,  token0Symbol: "LCX",  token1Symbol: "WETH", token0Dec: 18, token1Dec: 18, displayQuote: "ETH", showToken0Price: true },
      // V2 LCX/WETH — active: ~16k LCX / ~0.24 WETH (verified on-chain)
      { version: "v2", address: "0xfcb910d871d7e94f5a566b7b32fb2b19583c09d7", label: "LCX/ETH V2",     fee: 3000,  token0Symbol: "LCX",  token1Symbol: "WETH", token0Dec: 18, token1Dec: 18, displayQuote: "ETH", showToken0Price: true },
      // LCX/USDC pools (token0=LCX 0x037A... < USDC 0xa0b8... → actually LCX < USDC so token0=LCX)
      { version: "v3", address: "0xf152f10e4781c0d3844310193a2050384a5581f2", label: "LCX/USDC 0.3%",  fee: 3000,  token0Symbol: "LCX",  token1Symbol: "USDC", token0Dec: 18, token1Dec: 6,  displayQuote: "USD", showToken0Price: true },
      { version: "v3", address: "0xe03e5f8ff282843c59ff91f5b6cedcc9742a9c40", label: "LCX/USDC 1%",   fee: 10000, token0Symbol: "LCX",  token1Symbol: "USDC", token0Dec: 18, token1Dec: 6,  displayQuote: "USD", showToken0Price: true },
      // ── TOTO pools ───────────────────────────────────────────────────
      // V2 TOTO/WETH — active: ~25k TOTO / ~4.14 WETH (verified on-chain)
      { version: "v2", address: "0x5008d39f997468057947fd370a6a8c1786a27d71", label: "TOTO/ETH V2",    fee: 3000,  token0Symbol: "TOTO", token1Symbol: "WETH", token0Dec: 18, token1Dec: 18, displayQuote: "ETH", showToken0Price: true },
    ],
  },
  {
    name: "Sepolia",
    rpc: "https://sepolia.drpc.org",
    pools: [
      { version: "v3", address: "0x3289680dd4d6C10bb19b899729cda5Eef58AEff1", label: "ETH/USDC 0.05%",  fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6,  token1Dec: 18, displayQuote: "USD" },
    ],
  },
  {
    name: "Base",
    rpc: "https://mainnet.base.org",
    pools: [
      { version: "v3", address: "0x4C36388bE6F416A29C8d8Eee81C771cE6bE14B5", label: "ETH/USDC 0.05%",  fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6,  token1Dec: 18, displayQuote: "USD" },
      { version: "v3", address: "0xd0b53D9277642d899DF5C87A3966A349A798F224", label: "ETH/USDC 0.3%",   fee: 3000, token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6,  token1Dec: 18, displayQuote: "USD" },
    ],
  },
  {
    name: "Base Sep",
    rpc: "https://sepolia.base.org",
    pools: [
      { version: "v3", address: "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24", label: "ETH/USDC 0.3%",   fee: 3000, token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6,  token1Dec: 18, displayQuote: "USD" },
    ],
  },
  {
    name: "Arbitrum",
    rpc: "https://arb1.arbitrum.io/rpc",
    pools: [
      { version: "v3", address: "0xC6962004f452bE9203591991D15f6b388e09E8D0", label: "ETH/USDC 0.05%",  fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6,  token1Dec: 18, displayQuote: "USD" },
      { version: "v3", address: "0x17c14D2c404D167802b16C450d3c99F88F2c4F4d", label: "ETH/USDC 0.3%",   fee: 3000, token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6,  token1Dec: 18, displayQuote: "USD" },
    ],
  },
  {
    name: "Arb Sep",
    rpc: "https://sepolia-rollup.arbitrum.io/rpc",
    pools: [
      { version: "v3", address: "0x980A27a9b847a5D2e65093612bD81A76A36282B7", label: "ETH/USDC 0.05%",  fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6,  token1Dec: 18, displayQuote: "USD" },
    ],
  },
  {
    name: "Optimism",
    rpc: "https://mainnet.optimism.io",
    pools: [
      { version: "v3", address: "0x85149247691df622eaF1a8Bd0cafd40BC45154a", label: "ETH/USDC 0.05%",  fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6,  token1Dec: 18, displayQuote: "USD" },
    ],
  },
  {
    name: "OP Sep",
    rpc: "https://sepolia.optimism.io",
    pools: [
      { version: "v3", address: "0x6b62B25C96EAC6c5D1Fc2c28F2f6c1bD56B9A3E0", label: "ETH/USDC 0.05%",  fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6,  token1Dec: 18, displayQuote: "USD" },
    ],
  },
  {
    name: "Polygon",
    rpc: "https://polygon-rpc.com",
    pools: [
      { version: "v3", address: "0x45dDa9cb7c25131DF268515131f647d726f50608", label: "ETH/USDC 0.05%",  fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6,  token1Dec: 18, displayQuote: "USD" },
      { version: "v3", address: "0xA374094527e1673A86dE625aa59517c5dE346d32", label: "ETH/USDC 0.3%",   fee: 3000, token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6,  token1Dec: 18, displayQuote: "USD" },
    ],
  },
  {
    name: "Amoy",
    rpc: "https://rpc-amoy.polygon.technology",
    pools: [
      { version: "v3", address: "0xF9Eb97E4ECB1f84e0b0De2f3e72D5bDe4eA3d7F7", label: "ETH/USDC 0.05%",  fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6,  token1Dec: 18, displayQuote: "USD" },
    ],
  },
];

const TICKS_EACH_SIDE = 30; // number of ticks to sample each direction

// ── Types ─────────────────────────────────────────────────────────────────────

interface Slot0 {
  sqrtPriceX96: bigint;
  tick: number;
}

interface Level {
  price: number;
  liqRaw: bigint;
  liqPct: number;      // 0-100 depth bar
  side: "ask" | "bid";
  qty0: number;        // token0 amount in this tick range (human units)
  qty1: number;        // token1 amount in this tick range (human units)
  tickLo: number;
  tickHi: number;
}

// ── RPC ───────────────────────────────────────────────────────────────────────

async function ethCallOne(rpc: string, to: string, data: string): Promise<string> {
  const resp = await fetch(rpc, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to, data }, "latest"] }),
    signal: AbortSignal.timeout(8000),
  });
  const text = await resp.text();
  let j: any;
  try { j = JSON.parse(text); } catch { throw new Error("Non-JSON response: " + text.slice(0, 80)); }
  if (j.error) throw new Error(j.error.message ?? "RPC error");
  if (!j.result || j.result === "0x") throw new Error("Empty result — pool may not exist on this chain");
  return j.result as string;
}

async function ethCall(chainName: string, to: string, data: string): Promise<string> {
  const rpcs = CHAIN_RPCS[chainName] ?? [];
  let lastErr = "No RPC configured";
  for (const rpc of rpcs) {
    try { return await ethCallOne(rpc, to, data); }
    catch (e: any) { lastErr = e?.message ?? "fail"; }
  }
  throw new Error(lastErr);
}

// ── V2 fetch ──────────────────────────────────────────────────────────────────

interface V2Reserves {
  reserve0: bigint;
  reserve1: bigint;
}

async function fetchV2Reserves(chainName: string, pool: string): Promise<V2Reserves> {
  const raw = await ethCall(chainName, pool, GET_RESERVES);
  const hex = raw.slice(2);
  const reserve0 = BigInt("0x" + hex.slice(0, 64));
  const reserve1 = BigInt("0x" + hex.slice(64, 128));
  if (reserve0 === 0n && reserve1 === 0n) throw new Error("V2 pool has zero reserves — may not exist");
  return { reserve0, reserve1 };
}

// V2 price: token1_human / token0_human
function calcV2Price(res: V2Reserves, pool: PoolDef): number {
  const r0 = Number(res.reserve0) / Math.pow(10, pool.token0Dec);
  const r1 = Number(res.reserve1) / Math.pow(10, pool.token1Dec);
  // showToken0Price=true → price of token0 in token1 units (e.g. LCX in ETH) = r1/r0
  // showToken0Price=false → price of token1 in token0 units (e.g. ETH in USDC) = r0/r1
  return pool.showToken0Price ? r1 / r0 : r0 / r1;
}

// V2 orderbook: constant-product formula — simulate 5% price bands ±
// We show 10 synthetic levels each side using x*y=k curve
function buildV2Levels(res: V2Reserves, pool: PoolDef): Level[] {
  const r0 = Number(res.reserve0);
  const r1 = Number(res.reserve1);
  const k  = r0 * r1;
  const dec0 = Math.pow(10, pool.token0Dec);
  const dec1 = Math.pow(10, pool.token1Dec);
  const midPrice = calcV2Price(res, pool);
  const LEVELS = 10;
  const BAND   = 0.005; // 0.5% per level

  const levels: Level[] = [];

  // Ask side: selling token0 → price rises above mid (r1 increases, r0 decreases)
  const askQtys: number[] = [];
  for (let i = 1; i <= LEVELS; i++) {
    const targetPrice = pool.showToken0Price
      ? midPrice * (1 + i * BAND)   // LCX/ETH: price goes up
      : midPrice / (1 + i * BAND);  // ETH/USDC: USDC per ETH goes down (more ETH being bought)
    // For showToken0Price: price = r1/r0 (human), target = newR1/newR0
    // k = r0*r1, newR1 = sqrt(k * targetRaw), newR0 = k/newR1
    const decAdj = pool.showToken0Price
      ? Math.pow(10, pool.token1Dec - pool.token0Dec)
      : Math.pow(10, pool.token0Dec - pool.token1Dec);
    const targetRaw = pool.showToken0Price ? targetPrice / decAdj : 1 / (targetPrice / decAdj);
    const newR1 = Math.sqrt(k * targetRaw);
    const newR0 = k / newR1;
    const delta0 = (r0 - newR0) / dec0; // token0 flowing out (positive = ask)
    askQtys.push(Math.abs(delta0));
  }
  const maxAskQty = Math.max(...askQtys);
  for (let i = 0; i < LEVELS; i++) {
    const priceAtLevel = pool.showToken0Price
      ? midPrice * (1 + (i + 1) * BAND)
      : midPrice / (1 + (i + 1) * BAND);
    levels.push({
      price: priceAtLevel,
      liqRaw: BigInt(0),
      liqPct: maxAskQty > 0 ? Math.round((askQtys[i] / maxAskQty) * 100) : 0,
      side: "ask",
      qty0: askQtys[i],
      qty1: 0,
      tickLo: 0,
      tickHi: 0,
    });
  }

  // Bid side: buying token0 → price falls below mid
  const bidQtys: number[] = [];
  for (let i = 1; i <= LEVELS; i++) {
    const targetPrice = pool.showToken0Price
      ? midPrice * (1 - i * BAND)
      : midPrice / (1 - i * BAND);
    const decAdj = pool.showToken0Price
      ? Math.pow(10, pool.token1Dec - pool.token0Dec)
      : Math.pow(10, pool.token0Dec - pool.token1Dec);
    const targetRaw = pool.showToken0Price ? targetPrice / decAdj : 1 / (targetPrice / decAdj);
    const newR1 = Math.sqrt(k * targetRaw);
    const newR0 = k / newR1;
    const delta1 = (r1 - newR1) / dec1; // token1 flowing out (positive = bid)
    bidQtys.push(Math.abs(delta1));
  }
  const maxBidQty = Math.max(...bidQtys);
  for (let i = 0; i < LEVELS; i++) {
    const priceAtLevel = pool.showToken0Price
      ? midPrice * (1 - (i + 1) * BAND)
      : midPrice / (1 - (i + 1) * BAND);
    levels.push({
      price: priceAtLevel,
      liqRaw: BigInt(0),
      liqPct: maxBidQty > 0 ? Math.round((bidQtys[i] / maxBidQty) * 100) : 0,
      side: "bid",
      qty0: 0,
      qty1: bidQtys[i],
      tickLo: 0,
      tickHi: 0,
    });
  }

  return levels;
}

// ── V3 fetch ──────────────────────────────────────────────────────────────────

async function fetchSlot0(chainName: string, pool: string): Promise<Slot0> {
  const raw = await ethCall(chainName, pool, "0x3850c7bd");
  const hex = raw.slice(2);
  const sqrtPriceX96 = BigInt("0x" + hex.slice(0, 64));
  if (sqrtPriceX96 === 0n) throw new Error("Pool not initialised (sqrtPrice=0)");
  // tick is int24 — ABI-encoded as uint256 but only lower 24 bits matter.
  // parseInt on the full 64-char hex overflows Number → mask to 24 bits first.
  const tickFull = BigInt("0x" + hex.slice(64, 128));
  const tick24 = Number(tickFull & 0xFFFFFFn);
  const tick = tick24 >= (1 << 23) ? tick24 - (1 << 24) : tick24;
  return { sqrtPriceX96, tick };
}

async function fetchTickLiquidity(chainName: string, pool: string, tick: number): Promise<{ gross: bigint; net: bigint } | null> {
  const fill = tick < 0 ? "f" : "0";
  const abs = ((tick < 0 ? tick + (1 << 24) : tick) & 0xFFFFFF).toString(16);
  const encoded = abs.padStart(64, fill);
  try {
    const raw = await ethCall(chainName, pool, "0xf30dba93" + encoded);
    const hex = raw.slice(2);
    const gross = BigInt("0x" + hex.slice(0, 64));
    if (gross === 0n) return null;
    let net = BigInt("0x" + hex.slice(64, 128));
    const INT128_MAX = (1n << 127n) - 1n;
    if (net > INT128_MAX) net = net - (1n << 128n);
    return { gross, net };
  } catch {
    return null;
  }
}

// ── Math ──────────────────────────────────────────────────────────────────────

// rawRatio = (sqrtP/2^96)^2 = token1_raw / token0_raw
// human price of token1 in token0 = rawRatio * 10^(token0Dec - token1Dec)
// showToken0Price=false (default): display price of token1 (e.g. ETH) in token0 units (e.g. USDC)
//   → return 1 / (rawRatio * decAdj)   because rawRatio * decAdj = ETH per USDC, invert = USD per ETH ✓
// showToken0Price=true: display price of token0 (e.g. LCX) in token1 units (e.g. ETH)
//   → return rawRatio * decAdj           because rawRatio * decAdj = WETH per LCX = ETH per LCX ✓

function calcPrice(sqrtPriceX96: bigint, pool: PoolDef): number {
  const Q96 = 2 ** 96;
  const sqrtRatio = Number(sqrtPriceX96) / Q96;
  const rawRatio = sqrtRatio * sqrtRatio;
  const decAdj = Math.pow(10, pool.token0Dec - pool.token1Dec);
  const priceToken1InToken0 = rawRatio * decAdj;
  return pool.showToken0Price ? priceToken1InToken0 : 1 / priceToken1InToken0;
}

function tickToPrice(tick: number, pool: PoolDef): number {
  const rawRatio = Math.pow(1.0001, tick);
  const decAdj = Math.pow(10, pool.token0Dec - pool.token1Dec);
  const p1in0 = rawRatio * decAdj;
  return pool.showToken0Price ? p1in0 : 1 / p1in0;
}

function tickSpacing(fee: number): number {
  if (fee === 500)   return 10;
  if (fee === 3000)  return 60;
  if (fee === 10000) return 200;
  return 10;
}

// sqrtPrice from tick: sqrt(1.0001^tick) as a plain float
function sqrtPriceAtTick(tick: number): number {
  return Math.sqrt(Math.pow(1.0001, tick));
}

// Uniswap V3 token amounts for a position with given liquidity L in range [tickLo, tickHi]
// currentSqrtP = sqrt of current pool price (float, NOT Q96)
// Returns { amount0, amount1 } in raw smallest units (need to divide by decimals later)
//
// If range fully above current price → only token0 (ask side holds token0)
// If range fully below current price → only token1 (bid side holds token1)
// If range straddles current price   → both tokens (we use current sqrt price)
function calcAmounts(
  L: bigint,
  currentSqrtP: number,
  tickLo: number,
  tickHi: number,
): { amount0: number; amount1: number } {
  const sqrtA = sqrtPriceAtTick(tickLo);
  const sqrtB = sqrtPriceAtTick(tickHi);
  const sqrtC = Math.min(Math.max(currentSqrtP, sqrtA), sqrtB); // clamp to range
  const liq = Number(L);

  // amount0 = L * (sqrtB - sqrtC) / (sqrtB * sqrtC)
  // amount1 = L * (sqrtC - sqrtA)
  const amount0 = sqrtB > sqrtC ? liq * (sqrtB - sqrtC) / (sqrtB * sqrtC) : 0;
  const amount1 = sqrtC > sqrtA ? liq * (sqrtC - sqrtA) : 0;
  return { amount0, amount1 };
}

// ── Data fetch ────────────────────────────────────────────────────────────────

async function loadPool(chainName: string, pool: PoolDef): Promise<{ price: number; tick: number; levels: Level[]; isV2: boolean }> {
  // ── V2 path ────────────────────────────────────────────────────────────────
  if (pool.version === "v2") {
    const res = await fetchV2Reserves(chainName, pool.address);
    const price = calcV2Price(res, pool);
    const levels = buildV2Levels(res, pool);
    return { price, tick: 0, levels, isV2: true };
  }

  // ── V3 path ────────────────────────────────────────────────────────────────
  const slot0 = await fetchSlot0(chainName, pool.address);
  const price = calcPrice(slot0.sqrtPriceX96, pool);
  const ts = tickSpacing(pool.fee);
  const base = Math.round(slot0.tick / ts) * ts;

  // current sqrt price as plain float (not Q96)
  const currentSqrtP = Number(slot0.sqrtPriceX96) / (2 ** 96);

  const indices: number[] = [];
  for (let i = -TICKS_EACH_SIDE; i <= TICKS_EACH_SIDE; i++) {
    indices.push(base + i * ts);
  }

  // Fetch in parallel batches of 8
  const tickResults: Array<{ tick: number; gross: bigint; net: bigint }> = [];
  for (let i = 0; i < indices.length; i += 8) {
    const batch = indices.slice(i, i + 8);
    const settled = await Promise.allSettled(
      batch.map(t => fetchTickLiquidity(chainName, pool.address, t).then(r => r ? { tick: t, ...r } : null))
    );
    for (const r of settled) {
      if (r.status === "fulfilled" && r.value) tickResults.push(r.value);
    }
  }

  if (tickResults.length === 0) return { price, tick: slot0.tick, levels: [], isV2: false };

  const dec0 = Math.pow(10, pool.token0Dec);
  const dec1 = Math.pow(10, pool.token1Dec);

  const allTicks = tickResults.sort((a, b) => a.tick - b.tick);
  const levels: Level[] = [];

  for (let i = 0; i < allTicks.length; i++) {
    const t = allTicks[i];
    const tickLo = t.tick;
    const tickHi = t.tick + ts;
    const side: "ask" | "bid" = tickLo >= slot0.tick ? "ask" : "bid";

    const { amount0, amount1 } = calcAmounts(t.gross, currentSqrtP, tickLo, tickHi);
    const qty0 = amount0 / dec0;
    const qty1 = amount1 / dec1;
    const levelPrice = tickToPrice(tickLo, pool);

    levels.push({ price: levelPrice, liqRaw: t.gross, liqPct: 0, side, qty0, qty1, tickLo, tickHi });
  }

  const maxQty0 = levels.filter(l => l.side === "ask").reduce((m, l) => Math.max(m, l.qty0), 0);
  const maxQty1 = levels.filter(l => l.side === "bid").reduce((m, l) => Math.max(m, l.qty1), 0);
  for (const l of levels) {
    const ref = l.side === "ask" ? maxQty0 : maxQty1;
    const qty = l.side === "ask" ? l.qty0 : l.qty1;
    l.liqPct = ref > 0 ? Math.round((qty / ref) * 100) : 0;
  }

  return { price, tick: slot0.tick, levels, isV2: false };
}

// ── Format helpers ────────────────────────────────────────────────────────────

function fmtPrice(p: number, pool: PoolDef): string {
  // Adapt decimal places based on magnitude
  const dp = p >= 1000 ? 2 : p >= 1 ? 4 : p >= 0.001 ? 6 : 8;
  return p.toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });
}

function pricePrefix(pool: PoolDef): string {
  // Show $ only when quote is USD
  return pool.displayQuote === "USD" ? "$" : "";
}

function priceSuffix(pool: PoolDef): string {
  return pool.displayQuote !== "USD" ? " " + pool.displayQuote : "";
}

function fmtQty(n: number, sym: string): string {
  if (!isFinite(n) || n === 0) return "—";
  const abs = Math.abs(n);
  const s = abs >= 1e6 ? (n / 1e6).toFixed(2) + "M"
          : abs >= 1e3 ? n.toLocaleString("en-US", { maximumFractionDigits: 0 })
          : abs >= 1   ? n.toFixed(2)
          : n.toFixed(4);
  return s + " " + sym;
}

// ETH/USDC 0.05% reference pool used to convert ETH-quoted prices to USD
// Picked per-chain; falls back to Mainnet pool if chain has no ETH/USDC pool.
const ETH_USD_REF: Record<string, { chainName: string; pool: PoolDef }> = {
  "Mainnet":  { chainName: "Mainnet",  pool: { version: "v3", address: "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640", label: "ref", fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6, token1Dec: 18, displayQuote: "USD" } },
  "Sepolia":  { chainName: "Sepolia",  pool: { version: "v3", address: "0x3289680dd4d6C10bb19b899729cda5Eef58AEff1", label: "ref", fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6, token1Dec: 18, displayQuote: "USD" } },
  "Base":     { chainName: "Base",     pool: { version: "v3", address: "0x4C36388bE6F416A29C8d8Eee81C771cE6bE14B5", label: "ref", fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6, token1Dec: 18, displayQuote: "USD" } },
  "Base Sep": { chainName: "Mainnet",  pool: { version: "v3", address: "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640", label: "ref", fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6, token1Dec: 18, displayQuote: "USD" } },
  "Arbitrum": { chainName: "Arbitrum", pool: { version: "v3", address: "0xC6962004f452bE9203591991D15f6b388e09E8D0", label: "ref", fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6, token1Dec: 18, displayQuote: "USD" } },
  "Arb Sep":  { chainName: "Mainnet",  pool: { version: "v3", address: "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640", label: "ref", fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6, token1Dec: 18, displayQuote: "USD" } },
  "Optimism": { chainName: "Optimism", pool: { version: "v3", address: "0x85149247691df622eaF1a8Bd0cafd40BC45154a", label: "ref", fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6, token1Dec: 18, displayQuote: "USD" } },
  "OP Sep":   { chainName: "Mainnet",  pool: { version: "v3", address: "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640", label: "ref", fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6, token1Dec: 18, displayQuote: "USD" } },
  "Polygon":  { chainName: "Mainnet",  pool: { version: "v3", address: "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640", label: "ref", fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6, token1Dec: 18, displayQuote: "USD" } },
  "Amoy":     { chainName: "Mainnet",  pool: { version: "v3", address: "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640", label: "ref", fee: 500,  token0Symbol: "USDC", token1Symbol: "WETH", token0Dec: 6, token1Dec: 18, displayQuote: "USD" } },
};

async function fetchEthUsdPrice(chainName: string): Promise<number | null> {
  const ref = ETH_USD_REF[chainName];
  if (!ref) return null;
  try {
    const slot0 = await fetchSlot0(ref.chainName, ref.pool.address);
    return calcPrice(slot0.sqrtPriceX96, ref.pool);
  } catch {
    return null;
  }
}

// ── Component ─────────────────────────────────────────────────────────────────

export function AmmOrderbookPanel() {
  const [chainIdx, setChainIdx]   = useState(0);
  const [poolIdx, setPoolIdx]     = useState(0);
  const [price, setPrice]         = useState<number | null>(null);
  const [tick, setTick]           = useState<number | null>(null);
  const [levels, setLevels]       = useState<Level[]>([]);
  const [ethUsd, setEthUsd]       = useState<number | null>(null);
  const [isV2, setIsV2]           = useState(false);
  const [loading, setLoading]     = useState(false);
  const [error, setError]         = useState<string | null>(null);
  const [updatedAt, setUpdatedAt] = useState<Date | null>(null);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const chain = CHAINS[chainIdx];
  const pool  = chain?.pools[poolIdx] ?? chain?.pools[0];

  const load = useCallback(async () => {
    if (!chain || !pool) return;
    setLoading(true);
    setError(null);
    try {
      // Fetch selected pool + ETH/USD reference in parallel
      const [result, ethUsdPrice] = await Promise.all([
        loadPool(chain.name, pool),
        fetchEthUsdPrice(chain.name),
      ]);
      setPrice(result.price);
      setTick(result.tick);
      setLevels(result.levels);
      setIsV2(result.isV2);
      setEthUsd(ethUsdPrice);
      setUpdatedAt(new Date());
    } catch (e: any) {
      setError(e?.message ?? "RPC error");
      setPrice(null);
      setLevels([]);
    } finally {
      setLoading(false);
    }
  }, [chain?.name, pool?.address]);

  useEffect(() => {
    setPrice(null); setLevels([]); setError(null); setEthUsd(null); setIsV2(false);
    load();
    if (timerRef.current) clearInterval(timerRef.current);
    timerRef.current = setInterval(load, 15000);
    return () => { if (timerRef.current) clearInterval(timerRef.current); };
  }, [load]);

  useEffect(() => { setPoolIdx(0); }, [chainIdx]);

  const asks = levels.filter(l => l.side === "ask").sort((a, b) => a.price - b.price);
  const bids = levels.filter(l => l.side === "bid").sort((a, b) => b.price - a.price);

  // showToken0Price → display token0 price in token1 units, label = "token0/token1"
  // otherwise      → display token1 price in token0 units, label = "token1/token0"
  const priceLabel = pool
    ? pool.showToken0Price
      ? `${pool.token0Symbol}/${pool.token1Symbol}`
      : `${pool.token1Symbol}/${pool.token0Symbol}`
    : "ETH/USD";

  // Convert ETH-quoted price to USD using reference ETH/USD pool
  const needsEthConv = pool?.displayQuote === "ETH" && ethUsd !== null;
  const priceUsd     = needsEthConv && price !== null ? price * ethUsd! : null;
  const toUsd        = (p: number) => needsEthConv ? p * ethUsd! : null;

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 space-y-3">

      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
            Uniswap {isV2 ? "V2" : "V3"} — Live AMM Depth
          </h2>
          <p className="text-[10px] text-mempool-text-dim mt-0.5">
            On-chain · direct RPC · no API key · refreshes every 15s
            {isV2 && <span className="ml-1 text-purple-300/80">· x·y=k constant product · simulated levels ±0.5%/step</span>}
          </p>
        </div>
        <div className="flex items-center gap-2">
          {updatedAt && (
            <span className="text-[9px] text-mempool-text-dim font-mono">
              {updatedAt.toLocaleTimeString()}
            </span>
          )}
          {levels.length > 0 && pool && (
            <button
              onClick={() => {
                const poolLabel = pool.label.replace(/[^a-z0-9]/gi, "-").toLowerCase();
                const rows = [
                  ["side","price","qty0","qty1","liq_pct","tick_lo","tick_hi"].join(","),
                  ...[...levels].sort((a, b) => a.side === b.side
                    ? (a.side === "ask" ? a.price - b.price : b.price - a.price)
                    : a.side === "ask" ? -1 : 1
                  ).map((l) => [
                    l.side,
                    l.price.toFixed(8),
                    l.qty0.toFixed(8),
                    l.qty1.toFixed(8),
                    l.liqPct.toFixed(4),
                    l.tickLo,
                    l.tickHi,
                  ].join(",")),
                ].join("\n");
                const blob = new Blob([rows], { type: "text/csv" });
                const url = URL.createObjectURL(blob);
                const a = document.createElement("a");
                a.href = url; a.download = `omnibus-amm-${poolLabel}.csv`;
                a.click(); URL.revokeObjectURL(url);
              }}
              className="px-2 py-1 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
            >
              ⬇ CSV
            </button>
          )}
          <button
            onClick={load}
            disabled={loading}
            className="px-2 py-1 text-[10px] rounded bg-mempool-blue/20 text-mempool-blue hover:bg-mempool-blue/30 disabled:opacity-40 transition-colors"
          >
            {loading ? "…" : "↻"}
          </button>
        </div>
      </div>

      {/* Chain pills */}
      <div className="flex flex-wrap gap-1">
        {CHAINS.map((c, i) => (
          <button
            key={c.name}
            onClick={() => setChainIdx(i)}
            className={`px-2.5 py-0.5 text-[10px] rounded-full font-mono transition-colors ${
              chainIdx === i
                ? "bg-mempool-blue text-white font-semibold"
                : "bg-mempool-bg text-mempool-text-dim hover:text-mempool-text border border-mempool-border/40"
            }`}
          >
            {c.name}
          </button>
        ))}
      </div>

      {/* Pool selector (within chain) */}
      {chain && chain.pools.length > 1 && (
        <div className="flex gap-1">
          {chain.pools.map((p, i) => (
            <button
              key={p.address}
              onClick={() => setPoolIdx(i)}
              className={`px-2.5 py-0.5 text-[10px] rounded transition-colors ${
                poolIdx === i
                  ? "bg-purple-500/30 text-purple-200 font-semibold"
                  : "bg-mempool-bg text-mempool-text-dim hover:text-mempool-text border border-mempool-border/40"
              }`}
            >
              {p.label}
            </button>
          ))}
        </div>
      )}

      {/* Pool address */}
      {pool && (
        <p className="text-[9px] text-mempool-text-dim font-mono truncate">
          Pool: {pool.address}
          {" · "}{pool.version?.toUpperCase() ?? "V3"}
          {pool.version !== "v2" && <>{" · "}spacing: {tickSpacing(pool.fee)}</>}
          {" · "}{pool.token0Symbol}/{pool.token1Symbol}
        </p>
      )}

      {/* Error */}
      {error && (
        <div className="p-2 rounded bg-red-500/10 border border-red-500/30 text-[11px] text-red-300">
          {error}
        </div>
      )}

      {/* Mid price card */}
      {price !== null && pool && (
        <div className="flex items-center justify-between py-2 px-3 rounded-lg bg-mempool-bg border border-mempool-border/60">
          <div>
            <div className="text-[9px] uppercase tracking-wider text-mempool-text-dim mb-0.5">{priceLabel}</div>
            <div className="text-2xl font-bold text-mempool-text font-mono">
              {pricePrefix(pool)}{fmtPrice(price, pool)}{priceSuffix(pool)}
            </div>
            {/* USD equivalent for ETH-quoted pools */}
            {priceUsd !== null && (
              <div className="text-sm font-semibold text-yellow-300 font-mono mt-0.5">
                ≈ ${fmtPrice(priceUsd, { ...pool, displayQuote: "USD" })} USDC
              </div>
            )}
            <div className="text-[9px] text-mempool-text-dim mt-0.5">
              tick {tick}
              {ethUsd && pool.displayQuote === "ETH" && (
                <span className="ml-2 text-mempool-text-dim/60">ETH ref: ${ethUsd.toFixed(0)}</span>
              )}
            </div>
          </div>
          <div className="text-right text-[9px] text-mempool-text-dim space-y-0.5">
            <div className="text-mempool-text-dim/80">{chain?.name}</div>
            <div className="font-semibold text-purple-300">{pool.label}</div>
            <div>concentrated liq · x·y=k</div>
          </div>
        </div>
      )}

      {/* Orderbook */}
      {(price !== null || loading) && (
        <div>
          {/* Column headers */}
          <div className={`grid gap-1 text-[9px] uppercase tracking-wider text-mempool-text-dim px-1 mb-1 ${needsEthConv ? "grid-cols-[1fr_58px_90px_36px]" : "grid-cols-[1fr_90px_36px]"}`}>
            <span>Price ({pool?.displayQuote ?? "USD"})</span>
            {needsEthConv && <span className="text-yellow-400/70 text-right">≈ USDC</span>}
            <span className="text-right">Quantity</span>
            <span className="text-right">%</span>
          </div>

          {/* ASK side — above mid price, LPs hold token0 ready to sell */}
          <div className="space-y-px mb-1">
            <div className="text-[9px] text-mempool-text-dim/60 px-1 pb-0.5">
              ▲ Ask — {pool?.token0Symbol} for sale ({asks.length} levels)
            </div>
            {loading && asks.length === 0 ? (
              <div className="text-[10px] text-mempool-text-dim text-center py-3 animate-pulse">loading…</div>
            ) : asks.length === 0 ? (
              <div className="text-[10px] text-mempool-text-dim text-center py-2">no ask ticks sampled</div>
            ) : (
              <div className="max-h-52 overflow-y-auto space-y-px">
                {[...asks].reverse().map((l, i) => {
                  const usd = toUsd(l.price);
                  // Ask: token0 is being sold (e.g. LCX or WBTC); qty1 is also there but tiny
                  const mainQty = l.qty0 > 0 ? fmtQty(l.qty0, pool!.token0Symbol) : fmtQty(l.qty1, pool!.token1Symbol);
                  return (
                    <div key={`a${i}`} className={`relative grid gap-1 text-[10px] font-mono py-0.5 px-1 rounded overflow-hidden ${needsEthConv ? "grid-cols-[1fr_58px_90px_36px]" : "grid-cols-[1fr_90px_36px]"}`}>
                      <div className="absolute inset-y-0 right-0 bg-orange-500/10" style={{ width: `${l.liqPct}%` }} />
                      <span className="text-orange-400 relative z-10">{pricePrefix(pool!)}{fmtPrice(l.price, pool!)}{priceSuffix(pool!)}</span>
                      {needsEthConv && <span className="text-yellow-300/70 relative z-10 text-right">${usd !== null ? usd.toFixed(4) : "…"}</span>}
                      <span className="text-mempool-text-dim relative z-10 text-right">{mainQty}</span>
                      <span className="text-mempool-text-dim/50 relative z-10 text-right">{l.liqPct}%</span>
                    </div>
                  );
                })}
              </div>
            )}
          </div>

          {/* Mid separator */}
          {price !== null && pool && (
            <div className="flex items-center gap-3 py-1.5 px-3 my-1 rounded bg-mempool-bg border border-mempool-border/60">
              <span className="text-base font-bold text-mempool-text font-mono">
                {pricePrefix(pool)}{fmtPrice(price, pool)}{priceSuffix(pool)}
              </span>
              {priceUsd !== null && (
                <span className="text-sm font-semibold text-yellow-300 font-mono">
                  ≈ ${fmtPrice(priceUsd, { ...pool, displayQuote: "USD" })}
                </span>
              )}
              <span className="text-[9px] text-mempool-text-dim">← mid</span>
              <span className="ml-auto text-[9px] text-mempool-text-dim/60">
                {tickSpacing(pool.fee) * 0.01}% / tick
              </span>
            </div>
          )}

          {/* BID side — below mid price, LPs hold token1 (WETH) ready to buy token0 */}
          <div className="space-y-px mt-1">
            <div className="text-[9px] text-mempool-text-dim/60 px-1 pb-0.5">
              ▼ Bid — {pool?.token1Symbol} buying {pool?.token0Symbol} ({bids.length} levels)
            </div>
            {loading && bids.length === 0 ? (
              <div className="text-[10px] text-mempool-text-dim text-center py-3 animate-pulse">loading…</div>
            ) : bids.length === 0 ? (
              <div className="text-[10px] text-mempool-text-dim text-center py-2">no bid ticks sampled</div>
            ) : (
              <div className="max-h-52 overflow-y-auto space-y-px">
                {bids.map((l, i) => {
                  const usd = toUsd(l.price);
                  // Bid: token1 (WETH) is the liquidity on bid side
                  const mainQty = l.qty1 > 0 ? fmtQty(l.qty1, pool!.token1Symbol) : fmtQty(l.qty0, pool!.token0Symbol);
                  return (
                    <div key={`b${i}`} className={`relative grid gap-1 text-[10px] font-mono py-0.5 px-1 rounded overflow-hidden ${needsEthConv ? "grid-cols-[1fr_58px_90px_36px]" : "grid-cols-[1fr_90px_36px]"}`}>
                      <div className="absolute inset-y-0 right-0 bg-green-500/10" style={{ width: `${l.liqPct}%` }} />
                      <span className="text-green-400 relative z-10">{pricePrefix(pool!)}{fmtPrice(l.price, pool!)}{priceSuffix(pool!)}</span>
                      {needsEthConv && <span className="text-yellow-300/70 relative z-10 text-right">${usd !== null ? usd.toFixed(4) : "…"}</span>}
                      <span className="text-mempool-text-dim relative z-10 text-right">{mainQty}</span>
                      <span className="text-mempool-text-dim/50 relative z-10 text-right">{l.liqPct}%</span>
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        </div>
      )}

      {/* Legend */}
      <div className="pt-2 border-t border-mempool-border/40 grid grid-cols-2 gap-x-4 text-[9px] text-mempool-text-dim">
        <div><span className="text-orange-400">▲ Ask</span> — LP sells above mid</div>
        <div><span className="text-green-400">▼ Bid</span> — LP buys below mid</div>
        <div>{isV2 ? "Depth = x·y=k curve simulation" : "Depth = cumulative liquidityGross per tick"}</div>
        <div>{isV2 ? `V2 pool · fee ${pool ? pool.fee / 10000 : "?"}% · 10 levels ±0.5%` : `±${TICKS_EACH_SIDE} ticks · fee ${pool ? pool.fee / 10000 : "?"}% · spacing ${pool ? tickSpacing(pool.fee) : "?"}`}</div>
        {needsEthConv && ethUsd && (
          <div className="col-span-2 text-yellow-400/70 mt-0.5">
            <span className="text-yellow-300">USDC</span> prices via ETH/USDC ref pool · ETH = ${ethUsd.toFixed(2)}
          </div>
        )}
      </div>
    </div>
  );
}
