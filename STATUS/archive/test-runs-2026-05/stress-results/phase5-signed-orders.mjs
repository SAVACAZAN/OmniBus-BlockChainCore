#!/usr/bin/env node
// Phase 5 — signed multi-chain order placement on testnet
// Uses the test wallet (mnemonic="abandon... about") to sign EXCHANGE_ORDER_V1 messages.

import { secp256k1 } from '../frontend/node_modules/@noble/curves/secp256k1.js';
import { sha256 } from '../frontend/node_modules/@noble/hashes/sha2.js';
import { mnemonicToSeedSync } from '../frontend/node_modules/@scure/bip39/index.js';
import { HDKey } from '../frontend/node_modules/@scure/bip32/index.js';
import { ripemd160 } from '../frontend/node_modules/@noble/hashes/legacy.js';
import { bech32 } from '../frontend/node_modules/@scure/base/lib/esm/index.js';
import fs from 'node:fs';

const RPC = 'https://omnibusblockchain.cc:8443/api-testnet';
const TOKEN = '31926ece83bb8c9317ead56d60de99ed38c5d1e345055aedb0acf5db6512b8c4';
const MNEMONIC = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const EXPECTED_ADDR = 'ob1qw6zhsqg29aht23fksk5w54lkgavatpgltqxlvl';
const PAIRS = [
  { id: 0, name: 'OMNI/USDC' },
  { id: 2, name: 'LCX/USDC' },
  { id: 3, name: 'ETH/USDC' },
  { id: 5, name: 'OMNI/LCX' },
  { id: 6, name: 'OMNI/ETH' },
];

// Derive OMNI key at OmniBus path m/44'/777'/0'/0/0
const seed = mnemonicToSeedSync(MNEMONIC);
const root = HDKey.fromMasterSeed(seed);
const node = root.derive("m/44'/777'/0'/0/0");
const privBytes = node.privateKey;
const pub = secp256k1.getPublicKey(privBytes, true); // compressed 33B
const pubHex = Buffer.from(pub).toString('hex');

// Derive bech32 ob1q... from pubkey hash160
const h160 = ripemd160(sha256(pub));
const words = bech32.toWords(h160);
const addr = bech32.encode('ob', [0x00, ...words]);
console.log(`Derived address: ${addr}`);
console.log(`Expected:        ${EXPECTED_ADDR}`);
if (addr !== EXPECTED_ADDR) {
  console.error('Address mismatch!');
}

async function rpc(method, params) {
  const r = await fetch(RPC, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ jsonrpc: '2.0', method, params, id: Date.now() }),
  });
  return r.json();
}

function signOrder(side, pairId, price, amount, nonce, trader) {
  const msg = `EXCHANGE_ORDER_V1\n${side}\n${pairId}\n${price}\n${amount}\n${nonce}\n${trader}`;
  const hash = sha256(Buffer.from(msg, 'utf8'));
  // secp256k1 ECDSA — chain expects raw 64-byte r||s (low-s)
  const sig = secp256k1.sign(hash, privBytes, { lowS: true });
  // newer noble/curves returns Uint8Array (raw 64 bytes); older returns object with toCompactHex
  const sigHex = sig instanceof Uint8Array
    ? Buffer.from(sig).toString('hex')
    : (typeof sig.toCompactHex === 'function' ? sig.toCompactHex() : Buffer.from(sig.toCompactRawBytes()).toString('hex'));
  return { sig: sigHex, msg };
}

const out = { pairs: {}, totals: { placed: 0, accepted: 0, cancelled: 0, filled: 0, failed: 0 }, errors: [], lat: [] };

let baseNonce = Date.now();

