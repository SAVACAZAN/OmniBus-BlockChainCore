#!/usr/bin/env node
// Phase 5b — Finish testing pair 0 + 6 (which Phase 5 didn't complete due to 502)
import { secp256k1 } from '../frontend/node_modules/@noble/curves/secp256k1.js';
import { sha256 } from '../frontend/node_modules/@noble/hashes/sha2.js';
import { mnemonicToSeedSync } from '../frontend/node_modules/@scure/bip39/index.js';
import { HDKey } from '../frontend/node_modules/@scure/bip32/index.js';
import fs from 'node:fs';

const RPC = 'https://omnibusblockchain.cc:8443/api-testnet';
const TOKEN = '31926ece83bb8c9317ead56d60de99ed38c5d1e345055aedb0acf5db6512b8c4';
const MNEMONIC = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const ADDR = 'ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl';

const seed = mnemonicToSeedSync(MNEMONIC);
const root = HDKey.fromMasterSeed(seed);
const node = root.derive("m/44'/777'/0'/0/0");
const priv = node.privateKey;
const pub = secp256k1.getPublicKey(priv, true);
const pubHex = Buffer.from(pub).toString('hex');

async function rpc(method, params, retries = 2) {
  for (let i = 0; i <= retries; i++) {
    try {
      const r = await fetch(RPC, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TOKEN}` },
        body: JSON.stringify({ jsonrpc: '2.0', method, params, id: Date.now() }),
        signal: AbortSignal.timeout(15000),
      });
      const txt = await r.text();
      if (txt.startsWith('<')) {
        if (i < retries) { await new Promise(r => setTimeout(r, 2000)); continue; }
        return { error: { message: '502_bad_gateway' } };
      }
      return JSON.parse(txt);
    } catch (e) {
      if (i < retries) { await new Promise(r => setTimeout(r, 2000)); continue; }
      return { error: { message: e.message } };
    }
  }
}

function signOrder(side, pairId, price, amount, nonce, trader) {
  const msg = `EXCHANGE_ORDER_V1\n${side}\n${pairId}\n${price}\n${amount}\n${nonce}\n${trader}`;
  const hash = sha256(Buffer.from(msg, 'utf8'));
  const sig = secp256k1.sign(hash, priv, { lowS: true });
  return sig instanceof Uint8Array ? Buffer.from(sig).toString('hex') : Buffer.from(sig.toCompactRawBytes()).toString('hex');
}

const out = { pairs: {}, totals: { placed: 0, accepted: 0, cancelled: 0, filled: 0, failed: 0 }, lat: [] };
let baseNonce = Date.now() * 1000 + 100000;

async function stressPair(pid, name) {
  const r = { placed: 0, accepted: 0, cancelled: 0, filled: 0, failed: 0, errors: [], orderIds: [] };
  console.log(`\n=== Pair ${pid} ${name} ===`);
  for (let i = 0; i < 5; i++) {
    for (const side of ['buy', 'sell']) {
      const stepBps = (i + 1) * 50;
      const adj = side === 'buy' ? -stepBps : stepBps;
      const price = Math.floor(1_000_000 * (1 + adj / 10000));
      const amount = 100_000_000;
      const nonce = ++baseNonce;
      const sig = signOrder(side, pid, price, amount, nonce, ADDR);
      const t0 = Date.now();
      const resp = await rpc('exchange_placeOrder', [{
        trader: ADDR, pairId: pid, side, price, amount, nonce,
        signature: sig, publicKey: pubHex,
      }]);
      out.lat.push(Date.now() - t0);
      r.placed++;
      if (resp.error) {
        r.failed++;
        r.errors.push({ side, price, err: resp.error.message?.slice(0, 100) });
        console.log(`  ${side}@${price} FAIL: ${resp.error.message?.slice(0, 80)}`);
      } else {
        const oid = resp.result?.order_id || resp.result?.orderId || resp.result?.id;
        if (resp.result?.status === 'filled') { r.accepted++; r.filled++; }
        else if (oid !== undefined) { r.accepted++; r.orderIds.push(oid); }
        else r.failed++;
        console.log(`  ${side}@${price} OK orderId=${oid}`);
      }
      await new Promise(r => setTimeout(r, 100));
    }
  }
  // Verify orderbook reflects orders
  const ob = await rpc('exchange_getOrderbook', { pairId: pid });
  r.final_orderbook = ob.result ? { bids: ob.result.bids?.length || 0, asks: ob.result.asks?.length || 0, bestBid: ob.result.bestBid, bestAsk: ob.result.bestAsk } : null;

  console.log('  Cancelling 30s later...');
  await new Promise(r => setTimeout(r, 30000));
  for (const oid of r.orderIds) {
    const nonce = ++baseNonce;
    const cmsg = `EXCHANGE_CANCEL_V1\n${oid}\n${nonce}\n${ADDR}`;
    const csig = secp256k1.sign(sha256(Buffer.from(cmsg, 'utf8')), priv, { lowS: true });
    const csigHex = csig instanceof Uint8Array ? Buffer.from(csig).toString('hex') : Buffer.from(csig.toCompactRawBytes()).toString('hex');
    const cr = await rpc('exchange_cancelOrder', { trader: ADDR, orderId: oid, nonce, signature: csigHex, publicKey: pubHex });
    if (cr.error) console.log(`  cancel ${oid} FAIL: ${cr.error.message}`);
    else r.cancelled++;
    await new Promise(r => setTimeout(r, 60));
  }
  console.log(`  placed=${r.placed} accepted=${r.accepted} cancelled=${r.cancelled} filled=${r.filled} failed=${r.failed}`);
  return r;
}

const startTs = Date.now();
out.pairs[0] = await stressPair(0, 'OMNI/USDC');
out.pairs[6] = await stressPair(6, 'OMNI/ETH');
for (const p of [0, 6]) {
  out.totals.placed += out.pairs[p].placed;
  out.totals.accepted += out.pairs[p].accepted;
  out.totals.cancelled += out.pairs[p].cancelled;
  out.totals.filled += out.pairs[p].filled;
  out.totals.failed += out.pairs[p].failed;
}
out.duration_ms = Date.now() - startTs;
const sorted = [...out.lat].sort((a, b) => a - b);
out.latency = {
  count: sorted.length, p50: sorted[Math.floor(sorted.length * 0.5)],
  p95: sorted[Math.floor(sorted.length * 0.95)], max: sorted[sorted.length - 1],
};
fs.writeFileSync('phase5b-results.json', JSON.stringify(out, null, 2));
console.log('\n=== TOTALS ===\n', out.totals, '\nLatency:', out.latency);
