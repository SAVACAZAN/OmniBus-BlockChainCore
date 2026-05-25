/**
 * PQWalletPanel.tsx — Post-Quantum wallet panel.
 *
 * Shows 8 PQ address types (4 soulbound reputation domains + 4 transferable
 * OMNI-Quantum sub-addresses), allows sending from transferable PQ addresses,
 * and lists supported PQ schemes with their key/sig sizes.
 *
 * Soulbound (non-transferable, identity / reputation):
 *   ob_k1_  ML-DSA-87       LOVE   coin_type 778
 *   ob_f5_  Falcon-512      FOOD   coin_type 779
 *   ob_d5_  SLH-DSA-256s    RENT   coin_type 780
 *   ob_s3_  ML-DSA-87       VACATION coin_type 781
 *
 * Transferable OMNI Quantum sub-addresses:
 *   obk1_  ML-DSA-87
 *   obf5_  Falcon-512
 *   obd5_  SLH-DSA-256s
 *   obs3_  Dilithium-5
 *
 * RPCs: pq_balance, pq_send, pq_listSchemes
 */

import { useState, useEffect, useCallback } from "react";
import * as secp from "@noble/secp256k1";
import { sha256 } from "@noble/hashes/sha2";
import OmniBusRpcClient from "../../api/rpc-client";
import { useWallet } from "../../api/use-wallet";
import { bytesToHex, hexToBytes } from "../../api/exchange-sign";
import { PQ_OMNI_SCHEMES } from "../../api/wallet-keystore";
import type { PqOmniSlot } from "../../api/wallet-keystore";

const rpc = new OmniBusRpcClient();

// ── Types ──────────────────────────────────────────────────────────────────

interface PqAddressRow {
  label: string;
  tier: string;
  algo: string;
  bits: number;
  prefix: string;
  address: string;
  balance: number; // satoshis
  soulbound: boolean;
  colorClass: string;
  emoji: string;
}

interface PqSchemeRow {
  name: string;
  code: number;
  key_size: number;
  sig_size: number;
  security_level: number;
  prefix: string;
}

type SubTab = "addresses" | "send" | "schemes";

// ── Helpers ────────────────────────────────────────────────────────────────

function fmtOmni(sat: number): string {
  return (sat / 1e9).toFixed(4);
}

function shortAddr(addr: string): string {
  if (addr.length <= 18) return addr;
  return `${addr.slice(0, 10)}…${addr.slice(-6)}`;
}

/** Inline secp256k1 + SHA256d sign — same recipe as StakePage / WalletPage. */
function signMessage(
  privKeyHex: string,
  msg: string,
): { signature: string; publicKey: string } {
  const bytes = new TextEncoder().encode(msg);
  const h = sha256(sha256(bytes));
  const priv = hexToBytes(privKeyHex);
  const sig = secp.sign(h, priv, { lowS: true });
  const pub = secp.getPublicKey(priv, true);
  return { signature: bytesToHex(sig.toBytes()), publicKey: bytesToHex(pub) };
}

// Soulbound address metadata — in same order as coin_types 778-781.
// Addresses are stored in wallet.soulboundAddresses[].
const SOULBOUND_META = [
  { tier: "LOVE",     emoji: "❤️",  colorClass: "text-red-400",    algo: "ML-DSA-87",    bits: 256, prefix: "ob_k1_" },
  { tier: "FOOD",     emoji: "🥖",  colorClass: "text-orange-400", algo: "Falcon-512",   bits: 192, prefix: "ob_f5_" },
  { tier: "RENT",     emoji: "🏠",  colorClass: "text-green-400",  algo: "SLH-DSA-256s", bits: 256, prefix: "ob_d5_" },
  { tier: "VACATION", emoji: "🏖️", colorClass: "text-purple-400", algo: "ML-DSA-87",    bits: 256, prefix: "ob_s3_" },
];

// Transferable OMNI-Quantum color/emoji metadata (same order as PQ_OMNI_SCHEMES).
const TRANSFERABLE_META = [
  { emoji: "🔵", colorClass: "text-blue-400"   },
  { emoji: "🟡", colorClass: "text-yellow-400" },
  { emoji: "🟢", colorClass: "text-emerald-400"},
  { emoji: "🟣", colorClass: "text-violet-400" },
];