async function stressPair(pair) {
  console.log(`\n=== Pair ${pair.id} ${pair.name} ===`);
  const r = { placed: 0, accepted: 0, cancelled: 0, filled: 0, failed: 0, errors: [], orderIds: [] };

  // Get mid-price reference: use feed median for OMNI=BTC=$1 fallback
  // Use price=1 USDC = 1_000_000 micro-USD; amount = 100_000_000 sat (0.1 OMNI)
  const midMicro = 1_000_000; // $1.00

  for (let i = 0; i < 5; i++) {
    for (const side of ['buy', 'sell']) {
      const stepBps = (i + 1) * 50; // 0.5%, 1%, 1.5%, 2%, 2.5%
      const adj = side === 'buy' ? -stepBps : stepBps;
      const price = Math.floor(midMicro * (1 + adj / 10000));
      const amount = 100_000_000; // 0.1 OMNI
      const nonce = ++baseNonce;
      const { sig } = signOrder(side, pair.id, price, amount, nonce, addr);

      const t0 = Date.now();
      const params = {
        trader: addr, pairId: pair.id, side, price, amount, nonce,
        signature: sig, publicKey: pubHex,
      };
      const resp = await rpc('exchange_placeOrder', [params]);
      const dt = Date.now() - t0;
      out.lat.push(dt);
      r.placed++;

      if (resp.error) {
        r.failed++;
        r.errors.push({ side, price, err: resp.error.message?.slice(0, 120) });
        console.log(`  ${side}@${price} FAIL: ${resp.error.message?.slice(0, 80)}`);
      } else {
        const oid = resp.result?.order_id || resp.result?.orderId || resp.result?.id;
        if (resp.result?.status === 'filled') { r.accepted++; r.filled++; }
        else if (oid !== undefined) { r.accepted++; r.orderIds.push(oid); }
        else r.failed++;
        console.log(`  ${side}@${price} OK orderId=${oid} ${dt}ms`);
      }
      await new Promise(r => setTimeout(r, 80));
    }
  }

  // Sleep 30s, then cancel
  console.log('  Sleeping 30s before cancellation...');
  await new Promise(r => setTimeout(r, 30000));

  for (const oid of r.orderIds) {
    const nonce = ++baseNonce;
    const cancelMsg = `EXCHANGE_CANCEL_V1\n${oid}\n${nonce}\n${addr}`;
    const hash = sha256(Buffer.from(cancelMsg, 'utf8'));
    const sigRaw = secp256k1.sign(hash, privBytes, { lowS: true });
    const sig = sigRaw instanceof Uint8Array
      ? Buffer.from(sigRaw).toString('hex')
      : (typeof sigRaw.toCompactHex === 'function' ? sigRaw.toCompactHex() : Buffer.from(sigRaw.toCompactRawBytes()).toString('hex'));
    const resp = await rpc('exchange_cancelOrder', [{
      trader: addr, order_id: oid, nonce, signature: sig, publicKey: pubHex,
    }]);
    if (resp.error) console.log(`  cancel ${oid} FAIL: ${resp.error.message?.slice(0, 80)}`);
    else r.cancelled++;
    await new Promise(r => setTimeout(r, 50));
  }

  // Verify orderbook updated
  const ob = await rpc('exchange_listOrders', [{ pair_id: pair.id }]);
  r.final_orderbook = {
    asks: ob.result?.asks?.length || 0,
    bids: ob.result?.bids?.length || 0,
  };

  console.log(`  placed=${r.placed} accepted=${r.accepted} cancelled=${r.cancelled} filled=${r.filled} failed=${r.failed}`);
  return r;
}

const startTs = Date.now();
for (const p of PAIRS) {
  out.pairs[p.id] = await stressPair(p);
  out.totals.placed += out.pairs[p.id].placed;
  out.totals.accepted += out.pairs[p.id].accepted;
  out.totals.cancelled += out.pairs[p.id].cancelled;
  out.totals.filled += out.pairs[p.id].filled;
  out.totals.failed += out.pairs[p.id].failed;
}
out.duration_ms = Date.now() - startTs;
out.derived_address = addr;
out.publicKey = pubHex;

const sorted = [...out.lat].sort((a, b) => a - b);
out.latency = {
  count: sorted.length,
  p50: sorted[Math.floor(sorted.length * 0.5)],
  p95: sorted[Math.floor(sorted.length * 0.95)],
  p99: sorted[Math.floor(sorted.length * 0.99)],
  max: sorted[sorted.length - 1],
};

fs.writeFileSync('phase5-signed-results.json', JSON.stringify(out, null, 2));
console.log('\n=== TOTALS ===');
console.log(JSON.stringify(out.totals, null, 2));
console.log('Latency:', out.latency);
console.log('Saved to phase5-signed-results.json');
