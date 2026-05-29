/**
 * NotarizePage.tsx — On-chain document notarization + trustless escrow.
 *
 * Notarize:
 *   - Hash a file or text (browser-native crypto.subtle SHA-256)
 *   - Commit the hash on-chain via `notarizedoc` RPC
 *   - Verify any document hash against the chain via `verifynotarize`
 *   - Browse and revoke your own notarizations via `getnotarizations` / `revokenotarize`
 *
 * Escrow:
 *   - Create a hash-time-locked escrow via `escrow_create`
 *   - Release (recipient) or Refund (creator) or Dispute
 *   - Browse all your open/closed escrows via `getescrows`
 *
 * Signing uses secp256k1 SHA256d (same convention as StakePage / exchange-sign.ts).
 * Canonical message strings must stay in sync with rpc_server.zig verifiers.
 */

import React, { useCallback, useEffect, useRef, useState } from "react";
import { useBlockHeight } from "../../api/hooks/use-block-height";
import {
  FileText,
  Shield,
  Unlock,
  RefreshCw,
  AlertTriangle,
  Lock,
} from "lucide-react";
import { rpc } from "../../api/clients/rpc-client";
import { SAT_PER_OMNI, midTrunc, fmtOmni, fmtInt } from "../../utils/fmt";
import { AddressLabel } from "../common/AddressLabel";
import { CopyButton } from "../common/CopyButton";
import { useWallet } from "../../api/hooks/use-wallet";
import { signMessage } from "../../api/sign/exchange-sign";


// ── Constants ─────────────────────────────────────────────────────────────


// ── Types ─────────────────────────────────────────────────────────────────

type DocType = "contract" | "certificate" | "receipt" | "identity" | "media" | "other";

interface NotarizeResp {
  status: string;
  txid: string;
  notarize_id: number;
  doc_hash: string;
  doc_type: string;
  fee_sat: number;
}
interface VerifyResp {
  status: "valid" | "expired" | "revoked" | "not_found";
  notarize_id?: number;
  doc_hash: string;
  doc_type?: string;
  owner?: string;
  block_height?: number;
  tx_hash?: string;
  expiry_block?: number;
  note?: string;
}
interface NotarizationRow {
  notarize_id: number;
  doc_hash: string;
  doc_type: string;
  block_height: number;
  tx_hash: string;
  expiry_block: number;
  status: "valid" | "expired" | "revoked";
  note: string;
}
interface GetNotarizationsResp {
  notarizations: NotarizationRow[];
}

type EscrowStatus = "open" | "released" | "refunded" | "disputed";
interface EscrowRow {
  escrow_id: number;
  creator: string;
  recipient: string;
  amount_sat: number;
  condition_hash: string;
  timeout_block: number;
  created_block: number;
  status: EscrowStatus;
  role: "creator" | "recipient";
  release_tx_hash?: string;
  note?: string;
}
interface GetEscrowsResp {
  escrows: EscrowRow[];
}
interface EscrowCreateResp {
  status: string;
  txid: string;
  escrow_id: number;
  amount_sat: number;
  timeout_block: number;
  condition_hash: string;
}

type TopTab = "notarize" | "escrow" | "opreturn";
type NotarizeSubTab = "notarize-doc" | "verify-doc" | "my-docs";
type EscrowSubTab = "my-escrows" | "create-escrow" | "release-escrow";

const NOTARIZE_TOP_TABS: { id: TopTab; label: string }[] = [
  { id: "notarize", label: "Notarize" },
  { id: "escrow",   label: "Escrow" },
  { id: "opreturn", label: "OP_RETURN" },
];
const NOTARIZE_SUB_TABS: { id: NotarizeSubTab; label: string }[] = [
  { id: "notarize-doc", label: "Notarize" },
  { id: "verify-doc",   label: "Verify" },
  { id: "my-docs",      label: "My Docs" },
];
const ESCROW_SUB_TABS: { id: EscrowSubTab; label: string }[] = [
  { id: "my-escrows",     label: "My Escrows" },
  { id: "create-escrow",  label: "Create" },
  { id: "release-escrow", label: "Release" },
];

// ── SHA-256 helpers ───────────────────────────────────────────────────────

