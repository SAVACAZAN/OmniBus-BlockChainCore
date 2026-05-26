/**
 * PoapPage.tsx — Proof Of Attendance Protocol (POAP) on OmniBus.
 *
 * Allows users to:
 *   - View their POAP badge collection (my-poaps tab)
 *   - Look up any event by ID (lookup tab)
 *   - Create a new event (create tab)
 *   - Claim a POAP for an event they attended (claim tab)
 *
 * Backend RPCs (rpc_server.zig):
 *   - getpoaps          { address }          → { poaps: PoapEntry[] }
 *   - getpoapevent      { event_id }         → PoapEvent | null
 *   - poap_createevent  { from, event_id, name, max_claims, note, signature, public_key, nonce }
 *   - poap_claim        { from, event_id, signature, public_key, nonce }
 *   - poap_close        { from, event_id, signature, public_key, nonce }
 *
 * Signing uses SHA256d + secp256k1 (same as StakePage) with canonical strings:
 *   POAP_EVENT_V1\n${from}\n${event_id}\n${name}\n${max_claims}\n${nonce}
 *   POAP_CLAIM_V1\n${from}\n${event_id}\n${nonce}
 *   POAP_CLOSE_V1\n${from}\n${event_id}\n${nonce}
 */

import { useCallback, useEffect, useState } from "react";
import {
  Award,
  Search,
  PlusCircle,
  Download,
  RefreshCw,
  AlertTriangle,
  CheckCircle2,
  XCircle,
  Lock,
} from "lucide-react";
import { rpc } from "../../api/rpc-client";
import { AddressLabel } from "../common/AddressLabel";
import { useWallet } from "../../api/use-wallet";
import { signMessage } from "../../api/exchange-sign";
import { midTrunc, fmtInt } from "../../utils/fmt";


// ── Types ─────────────────────────────────────────────────────────────────

interface PoapEntry {
  event_id: string;
  claim_block: number;
  tx_hash: string;
}

interface PoapEvent {
  event_id: string;
  name: string;
  organizer: string;
  max_claims: number;
  claims_count: number;
  create_block: number;
  closed: boolean;
  note: string;
}

interface GetPoapsResp { poaps: PoapEntry[] }
interface CreateEventResp { status: string; txid: string; event_id: string; fee_sat: number }
interface ClaimResp { status: string; txid: string; event_id: string }
interface CloseResp { status: string; txid: string; closed: boolean }

type SubTab = "my-poaps" | "lookup" | "create" | "claim";

// ── Format helpers ────────────────────────────────────────────────────────



/** Derive a stable color class from an event_id string using a simple hash. */
function badgeColor(eventId: string): string {
  const COLORS = [
    "text-mempool-blue",
    "text-mempool-green",
    "text-mempool-orange",
    "text-purple-400",
    "text-pink-400",
  ];
  const BG_COLORS = [
    "bg-mempool-blue/20 border-mempool-blue/40",
    "bg-mempool-green/20 border-mempool-green/40",
    "bg-mempool-orange/20 border-mempool-orange/40",
    "bg-purple-400/20 border-purple-400/40",
    "bg-pink-400/20 border-pink-400/40",
  ];
  let h = 0;
  for (let i = 0; i < eventId.length; i++) {
    h = (h * 31 + eventId.charCodeAt(i)) >>> 0;
  }
  const idx = h % COLORS.length;
  return `${COLORS[idx]} ${BG_COLORS[idx]}`;
}

function badgeTextColor(eventId: string): string {
  const COLORS = [
    "text-mempool-blue",
    "text-mempool-green",
    "text-mempool-orange",
    "text-purple-400",
    "text-pink-400",
  ];
  let h = 0;
  for (let i = 0; i < eventId.length; i++) {
    h = (h * 31 + eventId.charCodeAt(i)) >>> 0;
  }
  return COLORS[h % COLORS.length];
}

// ── Signing ───────────────────────────────────────────────────────────────

