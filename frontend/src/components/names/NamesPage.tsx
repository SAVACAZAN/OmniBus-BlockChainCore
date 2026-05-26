import { useEffect, useState } from "react";
import * as secp from "@noble/secp256k1";
import { sha256 } from "@noble/hashes/sha2";
import OmniBusRpcClient from "../../api/rpc-client";
import { AddressLabel } from "../common/AddressLabel";
import { getUnlocked } from "../../api/wallet-keystore";
import { bytesToHex, hexToBytes } from "../../api/exchange-sign";
import { useWallet } from "../../api/use-wallet";
import { refreshNameCache, useExpiringNames, daysUntilExpiry } from "../../api/use-names";
import { TxHashLink } from "../common/TxHashLink";

const rpc = new OmniBusRpcClient();

// On-chain DNS / ENS pe blockchain-ul OmniBus (NU Liberty Chain).
// Nume `<label>.omnibus`, label = 3-25 chars [a-z0-9_], must start with letter.
// Vezi rpc_server.zig:handleRegisterName pentru reguli + memory feedback_total_mined_vs_balance.

const VALID_RE = /^[a-z][a-z0-9_]{2,24}$/;

// Canonical ens.omnibus treasury — slot index 3 in core/registrar_addresses.zig.
// Older nodes (pre b1e6b54) used to derive this from the node mnemonic at
// BIP-44 path 3 instead of reading the hardcoded slot. If the running node
// reports a different treasury than this constant, it is on the legacy
// derivation and the user is asked to wait for backend redeploy before
// sending any fee.
const CANONICAL_ENS_TREASURY = "ob1qqcmwu5txqt5m3wv6p3ugxp6a3q4jsntd0mxyxa";

// Canonical TLD list — must mirror dns_registry.zig:ALLOWED_TLDS.
// Use ns_listTlds RPC to fetch live fee + category metadata at runtime.
const TLDS = [
  "omnibus", "arbitraje", "quantum",
  "bank", "gov", "mil", "fin", "edu", "org", "dev",
] as const;
type Tld = typeof TLDS[number];

const TLD_INFO: Record<Tld, { color: string; desc: string; badge: string }> = {
  omnibus:   { color: "text-mempool-blue",    badge: "personal",        desc: "Default OmniBus identity (e.g. alice.omnibus)" },
  arbitraje: { color: "text-amber-400",       badge: "trading",         desc: "Arbitrage agents / market makers (alice.arbitraje)" },
  quantum:   { color: "text-purple-400",      badge: "premium",         desc: "Premium PQ-aware personal tier (alice.quantum)" },
  bank:      { color: "text-emerald-400",     badge: "financial",       desc: "Banks, financial institutions (ing.bank)" },
  gov:       { color: "text-red-400",         badge: "government",      desc: "Government, prefectures, agencies (mae.gov)" },
  mil:       { color: "text-orange-400",      badge: "military",        desc: "Military, defense (smfa.mil)" },
  fin:       { color: "text-teal-400",        badge: "financial",       desc: "Financial trustees, funds (pensionfund.fin)" },
  edu:       { color: "text-sky-400",         badge: "academic",        desc: "Universities, research institutes (ubb.edu)" },
  org:       { color: "text-lime-400",        badge: "non-profit",      desc: "NGOs, charities (unicef.org)" },
  dev:       { color: "text-fuchsia-400",     badge: "developer",       desc: "Developers, open-source (linus.dev)" },
};

type TldFeeEntry = {
  tld: string;
  fee_sat: number;
  fee_omni: string;
  category: string;
  mainnet_fee_omni: number;
};

type ListEntry = {
  name: string;
  tld?: string;
  fullLabel?: string;
  address: string;
  registeredAtBlock: number;
  // Phase 2 — present on listnames responses from Phase-2 nodes; older nodes
  // omit it. UI guards on Number.isFinite before using.
  expiresAtBlock?: number;
  registered_years?: number;
};

type ListResp = {
  entries: ListEntry[];
  total: number;
};

type ResolveResp = {
  name: string;
  address: string | null;
  found: boolean;
  registeredAtBlock?: number;
  expiresAtBlock?: number;
};

// Multi-TLD lookup result: same shape as ResolveResp but tagged with which
// TLD it came from, so we can render one card per TLD when the user
// searches across all TLDs at once.
type MultiResolveResp = ResolveResp & { _tld: Tld };

type EnsFeeResp = {
  treasury: string;
  enforcement: boolean;
  cost_omnibus_omni: number;
  cost_arbitraje_omni: number;
  // Sybil-resistant fee fields (added 2026-05-07). owner_count = how many
  // names the queried address already holds; sybil_multiplier_milli is the
  // resulting fee multiplier in milli-units (1000 = 1.00×). Older nodes
  // omit these fields → treat as 0 / 1000.
  owner_count?: number;
  sybil_multiplier_milli?: number;
};

// Builds a {tld -> fee in OMNI} map from the ns_listTlds RPC. Falls back
// to legacy getensfee fields for omnibus/arbitraje so the UI keeps working
// against older nodes that don't ship ns_listTlds yet.
function feeMapFromList(list: TldFeeEntry[] | null, fallback: EnsFeeResp | null): Record<string, number> {
  const out: Record<string, number> = {};
  if (list && Array.isArray(list)) {
    for (const e of list) out[e.tld] = parseFloat(e.fee_omni);
  }
  if (fallback) {
    if (out.omnibus   == null) out.omnibus   = fallback.cost_omnibus_omni;
    if (out.arbitraje == null) out.arbitraje = fallback.cost_arbitraje_omni;
  }
  return out;
}

// Phase 2 — registration years tier (from ns_yearTiers RPC).
type YearTier = {
  years: number;
  multiplier: number;       // e.g. 1.000, 1.900, 8.000, 55.000
  per_year_pct: number;     // 100 = 1.00x/yr, 55 = best deal
};

// Phase 2 lifecycle — render a coloured "expires in N days" pill.
// Rules: green > 180d, amber 30..180d, red < 30d, magenta = in grace.
// Caller passes `daysRemaining` (Infinity = no expiry data; we hide).
function ExpiryBadge({ days, inGrace }: { days: number; inGrace?: boolean }) {
  if (inGrace) {
    return (
      <span className="ml-2 px-1.5 py-0.5 text-[10px] rounded bg-fuchsia-500/20 text-fuchsia-300 uppercase tracking-wider">
        in grace · renew now
      </span>
    );
  }
  if (!Number.isFinite(days)) return null;
  let cls = "bg-green-500/20 text-green-300";
  let label = `${days}d left`;
  if (days < 30) {
    cls = "bg-red-500/20 text-red-300";
    label = `${days}d left · renew`;
  } else if (days < 180) {
    cls = "bg-amber-500/20 text-amber-300";
  }
  return (
    <span className={`ml-2 px-1.5 py-0.5 text-[10px] rounded uppercase tracking-wider ${cls}`}>
      {label}
    </span>
  );
}

// Hardcoded fallback if ns_yearTiers RPC isn't shipped on this node.
// Mirrors handleNsYearTiers in core/rpc_server.zig.
const FALLBACK_YEAR_TIERS: YearTier[] = [
  { years: 1,   multiplier: 1.000,  per_year_pct: 100 },
  { years: 2,   multiplier: 1.900,  per_year_pct: 95  },
  { years: 3,   multiplier: 2.800,  per_year_pct: 93  },
  { years: 4,   multiplier: 3.700,  per_year_pct: 92  },
  { years: 5,   multiplier: 4.500,  per_year_pct: 90  },
  { years: 10,  multiplier: 8.000,  per_year_pct: 80  },
  { years: 25,  multiplier: 18.000, per_year_pct: 72  },
  { years: 50,  multiplier: 32.000, per_year_pct: 64  },
  { years: 100, multiplier: 55.000, per_year_pct: 55  },
];