async function sha256Hex(data: Uint8Array | ArrayBuffer): Promise<string> {
  const hashBuf = await crypto.subtle.digest("SHA-256", data as BufferSource);
  return Array.from(new Uint8Array(hashBuf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function sha256HexFromText(text: string): Promise<string> {
  const enc = new TextEncoder().encode(text);
  return sha256Hex(enc.buffer);
}

// ── ECDSA signing (same convention as StakePage / exchange-sign.ts) ───────

function signNotarize(args: {
  privateKeyHex: string; from: string; docHash: string; docType: string;
  expiryBlocks: number; nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `NOTARIZE_V1\n${args.from}\n${args.docHash}\n${args.docType}\n${args.expiryBlocks}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

function signNotarizeRevoke(args: {
  privateKeyHex: string; from: string; notarizeId: number; nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `NOTARIZE_REVOKE_V1\n${args.from}\n${args.notarizeId}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

function signEscrowCreate(args: {
  privateKeyHex: string; from: string; to: string; amount: number;
  conditionHash: string; timeoutBlocks: number; nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `ESCROW_CREATE_V1\n${args.from}\n${args.to}\n${args.amount}\n${args.conditionHash}\n${args.timeoutBlocks}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

function signEscrowRelease(args: {
  privateKeyHex: string; from: string; escrowId: number; proofHash: string; nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `ESCROW_RELEASE_V1\n${args.from}\n${args.escrowId}\n${args.proofHash}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

function signEscrowRefund(args: {
  privateKeyHex: string; from: string; escrowId: number; nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `ESCROW_REFUND_V1\n${args.from}\n${args.escrowId}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

// ── Shared UI helpers ─────────────────────────────────────────────────────


function WalletRequired() {
  return (
    <p className="text-xs text-mempool-orange font-mono bg-mempool-orange/10 border border-mempool-orange/30 rounded px-3 py-2">
      Connect a wallet to use this feature. Signing happens locally — your private key never
      leaves the browser.
    </p>
  );
}

function Toast({ msg }: { msg: string | null }) {
  if (!msg) return null;
  return (
    <div className="fixed bottom-4 right-4 bg-mempool-bg-elev border border-mempool-border rounded px-4 py-2 text-xs text-mempool-text font-mono shadow-lg z-50 max-w-sm break-all">
      {msg}
    </div>
  );
}

function Spinner() {
  return <RefreshCw className="inline w-3.5 h-3.5 animate-spin" />;
}

function SubTabBar({
  tabs,
  active,
  onChange,
}: {
  tabs: { id: string; label: string }[];
  active: string;
  onChange: (t: string) => void;
}) {
  return (
    <div className="flex gap-1 border-b border-mempool-border mb-4 overflow-x-auto scrollbar-none">
      {tabs.map((t) => {
        const isActive = active === t.id;
        return (
          <button
            key={t.id}
            onClick={() => onChange(t.id)}
            className={
              "relative flex-shrink-0 px-3 sm:px-4 py-2.5 text-xs font-medium uppercase tracking-wider transition-colors whitespace-nowrap " +
              (isActive
                ? "text-mempool-blue"
                : "text-mempool-text-dim hover:text-mempool-text")
            }
          >
            {t.label}
            {isActive && (
              <span className="absolute left-0 right-0 -bottom-px h-0.5 bg-mempool-blue" />
            )}
          </button>
        );
      })}
    </div>
  );
}

const STATUS_BADGE_MAP: Record<string, string> = {
  valid:     "bg-green-500/20 text-green-400 border-green-500/40",
  released:  "bg-green-500/20 text-green-400 border-green-500/40",
  expired:   "bg-yellow-500/20 text-yellow-400 border-yellow-500/40",
  disputed:  "bg-orange-500/20 text-orange-400 border-orange-500/40",
  revoked:   "bg-red-500/20 text-red-400 border-red-500/40",
  not_found: "bg-red-500/20 text-red-400 border-red-500/40",
  open:      "bg-blue-500/20 text-blue-400 border-blue-500/40",
  refunded:  "bg-mempool-border/30 text-mempool-text-dim border-mempool-border",
};

const VERIFY_STATUS_COLOR: Record<string, string> = {
  valid:     "border-green-500/40 bg-green-500/5",
  expired:   "border-yellow-500/40 bg-yellow-500/5",
  revoked:   "border-red-500/40 bg-red-500/5",
  not_found: "border-red-500/40 bg-red-500/5",
};

function StatusBadge({ status }: { status: "valid" | "expired" | "revoked" | "not_found" | EscrowStatus }) {
  return (
    <span
      className={
        "text-[10px] uppercase tracking-wider px-2 py-0.5 rounded border font-medium " +
        (STATUS_BADGE_MAP[status] ?? STATUS_BADGE_MAP.refunded)
      }
    >
      {status.replace("_", " ")}
    </span>
  );
}

// ── File / text hash input ────────────────────────────────────────────────

function HashInput({
  hash,
  setHash,
  label = "Document source",
}: {
  hash: string;
  setHash: (h: string) => void;
  label?: string;
}) {
  const [mode, setMode] = useState<"file" | "text">("file");
  const [textInput, setTextInput] = useState("");
  const [fileName, setFileName] = useState<string | null>(null);
  const [computing, setComputing] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  // Compute hash from text as the user types
  useEffect(() => {
    if (mode !== "text") return;
    if (!textInput) { setHash(""); return; }
    let cancelled = false;
    setComputing(true);
    void sha256HexFromText(textInput).then((h) => {
      if (!cancelled) { setHash(h); setComputing(false); }
    });
    return () => { cancelled = true; };
  }, [textInput, mode, setHash]);

  const onFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setFileName(file.name);
    setComputing(true);
    try {
      const buf = await file.arrayBuffer();
      const h = await sha256Hex(buf);
      setHash(h);
    } finally {
      setComputing(false);
    }
  };

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2">
        <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim">{label}</span>
        <div className="flex gap-1 ml-auto">
          {(["file", "text"] as const).map((m) => (
            <button
              key={m}
              onClick={() => { setMode(m); setHash(""); setFileName(null); setTextInput(""); }}
              className={
                "px-2 py-0.5 text-[10px] rounded border uppercase tracking-wider " +
                (mode === m
                  ? "bg-mempool-blue/15 text-mempool-blue border-mempool-blue"
                  : "text-mempool-text-dim border-mempool-border hover:text-mempool-text")
              }
            >
              {m}
            </button>
          ))}
        </div>
      </div>

      {mode === "file" ? (
        <div>
          <input ref={fileRef} type="file" className="hidden" onChange={onFileChange} />
          <button
            onClick={() => fileRef.current?.click()}
            className="flex items-center gap-2 w-full px-3 py-2 text-xs rounded border border-dashed border-mempool-border text-mempool-text-dim hover:text-mempool-text hover:border-mempool-blue transition-colors"
          >
            <FileText className="w-4 h-4 flex-shrink-0" />
            {fileName ? (
              <span className="truncate text-mempool-text">{fileName}</span>
            ) : (
              <span>Click to select a file — SHA-256 computed in browser</span>
            )}
          </button>
        </div>
      ) : (
        <textarea
          rows={3}
          value={textInput}
          onChange={(e) => setTextInput(e.target.value)}
          placeholder="Enter text to hash…"
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue resize-none"
        />
      )}

      {(hash || computing) && (
        <div className="flex items-center gap-1 text-[11px] font-mono">
          <span className="text-mempool-text-dim">SHA-256:</span>
          {computing ? (
            <span className="text-mempool-text-dim"><Spinner /> computing…</span>
          ) : (
            <>
              <span className="text-mempool-text break-all">{hash}</span>
              <CopyButton text={hash} />
            </>
          )}
        </div>
      )}
    </div>
  );
}

// ── NOTARIZE section ──────────────────────────────────────────────────────

const EXPIRY_PRESETS = [
  { label: "Never (0)", value: 0 },
  { label: "~30 days", value: 2_592_000 },
  { label: "~1 year",  value: 31_536_000 },
  { label: "Custom",   value: -1 },
] as const;

const DOC_TYPES: { value: DocType; label: string }[] = [
  { value: "contract",    label: "Contract" },
  { value: "certificate", label: "Certificate" },
  { value: "receipt",     label: "Receipt" },
  { value: "identity",    label: "Identity" },
  { value: "media",       label: "Media" },
  { value: "other",       label: "Other" },
];

function NotarizeSection() {
  const [subTab, setSubTab] = useState<NotarizeSubTab>("notarize-doc");
  const subTabs = NOTARIZE_SUB_TABS;
  return (
    <div>
      <SubTabBar tabs={subTabs} active={subTab} onChange={(t) => setSubTab(t as typeof subTab)} />
      {subTab === "notarize-doc" && <NotarizeDocTab />}
      {subTab === "verify-doc"   && <VerifyDocTab />}
      {subTab === "my-docs"      && <MyDocsTab />}
    </div>
  );
}

function NotarizeDocTab() {
  const wallet = useWallet();
  const [hash, setHash]         = useState("");
  const [docType, setDocType]   = useState<DocType>("contract");
  const [expiryIdx, setExpiryIdx] = useState(0);  // index into EXPIRY_PRESETS
  const [customExpiry, setCustomExpiry] = useState("");
  const [note, setNote]         = useState("");
  const [busy, setBusy]         = useState(false);
  const [toast, setToast]       = useState<string | null>(null);

  const selectedPreset = EXPIRY_PRESETS[expiryIdx];
  const isCustom = selectedPreset.value === -1;
  const expiryBlocks = isCustom
    ? parseInt(customExpiry || "0", 10) || 0
    : selectedPreset.value;

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast(null), 6000);
  };

  const submit = async () => {
    if (!wallet) return;
    if (!hash || hash.length !== 64) { showToast("No valid 64-char hash. Select a file or enter text."); return; }
    setBusy(true);
    try {
      const nonce = await rpc.getNonce(wallet.address);
      const { signature, publicKey } = signNotarize({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        docHash: hash,
        docType,
        expiryBlocks,
        nonce,
      });
      const r = await rpc.request_raw("notarizedoc", [{
        from: wallet.address,
        doc_hash: hash,
        doc_type: docType,
        expiry_blocks: expiryBlocks,
        note,
        signature,
        public_key: publicKey,
        nonce,
      }]) as NotarizeResp;
      showToast(`Notarized — ID #${r.notarize_id} · txid ${r.txid.slice(0, 12)}… · fee ${fmtOmni(r.fee_sat)} OMNI`);
    } catch (e) {
      showToast(`Error: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-4">
      {!wallet && <WalletRequired />}

      <HashInput hash={hash} setHash={setHash} />

      {/* Doc type */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Document type</label>
        <div className="grid grid-cols-3 sm:grid-cols-6 gap-2">
          {DOC_TYPES.map((dt) => (
            <button
              key={dt.value}
              onClick={() => setDocType(dt.value)}
              className={
                "px-2 py-1.5 text-xs rounded border font-mono transition-colors " +
                (docType === dt.value
                  ? "bg-mempool-blue/15 text-mempool-blue border-mempool-blue"
                  : "bg-mempool-bg text-mempool-text-dim border-mempool-border hover:text-mempool-text")
              }
            >
              {dt.label}
            </button>
          ))}
        </div>
      </div>

      {/* Expiry */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Expiry</label>
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
          {EXPIRY_PRESETS.map((p, i) => (
            <button
              key={i}
              onClick={() => setExpiryIdx(i)}
              className={
                "px-2 py-1.5 text-xs rounded border font-mono transition-colors " +
                (expiryIdx === i
                  ? "bg-mempool-blue/15 text-mempool-blue border-mempool-blue"
                  : "bg-mempool-bg text-mempool-text-dim border-mempool-border hover:text-mempool-text")
              }
            >
              {p.label}
            </button>
          ))}
        </div>
        {isCustom && (
          <input
            type="number"
            min="0"
            value={customExpiry}
            onChange={(e) => setCustomExpiry(e.target.value)}
            placeholder="Custom block count"
            className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
        )}
      </div>

      {/* Note */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Note (optional)</label>
        <textarea
          rows={2}
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="Human-readable description stored on chain…"
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue resize-none"
        />
      </div>

      {/* Fee notice */}
      <p className="text-[11px] text-mempool-text-dim font-mono bg-mempool-bg border border-mempool-border rounded px-3 py-2">
        Notarization costs ~0.001 OMNI (100000 SAT).
      </p>

      <button
        onClick={() => void submit()}
        disabled={!wallet || busy || hash.length !== 64}
        className="w-full px-4 py-2.5 rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 disabled:cursor-not-allowed text-sm font-medium uppercase tracking-wider"
      >
        {busy ? "Signing & broadcasting…" : "Notarize document"}
      </button>

      <Toast msg={toast} />
    </div>
  );
}

function VerifyDocTab() {
  const [hash, setHash]       = useState("");
  const [busy, setBusy]       = useState(false);
  const [result, setResult]   = useState<VerifyResp | null>(null);
  const [err, setErr]         = useState<string | null>(null);

  const verify = async () => {
    if (!hash || hash.length !== 64) { setErr("Need a valid 64-char SHA-256 hash."); return; }
    setBusy(true);
    setErr(null);
    setResult(null);
    try {
      const r = await rpc.verifyNotarize(hash) as VerifyResp;
      setResult(r);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-4">
      <HashInput hash={hash} setHash={setHash} label="Document to verify" />

      <button
        onClick={() => void verify()}
        disabled={busy || hash.length !== 64}
        className="w-full px-4 py-2.5 rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 disabled:cursor-not-allowed text-sm font-medium uppercase tracking-wider"
      >
        {busy ? <><Spinner /> Verifying…</> : "Verify"}
      </button>

      {err && <p className="text-xs text-mempool-orange font-mono">{err}</p>}

      {result && (
        <div className={`rounded border p-3 space-y-2 text-xs font-mono ${VERIFY_STATUS_COLOR[result.status] ?? ""}`}>
          <div className="flex items-center gap-2">
            <StatusBadge status={result.status} />
            {result.status === "valid" && <span className="text-green-400 font-semibold">Verified on chain</span>}
            {result.status === "expired" && <span className="text-yellow-400 font-semibold">Expired</span>}
            {result.status === "revoked" && <span className="text-red-400 font-semibold">Revoked</span>}
            {result.status === "not_found" && <span className="text-red-400 font-semibold">Not found on chain</span>}
          </div>
          {result.status !== "not_found" && (
            <div className="space-y-1 text-mempool-text-dim">
              {result.notarize_id !== undefined && (
                <div className="flex justify-between">
                  <span>notarize_id</span>
                  <span className="text-mempool-text">#{result.notarize_id}</span>
                </div>
              )}
              {result.doc_type && (
                <div className="flex justify-between">
                  <span>type</span>
                  <span className="text-mempool-text">{result.doc_type}</span>
                </div>
              )}
              {result.owner && (
                <div className="flex justify-between gap-2">
                  <span className="flex-shrink-0">owner</span>
                  <span className="text-mempool-blue break-all">{result.owner}</span>
                </div>
              )}
              {result.block_height !== undefined && (
                <div className="flex justify-between">
                  <span>block</span>
                  <span className="text-mempool-text">{fmtInt(result.block_height)}</span>
                </div>
              )}
              {result.tx_hash && (
                <div className="flex justify-between gap-2">
                  <span className="flex-shrink-0">txid</span>
                  <span className="flex items-center gap-1">
                    <span className="text-mempool-blue">{midTrunc(result.tx_hash)}</span>
                    <CopyButton text={result.tx_hash} />
                  </span>
                </div>
              )}
              {result.expiry_block !== undefined && (
                <div className="flex justify-between">
                  <span>expiry block</span>
                  <span className="text-mempool-text">
                    {result.expiry_block === 0 ? "never" : fmtInt(result.expiry_block)}
                  </span>
                </div>
              )}
              {result.note && (
                <div className="flex justify-between gap-2">
                  <span className="flex-shrink-0">note</span>
                  <span className="text-mempool-text break-all">{result.note}</span>
                </div>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function MyDocsTab() {
  const wallet = useWallet();
  const [rows, setRows]             = useState<NotarizationRow[] | null>(null);
  const [loading, setLoading]       = useState(false);
  const [err, setErr]               = useState<string | null>(null);
  const [revokeModal, setRevokeModal] = useState<number | null>(null);
  const [revokeBusy, setRevokeBusy] = useState(false);
  const [toast, setToast]           = useState<string | null>(null);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast(null), 6000);
  };

  const load = useCallback(async () => {
    if (!wallet) return;
    setLoading(true);
    setErr(null);
    try {
      const r = await rpc.getNotarizations(wallet.address) as GetNotarizationsResp | null;
      setRows(r?.notarizations ?? []);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
      setRows([]);
    } finally {
      setLoading(false);
    }
  }, [wallet]);

  useEffect(() => { void load(); }, [load]);

  const doRevoke = async (notarizeId: number) => {
    if (!wallet) return;
    setRevokeBusy(true);
    try {
      const nonce = await rpc.getNonce(wallet.address);
      const { signature, publicKey } = signNotarizeRevoke({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        notarizeId,
        nonce,
      });
      await rpc.request_raw("revokenotarize", [{
        from: wallet.address,
        notarize_id: notarizeId,
        signature,
        public_key: publicKey,
        nonce,
      }]);
      showToast(`Revocation submitted for #${notarizeId}`);
      setRevokeModal(null);
      await load();
    } catch (e) {
      showToast(`Revoke failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setRevokeBusy(false);
    }
  };

  if (!wallet) return <WalletRequired />;

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <span className="text-xs text-mempool-text-dim font-mono break-all">
          wallet: <span className="text-mempool-text">{wallet.address}</span>
        </span>
        <button
          onClick={() => void load()}
          disabled={loading}
          className="flex items-center gap-1.5 px-3 py-1.5 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-50"
        >
          <RefreshCw className={`w-3.5 h-3.5 ${loading ? "animate-spin" : ""}`} />
          Refresh
        </button>
      </div>

      {err && <p className="text-xs text-mempool-orange font-mono">{err}</p>}
      {!err && rows && rows.length === 0 && (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          No notarizations yet. Use the Notarize tab to commit a document hash on chain.
        </p>
      )}

      {rows && rows.length > 0 && (
        <div className="flex justify-end mb-2">
          <button
            onClick={() => {
              const csvRows = [
                ["notarize_id","doc_hash","doc_type","block_height","tx_hash","expiry_block","status","note"].join(","),
                ...rows.map((r) => [
                  r.notarize_id,
                  `"${r.doc_hash}"`,
                  r.doc_type,
                  r.block_height,
                  `"${r.tx_hash}"`,
                  r.expiry_block,
                  r.status,
                  `"${(r.note ?? "").replace(/"/g, '""')}"`,
                ].join(",")),
              ].join("\n");
              const blob = new Blob([csvRows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = "omnibus-notarizations.csv";
              a.click(); URL.revokeObjectURL(url);
            }}
            className="flex items-center gap-1.5 px-3 py-1.5 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
          >
            ⬇ CSV
          </button>
        </div>
      )}

      {rows && rows.length > 0 && (
        <div className="overflow-x-auto -mx-3 sm:mx-0">
          <table className="w-full min-w-[600px] text-xs font-mono">
            <thead className="sticky top-0 bg-mempool-bg-elev">
              <tr className="text-left text-mempool-text-dim uppercase tracking-wider">
                <th className="py-2 px-2 font-medium">ID</th>
                <th className="py-2 px-2 font-medium">Hash</th>
                <th className="py-2 px-2 font-medium">Type</th>
                <th className="py-2 px-2 font-medium text-right">Block</th>
                <th className="py-2 px-2 font-medium">Status</th>
                <th className="py-2 px-2 font-medium">Actions</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.notarize_id} className="border-t border-mempool-border/40">
                  <td className="py-2 px-2 text-mempool-text-dim">#{row.notarize_id}</td>
                  <td className="py-2 px-2">
                    <span className="flex items-center gap-1">
                      <span className="text-mempool-blue">{midTrunc(row.doc_hash)}</span>
                      <CopyButton text={row.doc_hash} />
                    </span>
                  </td>
                  <td className="py-2 px-2 text-mempool-text">{row.doc_type}</td>
                  <td className="py-2 px-2 text-right text-mempool-text-dim">
                    {fmtInt(row.block_height)}
                  </td>
                  <td className="py-2 px-2">
                    <StatusBadge status={row.status} />
                  </td>
                  <td className="py-2 px-2">
                    {row.status === "valid" && (
                      <button
                        onClick={() => setRevokeModal(row.notarize_id)}
                        className="px-2 py-1 text-[10px] rounded border border-red-500/40 text-red-400 hover:bg-red-500/10"
                      >
                        Revoke
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* Revoke modal */}
      {revokeModal !== null && (
        <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
          <div className="bg-mempool-bg-elev border border-mempool-border rounded-lg w-full max-w-md mx-4 p-4 sm:p-5 space-y-4">
            <div className="flex items-center gap-2">
              <AlertTriangle className="w-5 h-5 text-mempool-orange" />
              <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
                Revoke notarization #{revokeModal}
              </h3>
            </div>
            <p className="text-xs text-mempool-text-dim leading-relaxed">
              Revoking marks the notarization as invalid on chain. This cannot be undone.
            </p>
            <div className="flex justify-end gap-2 pt-2">
              <button
                onClick={() => setRevokeModal(null)}
                className="px-3 py-2.5 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-text"
              >
                Cancel
              </button>
              <button
                onClick={() => void doRevoke(revokeModal)}
                disabled={revokeBusy}
                className="px-3 py-2.5 text-xs rounded bg-red-500/20 text-red-400 border border-red-500/40 hover:bg-red-500/30 disabled:opacity-50"
              >
                {revokeBusy ? "Submitting…" : "Confirm revoke"}
              </button>
            </div>
          </div>
        </div>
      )}

      <Toast msg={toast} />
    </div>
  );
}

// ── ESCROW section ────────────────────────────────────────────────────────

const TIMEOUT_PRESETS = [
  { label: "~7 days",  value: 604_800 },
  { label: "~30 days", value: 2_592_000 },
  { label: "Custom",   value: -1 },
] as const;

function EscrowSection({ blockHeight }: { blockHeight: number }) {
  const [subTab, setSubTab] = useState<EscrowSubTab>("my-escrows");
  const subTabs = ESCROW_SUB_TABS;
  return (
    <div>
      <SubTabBar tabs={subTabs} active={subTab} onChange={(t) => setSubTab(t as typeof subTab)} />
      {subTab === "my-escrows"     && <MyEscrowsTab blockHeight={blockHeight} />}
      {subTab === "create-escrow"  && <CreateEscrowTab blockHeight={blockHeight} />}
      {subTab === "release-escrow" && <ReleaseEscrowTab />}
    </div>
  );
}

function MyEscrowsTab({ blockHeight }: { blockHeight: number }) {
  const wallet = useWallet();
  const [rows, setRows]               = useState<EscrowRow[] | null>(null);
  const [loading, setLoading]         = useState(false);
  const [err, setErr]                 = useState<string | null>(null);
  const [toast, setToast]             = useState<string | null>(null);
  const [releaseId, setReleaseId]     = useState<number | null>(null);
  const [proofInput, setProofInput]   = useState("");
  const [proofHash, setProofHash]     = useState("");
  const [proofMode, setProofMode]     = useState<"text" | "hash">("text");
  const [actionBusy, setActionBusy]   = useState(false);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast(null), 6000);
  };

  const load = useCallback(async () => {
    if (!wallet) return;
    setLoading(true);
    setErr(null);
    try {
      const r = await rpc.getEscrows(wallet.address) as GetEscrowsResp | null;
      setRows(r?.escrows ?? []);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
      setRows([]);
    } finally {
      setLoading(false);
    }
  }, [wallet]);

  useEffect(() => { void load(); }, [load]);

  // Live-hash proof text
  useEffect(() => {
    if (proofMode !== "text" || !proofInput) { if (proofMode === "text") setProofHash(""); return; }
    void sha256HexFromText(proofInput).then(setProofHash).catch(() => setProofHash(""));
  }, [proofInput, proofMode]);

  const doRelease = async (escrowId: number) => {
    if (!wallet) return;
    const ph = proofMode === "text" ? proofHash : proofInput.trim();
    if (!ph || ph.length !== 64) { showToast("Provide a valid 64-char proof hash or secret phrase."); return; }
    setActionBusy(true);
    try {
      const nonce = await rpc.getNonce(wallet.address);
      const { signature, publicKey } = signEscrowRelease({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        escrowId,
        proofHash: ph,
        nonce,
      });
      await rpc.request_raw("escrow_release", [{
        from: wallet.address,
        escrow_id: escrowId,
        proof_hash: ph,
        signature,
        public_key: publicKey,
        nonce,
      }]);
      showToast(`Released escrow #${escrowId}`);
      setReleaseId(null);
      setProofInput("");
      await load();
    } catch (e) {
      showToast(`Release failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setActionBusy(false);
    }
  };

  const doRefund = async (escrowId: number) => {
    if (!wallet) return;
    setActionBusy(true);
    try {
      const nonce = await rpc.getNonce(wallet.address);
      const { signature, publicKey } = signEscrowRefund({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        escrowId,
        nonce,
      });
      await rpc.request_raw("escrow_refund", [{
        from: wallet.address,
        escrow_id: escrowId,
        signature,
        public_key: publicKey,
        nonce,
      }]);
      showToast(`Refund submitted for escrow #${escrowId}`);
      await load();
    } catch (e) {
      showToast(`Refund failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setActionBusy(false);
    }
  };

  const doDispute = async (escrowId: number) => {
    if (!wallet) return;
    setActionBusy(true);
    try {
      const nonce = await rpc.getNonce(wallet.address);
      const disputeHash = await sha256HexFromText(`dispute:${escrowId}:${wallet.address}:${nonce}`);
      const { signature, publicKey } = signMessage(
        wallet.privateKey,
        `ESCROW_DISPUTE_V1\n${wallet.address}\n${escrowId}\n${disputeHash}\n${nonce}`,
      );
      await rpc.request_raw("escrow_dispute", [{
        from: wallet.address,
        escrow_id: escrowId,
        dispute_hash: disputeHash,
        signature,
        public_key: publicKey,
        nonce,
      }]);
      showToast(`Dispute filed for escrow #${escrowId}`);
      await load();
    } catch (e) {
      showToast(`Dispute failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setActionBusy(false);
    }
  };

  if (!wallet) return <WalletRequired />;

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <span className="text-xs text-mempool-text-dim font-mono break-all">
          wallet: <span className="text-mempool-text">{wallet.address}</span>
        </span>
        <button
          onClick={() => void load()}
          disabled={loading}
          className="flex items-center gap-1.5 px-3 py-1.5 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-50"
        >
          <RefreshCw className={`w-3.5 h-3.5 ${loading ? "animate-spin" : ""}`} />
          Refresh
        </button>
      </div>

      {err && <p className="text-xs text-mempool-orange font-mono">{err}</p>}
      {!err && rows && rows.length === 0 && (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          No escrows yet. Use the Create tab to lock funds.
        </p>
      )}

      {rows && rows.length > 0 && (
        <div className="flex justify-end mb-2">
          <button
            onClick={() => {
              const csvRows = [
                ["escrow_id","creator","recipient","amount_omni","condition_hash","timeout_block","created_block","status","role","note"].join(","),
                ...rows.map((r) => [
                  r.escrow_id,
                  `"${r.creator}"`,
                  `"${r.recipient}"`,
                  (r.amount_sat / SAT_PER_OMNI).toFixed(8),
                  `"${r.condition_hash}"`,
                  r.timeout_block,
                  r.created_block,
                  r.status,
                  r.role,
                  `"${(r.note ?? "").replace(/"/g, '""')}"`,
                ].join(",")),
              ].join("\n");
              const blob = new Blob([csvRows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = "omnibus-escrows.csv";
              a.click(); URL.revokeObjectURL(url);
            }}
            className="flex items-center gap-1.5 px-3 py-1.5 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
          >
            ⬇ CSV
          </button>
        </div>
      )}

      {rows && rows.length > 0 && (
        <div className="overflow-x-auto -mx-3 sm:mx-0">
          <table className="w-full min-w-[680px] text-xs font-mono">
            <thead className="sticky top-0 bg-mempool-bg-elev">
              <tr className="text-left text-mempool-text-dim uppercase tracking-wider">
                <th className="py-2 px-2 font-medium">ID</th>
                <th className="py-2 px-2 font-medium">Role</th>
                <th className="py-2 px-2 font-medium text-right">Amount</th>
                <th className="py-2 px-2 font-medium">Counterparty</th>
                <th className="py-2 px-2 font-medium text-right">Timeout</th>
                <th className="py-2 px-2 font-medium">Status</th>
                <th className="py-2 px-2 font-medium">Actions</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => {
                const pastTimeout = blockHeight > 0 && blockHeight >= row.timeout_block;
                const counterparty = row.role === "creator" ? row.recipient : row.creator;
                return (
                  <tr key={row.escrow_id} className="border-t border-mempool-border/40">
                    <td className="py-2 px-2 text-mempool-text-dim">#{row.escrow_id}</td>
                    <td className="py-2 px-2">
                      <span className={row.role === "creator"
                        ? "text-mempool-blue"
                        : "text-mempool-green"
                      }>{row.role}</span>
                    </td>
                    <td className="py-2 px-2 text-right text-mempool-text">
                      {fmtOmni(row.amount_sat)} <span className="text-mempool-text-dim">OMNI</span>
                    </td>
                    <td className="py-2 px-2 text-mempool-blue" title={counterparty}>
                      <button onClick={() => { if (counterparty) window.location.hash = `#/address/${counterparty}`; }} className="hover:underline">
                        <AddressLabel address={counterparty ?? ""} showEmoji truncate={{ left: 8, right: 6 }} />
                      </button>
                    </td>
                    <td className="py-2 px-2 text-right text-mempool-text-dim">
                      {fmtInt(row.timeout_block)}
                      {pastTimeout && row.status === "open" && (
                        <span className="ml-1 text-mempool-orange">(elapsed)</span>
                      )}
                    </td>
                    <td className="py-2 px-2">
                      <StatusBadge status={row.status} />
                    </td>
                    <td className="py-2 px-2">
                      {row.status === "open" && (
                        <div className="flex gap-1 flex-wrap">
                          {row.role === "recipient" && (
                            <button
                              onClick={() => { setReleaseId(row.escrow_id); setProofInput(""); setProofHash(""); }}
                              disabled={actionBusy}
                              className="px-2 py-1 text-[10px] rounded border border-green-500/40 text-green-400 hover:bg-green-500/10 disabled:opacity-50"
                            >
                              Release
                            </button>
                          )}
                          {row.role === "creator" && pastTimeout && (
                            <button
                              onClick={() => void doRefund(row.escrow_id)}
                              disabled={actionBusy}
                              className="px-2 py-1 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-text disabled:opacity-50"
                            >
                              Refund
                            </button>
                          )}
                          <button
                            onClick={() => void doDispute(row.escrow_id)}
                            disabled={actionBusy}
                            className="px-2 py-1 text-[10px] rounded border border-orange-500/40 text-orange-400 hover:bg-orange-500/10 disabled:opacity-50"
                          >
                            Dispute
                          </button>
                        </div>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {/* Release modal */}
      {releaseId !== null && (
        <div className="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
          <div className="bg-mempool-bg-elev border border-mempool-border rounded-lg w-full max-w-md mx-4 p-4 sm:p-5 space-y-4">
            <div className="flex items-center gap-2">
              <Unlock className="w-5 h-5 text-green-400" />
              <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
                Release escrow #{releaseId}
              </h3>
            </div>
            <p className="text-xs text-mempool-text-dim leading-relaxed">
              Provide the secret phrase or proof hash that matches the{" "}
              <span className="text-mempool-text font-mono">condition_hash</span> set at creation.
            </p>
            <div className="flex gap-1">
              {(["text", "hash"] as const).map((m) => (
                <button
                  key={m}
                  onClick={() => { setProofMode(m); setProofInput(""); setProofHash(""); }}
                  className={
                    "px-2 py-0.5 text-[10px] rounded border uppercase tracking-wider " +
                    (proofMode === m
                      ? "bg-mempool-blue/15 text-mempool-blue border-mempool-blue"
                      : "text-mempool-text-dim border-mempool-border hover:text-mempool-text")
                  }
                >
                  {m === "text" ? "Secret phrase" : "Direct hash"}
                </button>
              ))}
            </div>
            {proofMode === "text" ? (
              <div className="space-y-1">
                <input
                  type="text"
                  value={proofInput}
                  onChange={(e) => setProofInput(e.target.value)}
                  placeholder="Secret phrase (hashed to SHA-256)…"
                  className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
                />
                {proofHash && (
                  <div className="flex items-center gap-1 text-[11px] font-mono text-mempool-text-dim">
                    <span>hash:</span>
                    <span className="text-mempool-text break-all">{proofHash}</span>
                    <CopyButton text={proofHash} />
                  </div>
                )}
              </div>
            ) : (
              <input
                type="text"
                value={proofInput}
                onChange={(e) => setProofInput(e.target.value)}
                placeholder="64-char SHA-256 hex proof hash…"
                className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
              />
            )}
            <div className="flex justify-end gap-2 pt-2">
              <button
                onClick={() => { setReleaseId(null); setProofInput(""); setProofHash(""); }}
                className="px-3 py-2.5 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-text"
              >
                Cancel
              </button>
              <button
                onClick={() => void doRelease(releaseId)}
                disabled={actionBusy || (proofMode === "text" ? proofHash.length !== 64 : proofInput.trim().length !== 64)}
                className="px-3 py-2.5 text-xs rounded bg-green-500/20 text-green-400 border border-green-500/40 hover:bg-green-500/30 disabled:opacity-50"
              >
                {actionBusy ? "Submitting…" : "Release funds"}
              </button>
            </div>
          </div>
        </div>
      )}

      <Toast msg={toast} />
    </div>
  );
}

function CreateEscrowTab({ blockHeight }: { blockHeight: number }) {
  const wallet = useWallet();
  const [recipient, setRecipient]       = useState("");
  const [amountStr, setAmountStr]       = useState("");
  const [condMode, setCondMode]         = useState<"text" | "hash">("text");
  const [condText, setCondText]         = useState("");
  const [condHash, setCondHash]         = useState("");
  const [condDirect, setCondDirect]     = useState("");
  const [timeoutIdx, setTimeoutIdx]     = useState(0);
  const [customTimeout, setCustomTimeout] = useState("");
  const [note, setNote]                 = useState("");
  const [busy, setBusy]                 = useState(false);
  const [toast, setToast]               = useState<string | null>(null);
  const [success, setSuccess]           = useState<EscrowCreateResp | null>(null);

  // Live hash from secret text
  useEffect(() => {
    if (condMode !== "text" || !condText) { if (condMode === "text") setCondHash(""); return; }
    void sha256HexFromText(condText).then(setCondHash).catch(() => setCondHash(""));
  }, [condText, condMode]);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast(null), 6000);
  };

  const selectedPreset = TIMEOUT_PRESETS[timeoutIdx];
  const isCustomTimeout = selectedPreset.value === -1;
  const timeoutBlocks = isCustomTimeout
    ? parseInt(customTimeout || "0", 10) || 0
    : selectedPreset.value;

  const effectiveCondHash = condMode === "text" ? condHash : condDirect.trim();
  const amountOmni = parseFloat(amountStr) || 0;
  const amountSat = Math.floor(amountOmni * SAT_PER_OMNI);
  const timeoutBlock = blockHeight + timeoutBlocks;

  const canSubmit = !!wallet && amountSat > 0 && recipient.length > 0
    && effectiveCondHash.length === 64 && !busy;

  const submit = async () => {
    if (!wallet || !canSubmit) return;
    setBusy(true);
    setSuccess(null);
    try {
      const nonce = await rpc.getNonce(wallet.address);
      const { signature, publicKey } = signEscrowCreate({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        to: recipient,
        amount: amountSat,
        conditionHash: effectiveCondHash,
        timeoutBlocks,
        nonce,
      });
      const r = await rpc.request_raw("escrow_create", [{
        from: wallet.address,
        to: recipient,
        amount: amountSat,
        condition_hash: effectiveCondHash,
        timeout_blocks: timeoutBlocks,
        note,
        signature,
        public_key: publicKey,
        nonce,
      }]) as EscrowCreateResp;
      setSuccess(r);
    } catch (e) {
      showToast(`Error: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(false);
    }
  };

  if (!wallet) return <WalletRequired />;

  return (
    <div className="space-y-4">
      {/* Recipient */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Recipient address</label>
        <input
          type="text"
          value={recipient}
          onChange={(e) => setRecipient(e.target.value)}
          placeholder="ob1q…"
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
        />
      </div>

      {/* Amount */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Amount (OMNI)</label>
        <input
          type="number"
          min="0"
          step="0.001"
          value={amountStr}
          onChange={(e) => setAmountStr(e.target.value)}
          placeholder="0.000"
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
        />
        {amountSat > 0 && (
          <div className="text-[11px] text-mempool-text-dim font-mono">
            = {fmtInt(amountSat)} SAT
          </div>
        )}
      </div>

      {/* Condition hash */}
      <div className="space-y-2">
        <div className="flex items-center gap-2">
          <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Release condition</label>
          <div className="flex gap-1 ml-auto">
            {(["text", "hash"] as const).map((m) => (
              <button
                key={m}
                onClick={() => { setCondMode(m); setCondText(""); setCondHash(""); setCondDirect(""); }}
                className={
                  "px-2 py-0.5 text-[10px] rounded border uppercase tracking-wider " +
                  (condMode === m
                    ? "bg-mempool-blue/15 text-mempool-blue border-mempool-blue"
                    : "text-mempool-text-dim border-mempool-border hover:text-mempool-text")
                }
              >
                {m === "text" ? "Secret phrase" : "Direct hash"}
              </button>
            ))}
          </div>
        </div>
        {condMode === "text" ? (
          <div className="space-y-1">
            <input
              type="text"
              value={condText}
              onChange={(e) => setCondText(e.target.value)}
              placeholder="Secret phrase known only to recipient…"
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
            />
            {condHash && (
              <div className="flex items-center gap-1 text-[11px] font-mono text-mempool-text-dim">
                <span>condition_hash:</span>
                <span className="text-mempool-text break-all">{condHash}</span>
                <CopyButton text={condHash} />
              </div>
            )}
          </div>
        ) : (
          <input
            type="text"
            value={condDirect}
            onChange={(e) => setCondDirect(e.target.value)}
            placeholder="64-char SHA-256 hex condition hash…"
            className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
        )}
      </div>

      {/* Timeout */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Timeout (refund if not released)
        </label>
        <div className="grid grid-cols-3 gap-2">
          {TIMEOUT_PRESETS.map((p, i) => (
            <button
              key={i}
              onClick={() => setTimeoutIdx(i)}
              className={
                "px-2 py-1.5 text-xs rounded border font-mono transition-colors " +
                (timeoutIdx === i
                  ? "bg-mempool-blue/15 text-mempool-blue border-mempool-blue"
                  : "bg-mempool-bg text-mempool-text-dim border-mempool-border hover:text-mempool-text")
              }
            >
              {p.label}
            </button>
          ))}
        </div>
        {isCustomTimeout && (
          <input
            type="number"
            min="0"
            value={customTimeout}
            onChange={(e) => setCustomTimeout(e.target.value)}
            placeholder="Custom block count…"
            className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
        )}
        {blockHeight > 0 && timeoutBlocks > 0 && (
          <div className="text-[11px] text-mempool-text-dim font-mono">
            timeout block: ~{fmtInt(timeoutBlock)} (in {fmtInt(timeoutBlocks)} blocks)
          </div>
        )}
      </div>

      {/* Note */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Note (optional)</label>
        <textarea
          rows={2}
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="Purpose of this escrow…"
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue resize-none"
        />
      </div>

      <button
        onClick={() => void submit()}
        disabled={!canSubmit}
        className="w-full px-4 py-2.5 rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 disabled:cursor-not-allowed text-sm font-medium uppercase tracking-wider"
      >
        {busy ? "Signing & broadcasting…" : "Create escrow"}
      </button>

      {/* Success panel */}
      {success && (
        <div className="bg-green-500/5 border border-green-500/40 rounded p-3 space-y-2 text-xs font-mono">
          <div className="text-green-400 font-semibold">Escrow created</div>
          <div className="flex justify-between text-mempool-text-dim">
            <span>escrow_id</span>
            <span className="text-mempool-text">#{success.escrow_id}</span>
          </div>
          <div className="flex justify-between text-mempool-text-dim">
            <span>amount</span>
            <span className="text-mempool-text">{fmtOmni(success.amount_sat)} OMNI</span>
          </div>
          <div className="flex justify-between text-mempool-text-dim">
            <span>txid</span>
            <span className="flex items-center gap-1">
              <span className="text-mempool-blue">{midTrunc(success.txid)}</span>
              <CopyButton text={success.txid} />
            </span>
          </div>
          <div className="flex justify-between text-mempool-text-dim">
            <span>timeout block</span>
            <span className="text-mempool-text">{fmtInt(success.timeout_block)}</span>
          </div>
          <div className="border-t border-mempool-border/60 pt-2 text-mempool-orange text-[11px] leading-relaxed">
            IMPORTANT: Save the condition_hash and/or secret phrase. The recipient needs it to
            release the funds. It is not stored on chain in plain text.
          </div>
          <div className="flex items-center gap-1 text-mempool-text-dim">
            <span className="flex-shrink-0">condition_hash:</span>
            <span className="text-mempool-text break-all">{success.condition_hash}</span>
            <CopyButton text={success.condition_hash} />
          </div>
        </div>
      )}

      <Toast msg={toast} />
    </div>
  );
}

function ReleaseEscrowTab() {
  const wallet = useWallet();
  const [escrowIdStr, setEscrowIdStr] = useState("");
  const [escrow, setEscrow]           = useState<EscrowRow | null>(null);
  const [loadingEscrow, setLoadingEscrow] = useState(false);
  const [errLoad, setErrLoad]         = useState<string | null>(null);
  const [proofMode, setProofMode]     = useState<"text" | "hash">("text");
  const [proofText, setProofText]     = useState("");
  const [proofHash, setProofHash]     = useState("");
  const [proofDirect, setProofDirect] = useState("");
  const [busy, setBusy]               = useState(false);
  const [toast, setToast]             = useState<string | null>(null);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast(null), 6000);
  };

  // Live hash from proof text
  useEffect(() => {
    if (proofMode !== "text" || !proofText) { if (proofMode === "text") setProofHash(""); return; }
    void sha256HexFromText(proofText).then(setProofHash).catch(() => setProofHash(""));
  }, [proofText, proofMode]);

  const loadEscrow = async () => {
    const id = parseInt(escrowIdStr, 10);
    if (!id) return;
    setLoadingEscrow(true);
    setErrLoad(null);
    setEscrow(null);
    try {
      const r = await rpc.getEscrow(id) as EscrowRow | null;
      setEscrow(r);
    } catch (e) {
      setErrLoad(e instanceof Error ? e.message : String(e));
    } finally {
      setLoadingEscrow(false);
    }
  };

  const effectiveProofHash = proofMode === "text" ? proofHash : proofDirect.trim();

  const doRelease = async () => {
    if (!wallet || !escrow) return;
    if (effectiveProofHash.length !== 64) { showToast("Provide a valid 64-char proof hash."); return; }
    setBusy(true);
    try {
      const nonce = await rpc.getNonce(wallet.address);
      const { signature, publicKey } = signEscrowRelease({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        escrowId: escrow.escrow_id,
        proofHash: effectiveProofHash,
        nonce,
      });
      await rpc.request_raw("escrow_release", [{
        from: wallet.address,
        escrow_id: escrow.escrow_id,
        proof_hash: effectiveProofHash,
        signature,
        public_key: publicKey,
        nonce,
      }]);
      showToast(`Released escrow #${escrow.escrow_id}`);
      setEscrow(null);
      setEscrowIdStr("");
    } catch (e) {
      showToast(`Release failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(false);
    }
  };

  if (!wallet) return <WalletRequired />;

  return (
    <div className="space-y-4">
      {/* Escrow lookup */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Escrow ID</label>
        <div className="flex gap-2">
          <input
            type="number"
            min="0"
            value={escrowIdStr}
            onChange={(e) => setEscrowIdStr(e.target.value)}
            placeholder="Escrow numeric ID…"
            className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
          <button
            onClick={() => void loadEscrow()}
            disabled={loadingEscrow || !escrowIdStr}
            className="px-3 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-50"
          >
            {loadingEscrow ? <Spinner /> : "Load"}
          </button>
        </div>
      </div>

      {errLoad && <p className="text-xs text-mempool-orange font-mono">{errLoad}</p>}

      {/* Escrow details */}
      {escrow && (
        <div className="bg-mempool-bg border border-mempool-border rounded p-3 space-y-1.5 text-xs font-mono">
          <div className="flex items-center gap-2 mb-1">
            <Lock className="w-4 h-4 text-mempool-blue" />
            <span className="text-mempool-text font-semibold">Escrow #{escrow.escrow_id}</span>
            <StatusBadge status={escrow.status} />
          </div>
          {[
            ["creator",  escrow.creator],
            ["recipient", escrow.recipient],
            ["amount",   `${fmtOmni(escrow.amount_sat)} OMNI`],
            ["timeout block", fmtInt(escrow.timeout_block)],
            ["condition_hash", midTrunc(escrow.condition_hash)],
          ].map(([k, v]) => (
            <div key={k} className="flex justify-between gap-2">
              <span className="text-mempool-text-dim flex-shrink-0">{k}</span>
              <span className="text-mempool-text break-all">{v}</span>
            </div>
          ))}
          {escrow.note && (
            <div className="flex justify-between gap-2">
              <span className="text-mempool-text-dim flex-shrink-0">note</span>
              <span className="text-mempool-text break-all">{escrow.note}</span>
            </div>
          )}
        </div>
      )}

      {/* Proof hash input */}
      {escrow && escrow.status === "open" && (
        <div className="space-y-2">
          <div className="flex items-center gap-2">
            <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Proof</label>
            <div className="flex gap-1 ml-auto">
              {(["text", "hash"] as const).map((m) => (
                <button
                  key={m}
                  onClick={() => { setProofMode(m); setProofText(""); setProofHash(""); setProofDirect(""); }}
                  className={
                    "px-2 py-0.5 text-[10px] rounded border uppercase tracking-wider " +
                    (proofMode === m
                      ? "bg-mempool-blue/15 text-mempool-blue border-mempool-blue"
                      : "text-mempool-text-dim border-mempool-border hover:text-mempool-text")
                  }
                >
                  {m === "text" ? "Secret phrase" : "Direct hash"}
                </button>
              ))}
            </div>
          </div>
          {proofMode === "text" ? (
            <div className="space-y-1">
              <input
                type="text"
                value={proofText}
                onChange={(e) => setProofText(e.target.value)}
                placeholder="Secret phrase (hashed to SHA-256)…"
                className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
              />
              {proofHash && (
                <div className="flex items-center gap-1 text-[11px] font-mono text-mempool-text-dim">
                  <span>hash:</span>
                  <span className="text-mempool-text break-all">{proofHash}</span>
                  <CopyButton text={proofHash} />
                </div>
              )}
            </div>
          ) : (
            <input
              type="text"
              value={proofDirect}
              onChange={(e) => setProofDirect(e.target.value)}
              placeholder="64-char SHA-256 hex proof hash…"
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
            />
          )}

          <button
            onClick={() => void doRelease()}
            disabled={busy || effectiveProofHash.length !== 64}
            className="w-full px-4 py-2.5 rounded bg-green-500/15 text-green-400 border border-green-500/40 hover:bg-green-500/25 disabled:opacity-40 disabled:cursor-not-allowed text-sm font-medium uppercase tracking-wider"
          >
            {busy ? "Releasing…" : "Release escrow"}
          </button>
        </div>
      )}

      {escrow && escrow.status !== "open" && (
        <p className="text-xs text-mempool-text-dim font-mono bg-mempool-bg border border-mempool-border rounded px-3 py-2">
          This escrow is already <strong className="text-mempool-text">{escrow.status}</strong>.
        </p>
      )}

      <Toast msg={toast} />
    </div>
  );
}

// ── Main Page Component ───────────────────────────────────────────────────

export function NotarizePage() {
  const [topTab, setTopTab]     = useState<TopTab>("notarize");
  const blockHeight = useBlockHeight();

  const topTabs = NOTARIZE_TOP_TABS;

  return (
    <section className="bg-mempool-bg-elev rounded-lg p-3 sm:p-4 border border-mempool-border backdrop-blur-sm">
      {/* Header */}
      <div className="flex items-center gap-2 sm:gap-3 mb-4">
        <Shield className="w-5 h-5 text-mempool-blue flex-shrink-0" />
        <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          Notarize &amp; Escrow
        </h2>
        <div className="flex-1 h-px bg-mempool-border" />
        <span className="text-[10px] sm:text-xs text-mempool-text-dim font-mono whitespace-nowrap">
          height {fmtInt(blockHeight)}
        </span>
      </div>

      {/* Top tab bar */}
      <div className="flex gap-1 border-b border-mempool-border mb-4 overflow-x-auto scrollbar-none">
        {topTabs.map((t) => {
          const active = topTab === t.id;
          return (
            <button
              key={t.id}
              onClick={() => setTopTab(t.id)}
              className={
                "relative flex-shrink-0 px-4 sm:px-6 py-2.5 text-xs font-semibold uppercase tracking-wider transition-colors whitespace-nowrap " +
                (active
                  ? "text-mempool-blue"
                  : "text-mempool-text-dim hover:text-mempool-text")
              }
            >
              {t.id === "notarize" ? (
                <><FileText className="inline w-3.5 h-3.5 mr-1 -mt-0.5" />{t.label}</>
              ) : t.id === "opreturn" ? (
                <><span className="mr-1 font-mono text-[9px]">OP</span>{t.label}</>
              ) : (
                <><Lock className="inline w-3.5 h-3.5 mr-1 -mt-0.5" />{t.label}</>
              )}
              {active && (
                <span className="absolute left-0 right-0 -bottom-px h-0.5 bg-mempool-blue" />
              )}
            </button>
          );
        })}
      </div>

      {topTab === "notarize" && <NotarizeSection />}
      {topTab === "escrow"   && <EscrowSection blockHeight={blockHeight} />}
      {topTab === "opreturn" && <OpReturnSection />}
    </section>
  );
}

// ── OP_RETURN Section (sendopreturn + sendrawtransaction) ─────────────────────

function OpReturnSection() {
  const wallet = useWallet();

  // sendopreturn
  const [opData, setOpData] = useState("");
  const [opFee, setOpFee] = useState("1000");
  const [opLoading, setOpLoading] = useState(false);
  const [opResult, setOpResult] = useState<{ ok: boolean; msg: string } | null>(null);

  const sendOpReturn = async () => {
    if (!opData.trim()) return;
    setOpLoading(true); setOpResult(null);
    try {
      const r = await rpc.request_raw("sendopreturn", [opData.trim(), parseInt(opFee, 10) || 1000]) as { txid?: string; tx_hash?: string; error?: string };
      if (r && (r.txid || r.tx_hash)) {
        setOpResult({ ok: true, msg: `TX: ${(r.txid ?? r.tx_hash ?? "").slice(0, 32)}…` });
      } else {
        setOpResult({ ok: false, msg: r?.error ?? JSON.stringify(r) });
      }
    } catch (e) { setOpResult({ ok: false, msg: String(e) }); }
    finally { setOpLoading(false); }
  };

  // sendrawtransaction
  const [rawFrom, setRawFrom] = useState("");
  const [rawTo, setRawTo] = useState("");
  const [rawAmount, setRawAmount] = useState("");
  const [rawFee, setRawFee] = useState("1000");
  const [rawSig, setRawSig] = useState("");
  const [rawHash, setRawHash] = useState("");
  const [rawPubkey, setRawPubkey] = useState("");
  const [rawNonce, setRawNonce] = useState("0");
  const [rawLoading, setRawLoading] = useState(false);
  const [rawResult, setRawResult] = useState<{ ok: boolean; msg: string } | null>(null);

  const sendRaw = async () => {
    setRawLoading(true); setRawResult(null);
    try {
      const r = await rpc.request_raw("sendrawtransaction", [{
        from: rawFrom.trim(),
        to: rawTo.trim(),
        amount: parseInt(rawAmount, 10),
        fee: parseInt(rawFee, 10) || 1000,
        signature: rawSig.trim(),
        hash: rawHash.trim(),
        publicKey: rawPubkey.trim(),
        nonce: parseInt(rawNonce, 10) || 0,
        timestamp: Math.floor(Date.now() / 1000),
      }]) as { txid?: string; tx_hash?: string; error?: string };
      if (r && (r.txid || r.tx_hash)) {
        setRawResult({ ok: true, msg: `TX: ${(r.txid ?? r.tx_hash ?? "").slice(0, 32)}…` });
      } else {
        setRawResult({ ok: false, msg: r?.error ?? JSON.stringify(r) });
      }
    } catch (e) { setRawResult({ ok: false, msg: String(e) }); }
    finally { setRawLoading(false); }
  };

  return (
    <div className="space-y-6">
      {/* sendopreturn */}
      <div className="rounded-xl border border-mempool-border bg-mempool-bg p-4 space-y-3">
        <h3 className="text-xs font-semibold text-mempool-text-dim uppercase tracking-wider">
          Send OP_RETURN (sendopreturn)
        </h3>
        <p className="text-[11px] text-mempool-text-dim">
          Embed up to 80 bytes of arbitrary data on-chain. Amount = 0, uses node wallet. Commonly used for notarization, name registration receipts, or protocol messages.
        </p>
        {!wallet?.address && (
          <p className="text-xs text-yellow-400">Unlock wallet first — node must be running with your mnemonic.</p>
        )}
        <div className="space-y-2">
          <div className="space-y-1">
            <label className="text-[10px] text-mempool-text-dim uppercase">Data (≤80 bytes UTF-8)</label>
            <input
              value={opData}
              onChange={(e) => setOpData(e.target.value)}
              placeholder="ns:alice.omnibus:ob1q…"
              maxLength={80}
              className="w-full bg-mempool-bg-elev border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text"
            />
            <p className="text-[9px] text-mempool-text-dim">{opData.length}/80 chars</p>
          </div>
          <div className="space-y-1">
            <label className="text-[10px] text-mempool-text-dim uppercase">Fee (SAT)</label>
            <input
              type="number"
              min="0"
              value={opFee}
              onChange={(e) => setOpFee(e.target.value)}
              className="w-full bg-mempool-bg-elev border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text"
            />
          </div>
          <button
            onClick={sendOpReturn}
            disabled={opLoading || !opData.trim()}
            className="w-full py-2 text-xs font-medium bg-mempool-blue/20 hover:bg-mempool-blue/40 text-mempool-blue border border-mempool-blue/30 rounded disabled:opacity-50"
          >
            {opLoading ? "Broadcasting…" : "Send OP_RETURN TX"}
          </button>
          {opResult && (
            <div className={`rounded px-3 py-2 text-xs border ${opResult.ok ? "bg-green-500/10 border-green-500/30 text-green-300" : "bg-red-500/10 border-red-500/30 text-red-300"}`}>
              {opResult.msg}
            </div>
          )}
        </div>
      </div>

      {/* sendrawtransaction */}
      <div className="rounded-xl border border-mempool-border bg-mempool-bg p-4 space-y-3">
        <h3 className="text-xs font-semibold text-mempool-text-dim uppercase tracking-wider">
          Broadcast Raw TX (sendrawtransaction)
        </h3>
        <p className="text-[11px] text-mempool-text-dim">
          Broadcast a pre-signed transaction directly to the mempool. All fields must be pre-computed (signature, hash, nonce). For advanced use only.
        </p>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
          {[
            ["From", rawFrom, setRawFrom, "ob1q…"],
            ["To", rawTo, setRawTo, "ob1q…"],
            ["Amount (SAT)", rawAmount, setRawAmount, "100000000"],
            ["Fee (SAT)", rawFee, setRawFee, "1000"],
            ["Signature (128 hex)", rawSig, setRawSig, "aabbcc…"],
            ["TX Hash (64 hex)", rawHash, setRawHash, "deadbeef…"],
            ["Public key (66 hex)", rawPubkey, setRawPubkey, "02aabb…"],
            ["Nonce", rawNonce, setRawNonce, "0"],
          ].map(([label, val, setter, ph]) => (
            <div key={label as string} className="space-y-0.5">
              <label className="text-[9px] text-mempool-text-dim uppercase">{label as string}</label>
              <input
                value={val as string}
                onChange={(e) => (setter as React.Dispatch<React.SetStateAction<string>>)(e.target.value)}
                placeholder={ph as string}
                className="w-full bg-mempool-bg-elev border border-mempool-border rounded px-2 py-1.5 text-[11px] font-mono text-mempool-text"
              />
            </div>
          ))}
        </div>
        <button
          onClick={sendRaw}
          disabled={rawLoading || !rawFrom || !rawTo || !rawAmount || !rawSig || !rawHash || !rawPubkey}
          className="w-full py-2 text-xs font-medium bg-orange-500/20 hover:bg-orange-500/40 text-orange-300 border border-orange-500/30 rounded disabled:opacity-50"
        >
          {rawLoading ? "Broadcasting…" : "Broadcast Raw TX"}
        </button>
        {rawResult && (
          <div className={`rounded px-3 py-2 text-xs border ${rawResult.ok ? "bg-green-500/10 border-green-500/30 text-green-300" : "bg-red-500/10 border-red-500/30 text-red-300"}`}>
            {rawResult.msg}
          </div>
        )}
      </div>
    </div>
  );
}

export default NotarizePage;
