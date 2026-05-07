import { useEffect, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import { getUnlocked, subscribeWallet } from "../../api/wallet-keystore";
import { buildBtcSpvProofObject, type BtcSpvProofObject } from "../../api/htlc-btc";
import { buildEthSpvProofObject, type EthSpvProofObject } from "../../api/htlc-eth";

const rpc = new OmniBusRpcClient();

type ChainCode = 1 | 2 | 3; // 1=btc, 2=eth, 3=base
const CHAIN_LABEL: Record<ChainCode, string> = { 1: "BTC", 2: "ETH", 3: "BASE" };

interface SwapBindingView {
  swap_id: string;
  order_id: number;
  state: "pending" | "both_locked" | "claimed" | "timed_out";
  maker_chain: string;
  taker_chain: string;
  timeout_block: number;
}

/**
 * Generate a random 32-byte preimage and its SHA-256 hash, both as
 * lowercase hex (64 chars). Browser-only — uses crypto.subtle.
 */
async function genPreimageAndHash(): Promise<{ preimage: string; hash: string }> {
  const buf = new Uint8Array(32);
  crypto.getRandomValues(buf);
  const digest = await crypto.subtle.digest("SHA-256", buf);
  const toHex = (u: Uint8Array) =>
    Array.from(u).map((b) => b.toString(16).padStart(2, "0")).join("");
  return { preimage: toHex(buf), hash: toHex(new Uint8Array(digest)) };
}

/**
 * Atomic Swap panel — bind an OmniBus on-chain orderbook entry to a
 * cross-chain HTLC counterparty. Flow:
 *
 *   1. User picks chain + amount + price + expiry, hits "Create swap".
 *   2. UI generates preimage R, computes hash_lock = sha256(R).
 *   3. UI calls htlc_btc_buildScript (or htlc_eth_buildScript) to get
 *      the remote-chain HTLC address — user funds it manually (QR / copy).
 *   4. User pastes the funding txid (or contract id) and clicks
 *      "Bind on-chain", which calls swap_open with that reference.
 *   5. The Omnibus side is placed via exchange_placeOrder so a local
 *      taker can match it; meanwhile the SwapBinding tracks both legs.
 *   6. When the taker reveals the preimage on the remote chain, the user
 *      pastes it here and clicks "Settle"; we call swap_proveSettle.
 */
export function AtomicSwapPanel() {
  const [, force] = useState(0);
  useEffect(() => subscribeWallet(() => force((n) => n + 1)), []);

  const u = getUnlocked();

  const [base, setBase] = useState("OMNI");
  const [quote, setQuote] = useState<keyof typeof CHAIN_LABEL extends never ? "BTC" : "BTC" | "ETH" | "BASE">("BTC");
  const [amount, setAmount] = useState("");
  const [price, setPrice] = useState("");
  const [expiryBlock, setExpiryBlock] = useState("");
  const [orderId, setOrderId] = useState("");
  const [remoteRef, setRemoteRef] = useState("");

  const [preimage, setPreimage] = useState<string | null>(null);
  const [hashLock, setHashLock] = useState<string | null>(null);
  const [btcAddress, setBtcAddress] = useState<string | null>(null);
  const [bindings, setBindings] = useState<SwapBindingView[]>([]);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const refreshBindings = async () => {
    try {
      const r = await rpc.request_raw("swap_listOpen", [{ address: u?.address ?? "" }]);
      if (Array.isArray(r)) setBindings(r as SwapBindingView[]);
    } catch (e) {
      // swap_listOpen may be unsupported on the connected node — silent.
      console.debug("swap_listOpen unavailable:", e);
    }
  };

  useEffect(() => {
    refreshBindings();
    const id = setInterval(refreshBindings, 6000);
    return () => clearInterval(id);
  }, [u?.address]);

  const chainCode = (q: string): ChainCode => (q === "BTC" ? 1 : q === "ETH" ? 2 : 3);

  const onGenerateSecret = async () => {
    setErr(null);
    setMsg(null);
    const { preimage, hash } = await genPreimageAndHash();
    setPreimage(preimage);
    setHashLock(hash);

    if (chainCode(quote) === 1) {
      // BTC — call the other agent's htlc_btc_buildScript handler.
      try {
        const lockerAddr = u?.address ?? "";
        const res = await rpc.request_raw("htlc_btc_buildScript", [{
          recipient: lockerAddr,
          sender: lockerAddr,
          hash_lock: hash,
          timeout: Number(expiryBlock || "0"),
        }]);
        if (res && typeof res === "object" && "address" in res) {
          setBtcAddress(String(res.address));
          setMsg("Fund the BTC address below, then paste the funding txid to bind on-chain.");
        } else {
          setMsg("Generated preimage. Provide the remote chain HTLC reference manually.");
        }
      } catch (e) {
        setMsg("htlc_btc_buildScript not available on this node — provide remote ref manually.");
      }
    } else {
      setMsg("Generated preimage. Deploy/find the EVM HTLC and paste its (chain_id, contract, id) reference.");
    }
  };

  const onBind = async () => {
    if (!hashLock) return setErr("Generate preimage + hash first.");
    if (!orderId) return setErr("Provide the order_id (the matching engine assigns it on placeOrder).");
    if (!remoteRef) return setErr("Provide the remote chain HTLC reference (hex).");
    setBusy(true);
    setErr(null);
    try {
      const res = await rpc.request_raw("swap_open", [{
        order_id: Number(orderId),
        taker_chain: chainCode(quote),
        taker_htlc_ref: remoteRef.replace(/^0x/, ""),
        hash_lock: hashLock,
        timeout: Number(expiryBlock || "0"),
      }]);
      setMsg(`Bound: swap_id=${res?.swap_id ?? "?"} state=${res?.state ?? "?"}`);
      refreshBindings();
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };

  /**
   * Call swap_proveSettle. Uses the new JSON-object shape for
   * `spv_proof_blob` when a proof object is provided; otherwise
   * sends preimage-only (the node falls into dev-mode warning path).
   *
   * The `spv_proof_blob` field, when present, is sent as a STRUCTURED
   * JSON object (chain/block_height/tx_hash/merkle_proof/indices/...)
   * — the OmniBus node's rpc_server.zig now detects this shape via
   * findJsonObject and verifies via verifySpvProofJson. The legacy
   * flat-string form remains accepted by the node for backward compat.
   */
  const callSwapProveSettle = async (
    swap_id: string,
    preimageHex: string,
    proof?: BtcSpvProofObject | EthSpvProofObject,
  ) => {
    const params: Record<string, unknown> = { swap_id, preimage: preimageHex };
    if (proof !== undefined) params.spv_proof_blob = proof;
    return rpc.request_raw("swap_proveSettle", [params]);
  };

  const onSettle = async (swap_id: string) => {
    if (!preimage) return setErr("Need the preimage to settle.");
    setBusy(true);
    setErr(null);
    try {
      // No SPV proof in the dev-mode UI yet. The helpers below show how
      // to construct a proper proof object for both chains:
      //   buildBtcSpvProofObject({ blockHeight, txHash, merkleProof, indices })
      //   buildEthSpvProofObject({ blockHeight, txHash, txIndexRlp,
      //                            receiptRlp, receiptProof, chainId? })
      // When the UI exposes proof inputs, pass the result as `proof` here.
      void buildBtcSpvProofObject; // re-export anchor for tree-shaking guards
      void buildEthSpvProofObject;
      const res = await callSwapProveSettle(swap_id, preimage);
      setMsg(`Settled ${swap_id}: ${res?.state ?? "?"}`);
      refreshBindings();
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="max-w-5xl mx-auto px-4 py-6 space-y-6">
      <header>
        <h1 className="text-xl font-semibold text-mempool-text">Atomic Swap (cross-chain)</h1>
        <p className="text-sm text-mempool-text-dim">
          Bind an Omnibus orderbook entry to a Bitcoin / Ethereum / Base HTLC.
          The Omnibus order is placed normally; the binding tracks the remote
          leg and settles atomically when the preimage is revealed on either chain.
        </p>
      </header>

      {!u && (
        <div className="text-mempool-orange text-sm">Unlock a wallet to create a swap.</div>
      )}

      <section className="border border-mempool-border bg-mempool-bg-elev rounded p-4 space-y-3">
        <h2 className="text-mempool-text font-medium">1 — New swap</h2>
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3 text-sm">
          <label className="flex flex-col">
            <span className="text-mempool-text-dim">Base</span>
            <input className="bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-mempool-text"
                   value={base} onChange={(e) => setBase(e.target.value.toUpperCase())} />
          </label>
          <label className="flex flex-col">
            <span className="text-mempool-text-dim">Quote (remote chain)</span>
            <select className="bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-mempool-text"
                    value={quote} onChange={(e) => setQuote(e.target.value as "BTC" | "ETH" | "BASE")}>
              <option value="BTC">BTC</option>
              <option value="ETH">ETH</option>
              <option value="BASE">BASE</option>
            </select>
          </label>
          <label className="flex flex-col">
            <span className="text-mempool-text-dim">Amount ({base})</span>
            <input className="bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-mempool-text"
                   value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.0" />
          </label>
          <label className="flex flex-col">
            <span className="text-mempool-text-dim">Price ({base}/{quote})</span>
            <input className="bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-mempool-text"
                   value={price} onChange={(e) => setPrice(e.target.value)} placeholder="0.0" />
          </label>
          <label className="flex flex-col col-span-2">
            <span className="text-mempool-text-dim">Expiry (Omnibus block height)</span>
            <input className="bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-mempool-text"
                   value={expiryBlock} onChange={(e) => setExpiryBlock(e.target.value)} placeholder="e.g. 200000" />
          </label>
        </div>
        <div className="flex gap-2">
          <button disabled={!u || busy}
                  onClick={onGenerateSecret}
                  className="bg-mempool-blue/20 border border-mempool-blue text-mempool-blue rounded px-3 py-1.5 hover:bg-mempool-blue/30 disabled:opacity-40">
            Generate preimage &amp; HTLC address
          </button>
        </div>
        {hashLock && (
          <div className="bg-mempool-bg border border-mempool-border rounded p-3 text-xs space-y-1">
            <div><span className="text-mempool-text-dim">hash_lock:</span> <code className="text-mempool-text">{hashLock}</code></div>
            <div><span className="text-mempool-text-dim">preimage:</span> <code className="text-mempool-text">{preimage}</code></div>
            <div className="text-mempool-orange">Save the preimage off-chain. Lose it = lose the swap.</div>
            {btcAddress && (
              <div className="pt-2">
                <span className="text-mempool-text-dim">Fund this BTC address:</span>{" "}
                <code className="text-mempool-text">{btcAddress}</code>
              </div>
            )}
          </div>
        )}
      </section>

      <section className="border border-mempool-border bg-mempool-bg-elev rounded p-4 space-y-3">
        <h2 className="text-mempool-text font-medium">2 — Bind on-chain</h2>
        <p className="text-xs text-mempool-text-dim">
          After your order_place TX is mined, the matching engine assigns it
          an order_id (visible in the User Orders panel). Paste it here along
          with the remote-chain HTLC reference (BTC: txid + vout LE; EVM:
          chain_id LE + contract + id).
        </p>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3 text-sm">
          <label className="flex flex-col">
            <span className="text-mempool-text-dim">order_id</span>
            <input className="bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-mempool-text"
                   value={orderId} onChange={(e) => setOrderId(e.target.value)} placeholder="42" />
          </label>
          <label className="flex flex-col">
            <span className="text-mempool-text-dim">remote HTLC ref (hex, max 80 chars)</span>
            <input className="bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-mempool-text"
                   value={remoteRef} onChange={(e) => setRemoteRef(e.target.value)} placeholder="aabbcc..." />
          </label>
        </div>
        <button disabled={!u || busy || !hashLock}
                onClick={onBind}
                className="bg-mempool-green/20 border border-mempool-green text-mempool-green rounded px-3 py-1.5 hover:bg-mempool-green/30 disabled:opacity-40">
          Bind swap on-chain
        </button>
      </section>

      <section className="border border-mempool-border bg-mempool-bg-elev rounded p-4 space-y-3">
        <div className="flex items-center justify-between">
          <h2 className="text-mempool-text font-medium">3 — Open swaps</h2>
          <button onClick={refreshBindings} className="text-xs text-mempool-blue hover:underline">refresh</button>
        </div>
        <table className="w-full text-xs">
          <thead className="text-mempool-text-dim">
            <tr>
              <th className="text-left py-1">swap_id</th>
              <th className="text-left">order</th>
              <th className="text-left">state</th>
              <th className="text-left">maker → taker</th>
              <th className="text-left">timeout</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {bindings.length === 0 && (
              <tr><td colSpan={6} className="text-mempool-text-dim py-2">No open swaps.</td></tr>
            )}
            {bindings.map((b) => (
              <tr key={b.swap_id} className="border-t border-mempool-border/40">
                <td className="py-1 font-mono">{b.swap_id.slice(0, 16)}…</td>
                <td>{b.order_id}</td>
                <td>{b.state}</td>
                <td>{b.maker_chain} → {b.taker_chain}</td>
                <td>{b.timeout_block}</td>
                <td>
                  {b.state === "both_locked" && (
                    <button onClick={() => onSettle(b.swap_id)}
                            disabled={busy || !preimage}
                            className="text-xs bg-mempool-blue/20 border border-mempool-blue text-mempool-blue rounded px-2 py-0.5">
                      Settle
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      {msg && <div className="text-mempool-green text-sm">{msg}</div>}
      {err && <div className="text-mempool-red text-sm">{err}</div>}
    </div>
  );
}

export default AtomicSwapPanel;