function signCreateEvent(args: {
  privateKeyHex: string; from: string; event_id: string;
  name: string; max_claims: number; nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `POAP_EVENT_V1\n${args.from}\n${args.event_id}\n${args.name}\n${args.max_claims}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

function signClaim(args: {
  privateKeyHex: string; from: string; event_id: string; nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `POAP_CLAIM_V1\n${args.from}\n${args.event_id}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

function signClose(args: {
  privateKeyHex: string; from: string; event_id: string; nonce: number;
}): { signature: string; publicKey: string } {
  const msg = `POAP_CLOSE_V1\n${args.from}\n${args.event_id}\n${args.nonce}`;
  return signMessage(args.privateKeyHex, msg);
}

// ── Nonce helper ──────────────────────────────────────────────────────────

// ── Toast helper ──────────────────────────────────────────────────────────

function Toast({ msg }: { msg: string }) {
  return (
    <div className="fixed bottom-4 right-4 bg-mempool-bg-elev border border-mempool-border rounded px-4 py-2 text-xs text-mempool-text font-mono shadow-lg z-50 max-w-xs">
      {msg}
    </div>
  );
}

// ── Badge Card ────────────────────────────────────────────────────────────

function BadgeCard({
  poap,
  onClick,
  selected,
}: {
  poap: PoapEntry;
  onClick: () => void;
  selected: boolean;
}) {
  const colorClass = badgeColor(poap.event_id);
  const letter = (poap.event_id[0] ?? "?").toUpperCase();

  return (
    <button
      onClick={onClick}
      className={
        "flex flex-col items-center gap-2 p-3 rounded-lg border text-left transition-all " +
        (selected
          ? "border-mempool-blue bg-mempool-blue/10"
          : "border-mempool-border bg-mempool-bg hover:border-mempool-text-dim")
      }
    >
      {/* Hexagonal-style accent circle */}
      <div
        className={
          "w-12 h-12 rounded-full flex items-center justify-center border-2 text-xl font-bold " +
          colorClass
        }
      >
        {letter}
      </div>
      <div className="text-center w-full">
        <div className={`text-xs font-mono font-semibold truncate max-w-full ${badgeTextColor(poap.event_id)}`}>
          {poap.event_id}
        </div>
        <div className="text-[10px] text-mempool-text-dim font-mono mt-0.5">
          block #{fmtInt(poap.claim_block)}
        </div>
      </div>
    </button>
  );
}

// ── Event Info Card ───────────────────────────────────────────────────────

function EventInfoCard({
  event,
  onClaim,
  onClose,
  walletAddress,
  busyClaim,
  busyClose,
}: {
  event: PoapEvent;
  onClaim?: () => void;
  onClose?: () => void;
  walletAddress?: string;
  busyClaim?: boolean;
  busyClose?: boolean;
}) {
  const isOrganizer = walletAddress && walletAddress === event.organizer;
  const unlimited = event.max_claims === 0;
  const claimPct = unlimited ? null : Math.round((event.claims_count / event.max_claims) * 100);

  return (
    <div className="bg-mempool-bg border border-mempool-border rounded-lg p-3 space-y-3">
      {/* Header */}
      <div className="flex items-start justify-between gap-2">
        <div>
          <div className="text-sm font-semibold text-mempool-text">{event.name}</div>
          <div className="text-[10px] font-mono text-mempool-text-dim mt-0.5">{event.event_id}</div>
        </div>
        <span
          className={
            "flex-shrink-0 text-[10px] uppercase tracking-wider px-2 py-0.5 rounded border font-medium " +
            (event.closed
              ? "bg-mempool-border/30 text-mempool-text-dim border-mempool-border"
              : "bg-mempool-green/15 text-mempool-green border-mempool-green/40")
          }
        >
          {event.closed ? "Closed" : "Open"}
        </span>
      </div>

      {/* Meta rows */}
      <div className="space-y-1">
        <Row label="organizer" value={
          <button onClick={() => { window.location.hash = `#/address/${event.organizer}`; }} className="text-mempool-blue hover:underline">
            <AddressLabel address={event.organizer} showEmoji truncate={{ left: 8, right: 6 }} />
          </button>
        } />
        <Row label="created at block" value={fmtInt(event.create_block)} />
        <Row
          label="claims"
          value={
            unlimited
              ? `${fmtInt(event.claims_count)} / unlimited`
              : `${fmtInt(event.claims_count)} / ${fmtInt(event.max_claims)}`
          }
        />
        {!unlimited && claimPct !== null && (
          <div className="mt-1">
            <div className="h-1.5 bg-mempool-bg-elev rounded-full overflow-hidden">
              <div
                className="h-full bg-mempool-blue rounded-full transition-all"
                style={{ width: `${Math.min(claimPct, 100)}%` }}
              />
            </div>
          </div>
        )}
        {event.note && (
          <div className="text-[11px] text-mempool-text-dim font-mono mt-1 pt-1 border-t border-mempool-border/40 italic">
            {event.note}
          </div>
        )}
      </div>

      {/* Action buttons */}
      {(onClaim || onClose) && (
        <div className="flex flex-wrap gap-2 pt-1">
          {onClaim && !event.closed && (
            <button
              onClick={onClaim}
              disabled={busyClaim}
              className="px-3 py-2 text-xs rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 font-medium"
            >
              {busyClaim ? "Claiming…" : "Claim POAP"}
            </button>
          )}
          {isOrganizer && !event.closed && onClose && (
            <button
              onClick={onClose}
              disabled={busyClose}
              className="px-3 py-2 text-xs rounded bg-mempool-orange/15 text-mempool-orange border border-mempool-orange/40 hover:bg-mempool-orange/25 disabled:opacity-40 font-medium"
            >
              {busyClose ? "Closing…" : "Close Event"}
            </button>
          )}
        </div>
      )}
    </div>
  );
}

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex justify-between text-xs font-mono">
      <span className="text-mempool-text-dim">{label}</span>
      <span className="text-mempool-text">{value}</span>
    </div>
  );
}