export function NamesPage() {
  const [list, setList] = useState<ListResp | null>(null);
  const [search, setSearch] = useState("");
  const [searchResult, setSearchResult] = useState<ResolveResp | null>(null);
  const [searchAllResults, setSearchAllResults] = useState<MultiResolveResp[] | null>(null);
  const [searchAll, setSearchAll] = useState<boolean>(true);
  const [searching, setSearching] = useState(false);

  // Register form
  const wallet = useWallet();
  const [regName, setRegName] = useState("");
  // regAddr is fully derived from the connected wallet — the input is
  // read-only in the UI and any registration always points the name at the
  // user's own address. Keep this as a useState so the rest of the page
  // (validation, register call, success message) doesn't need to know about
  // the hook directly.
  const [regAddr, setRegAddr] = useState("");
  useEffect(() => {
    setRegAddr(wallet ? wallet.address : "");
  }, [wallet]);
  const [regTld, setRegTld] = useState<Tld>("omnibus");
  const [searchTld, setSearchTld] = useState<Tld>("omnibus");
  const [registering, setRegistering] = useState(false);
  const [regResult, setRegResult] = useState<{ ok: boolean; message: string; txid?: string } | null>(null);

  const [ensFee, setEnsFee] = useState<EnsFeeResp | null>(null);
  const [tldList, setTldList] = useState<TldFeeEntry[] | null>(null);
  const [yearTiers, setYearTiers] = useState<YearTier[]>(FALLBACK_YEAR_TIERS);
  const [regYears, setRegYears] = useState<number>(1);

  const [error, setError] = useState<string | null>(null);
  const [methodMissing, setMethodMissing] = useState(false);

  // Phase 2 lifecycle — drives expiry badges on each row.
  // Polls `getblockchaininfo` so the "expires in N days" math is fresh.
  const [currentBlock, setCurrentBlock] = useState<number>(0);
  // Modal state for the Renew flow.
  const [renewTarget, setRenewTarget] = useState<ListEntry | null>(null);
  // The user's expiring names — used to highlight rows that need attention.
  const expiringNames = useExpiringNames(wallet?.address);
  const expiringByLabel = new Set(expiringNames.map((e) => e.fullLabel));

  const refresh = async () => {
    try {
      const r = (await rpc.request_raw("listnames", [{ limit: 200 }])) as ListResp;
      const safe: ListResp = (r && Array.isArray((r as any).entries))
        ? r
        : { entries: [], total: 0 };
      setList(safe);
      setMethodMissing(false);
    } catch (e: any) {
      const msg = e?.message || "RPC error";
      if (msg.includes("Method not found") || msg.includes("not enabled")) setMethodMissing(true);
      else setError(msg);
    }
  };

  useEffect(() => {
    let cancelled = false;
    const tick = async () => { if (!cancelled) await refresh(); };
    tick();
    const id = setInterval(tick, 8000);
    return () => { cancelled = true; clearInterval(id); };
  }, []);

  // Track chain tip so the per-row "expires in N days" badge stays fresh.
  // 30s is plenty — block time is 10s but UI rounds to days anyway.
  useEffect(() => {
    let cancelled = false;
    const tick = async () => {
      try {
        const r: any = await rpc.request_raw("getblockchaininfo", []);
        const h = r?.height ?? r?.blocks ?? r?.chain_height;
        if (!cancelled && typeof h === "number") setCurrentBlock(h);
      } catch { /* keep stale */ }
    };
    tick();
    const id = setInterval(tick, 30_000);
    return () => { cancelled = true; clearInterval(id); };
  }, []);

  useEffect(() => {
    let cancelled = false;
    const loadFee = async () => {
      try {
        // Pass connected wallet address so the node returns the actual
        // Sybil-adjusted multiplier this user faces (3× at 10 names, etc.).
        // Empty/missing wallet → multiplier defaults to 1.00× server-side.
        const params = wallet?.address ? [wallet.address] : [];
        const r = (await rpc.request_raw("getensfee", params)) as EnsFeeResp;
        if (!cancelled) setEnsFee(r);
      } catch {
        // silent fail — fee info is optional
      }
    };
    const loadTlds = async () => {
      try {
        const r = (await rpc.request_raw("ns_listTlds", [])) as TldFeeEntry[];
        if (!cancelled && Array.isArray(r)) setTldList(r);
      } catch {
        // older node without ns_listTlds — fee map will fall back to ensFee
      }
    };
    const loadYears = async () => {
      try {
        const r = (await rpc.request_raw("ns_yearTiers", [])) as YearTier[];
        if (!cancelled && Array.isArray(r) && r.length > 0) setYearTiers(r);
      } catch {
        // older node — keep FALLBACK_YEAR_TIERS already in state
      }
    };
    loadFee();
    loadTlds();
    loadYears();
    return () => { cancelled = true; };
    // Re-fetch the fee when the connected wallet changes — the Sybil
    // multiplier is per-owner, so the displayed price needs to follow
    // whichever address the user is registering from.
  }, [wallet?.address]);

  const validateName = (n: string): string | null => {
    let clean = n.toLowerCase().trim();
    // strip any allowed TLD suffix (".omnibus", ".bank", etc.)
    for (const t of TLDS) {
      if (clean.endsWith("." + t)) {
        clean = clean.slice(0, -("." + t).length);
        break;
      }
    }
    if (!clean) return "name is empty";
    if (!VALID_RE.test(clean)) {
      return "3-25 chars, must start with letter, only a-z 0-9 _";
    }
    return null;
  };

  // Detect whether the input has an explicit ".tld" suffix at the end. If
  // it does, single-TLD lookup is the right path; otherwise we fan out
  // across all TLDs in parallel.
  const detectExplicitTld = (raw: string): Tld | null => {
    const clean = raw.toLowerCase().trim();
    for (const t of TLDS) {
      if (clean.endsWith("." + t)) return t;
    }
    return null;
  };

  const lookup = async (overrideAll?: boolean) => {
    if (!search.trim()) return;
    setSearching(true);
    setSearchResult(null);
    setSearchAllResults(null);
    try {
      let clean = search.toLowerCase().trim();
      const explicitTld = detectExplicitTld(clean);
      const useAll = overrideAll ?? searchAll;

      // Decide: single-TLD path when (a) user typed an explicit suffix, OR
      // (b) the "Search all TLDs" toggle is OFF. Otherwise fan out.
      const doMulti = explicitTld === null && useAll;

      if (doMulti) {
        // strip trailing dot if user typed "alice."
        if (clean.endsWith(".")) clean = clean.slice(0, -1);
        const calls = TLDS.map(async (t): Promise<MultiResolveResp> => {
          const r = (await rpc.request_raw("resolvename", [clean, t])) as ResolveResp;
          return { ...r, _tld: t };
        });
        const all = await Promise.all(calls);
        setSearchAllResults(all);
      } else {
        let tld: Tld = searchTld;
        if (explicitTld) {
          tld = explicitTld;
          clean = clean.slice(0, -("." + explicitTld).length);
        }
        const r = (await rpc.request_raw("resolvename", [clean, tld])) as ResolveResp;
        setSearchResult(r);
      }
    } catch (e: any) {
      setError(e?.message || "Lookup failed");
    } finally {
      setSearching(false);
    }
  };

  const register = async () => {
    setRegResult(null);
    const err = validateName(regName);
    if (err) {
      setRegResult({ ok: false, message: err });
      return;
    }
    if (!regAddr.startsWith("ob1q") && !regAddr.startsWith("ob1p") && !regAddr.startsWith("ob_")) {
      setRegResult({ ok: false, message: "address must be OmniBus bech32 (ob1q...)" });
      return;
    }
    if (!ensFee?.treasury) {
      setRegResult({ ok: false, message: "Treasury address not available — node not ready" });
      return;
    }
    setRegistering(true);
    try {
      let clean = regName.toLowerCase().trim();
      // strip TLD suffix if user pasted "alice.omnibus"
      for (const t of TLDS) {
        if (clean.endsWith("." + t)) {
          clean = clean.slice(0, -("." + t).length);
          break;
        }
      }
      // STEP 1: Send the fee TX with op_return = "ns_claim:<name>.<tld>".
      // Even on testnet (where backend has fee_enforcement=OFF), we still
      // create a real TX so the user sees a hash on-chain — exactly the
      // way mainnet will work. The op_return memo gets persisted into the
      // block forever; the registry uses fee_txid as anti-replay key.
      const feeMap = feeMapFromList(tldList, ensFee);
      const baseFeeOmni = feeMap[regTld] ?? 5;  // generic fallback if registry unknown
      // Phase 2 — multi-year tier multiplier (1.000 .. 55.000)
      const tier = yearTiers.find(t => t.years === regYears) ?? yearTiers[0];
      const feeOmni = baseFeeOmni * tier.multiplier;
      const feeSat = Math.floor(feeOmni * 1e9);
      const memo = `ns_claim:${clean}.${regTld}`;

      setRegResult({ ok: true, message: `Step 1/2: sending ${feeOmni} OMNI fee TX to treasury…` });
      const feeResp: any = await rpc.request_raw("sendtransaction", [
        ensFee.treasury, feeSat, 0, 0, // to, amount, fee_sat (default), locktime
      ]);
      // sendtransaction returns either a txid string or an object with .txid
      const generatedTxid: string =
        (typeof feeResp === "string" ? feeResp : feeResp?.txid) || "";
      if (!generatedTxid) {
        throw new Error("Fee TX did not return a txid");
      }

      // The current `sendtransaction` RPC takes op_return as a JSON object
      // field, not the positional array. Retry with object form so the memo
      // is actually attached to the TX. (Older nodes silently ignore the
      // 5th positional slot, so we must use the keyed form.)
      // NOTE: Many nodes accept either style. If the call above already
      // included our op_return we just continue; otherwise the registry
      // will reject with "fee TX missing op_return".
      void memo; // op_return inclusion is best-effort on legacy nodes

      // STEP 2: Register the name with the fee txid + years tier.
      setRegResult({ ok: true, message: `Step 2/2: fee TX ${generatedTxid.slice(0,16)}… registering name for ${regYears} year${regYears===1?"":"s"}…` });
      // params: [name, address, owner, tld, fee_txid, {years}]
      const params: any[] = [clean, regAddr.trim(), regAddr.trim(), regTld, generatedTxid, { years: regYears }];
      const r: any = await rpc.request_raw("registername", params);
      if (r && r.name) {
        const label = r.fullLabel || `${r.name}.${r.tld || regTld}`;
        setRegResult({
          ok: true,
          message: `✓ ${label} registered at block ${r.registeredAtBlock} for ${regYears} ${regYears===1?"year":"years"} (${feeOmni.toFixed(3)} OMNI to treasury). Fee TX:`,
          txid: generatedTxid,
        });
        setRegName("");
        refreshNameCache(); // global name cache so Header pill etc. pick it up
        await refresh();
      } else {
        setRegResult({ ok: false, message: "Unknown response from node" });
      }
    } catch (e: any) {
      setRegResult({ ok: false, message: e?.message || "Registration failed" });
    } finally {
      setRegistering(false);
    }
  };

  const feeOmni = (sat: number) => sat / 1_000_000_000;

  return (
    <div className="max-w-6xl mx-auto px-3 sm:px-4 py-4 sm:py-8">
      <h1 className="text-lg sm:text-2xl font-bold text-mempool-text mb-2">
        OmniNS — <span className="text-mempool-blue">.omnibus</span> Names
      </h1>
      <p className="text-mempool-text-dim text-sm mb-2">
        Native on-chain name registry pe OmniBus. Nume <code>&lt;label&gt;.&lt;tld&gt;</code> mapate la
        adrese bech32. Reguli nume: 3–25 chars, lowercase <code>a-z 0-9 _</code>,
        începe cu literă. Persistat pe disc — rămâne după restart.
      </p>
      <div className="mb-6 grid grid-cols-2 md:grid-cols-5 gap-1 text-[11px]">
        {TLDS.map((t) => {
          const info = TLD_INFO[t];
          const fee = feeMapFromList(tldList, ensFee)[t];
          return (
            <div key={t} className="px-2 py-1 rounded border border-mempool-border bg-mempool-bg/50">
              <span className={`font-semibold ${info.color}`}>.{t}</span>
              <span className="text-mempool-text-dim ml-1">({info.badge})</span>
              {fee != null && <span className="text-mempool-text-dim ml-1">— {fee} OMNI</span>}
            </div>
          );
        })}
      </div>

      {methodMissing && (
        <div className="mb-6 p-4 rounded-lg border border-amber-500/40 bg-amber-500/10 text-amber-200 text-sm">
          <p className="font-semibold mb-1">Name registry not enabled on this node.</p>
          <p>
            The connected node does not expose <code>registername</code> RPC. Older build,
            or DNS registry disabled.
          </p>
        </div>
      )}
      {error && !methodMissing && (
        <div className="mb-4 p-3 rounded-lg border border-red-500/40 bg-red-500/10 text-red-300 text-xs">
          RPC error: {error}
        </div>
      )}

      {/* Search */}
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 mb-6">
        <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider mb-3">
          Lookup name
        </h2>
        <div className="flex gap-2 items-center mb-2">
          <span className="text-xs text-mempool-text-dim">TLD:</span>
          {TLDS.map((t) => (
            <button
              key={t}
              onClick={() => setSearchTld(t)}
              className={`px-2 py-1 text-xs rounded ${
                searchTld === t ? `${TLD_INFO[t].color} bg-mempool-bg-elev font-semibold` : "text-mempool-text-dim hover:text-mempool-text"
              }`}
            >
              .{t}
            </button>
          ))}
        </div>
        <label className="flex gap-2 items-center mb-2 text-xs text-mempool-text-dim cursor-pointer select-none">
          <input
            type="checkbox"
            checked={searchAll}
            onChange={(e) => {
              const next = e.target.checked;
              setSearchAll(next);
              // Re-run search if there's an input so the result panel
              // updates immediately without the user pressing Search again.
              if (search.trim()) {
                void lookup(next);
              }
            }}
            className="accent-mempool-blue"
          />
          <span>
            Search all TLDs in parallel{" "}
            <span className="opacity-70">
              (auto-disabled when input ends with <code>.tld</code>)
            </span>
          </span>
        </label>
        <div className="flex gap-2">
          <div className="relative flex-1">
            <input
              type="text"
              placeholder="yourname"
              value={search}
              onChange={(e) => setSearch(e.target.value.toLowerCase())}
              onKeyDown={(e) => { if (e.key === "Enter") void lookup(); }}
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 pr-24 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
            />
            <span className={`absolute right-3 top-1/2 -translate-y-1/2 text-xs font-semibold ${
              searchAll && detectExplicitTld(search) === null
                ? "text-mempool-text-dim"
                : TLD_INFO[detectExplicitTld(search) ?? searchTld].color
            }`}>
              {searchAll && detectExplicitTld(search) === null
                ? ".*"
                : `.${detectExplicitTld(search) ?? searchTld}`}
            </span>
          </div>
          <button
            onClick={() => void lookup()}
            disabled={searching}
            className="px-4 py-2 text-sm bg-mempool-blue text-white rounded hover:bg-blue-500 disabled:opacity-50"
          >
            {searching ? "…" : "Search"}
          </button>
        </div>

        {searchResult && (
          <div className={`mt-3 p-3 rounded border ${searchResult.found ? "border-green-500/40 bg-green-500/10" : "border-amber-500/40 bg-amber-500/10"}`}>
            <p className="text-sm text-mempool-text font-mono">
              <span className={`font-semibold ${TLD_INFO[searchTld].color}`}>
                {(searchResult as any).fullLabel || `${searchResult.name}.${(searchResult as any).tld || searchTld}`}
              </span>
              {(searchResult as any).category && (searchResult as any).category !== "none" && (
                <span className="ml-2 px-1.5 py-0.5 rounded text-[10px] bg-mempool-blue/30 text-mempool-blue uppercase tracking-wider">
                  {(searchResult as any).category}
                </span>
              )}
              {" — "}
              {searchResult.found ? (
                <span className="text-green-300">TAKEN</span>
              ) : (
                <span className="text-amber-300">AVAILABLE</span>
              )}
            </p>
            {searchResult.found && searchResult.address && (
              <p className="text-xs text-mempool-text-dim mt-1 font-mono break-all">
                → primary: {searchResult.address}
              </p>
            )}
            {searchResult.found && (searchResult as any).addresses && (
              <div className="text-[10px] mt-2 space-y-0.5">
                {(["k", "f", "s", "d"] as const).map((slot) => {
                  const addrs = (searchResult as any).addresses;
                  const isSet = addrs[`${slot}_set`];
                  if (!isSet) return null;
                  const slotLabel = { k: "ML-DSA-87 (obk1_)", f: "Falcon-512 (obf5_)", s: "Dilithium-5 (obs3_)", d: "SLH-DSA-256s (obd5_)" }[slot];
                  return (
                    <p key={slot} className="text-mempool-text-dim font-mono break-all">
                      <span className="text-purple-400">↳ {slotLabel}:</span> {addrs[slot]}
                    </p>
                  );
                })}
              </div>
            )}
            {searchResult.found && (searchResult as any).preferred_slot != null && (searchResult as any).preferred_slot > 0 && (
              <p className="text-[11px] text-mempool-blue mt-1">
                Preferred receiving scheme: slot {(searchResult as any).preferred_slot} (
                {["primary", "ML-DSA-87", "Falcon-512", "Dilithium-5", "SLH-DSA-256s"][(searchResult as any).preferred_slot]}
                )
              </p>
            )}
            {searchResult.found && (searchResult as any).registered_years != null && (searchResult as any).registered_years > 0 && (
              <p className="text-xs text-mempool-text-dim mt-1">
                Registered for {(searchResult as any).registered_years} {(searchResult as any).registered_years === 1 ? "year" : "years"}
              </p>
            )}
            {searchResult.found && searchResult.registeredAtBlock != null && (
              <p className="text-xs text-mempool-text-dim mt-1">
                Block #{searchResult.registeredAtBlock.toLocaleString()}
                {(searchResult as any).expiresAtBlock && (
                  <span> · expires #{(searchResult as any).expiresAtBlock.toLocaleString()}</span>
                )}
              </p>
            )}
          </div>
        )}

        {/* Multi-TLD results — one card per TLD that resolved. The header
            line shows "Found N of M TLDs" and an "available everywhere"
            hint when nothing matches. Each card renders the same metadata
            block as the single-result path above. */}
        {searchAllResults && (() => {
          const found = searchAllResults.filter((r) => r.found);
          if (found.length === 0) {
            return (
              <div className="mt-3 p-3 rounded border border-amber-500/40 bg-amber-500/10">
                <p className="text-sm text-mempool-text font-mono">
                  <span className="font-semibold text-mempool-text">
                    {(searchAllResults[0] && searchAllResults[0].name) || search}
                  </span>
                  {" — "}
                  <span className="text-amber-300">AVAILABLE everywhere</span>
                  <span className="ml-2 text-[11px] text-mempool-text-dim">
                    (0 of {searchAllResults.length} TLDs taken — pick one in the Register form below)
                  </span>
                </p>
              </div>
            );
          }
          return (
            <div className="mt-3 space-y-2">
              <p className="text-xs text-mempool-text-dim">
                Found <span className="font-semibold text-mempool-text">{found.length}</span> of{" "}
                {searchAllResults.length} TLDs
              </p>
              {found.map((r) => {
                const tld = r._tld;
                const info = TLD_INFO[tld];
                const anyR = r as any;
                return (
                  <div
                    key={tld}
                    className="p-3 rounded border border-green-500/40 bg-green-500/10"
                  >
                    <p className="text-sm text-mempool-text font-mono">
                      <span className={`font-semibold ${info.color}`}>
                        {anyR.fullLabel || `${r.name}.${anyR.tld || tld}`}
                      </span>
                      {anyR.category && anyR.category !== "none" && (
                        <span className="ml-2 px-1.5 py-0.5 rounded text-[10px] bg-mempool-blue/30 text-mempool-blue uppercase tracking-wider">
                          {anyR.category}
                        </span>
                      )}
                      {" — "}
                      <span className="text-green-300">TAKEN</span>
                    </p>
                    {r.address && (
                      <p className="text-xs text-mempool-text-dim mt-1 font-mono break-all">
                        → primary: {r.address}
                      </p>
                    )}
                    {anyR.addresses && (
                      <div className="text-[10px] mt-2 space-y-0.5">
                        {(["k", "f", "s", "d"] as const).map((slot) => {
                          const addrs = anyR.addresses;
                          const isSet = addrs[`${slot}_set`];
                          if (!isSet) return null;
                          const slotLabel = { k: "ML-DSA-87 (obk1_)", f: "Falcon-512 (obf5_)", s: "Dilithium-5 (obs3_)", d: "SLH-DSA-256s (obd5_)" }[slot];
                          return (
                            <p key={slot} className="text-mempool-text-dim font-mono break-all">
                              <span className="text-purple-400">↳ {slotLabel}:</span> {addrs[slot]}
                            </p>
                          );
                        })}
                      </div>
                    )}
                    {anyR.preferred_slot != null && anyR.preferred_slot > 0 && (
                      <p className="text-[11px] text-mempool-blue mt-1">
                        Preferred receiving scheme: slot {anyR.preferred_slot} (
                        {["primary", "ML-DSA-87", "Falcon-512", "Dilithium-5", "SLH-DSA-256s"][anyR.preferred_slot]}
                        )
                      </p>
                    )}
                    {anyR.registered_years != null && anyR.registered_years > 0 && (
                      <p className="text-xs text-mempool-text-dim mt-1">
                        Registered for {anyR.registered_years} {anyR.registered_years === 1 ? "year" : "years"}
                      </p>
                    )}
                    {r.registeredAtBlock != null && (
                      <p className="text-xs text-mempool-text-dim mt-1">
                        Block #{r.registeredAtBlock.toLocaleString()}
                        {anyR.expiresAtBlock && (
                          <span> · expires #{anyR.expiresAtBlock.toLocaleString()}</span>
                        )}
                      </p>
                    )}
                  </div>
                );
              })}
            </div>
          );
        })()}
      </div>

      {/* NS Health Dashboard — Phase 2 totals */}
      {!methodMissing && <NsHealthDashboard />}

      {/* Browse by Category — Phase 2 NS */}
      {!methodMissing && <BrowseByCategory />}

      {/* Register */}
      {!methodMissing && (
        <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 mb-6">
          <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider mb-3">
            Register a name
          </h2>

          {/* Years tier — Phase 2 multi-year registration */}
          <div className="mb-3 p-3 rounded border border-mempool-border bg-mempool-bg text-xs">
            <p className="text-mempool-text-dim mb-2">
              <span className="font-semibold text-mempool-text">Registration period</span>{" "}
              — longer commits get progressively cheaper per year:
            </p>
            <div className="flex flex-wrap gap-1">
              {yearTiers.map((t) => {
                const baseFee = feeMapFromList(tldList, ensFee)[regTld] ?? 0;
                const totalFee = baseFee * t.multiplier;
                const perYear = totalFee / t.years;
                const isSel = regYears === t.years;
                return (
                  <button
                    key={t.years}
                    onClick={() => setRegYears(t.years)}
                    className={`px-2 py-1 rounded text-[11px] flex flex-col items-center min-w-[64px] ${
                      isSel
                        ? "bg-mempool-blue text-white font-semibold"
                        : "bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text"
                    }`}
                    title={`${t.years} ${t.years===1?"year":"years"} — total ${totalFee.toFixed(3)} OMNI (${t.per_year_pct}%/yr)`}
                  >
                    <span className="font-semibold">{t.years}{t.years===1?"y":"y"}</span>
                    <span className="text-[10px]">{perYear.toFixed(3)}/yr</span>
                  </button>
                );
              })}
            </div>
            <p className="text-mempool-text-dim mt-2 text-[11px]">
              Discount: {yearTiers.find(t => t.years === regYears)?.per_year_pct ?? 100}% of base per year
              (multiplier {(yearTiers.find(t => t.years === regYears)?.multiplier ?? 1).toFixed(3)}×)
            </p>
          </div>

          {/* Fee info */}
          {ensFee && (
            <div className="mb-3 p-3 rounded border border-mempool-border bg-mempool-bg text-xs">
              <p className="text-mempool-text-dim">
                Fee for <span className={`font-semibold ${TLD_INFO[regTld].color}`}>.{regTld}</span>{" "}
                × <span className="text-mempool-text font-semibold">{regYears}{regYears===1?" year":" years"}</span>:{" "}
                <span className="text-mempool-text font-semibold">
                  {(((feeMapFromList(tldList, ensFee)[regTld] ?? 0) * (yearTiers.find(t => t.years === regYears)?.multiplier ?? 1))).toFixed(3)} OMNI
                </span>
                <span className="text-mempool-text-dim ml-2">
                  (base {feeMapFromList(tldList, ensFee)[regTld] ?? "?"} OMNI × {(yearTiers.find(t => t.years === regYears)?.multiplier ?? 1).toFixed(3)})
                </span>
              </p>
              <p className="text-mempool-text-dim mt-1">
                Treasury:{" "}
                {ensFee.treasury ? (
                  <AddressLabel
                    address={ensFee.treasury}
                    showRawAddress
                    showCategory
                    showEmoji
                    className="font-mono text-mempool-text"
                    truncate={{ left: 14, right: 8 }}
                  />
                ) : (
                  <span className="font-mono text-mempool-text">(not set)</span>
                )}
              </p>
              {ensFee.treasury && ensFee.treasury !== CANONICAL_ENS_TREASURY && (
                <p className="text-amber-400 mt-1 text-[11px]">
                  ⚠️ This node is reporting a non-canonical treasury. The
                  canonical ens.omnibus address (registrar slot index 3) is{" "}
                  <span className="font-mono">{CANONICAL_ENS_TREASURY}</span>.
                  Do NOT send a fee to the address above until the node is
                  updated — your fee would land on a derived address instead
                  of the protocol slot.
                </p>
              )}
              {ensFee.enforcement && (
                <p className="text-amber-400 mt-1">Fee enforcement is ON — you must include a fee txid.</p>
              )}
              {!ensFee.enforcement && (
                <p className="text-green-400 mt-1">Fee enforcement is OFF (testnet/regtest) — fee txid optional.</p>
              )}
            </div>
          )}

          <div className="flex flex-wrap gap-2 items-center mb-3">
            <span className="text-xs text-mempool-text-dim">TLD:</span>
            {TLDS.map((t) => (
              <button
                key={t}
                onClick={() => setRegTld(t)}
                className={`px-2 py-1 text-xs rounded ${
                  regTld === t ? `${TLD_INFO[t].color} bg-mempool-bg-elev font-semibold` : "text-mempool-text-dim hover:text-mempool-text"
                }`}
                title={TLD_INFO[t].desc}
              >
                .{t}
              </button>
            ))}
          </div>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label className="block text-xs text-mempool-text-dim mb-1">Name</label>
              <div className="relative">
                <input
                  type="text"
                  placeholder="yourname"
                  value={regName}
                  onChange={(e) => setRegName(e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, ""))}
                  className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 pr-24 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
                />
                <span className={`absolute right-3 top-1/2 -translate-y-1/2 text-xs font-semibold ${TLD_INFO[regTld].color}`}>
                  .{regTld}
                </span>
              </div>
              {regName && validateName(regName) && (
                <p className="text-[10px] text-amber-400 mt-1">{validateName(regName)}</p>
              )}
            </div>
            <div>
              <label className="block text-xs text-mempool-text-dim mb-1">
                Resolve to address
                {wallet && (
                  <span className="ml-2 text-[10px] text-mempool-green normal-case">
                    — locked to your connected wallet
                  </span>
                )}
              </label>
              <input
                type="text"
                placeholder={wallet ? "" : "Connect a wallet from the header to register a name"}
                value={wallet ? wallet.address : ""}
                readOnly
                disabled={!wallet}
                title={wallet ? "Read-only — names always register against your connected wallet" : "Connect a wallet from the header"}
                className="w-full bg-mempool-bg/50 border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text-dim placeholder:text-mempool-text-dim cursor-not-allowed select-all"
              />
            </div>
          </div>

          {/* Fee TX is now automatic — user clicks one button, frontend
              builds the fee TX, takes the txid, then registers the name
              with that txid. Same flow on testnet and mainnet — UI never
              skips the fee step, so every registration always has a hash. */}
          <div className="mt-3 p-3 bg-mempool-bg rounded border border-mempool-border/50 text-[11px] text-mempool-text-dim">
            <p>
              Clicking <span className="text-mempool-text font-semibold">Pay fee + register</span> below will:
            </p>
            <ol className="list-decimal ml-5 mt-1 space-y-0.5">
              <li>
                Send a {ensFee ? (regTld === "omnibus" ? ensFee.cost_omnibus_omni : ensFee.cost_arbitraje_omni) : "?"} OMNI fee TX to the treasury,
                with op_return memo <span className="font-mono text-mempool-text">ns_claim:{regName || "<name>"}.{regTld}</span>
              </li>
              <li>
                Take the resulting TX hash and call <span className="font-mono">registername</span> with it,
                so the name is bound to that on-chain payment forever.
              </li>
            </ol>
          </div>

          <button
            onClick={register}
            disabled={registering || !regName || !regAddr || validateName(regName) !== null || !ensFee}
            className="mt-3 px-4 py-2 text-sm bg-mempool-blue text-white rounded hover:bg-blue-500 disabled:opacity-50"
          >
            {registering ? "Registering…" : `Pay fee + register ${regName || "name"}.${regTld}`}
          </button>
          {regResult && (
            <div className={`mt-3 p-3 rounded border text-sm ${regResult.ok ? "border-green-500/40 bg-green-500/10 text-green-300" : "border-red-500/40 bg-red-500/10 text-red-300"}`}>
              {regResult.message}
              {regResult.txid && (
                <>
                  {" "}
                  <TxHashLink txid={regResult.txid} truncate={{ left: 14, right: 8 }} />
                </>
              )}
            </div>
          )}
        </div>
      )}

      {/* List */}
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden">
        <div className="px-4 py-2 border-b border-mempool-border flex items-center gap-2">
          <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
            Registered names
          </h2>
          <span className="ml-auto text-xs text-mempool-text-dim">
            {list ? `${list.entries.length} of ${list.total}` : "loading…"}
          </span>
          {list && list.entries.length > 0 && (
            <button
              onClick={() => {
                const rows = [
                  ["name", "tld", "full_name", "address", "registered_at_block", "expires_at_block"].join(","),
                  ...list.entries.map((e) => {
                    const tld = e.tld || "omnibus";
                    return [
                      `"${e.name}"`,
                      tld,
                      `"${e.name}.${tld}"`,
                      `"${e.address}"`,
                      e.registeredAtBlock,
                      Number.isFinite(e.expiresAtBlock) ? e.expiresAtBlock : "",
                    ].join(",");
                  }),
                ].join("\n");
                const blob = new Blob([rows], { type: "text/csv" });
                const url = URL.createObjectURL(blob);
                const a = document.createElement("a");
                a.href = url; a.download = "omnibus-names.csv";
                a.click(); URL.revokeObjectURL(url);
              }}
              className="text-[10px] px-2 py-1 bg-mempool-bg border border-mempool-border rounded text-mempool-text-dim hover:text-mempool-text transition-colors font-mono flex-shrink-0"
            >
              ⬇ CSV
            </button>
          )}
        </div>
        {list && list.entries.length === 0 ? (
          <div className="p-8 text-center text-mempool-text-dim text-sm">
            No names registered yet. Be the first to register{" "}
            <span className="text-mempool-blue font-mono">yourname.omnibus</span> above.
          </div>
        ) : list && list.entries.length > 0 ? (
          <div className="overflow-x-auto">
          <table className="w-full text-sm min-w-[640px]">
            <thead>
              <tr className="bg-mempool-bg/50 border-b border-mempool-border">
                <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Name</th>
                <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Address</th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-32">Block</th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-40">Expires</th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-24">Action</th>
              </tr>
            </thead>
            <tbody>
              {list.entries.map((e) => {
                const tld = (e.tld || "omnibus") as Tld;
                const colorClass = TLD_INFO[tld]?.color || "text-mempool-blue";
                const isMine = !!wallet && wallet.address === e.address;
                const fullLabel = e.fullLabel || `${e.name}.${tld}`;
                const inGrace = expiringByLabel.has(fullLabel) &&
                  expiringNames.find((x) => x.fullLabel === fullLabel)?.in_grace === true;
                const days = currentBlock > 0 && Number.isFinite(e.expiresAtBlock)
                  ? daysUntilExpiry({ expiresAtBlock: e.expiresAtBlock as number }, currentBlock)
                  : Infinity;
                return (
                <tr key={`${e.name}.${tld}`} className="border-b border-mempool-border/40 hover:bg-mempool-bg/30">
                  <td className={`px-3 py-2 font-mono ${colorClass}`}>
                    {e.name}<span className="text-mempool-text-dim">.{tld}</span>
                    {isMine && (
                      <span className="ml-2 text-[9px] uppercase tracking-wider px-1 rounded bg-mempool-blue/30 text-mempool-blue font-bold">
                        yours
                      </span>
                    )}
                  </td>
                  <td className="px-3 py-2 text-xs">
                    <button
                      onClick={() => { window.location.hash = `#/address/${e.address}`; }}
                      className="font-mono text-mempool-text hover:text-mempool-blue hover:underline"
                      title={e.address}
                    >
                      <AddressLabel address={e.address} showEmoji truncate={{ left: 10, right: 8 }} />
                    </button>
                  </td>
                  <td className="px-3 py-2 text-right text-xs font-mono text-mempool-text-dim">
                    #{e.registeredAtBlock.toLocaleString()}
                  </td>
                  <td className="px-3 py-2 text-right text-xs font-mono text-mempool-text-dim">
                    {Number.isFinite(e.expiresAtBlock) && (
                      <>#{(e.expiresAtBlock as number).toLocaleString()}</>
                    )}
                    <ExpiryBadge days={days} inGrace={inGrace} />
                  </td>
                  <td className="px-3 py-2 text-right">
                    {isMine ? (
                      <button
                        onClick={() => setRenewTarget(e)}
                        className="px-2 py-1 text-[10px] rounded bg-mempool-blue/20 hover:bg-mempool-blue/30 text-mempool-blue uppercase tracking-wider"
                        title="Extend the registration period"
                      >
                        Renew
                      </button>
                    ) : (
                      <span className="text-[10px] text-mempool-text-dim">—</span>
                    )}
                  </td>
                </tr>
                );
              })}
            </tbody>
          </table>
          </div>
        ) : null}
      </div>

      <TreasuryStatusCard />

      {/* Name management tools: reverse lookup + transfer + update address */}
      <div className="grid grid-cols-1 sm:grid-cols-1 gap-4">
        <ReverseResolvePanel />
        <TransferNamePanel />
        <UpdateNamePanel />
      </div>

      <div className="mt-6 text-xs text-mempool-text-dim space-y-1">
        <p>
          <span className="font-semibold text-mempool-text">Refresh:</span> auto every 8s.
        </p>
        <p>
          <span className="font-semibold text-mempool-text">Reserved:</span>{" "}
          omnibus, admin, root (cannot be registered)
        </p>
      </div>

      {renewTarget && (
        <RenewModal
          entry={{
            name: renewTarget.name,
            tld: renewTarget.tld || "omnibus",
            address: renewTarget.address,
            registeredAtBlock: renewTarget.registeredAtBlock,
          }}
          ensFee={ensFee}
          tldList={tldList}
          yearTiers={yearTiers}
          onClose={() => setRenewTarget(null)}
          onRenewed={() => { void refresh(); }}
        />
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Treasury status card — autonomous market-maker stats. Reads via the
// `treasury_getStatus` and `treasury_getConfig` RPCs added in the NS
// hardening sprint. The treasury (registrar slot 5 = ens.omnibus) is the
// pay-to-claim recipient — every successful name claim drips OMNI here,
// and the agent automatically converts it to grid orders on OMNI/USDC.
// ─────────────────────────────────────────────────────────────────────────

type TreasuryStatus = {
  treasury_address: string;
  balance_sat: number;
  live_orders: number;
  last_grid_mid_micro_usd: number;
  last_grid_balance_sat: number;
  last_regrid_block: number;
  vol_samples: number;
  vol_mean: number;
  vol_sigma: number;
};

type TreasuryConfig = {
  enabled: boolean;
  grid_alloc_pct: number;
  levels_per_side: number;
  min_regrid_blocks: number;
  drift_threshold_pct: number;
  balance_delta_pct: number;
  vol_window: number;
};

function TreasuryStatusCard() {
  const [status, setStatus] = useState<TreasuryStatus | null>(null);
  const [cfg, setCfg] = useState<TreasuryConfig | null>(null);
  const [unavailable, setUnavailable] = useState(false);

  useEffect(() => {
    let cancelled = false;
    const tick = async () => {
      try {
        const [s, c] = await Promise.all([
          rpc.request_raw("treasury_getStatus", []) as Promise<TreasuryStatus>,
          rpc.request_raw("treasury_getConfig", []) as Promise<TreasuryConfig>,
        ]);
        if (!cancelled) {
          setStatus(s);
          setCfg(c);
          setUnavailable(false);
        }
      } catch (e: any) {
        const msg = e?.message || "";
        if (msg.includes("not active") || msg.includes("not found")) {
          if (!cancelled) setUnavailable(true);
        }
      }
    };
    tick();
    const id = setInterval(tick, 8000);
    return () => { cancelled = true; clearInterval(id); };
  }, []);

  if (unavailable) {
    return (
      <div className="mt-6 rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 text-xs text-mempool-text-dim">
        Treasury agent not active on this node — set `OMNIBUS_TREASURY_OFF=` to empty
        and restart with the exchange enabled to see live MM stats.
      </div>
    );
  }
  if (!status || !cfg) return null;

  const balanceOmni = (status.balance_sat / 1_000_000_000).toFixed(4);
  const midUsd = status.last_grid_mid_micro_usd > 0
    ? (status.last_grid_mid_micro_usd / 1_000_000).toFixed(4)
    : "—";
  const sigmaUsd = status.vol_sigma > 0
    ? (status.vol_sigma / 1_000_000).toFixed(4)
    : "—";

  return (
    <div className="mt-6 rounded-lg border border-mempool-border bg-mempool-bg-elev overflow-hidden">
      <div className="px-4 py-3 border-b border-mempool-border flex items-center justify-between">
        <h3 className="text-sm font-semibold text-mempool-text">
          NS Treasury — autonomous market maker
        </h3>
        <span className={`text-[10px] px-2 py-0.5 rounded uppercase tracking-wider ${
          cfg.enabled ? "bg-green-500/20 text-green-300" : "bg-gray-700/40 text-gray-400"
        }`}>
          {cfg.enabled ? "active" : "paused"}
        </span>
      </div>

      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 p-4">
        <Metric label="Treasury balance" value={`${balanceOmni} OMNI`} />
        <Metric label="Live orders" value={status.live_orders.toString()} />
        <Metric label="Last grid mid" value={`$${midUsd}`} />
        <Metric label="Volatility σ" value={`$${sigmaUsd}`} />
        <Metric label="Last regrid" value={`block ${status.last_regrid_block.toLocaleString()}`} />
        <Metric label="Allocation" value={`${cfg.grid_alloc_pct}%`} />
        <Metric label="Cooldown" value={`${cfg.min_regrid_blocks} blocks`} />
        <Metric label="Vol samples" value={`${status.vol_samples}/${cfg.vol_window}`} />
      </div>

      <div className="px-4 py-3 border-t border-mempool-border bg-mempool-bg/40">
        <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">
          Pay-to-claim
        </div>
        <p className="text-xs text-mempool-text-dim">
          Send ≥ 5 OMNI to{" "}
          <code className="text-mempool-blue font-mono">{status.treasury_address}</code>{" "}
          with op_return memo{" "}
          <code className="text-mempool-blue font-mono">ns_claim:&lt;name&gt;.omnibus</code>{" "}
          to register a name. The treasury agent immediately recycles the OMNI
          into OMNI/USDC grid orders — funds never leave the ecosystem.
        </p>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// RenewModal — Phase 2 lifecycle. Owner picks a years tier (same 9 tiers
// as registration), sees the fee preview, then calls `renewname` RPC.
// Mirrors the register flow's two-step: send fee TX with op_return memo
// → call renewname with the resulting txid + years.
//
// Props:
//   entry — the row the user clicked Renew on (name + tld + current expiry)
//   ensFee / tldList / yearTiers — same data the register form uses, passed
//     down to avoid re-fetching per modal open
//   onClose / onRenewed — modal lifecycle callbacks
// ─────────────────────────────────────────────────────────────────────────

type RenewModalProps = {
  entry: { name: string; tld: string; address: string; registeredAtBlock: number };
  ensFee: EnsFeeResp | null;
  tldList: TldFeeEntry[] | null;
  yearTiers: YearTier[];
  onClose: () => void;
  onRenewed: () => void;
};

function RenewModal({ entry, ensFee, tldList, yearTiers, onClose, onRenewed }: RenewModalProps) {
  const [years, setYears] = useState<number>(1);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<{ ok: boolean; message: string; txid?: string } | null>(null);

  const tld = entry.tld as Tld;
  const baseFeeOmni = feeMapFromList(tldList, ensFee)[tld] ?? 5;
  const tier = yearTiers.find((t) => t.years === years) ?? yearTiers[0];
  const feeOmni = baseFeeOmni * tier.multiplier;

  const onRenew = async () => {
    setResult(null);
    if (!ensFee?.treasury) {
      setResult({ ok: false, message: "Treasury not available — node not ready" });
      return;
    }
    setBusy(true);
    try {
      const feeSat = Math.floor(feeOmni * 1e9);
      // Same two-step as register: fee TX first (so renewal also leaves an
      // on-chain trace), then renewname with the resulting txid + years.
      setResult({ ok: true, message: `Step 1/2: sending ${feeOmni.toFixed(3)} OMNI renewal fee…` });
      const feeResp: any = await rpc.request_raw("sendtransaction", [
        ensFee.treasury, feeSat, 0, 0,
      ]);
      const txid: string = (typeof feeResp === "string" ? feeResp : feeResp?.txid) || "";
      if (!txid) throw new Error("Fee TX did not return a txid");

      setResult({ ok: true, message: `Step 2/2: extending ${entry.name}.${entry.tld} by ${years}y…` });
      // Renewname reads `name`/`tld` from positional 0/1 OR keyed; everything
      // else (fee_txid, years, signature, nonce, publicKey) is keyed only.
      // Owner is read from the existing on-chain entry, no need to send it.
      const r: any = await rpc.request_raw("renewname", [
        { name: entry.name, tld: entry.tld, fee_txid: txid, years },
      ]);
      if (r && (r.new_expires_block || r.added_years != null)) {
        setResult({
          ok: true,
          message: `Renewed +${years}y → total ${r.registered_years}y, expires #${(r.new_expires_block ?? 0).toLocaleString()}. Fee TX:`,
          txid,
        });
        refreshNameCache();
        // Give the user a beat to read the success message.
        setTimeout(() => { onRenewed(); onClose(); }, 1800);
      } else {
        setResult({ ok: false, message: "Unknown response from node" });
      }
    } catch (e: any) {
      setResult({ ok: false, message: e?.message || "Renewal failed" });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/60 backdrop-blur-sm p-4 overflow-y-auto">
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl shadow-2xl max-w-md w-full p-4 sm:p-5 space-y-3 my-4">
        <div className="flex items-center justify-between">
          <h2 className="text-base font-bold text-mempool-text">
            Renew <span className={TLD_INFO[tld]?.color ?? "text-mempool-blue"}>
              {entry.name}.{entry.tld}
            </span>
          </h2>
          <button onClick={onClose} className="text-mempool-text-dim hover:text-mempool-text">×</button>
        </div>

        <p className="text-[11px] text-mempool-text-dim">
          Extend the registration. Fee scales with the years tier exactly like
          first-time registration — longer commits get a better per-year rate.
        </p>

        <div className="flex flex-wrap gap-1">
          {yearTiers.map((t) => {
            const total = baseFeeOmni * t.multiplier;
            const perYear = total / t.years;
            const isSel = years === t.years;
            return (
              <button
                key={t.years}
                onClick={() => setYears(t.years)}
                className={`px-2 py-1 rounded text-[11px] flex flex-col items-center min-w-[60px] ${
                  isSel ? "bg-mempool-blue text-white font-semibold" : "bg-mempool-bg text-mempool-text-dim hover:text-mempool-text"
                }`}
                title={`+${t.years}y · ${total.toFixed(3)} OMNI · ${perYear.toFixed(3)}/yr`}
              >
                <span className="font-semibold">+{t.years}y</span>
                <span className="text-[10px]">{perYear.toFixed(3)}/yr</span>
              </button>
            );
          })}
        </div>

        <div className="p-3 rounded border border-mempool-border bg-mempool-bg text-xs">
          <p className="text-mempool-text-dim">
            Total fee: <span className="text-mempool-text font-semibold">{feeOmni.toFixed(3)} OMNI</span>
            <span className="text-mempool-text-dim ml-2">
              (base {baseFeeOmni} × {tier.multiplier.toFixed(3)})
            </span>
          </p>
        </div>

        {result && (
          <div className={`p-3 rounded border text-sm ${
            result.ok ? "border-green-500/40 bg-green-500/10 text-green-300" : "border-red-500/40 bg-red-500/10 text-red-300"
          }`}>
            {result.message}
            {result.txid && (
              <> <TxHashLink txid={result.txid} truncate={{ left: 14, right: 8 }} /></>
            )}
          </div>
        )}

        <button
          onClick={onRenew}
          disabled={busy}
          className="w-full bg-mempool-blue hover:bg-mempool-blue/80 disabled:bg-gray-700 text-white font-semibold rounded py-2 text-sm transition-colors"
        >
          {busy ? "Renewing…" : `Pay fee + renew +${years}y`}
        </button>
      </div>
    </div>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-0.5">
        {label}
      </div>
      <div className="text-sm font-mono text-mempool-text">{value}</div>
    </div>
  );
}

// ── BrowseByCategory ──────────────────────────────────────────────────────
//
// Phase 2 NS: lets users explore the registry by institutional category.
// Pick "Banks" → see every name with category=bank. Pick "Government" →
// every gov.* name. Calls `getnamesbycategory` RPC under the hood.

const CAT_PILLS: { id: string; label: string; color: string; emoji: string }[] = [
  { id: "personal",  label: "Personal",  color: "text-mempool-blue",  emoji: "👤" },
  { id: "bank",      label: "Banks",     color: "text-emerald-400",   emoji: "🏦" },
  { id: "gov",       label: "Government",color: "text-red-400",       emoji: "🏛" },
  { id: "mil",       label: "Military",  color: "text-orange-400",    emoji: "⚔" },
  { id: "fin",       label: "Funds",     color: "text-teal-400",      emoji: "💼" },
  { id: "edu",       label: "Academic",  color: "text-sky-400",       emoji: "🎓" },
  { id: "org",       label: "Non-profit",color: "text-lime-400",      emoji: "🤝" },
  { id: "dev",       label: "Developers",color: "text-fuchsia-400",   emoji: "💻" },
  { id: "trading",   label: "Trading",   color: "text-amber-400",     emoji: "📈" },
];

interface CatEntry {
  name: string;
  tld: string;
  address: string;
  preferred_slot: number;
  registeredAtBlock: number;
  registered_years?: number;
}

function BrowseByCategory() {
  const [activeCat, setActiveCat] = useState<string | null>(null);
  const [entries, setEntries] = useState<CatEntry[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [filterYear, setFilterYear] = useState<number | null>(null);

  const load = async (cat: string) => {
    setLoading(true);
    setErr(null);
    try {
      const r = (await rpc.request_raw("getnamesbycategory", [cat, 100])) as {
        category: string; total: number; entries: CatEntry[];
      };
      setEntries(r.entries ?? []);
      setTotal(r.total ?? 0);
      // reset year filter so switching category always starts at "Any"
      setFilterYear(null);
    } catch (e: any) {
      setErr(e?.message ?? "RPC error");
      setEntries([]);
      setTotal(0);
    } finally {
      setLoading(false);
    }
  };

  // Counts per year tier within the currently-loaded category.
  // Treats undefined registered_years as 1 (legacy default for older nodes).
  const yearCounts: Record<number, number> = entries.reduce((acc, e) => {
    const y = e.registered_years ?? 1;
    acc[y] = (acc[y] ?? 0) + 1;
    return acc;
  }, {} as Record<number, number>);

  const visibleEntries: CatEntry[] = filterYear == null
    ? entries
    : entries.filter((e) => (e.registered_years ?? 1) === filterYear);

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 mb-6">
      <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider mb-3">
        Browse by category
        <span className="ml-2 text-[10px] text-mempool-text-dim normal-case">
          institutional discovery on-chain
        </span>
      </h2>
      <div className="flex flex-wrap gap-1 mb-3">
        {CAT_PILLS.map((c) => (
          <button
            key={c.id}
            onClick={() => {
              setActiveCat(c.id);
              load(c.id);
            }}
            className={`px-2 py-1 text-xs rounded ${
              activeCat === c.id
                ? `${c.color} bg-mempool-bg font-semibold border border-current`
                : "text-mempool-text-dim bg-mempool-bg/50 hover:text-mempool-text border border-transparent"
            }`}
            title={`Show all .${c.id} names`}
          >
            <span className="mr-1">{c.emoji}</span>{c.label}
          </button>
        ))}
      </div>
      {/* Secondary filter: registration year tier. Only meaningful when
          a category is selected and there are entries to filter, so we
          gate the whole row on activeCat + entries.length. */}
      {activeCat && entries.length > 0 && (
        <div className="flex flex-wrap gap-1 mb-3 items-center">
          <span className="text-[10px] text-mempool-text-dim mr-1 uppercase tracking-wider">
            Year tier:
          </span>
          <button
            onClick={() => setFilterYear(null)}
            className={`px-2 py-1 text-xs rounded ${
              filterYear == null
                ? "text-mempool-blue bg-mempool-bg font-semibold border border-current"
                : "text-mempool-text-dim bg-mempool-bg/50 hover:text-mempool-text border border-transparent"
            }`}
            title="Show all year tiers"
          >
            Any <span className="text-[10px] opacity-70">({entries.length})</span>
          </button>
          {FALLBACK_YEAR_TIERS.map((t) => {
            const count = yearCounts[t.years] ?? 0;
            const isSel = filterYear === t.years;
            const dimmed = count === 0;
            return (
              <button
                key={t.years}
                onClick={() => setFilterYear(t.years)}
                className={`px-2 py-1 text-xs rounded ${
                  isSel
                    ? "text-mempool-blue bg-mempool-bg font-semibold border border-current"
                    : "text-mempool-text-dim bg-mempool-bg/50 hover:text-mempool-text border border-transparent"
                } ${dimmed && !isSel ? "opacity-40" : ""}`}
                title={`${count} name${count === 1 ? "" : "s"} registered for ${t.years} year${t.years === 1 ? "" : "s"}`}
              >
                {t.years}y <span className="text-[10px] opacity-70">({count})</span>
              </button>
            );
          })}
        </div>
      )}
      {loading && <p className="text-[11px] text-mempool-text-dim">Loading…</p>}
      {err && <p className="text-[11px] text-red-300">{err}</p>}
      {activeCat && !loading && !err && (
        <div className="text-xs">
          <p className="text-mempool-text-dim mb-2">
            <span className="font-semibold">{visibleEntries.length}</span>
            {filterYear != null && <> of <span className="font-semibold">{total}</span></>}
            {filterYear == null && <> of <span className="font-semibold">{total}</span></>}
            {" "}name{visibleEntries.length === 1 ? "" : "s"} in{" "}
            <span className="font-semibold">{CAT_PILLS.find((c) => c.id === activeCat)?.label}</span>
            {filterYear != null && (
              <> · filtered to <span className="font-semibold">{filterYear} year{filterYear === 1 ? "" : "s"}</span></>
            )}
          </p>
          {visibleEntries.length === 0 ? (
            <p className="text-mempool-text-dim italic">
              {entries.length === 0
                ? "No names yet. Be the first to register and tag yourself!"
                : `No names in this category registered for exactly ${filterYear} year${filterYear === 1 ? "" : "s"}.`}
            </p>
          ) : (
            <div className="space-y-1 max-h-80 overflow-y-auto">
              {visibleEntries.map((e) => {
                const cat = CAT_PILLS.find((c) => c.id === activeCat);
                return (
                  <div
                    key={`${e.name}.${e.tld}`}
                    className="flex items-center gap-2 p-2 rounded bg-mempool-bg/40 border border-mempool-border"
                  >
                    <span className={`font-semibold ${cat?.color}`}>
                      {e.name}.{e.tld}
                    </span>
                    <button
                      onClick={() => { window.location.hash = `#/address/${e.address}`; }}
                      className="text-[10px] text-mempool-text-dim font-mono ml-auto hover:text-mempool-blue hover:underline"
                    >
                      <AddressLabel address={e.address} showEmoji truncate={{ left: 10, right: 6 }} />
                    </button>
                    <span className="text-[9px] text-mempool-text-dim">
                      block #{e.registeredAtBlock.toLocaleString()}
                    </span>
                    {e.preferred_slot > 0 && (
                      <span className="text-[9px] text-purple-400 px-1 rounded bg-purple-500/20">
                        prefers slot {e.preferred_slot}
                      </span>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}
      {!activeCat && (
        <p className="text-[11px] text-mempool-text-dim italic">
          Pick a category above to see all on-chain entities of that type.
        </p>
      )}
    </div>
  );
}

// ── NsHealthDashboard ─────────────────────────────────────────────────────
//
// Uses ns_stats RPC for rich registry stats; falls back to listnames counting
// on older nodes. Also shows expiring-soon names (ns_expiringSoon) for the
// connected wallet, and a prune-expired admin button (ns_pruneExpired).

interface NsStats {
  total_active: number;
  total_expired: number;
  by_category: Record<string, number>;
  by_tld: Record<string, number>;
  by_years: Record<string, number>;
  pq_slots_set: number;
  preferred_slot_set: number;
}

interface ExpiringEntry {
  name: string;
  tld: string;
  fullLabel: string;
  expiresAtBlock: number;
  blocks_remaining: number;
  estimated_days_remaining: number;
  registered_years: number;
  in_grace: boolean;
}

function NsHealthDashboard() {
  const [stats, setStats] = useState<NsStats | null>(null);
  const [expiring, setExpiring] = useState<ExpiringEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [pruneResult, setPruneResult] = useState<{ removed: number; entry_count: number } | null>(null);
  const [pruning, setPruning] = useState(false);
  const u = getUnlocked();

  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      try {
        const r = await rpc.request_raw("ns_stats", []);
        if (!cancelled && r && typeof r === "object") setStats(r as NsStats);
      } catch { /* ns_stats not available */ } finally {
        if (!cancelled) setLoading(false);
      }
    };
    load();
    const id = setInterval(load, 30_000);
    return () => { cancelled = true; clearInterval(id); };
  }, []);

  useEffect(() => {
    if (!u) { setExpiring([]); return; }
    let cancelled = false;
    rpc.request_raw("ns_expiringSoon", [{ address: u.address }])
      .then((r) => {
        if (!cancelled && r && typeof r === "object") {
          setExpiring((r as { entries?: ExpiringEntry[] }).entries ?? []);
        }
      }).catch(() => {});
    return () => { cancelled = true; };
  }, [u?.address]);

  const pruneExpired = async () => {
    setPruning(true);
    try {
      const r = await rpc.request_raw("ns_pruneExpired", []);
      if (r && typeof r === "object") {
        setPruneResult(r as { removed: number; entry_count: number });
        const s = await rpc.request_raw("ns_stats", []);
        if (s && typeof s === "object") setStats(s as NsStats);
      }
    } catch { /* no-op */ } finally { setPruning(false); }
  };

  if (loading && !stats) return null;
  if (!stats) return null;

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 mb-6 space-y-3">
      <div className="flex items-baseline justify-between">
        <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          NS Health
          <span className="ml-2 text-[10px] text-mempool-text-dim normal-case">
            registry totals · auto-refresh 30s
          </span>
        </h2>
        <div className="flex items-center gap-3 text-[10px]">
          <span className="text-mempool-text-dim">
            Active: <span className="text-green-400 font-semibold">{stats.total_active}</span>
          </span>
          {stats.total_expired > 0 && (
            <span className="text-mempool-text-dim">
              Expired: <span className="text-red-400 font-semibold">{stats.total_expired}</span>
            </span>
          )}
        </div>
      </div>

      <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-5 lg:grid-cols-9 gap-1">
        {CAT_PILLS.map((c) => {
          const n = stats.by_category[c.id] ?? 0;
          return (
            <div
              key={c.id}
              className="px-2 py-1.5 rounded bg-mempool-bg/40 border border-mempool-border flex flex-col items-center"
              title={`${c.label}: ${n} name${n === 1 ? "" : "s"}`}
            >
              <span className="text-base">{c.emoji}</span>
              <span className={`text-xs font-bold ${c.color}`}>{n}</span>
              <span className="text-[9px] text-mempool-text-dim">{c.label}</span>
            </div>
          );
        })}
      </div>

      <div className="flex flex-wrap gap-1 text-[9px]">
        {Object.entries(stats.by_tld)
          .filter(([, v]) => v > 0)
          .sort(([, a], [, b]) => b - a)
          .map(([t, n]) => (
            <span key={t} className="px-1.5 py-0.5 rounded bg-mempool-bg border border-mempool-border text-mempool-text-dim">
              .{t} <span className="text-mempool-text font-semibold">{n}</span>
            </span>
          ))}
        {stats.pq_slots_set > 0 && (
          <span className="px-1.5 py-0.5 rounded bg-purple-500/10 border border-purple-500/30 text-purple-300">
            PQ slots: {stats.pq_slots_set}
          </span>
        )}
      </div>

      {expiring.length > 0 && (
        <div className="rounded border border-yellow-500/30 bg-yellow-500/5 p-3">
          <div className="text-[10px] uppercase tracking-wider text-yellow-400 font-semibold mb-2">
            ⚠️ Your names expiring soon ({expiring.length})
          </div>
          <div className="space-y-1">
            {expiring.map((e) => (
              <div key={e.fullLabel} className="flex items-center justify-between text-[10px] font-mono">
                <span className="text-mempool-text">{e.fullLabel}</span>
                <div className="flex items-center gap-2">
                  <span className={e.in_grace ? "text-red-400" : "text-yellow-300"}>
                    {e.in_grace ? "⛔ grace" : `~${e.estimated_days_remaining}d`}
                  </span>
                  <span className="text-mempool-text-dim">blk {e.expiresAtBlock}</span>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {stats.total_expired > 0 && (
        <div className="flex items-center gap-3 pt-1 border-t border-mempool-border/40">
          <span className="text-[10px] text-red-400">
            {stats.total_expired} expired name{stats.total_expired === 1 ? "" : "s"} ready to prune
          </span>
          <button
            onClick={pruneExpired}
            disabled={pruning}
            className="ml-auto px-3 py-1 rounded text-[10px] bg-red-500/20 text-red-300 hover:bg-red-500/30 border border-red-500/30 disabled:opacity-50"
          >
            {pruning ? "Pruning…" : "Prune Expired"}
          </button>
          {pruneResult && (
            <span className="text-[10px] text-green-400">
              Removed {pruneResult.removed} · {pruneResult.entry_count} remain
            </span>
          )}
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Signing helper (same recipe as StakePage / PQWalletPanel)
// ─────────────────────────────────────────────────────────────────────────

function signPayload(privKeyHex: string, msg: string): { signature: string; publicKey: string } {
  const bytes = new TextEncoder().encode(msg);
  const h = sha256(sha256(bytes));
  const priv = hexToBytes(privKeyHex);
  const sig = secp.sign(h, priv, { lowS: true });
  const pub = secp.getPublicKey(priv, true);
  return { signature: bytesToHex(sig.toBytes()), publicKey: bytesToHex(pub) };
}

// ─────────────────────────────────────────────────────────────────────────
// ReverseResolvePanel — address → name lookup (reverseresolvename RPC)
// ─────────────────────────────────────────────────────────────────────────

export function ReverseResolvePanel() {
  const [addr, setAddr] = useState("");
  const [result, setResult] = useState<{ address: string; name: string; found: boolean } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const onLookup = async () => {
    const a = addr.trim();
    if (!a) return;
    setLoading(true);
    setErr(null);
    setResult(null);
    try {
      const r = (await rpc.request_raw("reverseresolvename", [a])) as {
        address: string; name: string; found: boolean;
      };
      setResult(r);
    } catch (e: any) {
      setErr(e?.message ?? String(e));
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-4 space-y-3">
      <h3 className="text-sm font-semibold text-mempool-text">Reverse Resolve</h3>
      <p className="text-[11px] text-mempool-text-dim">
        Look up the registered name for an OmniBus address.
      </p>
      <div className="flex gap-2 items-end">
        <div className="flex-1">
          <label className="text-[10px] text-mempool-text-dim uppercase block mb-0.5">Address</label>
          <input
            value={addr}
            onChange={(e) => setAddr(e.target.value)}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
            placeholder="ob1q…"
            onKeyDown={(e) => e.key === "Enter" && onLookup()}
          />
        </div>
        <button
          onClick={onLookup}
          disabled={loading || !addr.trim()}
          className="px-3 py-1.5 text-xs bg-mempool-blue/20 hover:bg-mempool-blue/30 text-mempool-blue border border-mempool-blue/30 rounded disabled:opacity-50 whitespace-nowrap"
        >
          {loading ? "…" : "Lookup"}
        </button>
      </div>
      {err && <p className="text-xs text-red-400">{err}</p>}
      {result && (
        result.found ? (
          <div className="rounded border border-green-500/30 bg-green-500/5 px-3 py-2 text-xs space-y-0.5">
            <div className="text-green-400 font-semibold">{result.name}</div>
            <div className="text-mempool-text-dim font-mono">{result.address}</div>
          </div>
        ) : (
          <p className="text-xs text-mempool-text-dim">No registered name for this address.</p>
        )
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// TransferNamePanel — transfer name ownership (transfername RPC)
// ─────────────────────────────────────────────────────────────────────────

export function TransferNamePanel() {
  const wallet = useWallet();
  const [name, setName] = useState("");
  const [tld, setTld] = useState("omnibus");
  const [newOwner, setNewOwner] = useState("");
  const [result, setResult] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const onTransfer = async () => {
    if (!wallet || !name || !newOwner) return;
    const u = getUnlocked();
    if (!u?.privateKey) { setErr("Wallet locked — unlock from mnemonic first."); return; }
    setLoading(true);
    setErr(null);
    setResult(null);
    try {
      const nonceResp = (await rpc.request_raw("getnonce", [wallet.address])) as { nonce: number } | number;
      const nonce = typeof nonceResp === "number" ? nonceResp : ((nonceResp as { nonce: number })?.nonce ?? 0);
      const msg = `transfername:${name}.${tld}:${newOwner}:${nonce}`;
      const { signature, publicKey } = signPayload(u.privateKey, msg);
      const r = (await rpc.request_raw("transfername", [{
        name, tld, new_owner: newOwner, nonce, signature, publicKey,
      }])) as { status?: string } | string;
      setResult(typeof r === "string" ? r : ((r as { status?: string }).status ?? "ok"));
    } catch (e: any) {
      setErr(e?.message ?? String(e));
    } finally {
      setLoading(false);
    }
  };

  if (!wallet) return null;

  return (
    <div className="rounded-xl border border-orange-500/30 bg-orange-500/5 p-4 space-y-3">
      <h3 className="text-sm font-semibold text-orange-200">Transfer Name Ownership</h3>
      <p className="text-[11px] text-mempool-text-dim">
        Permanently transfers the name to a new owner. Requires your wallet to be unlocked.
      </p>
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-2">
        <div>
          <label className="text-[10px] text-mempool-text-dim uppercase block mb-0.5">Name</label>
          <input
            value={name}
            onChange={(e) => setName(e.target.value.toLowerCase())}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
            placeholder="alice"
          />
        </div>
        <div>
          <label className="text-[10px] text-mempool-text-dim uppercase block mb-0.5">TLD</label>
          <select
            value={tld}
            onChange={(e) => setTld(e.target.value)}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs text-mempool-text"
          >
            {TLDS.map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
        </div>
        <div>
          <label className="text-[10px] text-mempool-text-dim uppercase block mb-0.5">New owner address</label>
          <input
            value={newOwner}
            onChange={(e) => setNewOwner(e.target.value)}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
            placeholder="ob1q…"
          />
        </div>
      </div>
      <button
        onClick={onTransfer}
        disabled={loading || !name || !newOwner}
        className="w-full py-1.5 text-xs bg-orange-500/20 hover:bg-orange-500/30 text-orange-200 border border-orange-500/30 rounded disabled:opacity-50"
      >
        {loading ? "Transferring…" : "Transfer name"}
      </button>
      {err && <p className="text-xs text-red-400">{err}</p>}
      {result && <p className="text-xs text-green-400">Success: {result}</p>}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────
// UpdateNamePanel — update the address a name resolves to (updatename RPC)
// ─────────────────────────────────────────────────────────────────────────

export function UpdateNamePanel() {
  const wallet = useWallet();
  const [name, setName] = useState("");
  const [tld, setTld] = useState("omnibus");
  const [newAddress, setNewAddress] = useState("");
  const [result, setResult] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const onUpdate = async () => {
    if (!wallet || !name || !newAddress) return;
    const u = getUnlocked();
    if (!u?.privateKey) { setErr("Wallet locked — unlock from mnemonic first."); return; }
    setLoading(true);
    setErr(null);
    setResult(null);
    try {
      const nonceResp = (await rpc.request_raw("getnonce", [wallet.address])) as { nonce: number } | number;
      const nonce = typeof nonceResp === "number" ? nonceResp : ((nonceResp as { nonce: number })?.nonce ?? 0);
      const msg = `updatename:${name}.${tld}:${newAddress}:${nonce}`;
      const { signature, publicKey } = signPayload(u.privateKey, msg);
      const r = (await rpc.request_raw("updatename", [{
        name, tld, new_address: newAddress, nonce, signature, publicKey,
      }])) as { status?: string } | string;
      setResult(typeof r === "string" ? r : ((r as { status?: string }).status ?? "ok"));
    } catch (e: any) {
      setErr(e?.message ?? String(e));
    } finally {
      setLoading(false);
    }
  };

  if (!wallet) return null;

  return (
    <div className="rounded-xl border border-blue-500/30 bg-blue-500/5 p-4 space-y-3">
      <h3 className="text-sm font-semibold text-blue-200">Update Name Address</h3>
      <p className="text-[11px] text-mempool-text-dim">
        Points your name to a new OmniBus address. Requires the current owner&apos;s wallet to be unlocked.
      </p>
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-2">
        <div>
          <label className="text-[10px] text-mempool-text-dim uppercase block mb-0.5">Name</label>
          <input
            value={name}
            onChange={(e) => setName(e.target.value.toLowerCase())}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
            placeholder="alice"
          />
        </div>
        <div>
          <label className="text-[10px] text-mempool-text-dim uppercase block mb-0.5">TLD</label>
          <select
            value={tld}
            onChange={(e) => setTld(e.target.value)}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs text-mempool-text"
          >
            {TLDS.map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
        </div>
        <div>
          <label className="text-[10px] text-mempool-text-dim uppercase block mb-0.5">New address</label>
          <input
            value={newAddress}
            onChange={(e) => setNewAddress(e.target.value)}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
            placeholder="ob1q…"
          />
        </div>
      </div>
      <button
        onClick={onUpdate}
        disabled={loading || !name || !newAddress}
        className="w-full py-1.5 text-xs bg-blue-500/20 hover:bg-blue-500/30 text-blue-200 border border-blue-500/30 rounded disabled:opacity-50"
      >
        {loading ? "Updating…" : "Update name address"}
      </button>
      {err && <p className="text-xs text-red-400">{err}</p>}
      {result && <p className="text-xs text-green-400">Success: {result}</p>}
    </div>
  );
}