// Map short scheme name → wire scheme name expected by pq_send.
const SCHEME_WIRE: Record<string, string> = {
  ml_dsa_87:    "pq_omni_ml_dsa",
  falcon_512:   "pq_omni_falcon",
  dilithium_5:  "pq_omni_dilithium",
  slh_dsa_256s: "pq_omni_slh_dsa",
};

// ── Component ──────────────────────────────────────────────────────────────

export function PQWalletPanel() {
  const wallet = useWallet();
  const [tab, setTab] = useState<SubTab>("addresses");

  // ── Tab 1: addresses ──────────────────────────────────────────────────
  const [rows, setRows] = useState<PqAddressRow[]>([]);
  const [loadingBal, setLoadingBal] = useState(false);
  const [copied, setCopied] = useState<string | null>(null);

  // ── Tab 2: send ───────────────────────────────────────────────────────
  const [sendTo, setSendTo] = useState("");
  const [sendAmount, setSendAmount] = useState("");
  const [sendScheme, setSendScheme] = useState<string>(PQ_OMNI_SCHEMES[0].scheme);
  const [sending, setSending] = useState(false);
  const [sendResult, setSendResult] = useState<{ ok: boolean; msg: string; txid?: string } | null>(null);

  // ── Tab 3: schemes ────────────────────────────────────────────────────
  const [schemes, setSchemes] = useState<PqSchemeRow[]>([]);
  const [loadingSchemes, setLoadingSchemes] = useState(false);

  // Build rows array from wallet state + fetch balances.
  const loadAddresses = useCallback(async () => {
    if (!wallet) return;
    setLoadingBal(true);

    const built: PqAddressRow[] = [];

    // Soulbound addresses.
    const soulboundList = wallet.soulboundAddresses ?? [];
    for (let i = 0; i < SOULBOUND_META.length; i++) {
      const meta = SOULBOUND_META[i];
      const entry = soulboundList.find(
        (s) => s.prefix === meta.prefix || s.tier === meta.tier,
      );
      const addr = entry?.address ?? "";
      let balance = 0;
      if (addr) {
        try {
          const res: unknown = await rpc.request_raw("pq_balance", [{ address: addr }]);
          const r = res as { balance?: number } | null;
          balance = r?.balance ?? 0;
        } catch { /* ignore */ }
      }
      built.push({
        label: `${meta.emoji} ${meta.tier}`,
        tier: meta.tier,
        algo: meta.algo,
        bits: meta.bits,
        prefix: meta.prefix,
        address: addr,
        balance,
        soulbound: true,
        colorClass: meta.colorClass,
        emoji: meta.emoji,
      });
    }

    // Transferable PQ-OMNI addresses.
    const pqOmniList: PqOmniSlot[] = wallet.pqOmni ?? [];
    for (let i = 0; i < PQ_OMNI_SCHEMES.length; i++) {
      const scheme = PQ_OMNI_SCHEMES[i];
      const meta = TRANSFERABLE_META[i];
      const slot = pqOmniList.find((s) => s.scheme === scheme.scheme);
      const addr = slot?.address ?? "";
      let balance = 0;
      if (addr) {
        try {
          const res: unknown = await rpc.request_raw("pq_balance", [{ address: addr }]);
          const r = res as { balance?: number } | null;
          balance = r?.balance ?? 0;
        } catch { /* ignore */ }
      }
      built.push({
        label: `${meta.emoji} ${scheme.algo}`,
        tier: scheme.scheme,
        algo: scheme.algo,
        bits: scheme.bits,
        prefix: scheme.prefix,
        address: addr,
        balance,
        soulbound: false,
        colorClass: meta.colorClass,
        emoji: meta.emoji,
      });
    }

    setRows(built);
    setLoadingBal(false);
  }, [wallet]);

  useEffect(() => {
    if (tab === "addresses") {
      loadAddresses();
    }
  }, [tab, loadAddresses]);

  // Load schemes on mount (cheap read-only call).
  useEffect(() => {
    if (tab !== "schemes") return;
    setLoadingSchemes(true);
    rpc
      .request_raw("pq_listSchemes", [])
      .then((res: unknown) => {
        const r = res as { schemes?: PqSchemeRow[] } | PqSchemeRow[] | null;
        if (Array.isArray(r)) setSchemes(r);
        else if (r && "schemes" in r && Array.isArray(r.schemes)) setSchemes(r.schemes);
      })
      .catch(() => { /* node may not expose yet */ })
      .finally(() => setLoadingSchemes(false));
  }, [tab]);

  const copyAddr = (addr: string) => {
    navigator.clipboard.writeText(addr).catch(() => {});
    setCopied(addr);
    setTimeout(() => setCopied(null), 2000);
  };

  // ── Send handler ──────────────────────────────────────────────────────
  const handleSend = async () => {
    if (!wallet || !sendTo || !sendAmount) return;
    const toAddr = sendTo.trim();
    if (!/^ob/.test(toAddr)) {
      setSendResult({ ok: false, msg: "Destination must start with 'ob' (OmniBus address)" });
      return;
    }

    setSending(true);
    setSendResult(null);
    try {
      const amountSat = Math.floor(parseFloat(sendAmount) * 1e9);
      if (amountSat <= 0) throw new Error("Amount must be > 0");

      const pqOmniList: PqOmniSlot[] = wallet.pqOmni ?? [];
      const slot = pqOmniList.find((s) => s.scheme === sendScheme);
      if (!slot) throw new Error("PQ-OMNI slot not derived — re-unlock from mnemonic");
      if (!slot.secretKey?.length)
        throw new Error("PQ secret key missing — re-unlock from mnemonic (not from vault)");

      // Nonce
      const nonceRes: unknown = await rpc.request_raw("getnonce", [slot.address]);
      const nr = nonceRes as { nonce?: number } | number | null;
      const nonce: number =
        typeof nr === "number" ? nr : typeof nr === "object" && nr && "nonce" in nr ? (nr.nonce ?? 0) : 0;

      const txId = Math.floor(Math.random() * 0x7fffffff);
      const timestamp = Math.floor(Date.now() / 1000);
      const fee = 1000; // 0.000001 OMNI default

      const { hexToBytes: hToB, bytesToHex: bToH, buildTxHash, pqSign } =
        await import("../../api/pq-sign");

      const pubKeyBytes = hToB(slot.publicKey);
      const schemeIdx = PQ_OMNI_SCHEMES.findIndex((s) => s.scheme === slot.scheme);
      const schemeCode = schemeIdx >= 0 ? schemeIdx + 5 : 5;

      const msgHash = buildTxHash({
        id: txId,
        from: slot.address,
        to: toAddr,
        amount: amountSat,
        fee,
        timestamp,
        nonce,
        schemeCode,
        publicKeyBytes: pubKeyBytes,
        opReturn: "",
      });

      const sigBytes = await pqSign(slot.scheme, hToB(slot.secretKey), msgHash);
      const wireScheme = SCHEME_WIRE[slot.scheme] ?? slot.scheme;

      const result: unknown = await rpc.pqSend({
        from: slot.address,
        to: toAddr,
        amount: amountSat,
        fee,
        scheme: wireScheme,
        signature: bToH(sigBytes),
        public_key: bToH(pubKeyBytes),
        id: txId,
        timestamp,
        nonce,
        op_return: "",
      });
      const r = result as { txid?: string } | string | null;
      const txid = typeof r === "string" ? r : (r as { txid?: string })?.txid ?? "";
      setSendResult({ ok: true, msg: `PQ TX sent (${slot.scheme})`, txid });
      setSendTo("");
      setSendAmount("");
    } catch (err: unknown) {
      const e = err as Error;
      setSendResult({ ok: false, msg: e.message || "Transaction failed" });
    } finally {
      setSending(false);
    }
  };

  // ── Locked guard ──────────────────────────────────────────────────────
  if (!wallet) {
    return (
      <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-6 text-center">
        <p className="text-mempool-text-dim text-sm">
          Connect your wallet to view PQ addresses.
        </p>
      </div>
    );
  }

  const hasPqData =
    (wallet.pqOmni?.length ?? 0) > 0 || (wallet.soulboundAddresses?.length ?? 0) > 0;

  // ── Render ────────────────────────────────────────────────────────────
  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4">
        <div className="flex items-center justify-between">
          <div>
            <h2 className="text-mempool-text font-semibold text-lg">Post-Quantum Wallet</h2>
            <p className="text-mempool-text-dim text-xs mt-0.5">
              8 PQ addresses — 4 soulbound (identity) + 4 transferable (OMNI-Quantum)
            </p>
          </div>
          {!hasPqData && (
            <span className="text-xs text-orange-400 bg-orange-400/10 border border-orange-400/30 rounded-lg px-3 py-1">
              Re-unlock from mnemonic for full PQ keys
            </span>
          )}
        </div>
      </div>

      {/* Sub-tabs */}
      <div className="flex gap-1 bg-mempool-bg-elev rounded-xl border border-mempool-border p-1">
        {(["addresses", "send", "schemes"] as SubTab[]).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`flex-1 py-2 text-sm font-medium rounded-lg transition-colors ${
              tab === t
                ? "bg-mempool-blue text-white"
                : "text-mempool-text-dim hover:text-mempool-text"
            }`}
          >
            {t === "addresses" ? "PQ Addresses" : t === "send" ? "Send PQ" : "Schemes"}
          </button>
        ))}
      </div>

      {/* ── Tab 1: PQ Addresses ─────────────────────────────────────── */}
      {tab === "addresses" && (
        <div className="space-y-3">
          {/* Soulbound section */}
          <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4">
            <div className="flex items-center gap-2 mb-3">
              <span className="text-xs font-semibold text-purple-400 bg-purple-400/10 border border-purple-400/30 rounded px-2 py-0.5">
                SOULBOUND
              </span>
              <span className="text-xs text-mempool-text-dim">
                Non-transferable · identity &amp; reputation domains
              </span>
            </div>
            <div className="space-y-2">
              {rows.filter((r) => r.soulbound).map((row) => (
                <PQAddressCard
                  key={row.prefix}
                  row={row}
                  copied={copied}
                  onCopy={copyAddr}
                  loadingBal={loadingBal}
                />
              ))}
              {!loadingBal && rows.filter((r) => r.soulbound).length === 0 && (
                <p className="text-mempool-text-dim text-xs text-center py-3">
                  Unlock from mnemonic to derive soulbound addresses.
                </p>
              )}
            </div>
          </div>

          {/* Transferable section */}
          <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4">
            <div className="flex items-center gap-2 mb-3">
              <span className="text-xs font-semibold text-blue-400 bg-blue-400/10 border border-blue-400/30 rounded px-2 py-0.5">
                TRANSFERABLE
              </span>
              <span className="text-xs text-mempool-text-dim">
                OMNI-Quantum sub-addresses · same chain semantics as OMNI
              </span>
            </div>
            <div className="space-y-2">
              {rows.filter((r) => !r.soulbound).map((row) => (
                <PQAddressCard
                  key={row.prefix}
                  row={row}
                  copied={copied}
                  onCopy={copyAddr}
                  loadingBal={loadingBal}
                />
              ))}
              {!loadingBal && rows.filter((r) => !r.soulbound).length === 0 && (
                <p className="text-mempool-text-dim text-xs text-center py-3">
                  Unlock from mnemonic to derive transferable PQ addresses.
                </p>
              )}
            </div>
          </div>

          {loadingBal && (
            <p className="text-mempool-text-dim text-xs text-center py-2 animate-pulse">
              Loading balances…
            </p>
          )}

          <button
            onClick={loadAddresses}
            disabled={loadingBal}
            className="w-full py-2 text-sm text-mempool-text-dim border border-mempool-border rounded-lg hover:border-mempool-blue hover:text-mempool-blue transition-colors disabled:opacity-50"
          >
            Refresh balances
          </button>
        </div>
      )}

      {/* ── Tab 2: Send PQ ──────────────────────────────────────────── */}
      {tab === "send" && (
        <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4 space-y-4">
          <h3 className="text-mempool-text font-semibold">Send from PQ-OMNI address</h3>

          {/* Source scheme */}
          <div className="space-y-1">
            <label className="text-xs text-mempool-text-dim">Source PQ scheme</label>
            <select
              value={sendScheme}
              onChange={(e) => setSendScheme(e.target.value)}
              className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text w-full focus:outline-none focus:border-mempool-blue"
            >
              {PQ_OMNI_SCHEMES.map((s) => {
                const slot = wallet.pqOmni?.find((p) => p.scheme === s.scheme);
                const addr = slot?.address ?? "";
                return (
                  <option key={s.scheme} value={s.scheme}>
                    {s.prefix} — {s.algo} {addr ? `(${addr.slice(0, 12)}…)` : "(no key)"}
                  </option>
                );
              })}
            </select>
            {!wallet.pqOmni?.find((p) => p.scheme === sendScheme)?.secretKey && (
              <p className="text-orange-400 text-xs">
                Secret key not in memory — re-unlock from mnemonic to sign PQ TX.
              </p>
            )}
          </div>

          {/* Destination */}
          <div className="space-y-1">
            <label className="text-xs text-mempool-text-dim">To address</label>
            <input
              type="text"
              value={sendTo}
              onChange={(e) => setSendTo(e.target.value)}
              placeholder="ob1q… / obk1_… / obf5_… / etc."
              className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text w-full focus:outline-none focus:border-mempool-blue"
            />
            {sendTo && !/^ob/.test(sendTo.trim()) && (
              <p className="text-red-400 text-xs">Address must start with 'ob'</p>
            )}
          </div>

          {/* Amount */}
          <div className="space-y-1">
            <label className="text-xs text-mempool-text-dim">Amount (OMNI)</label>
            <input
              type="number"
              value={sendAmount}
              onChange={(e) => setSendAmount(e.target.value)}
              placeholder="0.0000"
              min="0"
              step="0.0001"
              className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text w-full focus:outline-none focus:border-mempool-blue"
            />
            {sendAmount && (
              <p className="text-xs text-mempool-text-dim">
                = {Math.floor(parseFloat(sendAmount || "0") * 1e9).toLocaleString()} sat
              </p>
            )}
          </div>

          {/* Send button */}
          <button
            onClick={handleSend}
            disabled={sending || !sendTo || !sendAmount}
            className="bg-mempool-blue text-white px-4 py-2 rounded-lg text-sm font-semibold hover:opacity-90 disabled:opacity-50 w-full"
          >
            {sending ? "Signing & sending…" : "Send PQ Transaction"}
          </button>

          {sendResult && (
            <div
              className={`rounded-lg px-4 py-3 text-sm border ${
                sendResult.ok
                  ? "bg-green-500/10 border-green-500/30 text-green-300"
                  : "bg-red-500/10 border-red-500/30 text-red-300"
              }`}
            >
              <p className="font-medium">{sendResult.msg}</p>
              {sendResult.txid && (
                <p className="text-xs mt-1 font-mono opacity-80 break-all">
                  txid: {sendResult.txid}
                </p>
              )}
            </div>
          )}
        </div>
      )}

      {/* ── Tab 3: Schemes ──────────────────────────────────────────── */}
      {tab === "schemes" && (
        <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4">
          <h3 className="text-mempool-text font-semibold mb-3">Supported PQ Schemes</h3>

          {loadingSchemes && (
            <p className="text-mempool-text-dim text-xs animate-pulse">Loading…</p>
          )}

          {!loadingSchemes && schemes.length > 0 && (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="text-mempool-text-dim text-xs border-b border-mempool-border">
                    <th className="text-left pb-2 font-medium">Scheme</th>
                    <th className="text-right pb-2 font-medium">Code</th>
                    <th className="text-right pb-2 font-medium">Key (B)</th>
                    <th className="text-right pb-2 font-medium">Sig (B)</th>
                    <th className="text-right pb-2 font-medium">Security</th>
                    <th className="text-left pb-2 font-medium pl-3">Prefix</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-mempool-border/40">
                  {schemes.map((s) => (
                    <tr key={s.name} className="hover:bg-white/5">
                      <td className="py-2 text-mempool-text font-mono text-xs">{s.name}</td>
                      <td className="py-2 text-right text-mempool-text-dim">{s.code}</td>
                      <td className="py-2 text-right text-mempool-text-dim">{s.key_size.toLocaleString()}</td>
                      <td className="py-2 text-right text-mempool-text-dim">{s.sig_size.toLocaleString()}</td>
                      <td className="py-2 text-right">
                        <span className="text-mempool-blue text-xs">{s.security_level}-bit</span>
                      </td>
                      <td className="py-2 pl-3 font-mono text-xs text-purple-400">{s.prefix}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          {!loadingSchemes && schemes.length === 0 && (
            <div className="text-center py-4 space-y-2">
              <p className="text-mempool-text-dim text-sm">
                Node did not return scheme data (may be an older build).
              </p>
              <div className="text-left space-y-1 mt-3">
                {[
                  { name: "pq_omni_ml_dsa",    code: 5, key: 2592,  sig: 4627,  sec: 256, prefix: "obk1_" },
                  { name: "pq_omni_falcon",     code: 6, key: 897,   sig: 752,   sec: 192, prefix: "obf5_" },
                  { name: "pq_omni_dilithium",  code: 7, key: 2592,  sig: 4627,  sec: 256, prefix: "obs3_" },
                  { name: "pq_omni_slh_dsa",    code: 8, key: 64,    sig: 29792, sec: 256, prefix: "obd5_" },
                ].map((s) => (
                  <div
                    key={s.name}
                    className="flex items-center justify-between bg-mempool-bg rounded-lg px-3 py-2 text-xs"
                  >
                    <span className="font-mono text-mempool-text">{s.name}</span>
                    <span className="text-mempool-text-dim">
                      key {s.key}B · sig {s.sig}B · {s.sec}-bit
                    </span>
                    <span className="font-mono text-purple-400">{s.prefix}</span>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// ── Sub-component: address card ────────────────────────────────────────────

interface PQAddressCardProps {
  row: PqAddressRow;
  copied: string | null;
  onCopy: (addr: string) => void;
  loadingBal: boolean;
}

function PQAddressCard({ row, copied, onCopy, loadingBal }: PQAddressCardProps) {
  return (
    <div className="flex items-center justify-between gap-3 bg-mempool-bg rounded-lg px-3 py-2.5">
      {/* Left: domain info */}
      <div className="flex items-center gap-2 min-w-0">
        <div className={`w-8 h-8 rounded-lg flex items-center justify-center text-base flex-shrink-0 ${
          row.soulbound ? "bg-purple-500/10" : "bg-blue-500/10"
        }`}>
          {row.emoji}
        </div>
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <span className={`text-sm font-semibold ${row.colorClass}`}>{row.label}</span>
            <span className={`text-xs px-1.5 py-0.5 rounded font-medium ${
              row.soulbound
                ? "bg-purple-500/20 text-purple-400"
                : "bg-blue-500/20 text-blue-400"
            }`}>
              {row.soulbound ? "soulbound" : "transferable"}
            </span>
          </div>
          <div className="flex items-center gap-2 mt-0.5">
            <span className="text-xs text-mempool-text-dim">{row.algo}</span>
            <span className="text-xs text-mempool-text-dim opacity-60">{row.bits}-bit</span>
          </div>
        </div>
      </div>

      {/* Center: address */}
      <div className="flex-1 min-w-0 text-center">
        {row.address ? (
          <div className="flex items-center justify-center gap-1">
            <span className="font-mono text-xs text-mempool-text truncate">
              {shortAddr(row.address)}
            </span>
            <button
              onClick={() => onCopy(row.address)}
              className="flex-shrink-0 text-mempool-text-dim hover:text-mempool-blue transition-colors"
              title="Copy address"
            >
              {copied === row.address ? (
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" className="text-green-400">
                  <path d="M20 6L9 17l-5-5" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />
                </svg>
              ) : (
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
                  <rect x="9" y="9" width="13" height="13" rx="2" stroke="currentColor" strokeWidth="2" />
                  <path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1" stroke="currentColor" strokeWidth="2" />
                </svg>
              )}
            </button>
          </div>
        ) : (
          <span className="text-xs text-mempool-text-dim italic">not derived</span>
        )}
      </div>

      {/* Right: balance */}
      <div className="text-right flex-shrink-0 w-24">
        {loadingBal ? (
          <span className="text-mempool-text-dim text-xs animate-pulse">…</span>
        ) : (
          <span className={`text-sm font-semibold ${row.balance > 0 ? "text-mempool-green" : "text-mempool-text-dim"}`}>
            {fmtOmni(row.balance)}
          </span>
        )}
        <p className="text-xs text-mempool-text-dim">OMNI</p>
      </div>
    </div>
  );
}

// Ensure signMessage is "used" for future inline use — suppress lint warning.
void signMessage;