// ── Main Page ─────────────────────────────────────────────────────────────

export function PoapPage() {
  const wallet = useWallet();
  const [tab, setTab] = useState<SubTab>("my-poaps");

  return (
    <section className="bg-mempool-bg-elev rounded-lg p-3 sm:p-4 border border-mempool-border backdrop-blur-sm">
      {/* Header */}
      <div className="flex items-center gap-2 sm:gap-3 mb-4">
        <Award className="w-5 h-5 text-mempool-blue flex-shrink-0" />
        <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          POAP
        </h2>
        <div className="flex-1 h-px bg-mempool-border" />
        <span className="text-[10px] sm:text-xs text-mempool-text-dim font-mono whitespace-nowrap">
          Proof Of Attendance Protocol
        </span>
      </div>

      {/* Sub-tab bar */}
      <div className="flex gap-1 border-b border-mempool-border mb-4 overflow-x-auto scrollbar-none">
        {([
          { id: "my-poaps", label: "My POAPs",    icon: Award },
          { id: "lookup",   label: "Lookup",      icon: Search },
          { id: "create",   label: "Create Event", icon: PlusCircle },
          { id: "claim",    label: "Claim",        icon: Download },
        ] as { id: SubTab; label: string; icon: React.FC<{ className?: string }> }[]).map((t) => {
          const active = tab === t.id;
          return (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={
                "relative flex-shrink-0 flex items-center gap-1.5 px-3 sm:px-4 py-2.5 text-xs font-medium uppercase tracking-wider transition-colors whitespace-nowrap " +
                (active
                  ? "text-mempool-blue"
                  : "text-mempool-text-dim hover:text-mempool-text")
              }
            >
              <t.icon className="w-3.5 h-3.5" />
              {t.label}
              {active && (
                <span className="absolute left-0 right-0 -bottom-px h-0.5 bg-mempool-blue" />
              )}
            </button>
          );
        })}
      </div>

      {tab === "my-poaps" && <MyPoapsTab wallet={wallet} />}
      {tab === "lookup"   && <LookupTab wallet={wallet} />}
      {tab === "create"   && <CreateEventTab wallet={wallet} />}
      {tab === "claim"    && <ClaimTab wallet={wallet} />}
    </section>
  );
}

// ── Tab 1: My POAPs ───────────────────────────────────────────────────────

type WalletProp = ReturnType<typeof useWallet>;

function MyPoapsTab({ wallet }: { wallet: WalletProp }) {
  const [addrInput, setAddrInput] = useState<string>("");
  const effectiveAddress = wallet?.address ?? addrInput.trim();

  const [poaps, setPoaps] = useState<PoapEntry[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  // Selected badge for detail view
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [selectedEvent, setSelectedEvent] = useState<PoapEvent | null>(null);
  const [eventLoading, setEventLoading] = useState(false);

  // Close event from detail panel
  const [busyClose, setBusyClose] = useState(false);
  const [toast, setToast] = useState<string | null>(null);

  // Quick inline lookup
  const [lookupInput, setLookupInput] = useState<string>("");

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast(null), 6000);
  };

  const refresh = useCallback(async () => {
    if (!effectiveAddress) { setPoaps([]); return; }
    setLoading(true);
    setErr(null);
    try {
      const r = await rpc.request_raw("getpoaps", [{ address: effectiveAddress }]) as GetPoapsResp | null;
      setPoaps(r?.poaps ?? []);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
      setPoaps([]);
    } finally {
      setLoading(false);
    }
  }, [effectiveAddress]);

  useEffect(() => { void refresh(); }, [refresh]);

  const loadEventDetail = async (event_id: string) => {
    setSelectedId(event_id);
    setSelectedEvent(null);
    setEventLoading(true);
    try {
      const ev = await rpc.request_raw("getpoapevent", [{ event_id }]) as PoapEvent | null;
      setSelectedEvent(ev);
    } catch { /* ignore */ } finally {
      setEventLoading(false);
    }
  };

  const doClose = async () => {
    if (!wallet || !selectedId) return;
    setBusyClose(true);
    try {
      const nonce = await rpc.getNonce(wallet.address);
      const { signature, publicKey } = signClose({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        event_id: selectedId,
        nonce,
      });
      const r = await rpc.request_raw("poap_close", [{
        from: wallet.address,
        event_id: selectedId,
        signature,
        public_key: publicKey,
        nonce,
      }]) as CloseResp;
      showToast(`Event closed — txid ${r.txid.slice(0, 12)}…`);
      await loadEventDetail(selectedId);
    } catch (e) {
      showToast(`Close failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusyClose(false);
    }
  };

  const doInlineLookup = async () => {
    const id = lookupInput.trim();
    if (!id) return;
    await loadEventDetail(id);
  };

  return (
    <div className="space-y-4">
      {/* Address row */}
      <div className="flex flex-wrap items-center gap-2">
        {wallet ? (
          <span className="text-xs text-mempool-text-dim font-mono truncate max-w-full">
            wallet: <span className="text-mempool-text break-all">{wallet.address}</span>
          </span>
        ) : (
          <input
            type="text"
            value={addrInput}
            onChange={(e) => setAddrInput(e.target.value)}
            placeholder="ob1q… (paste address to view POAPs)"
            className="flex-1 min-w-0 sm:min-w-[280px] w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
        )}
        {poaps !== null && poaps.length > 0 && (
          <button
            onClick={() => {
              const rows = [
                ["event_id","claim_block","tx_hash"].join(","),
                ...poaps.map((p) => [
                  `"${p.event_id}"`,
                  p.claim_block,
                  `"${p.tx_hash}"`,
                ].join(",")),
              ].join("\n");
              const blob = new Blob([rows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = "omnibus-poaps.csv";
              a.click(); URL.revokeObjectURL(url);
            }}
            className="flex items-center gap-1.5 px-3 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
          >
            ⬇ CSV
          </button>
        )}
        <button
          onClick={() => void refresh()}
          disabled={loading}
          className="flex items-center gap-1.5 px-3 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-50"
        >
          <RefreshCw className={`w-3.5 h-3.5 ${loading ? "animate-spin" : ""}`} />
          Refresh
        </button>
      </div>

      {/* Inline event lookup */}
      <div className="flex gap-2">
        <input
          type="text"
          value={lookupInput}
          onChange={(e) => setLookupInput(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter") void doInlineLookup(); }}
          placeholder="Lookup event by ID…"
          className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
        />
        <button
          onClick={() => void doInlineLookup()}
          className="flex items-center gap-1.5 px-3 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
        >
          <Search className="w-3.5 h-3.5" />
          Go
        </button>
      </div>

      {err && <p className="text-xs text-mempool-orange font-mono">{err}</p>}

      {/* Badge grid */}
      {!err && poaps !== null && poaps.length === 0 && (
        <p className="text-xs text-mempool-text-dim font-mono py-8 text-center">
          No POAPs yet. Find an event and claim one!
        </p>
      )}

      {poaps !== null && poaps.length > 0 && (
        <div className="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-5 gap-2">
          {poaps.map((p) => (
            <BadgeCard
              key={p.event_id}
              poap={p}
              onClick={() => void loadEventDetail(p.event_id)}
              selected={selectedId === p.event_id}
            />
          ))}
        </div>
      )}

      {/* Detail panel for selected badge */}
      {selectedId !== null && (
        <div className="space-y-2">
          <div className="flex items-center gap-2">
            <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim font-mono">
              Event details
            </span>
            <button
              onClick={() => { setSelectedId(null); setSelectedEvent(null); }}
              className="text-[10px] text-mempool-text-dim hover:text-mempool-text ml-1"
            >
              [hide]
            </button>
          </div>
          {eventLoading && (
            <p className="text-xs text-mempool-text-dim font-mono">Loading…</p>
          )}
          {!eventLoading && selectedEvent === null && (
            <p className="text-xs text-mempool-orange font-mono">Event not found or RPC error.</p>
          )}
          {!eventLoading && selectedEvent !== null && (
            <>
              <EventInfoCard
                event={selectedEvent}
                walletAddress={wallet?.address}
                onClose={wallet ? doClose : undefined}
                busyClose={busyClose}
              />
              {/* Show TX hash for the owned POAP if it's in our list */}
              {poaps?.find((p) => p.event_id === selectedId) && (() => {
                const p = poaps!.find((pp) => pp.event_id === selectedId)!;
                return (
                  <div className="text-[11px] text-mempool-text-dim font-mono">
                    claim tx:{" "}
                    <a
                      href={`/blocks/${p.tx_hash}`}
                      className="text-mempool-blue hover:underline"
                      title={p.tx_hash}
                    >
                      {midTrunc(p.tx_hash, 10, 6)}
                    </a>
                  </div>
                );
              })()}
            </>
          )}
        </div>
      )}

      {toast && <Toast msg={toast} />}
    </div>
  );
}

// ── Tab 2: Lookup ─────────────────────────────────────────────────────────

function LookupTab({ wallet }: { wallet: WalletProp }) {
  const [eventIdInput, setEventIdInput] = useState<string>("");
  const [event, setEvent] = useState<PoapEvent | null | undefined>(undefined);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const [busyClaim, setBusyClaim] = useState(false);
  const [busyClose, setBusyClose] = useState(false);
  const [toast, setToast] = useState<string | null>(null);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast(null), 6000);
  };

  const doLookup = async () => {
    const event_id = eventIdInput.trim();
    if (!event_id) return;
    setLoading(true);
    setErr(null);
    setEvent(undefined);
    try {
      const ev = await rpc.request_raw("getpoapevent", [{ event_id }]) as PoapEvent | null;
      setEvent(ev ?? null);
      if (ev === null) setErr("Event not found");
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
      setEvent(null);
    } finally {
      setLoading(false);
    }
  };

  const doClaim = async () => {
    if (!wallet || !event) return;
    setBusyClaim(true);
    try {
      const nonce = await rpc.getNonce(wallet.address);
      const { signature, publicKey } = signClaim({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        event_id: event.event_id,
        nonce,
      });
      const r = await rpc.request_raw("poap_claim", [{
        from: wallet.address,
        event_id: event.event_id,
        signature,
        public_key: publicKey,
        nonce,
      }]) as ClaimResp;
      showToast(`POAP claimed! txid ${r.txid.slice(0, 12)}…`);
      // Refresh event data
      await doLookup();
    } catch (e) {
      showToast(`Claim failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusyClaim(false);
    }
  };

  const doClose = async () => {
    if (!wallet || !event) return;
    setBusyClose(true);
    try {
      const nonce = await rpc.getNonce(wallet.address);
      const { signature, publicKey } = signClose({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        event_id: event.event_id,
        nonce,
      });
      const r = await rpc.request_raw("poap_close", [{
        from: wallet.address,
        event_id: event.event_id,
        signature,
        public_key: publicKey,
        nonce,
      }]) as CloseResp;
      showToast(`Event closed — txid ${r.txid.slice(0, 12)}…`);
      await doLookup();
    } catch (e) {
      showToast(`Close failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusyClose(false);
    }
  };

  return (
    <div className="space-y-4">
      {/* Search input */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Event ID
        </label>
        <div className="flex gap-2">
          <input
            type="text"
            value={eventIdInput}
            onChange={(e) => setEventIdInput(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") void doLookup(); }}
            placeholder="omnibus-conf-2026"
            className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
          <button
            onClick={() => void doLookup()}
            disabled={loading || !eventIdInput.trim()}
            className="flex items-center gap-1.5 px-4 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-50"
          >
            {loading ? (
              <RefreshCw className="w-3.5 h-3.5 animate-spin" />
            ) : (
              <Search className="w-3.5 h-3.5" />
            )}
            Lookup
          </button>
        </div>
      </div>

      {err && (
        <div className="flex items-center gap-2 text-xs text-mempool-orange font-mono bg-mempool-orange/10 border border-mempool-orange/30 rounded px-3 py-2">
          <XCircle className="w-4 h-4 flex-shrink-0" />
          {err}
        </div>
      )}

      {!wallet && event && !event.closed && (
        <div className="flex items-center gap-2 text-xs text-mempool-text-dim font-mono bg-mempool-bg border border-mempool-border rounded px-3 py-2">
          <Lock className="w-4 h-4 flex-shrink-0" />
          Connect a wallet to claim this POAP.
        </div>
      )}

      {event && (
        <EventInfoCard
          event={event}
          walletAddress={wallet?.address}
          onClaim={wallet ? doClaim : undefined}
          onClose={wallet ? doClose : undefined}
          busyClaim={busyClaim}
          busyClose={busyClose}
        />
      )}

      {toast && <Toast msg={toast} />}
    </div>
  );
}

// ── Tab 3: Create Event ───────────────────────────────────────────────────

const EVENT_ID_RE = /^[a-zA-Z0-9-]+$/;

function CreateEventTab({ wallet }: { wallet: WalletProp }) {
  const [eventId, setEventId]       = useState<string>("");
  const [name, setName]             = useState<string>("");
  const [maxClaims, setMaxClaims]   = useState<string>("0");
  const [note, setNote]             = useState<string>("");
  const [busy, setBusy]             = useState(false);
  const [toast, setToast]           = useState<string | null>(null);
  const [successInfo, setSuccessInfo] = useState<CreateEventResp | null>(null);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast(null), 7000);
  };

  const eventIdValid = eventId.length > 0 && eventId.length <= 32 && EVENT_ID_RE.test(eventId);
  const nameValid = name.trim().length > 0;
  const maxClaimsNum = parseInt(maxClaims, 10);
  const maxClaimsValid = !isNaN(maxClaimsNum) && maxClaimsNum >= 0;
  const canSubmit = !!wallet && eventIdValid && nameValid && maxClaimsValid && !busy;

  const doCreate = async () => {
    if (!wallet) { showToast("Connect wallet first"); return; }
    setBusy(true);
    setSuccessInfo(null);
    try {
      const nonce = await rpc.getNonce(wallet.address);
      const { signature, publicKey } = signCreateEvent({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        event_id: eventId.trim(),
        name: name.trim(),
        max_claims: maxClaimsNum,
        nonce,
      });
      const r = await rpc.request_raw("poap_createevent", [{
        from: wallet.address,
        event_id: eventId.trim(),
        name: name.trim(),
        max_claims: maxClaimsNum,
        note: note.trim(),
        signature,
        public_key: publicKey,
        nonce,
      }]) as CreateEventResp;
      setSuccessInfo(r);
      showToast(`Event created — txid ${r.txid.slice(0, 12)}…`);
      // Reset form
      setEventId("");
      setName("");
      setMaxClaims("0");
      setNote("");
    } catch (e) {
      showToast(`Create failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-4">
      {!wallet && (
        <div className="flex items-center gap-2 text-xs text-mempool-orange font-mono bg-mempool-orange/10 border border-mempool-orange/30 rounded px-3 py-2">
          <AlertTriangle className="w-4 h-4 flex-shrink-0" />
          Connect a wallet to create an event. Signing happens locally — your private key never leaves the browser.
        </div>
      )}

      {/* Event ID */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Event ID <span className="normal-case">(alphanumeric + hyphen, max 32 chars)</span>
        </label>
        <input
          type="text"
          value={eventId}
          onChange={(e) => setEventId(e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ""))}
          maxLength={32}
          placeholder="omnibus-conf-2026"
          disabled={!wallet}
          className={
            "w-full bg-mempool-bg border rounded px-3 py-2 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none disabled:opacity-40 " +
            (eventId.length > 0 && !eventIdValid
              ? "border-mempool-orange focus:border-mempool-orange"
              : "border-mempool-border focus:border-mempool-blue")
          }
        />
        <div className="flex justify-between text-[10px] font-mono text-mempool-text-dim">
          <span>
            {eventId.length > 0 && !eventIdValid && (
              <span className="text-mempool-orange">Only a-z, 0-9, hyphen allowed</span>
            )}
          </span>
          <span>{eventId.length}/32</span>
        </div>
      </div>

      {/* Name */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Event Name
        </label>
        <input
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="OmniBus Conference 2026"
          disabled={!wallet}
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue disabled:opacity-40"
        />
      </div>

      {/* Max Claims */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Max Claims <span className="normal-case">(0 = unlimited)</span>
        </label>
        <input
          type="number"
          min="0"
          step="1"
          value={maxClaims}
          onChange={(e) => setMaxClaims(e.target.value)}
          placeholder="0"
          disabled={!wallet}
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue disabled:opacity-40"
        />
        <div className="text-[10px] text-mempool-text-dim font-mono">
          {maxClaimsNum === 0 ? "Unlimited participants can claim this badge." : `Up to ${fmtInt(maxClaimsNum)} participants.`}
        </div>
      </div>

      {/* Note */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Note <span className="normal-case">(optional description)</span>
        </label>
        <textarea
          value={note}
          onChange={(e) => setNote(e.target.value)}
          rows={3}
          placeholder="Annual OmniBus developer meetup. Claim this POAP to prove you attended."
          disabled={!wallet}
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue resize-none disabled:opacity-40"
        />
      </div>

      {/* Fee info */}
      <div className="bg-mempool-bg border border-mempool-border rounded p-3 text-xs font-mono text-mempool-text-dim">
        <div className="flex items-center gap-2">
          <CheckCircle2 className="w-4 h-4 text-mempool-blue flex-shrink-0" />
          <span>Creating an event costs <span className="text-mempool-text">~0.01 OMNI</span> as a chain fee.</span>
        </div>
      </div>

      <button
        onClick={() => void doCreate()}
        disabled={!canSubmit}
        className="w-full px-4 py-2.5 rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 disabled:cursor-not-allowed text-sm font-medium uppercase tracking-wider"
      >
        {busy ? "Signing & broadcasting…" : "Create Event"}
      </button>

      {/* Success info */}
      {successInfo && (
        <div className="bg-mempool-green/10 border border-mempool-green/30 rounded p-3 space-y-2">
          <div className="flex items-center gap-2 text-xs text-mempool-green font-semibold uppercase tracking-wider">
            <CheckCircle2 className="w-4 h-4" />
            Event created successfully
          </div>
          <div className="text-xs font-mono space-y-1">
            <Row label="event_id" value={<span className="text-mempool-text">{successInfo.event_id}</span>} />
            <Row label="txid" value={
              <a href={`/blocks/${successInfo.txid}`} className="text-mempool-blue hover:underline" title={successInfo.txid}>
                {midTrunc(successInfo.txid, 10, 6)}
              </a>
            } />
            <Row label="fee" value={`${successInfo.fee_sat} sat`} />
          </div>
          <div className="text-[10px] text-mempool-text-dim font-mono pt-1 border-t border-mempool-green/20">
            Share the event ID <span className="text-mempool-text font-semibold">{successInfo.event_id}</span> with attendees so they can claim their badge in the Claim tab.
          </div>
        </div>
      )}

      {toast && <Toast msg={toast} />}
    </div>
  );
}

// ── Tab 4: Claim ──────────────────────────────────────────────────────────

function ClaimTab({ wallet }: { wallet: WalletProp }) {
  const [eventIdInput, setEventIdInput] = useState<string>("");
  const [previewEvent, setPreviewEvent] = useState<PoapEvent | null | undefined>(undefined);
  const [previewLoading, setPreviewLoading] = useState(false);
  const [previewErr, setPreviewErr] = useState<string | null>(null);

  const [busyClaim, setBusyClaim] = useState(false);
  const [claimResult, setClaimResult] = useState<ClaimResp | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  const showToast = (msg: string) => {
    setToast(msg);
    window.setTimeout(() => setToast(null), 7000);
  };

  const doPreview = async () => {
    const event_id = eventIdInput.trim();
    if (!event_id) return;
    setPreviewLoading(true);
    setPreviewErr(null);
    setPreviewEvent(undefined);
    setClaimResult(null);
    try {
      const ev = await rpc.request_raw("getpoapevent", [{ event_id }]) as PoapEvent | null;
      setPreviewEvent(ev);
      if (!ev) setPreviewErr("Event not found");
    } catch (e) {
      setPreviewErr(e instanceof Error ? e.message : String(e));
      setPreviewEvent(null);
    } finally {
      setPreviewLoading(false);
    }
  };

  const doClaim = async () => {
    if (!wallet || !previewEvent) return;
    setBusyClaim(true);
    setClaimResult(null);
    try {
      const nonce = await rpc.getNonce(wallet.address);
      const { signature, publicKey } = signClaim({
        privateKeyHex: wallet.privateKey,
        from: wallet.address,
        event_id: previewEvent.event_id,
        nonce,
      });
      const r = await rpc.request_raw("poap_claim", [{
        from: wallet.address,
        event_id: previewEvent.event_id,
        signature,
        public_key: publicKey,
        nonce,
      }]) as ClaimResp;
      setClaimResult(r);
      showToast(`POAP claimed! txid ${r.txid.slice(0, 12)}…`);
      // Refresh preview
      await doPreview();
    } catch (e) {
      showToast(`Claim failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusyClaim(false);
    }
  };

  return (
    <div className="space-y-4">
      {!wallet && (
        <div className="flex items-center gap-2 text-xs text-mempool-orange font-mono bg-mempool-orange/10 border border-mempool-orange/30 rounded px-3 py-2">
          <AlertTriangle className="w-4 h-4 flex-shrink-0" />
          Connect a wallet to claim a POAP. Signing happens locally — your private key never leaves the browser.
        </div>
      )}

      {/* Event ID input + preview */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Event ID</label>
        <div className="flex gap-2">
          <input
            type="text"
            value={eventIdInput}
            onChange={(e) => setEventIdInput(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") void doPreview(); }}
            placeholder="omnibus-conf-2026"
            className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          />
          <button
            onClick={() => void doPreview()}
            disabled={previewLoading || !eventIdInput.trim()}
            className="flex items-center gap-1.5 px-4 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-50"
          >
            {previewLoading ? (
              <RefreshCw className="w-3.5 h-3.5 animate-spin" />
            ) : (
              <Search className="w-3.5 h-3.5" />
            )}
            Look up
          </button>
        </div>
      </div>

      {previewErr && (
        <div className="flex items-center gap-2 text-xs text-mempool-orange font-mono bg-mempool-orange/10 border border-mempool-orange/30 rounded px-3 py-2">
          <XCircle className="w-4 h-4 flex-shrink-0" />
          {previewErr}
        </div>
      )}

      {previewEvent && (
        <EventInfoCard
          event={previewEvent}
          walletAddress={wallet?.address}
          onClaim={wallet && !previewEvent.closed ? doClaim : undefined}
          busyClaim={busyClaim}
        />
      )}

      {/* Success badge animation */}
      {claimResult && (
        <div className="bg-mempool-green/10 border border-mempool-green/30 rounded-lg p-4 text-center space-y-3">
          {/* Animated badge */}
          <div className="flex justify-center">
            <div
              className={
                "w-16 h-16 rounded-full flex items-center justify-center border-2 text-2xl font-bold animate-pulse " +
                badgeColor(claimResult.event_id)
              }
            >
              {(claimResult.event_id[0] ?? "?").toUpperCase()}
            </div>
          </div>
          <div>
            <div className="text-sm font-semibold text-mempool-green">POAP Claimed!</div>
            <div className={`text-xs font-mono mt-1 ${badgeTextColor(claimResult.event_id)}`}>
              {claimResult.event_id}
            </div>
          </div>
          <div className="text-xs font-mono text-mempool-text-dim space-y-1">
            <div>
              txid:{" "}
              <a href={`/blocks/${claimResult.txid}`} className="text-mempool-blue hover:underline" title={claimResult.txid}>
                {midTrunc(claimResult.txid, 10, 6)}
              </a>
            </div>
            <div>Status: <span className="text-mempool-green">{claimResult.status}</span></div>
          </div>
          <div className="text-[10px] text-mempool-text-dim font-mono">
            Your badge will appear in the My POAPs tab once the transaction is confirmed.
          </div>
        </div>
      )}

      {toast && <Toast msg={toast} />}
    </div>
  );
}

export default PoapPage;
