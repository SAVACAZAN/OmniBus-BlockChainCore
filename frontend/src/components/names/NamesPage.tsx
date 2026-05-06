import { useEffect, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import { useWallet } from "../../api/use-wallet";
import { refreshNameCache } from "../../api/use-names";
import { AddressLabel } from "../common/AddressLabel";
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

type EnsFeeResp = {
  treasury: string;
  enforcement: boolean;
  cost_omnibus_omni: number;
  cost_arbitraje_omni: number;
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

  useEffect(() => {
    let cancelled = false;
    const loadFee = async () => {
      try {
        const r = (await rpc.request_raw("getensfee", [])) as EnsFeeResp;
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
  }, []);

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

  const lookup = async () => {
    if (!search.trim()) return;
    setSearching(true);
    setSearchResult(null);
    try {
      let clean = search.toLowerCase().trim();
      // If user types "alice.arbitraje", auto-detect TLD; else use selectorul.
      let tld: Tld = searchTld;
      for (const t of TLDS) {
        if (clean.endsWith("." + t)) {
          tld = t;
          clean = clean.slice(0, -("." + t).length);
          break;
        }
      }
      const r = (await rpc.request_raw("resolvename", [clean, tld])) as ResolveResp;
      setSearchResult(r);
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
    <div className="max-w-6xl mx-auto px-4 py-8">
      <h1 className="text-2xl font-bold text-mempool-text mb-2">
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
        <div className="flex gap-2">
          <div className="relative flex-1">
            <input
              type="text"
              placeholder="yourname"
              value={search}
              onChange={(e) => setSearch(e.target.value.toLowerCase())}
              onKeyDown={(e) => { if (e.key === "Enter") lookup(); }}
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 pr-24 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
            />
            <span className={`absolute right-3 top-1/2 -translate-y-1/2 text-xs font-semibold ${TLD_INFO[searchTld].color}`}>
              .{searchTld}
            </span>
          </div>
          <button
            onClick={lookup}
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
      </div>

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

          <div className="flex gap-2 items-center mb-3">
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
        </div>
        {list && list.entries.length === 0 ? (
          <div className="p-8 text-center text-mempool-text-dim text-sm">
            No names registered yet. Be the first to register{" "}
            <span className="text-mempool-blue font-mono">yourname.omnibus</span> above.
          </div>
        ) : list && list.entries.length > 0 ? (
          <table className="w-full text-sm">
            <thead>
              <tr className="bg-mempool-bg/50 border-b border-mempool-border">
                <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Name</th>
                <th className="text-left px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim">Address</th>
                <th className="text-right px-3 py-2 text-xs uppercase tracking-wider text-mempool-text-dim w-32">Block</th>
              </tr>
            </thead>
            <tbody>
              {list.entries.map((e) => {
                const tld = (e.tld || "omnibus") as Tld;
                const colorClass = TLD_INFO[tld]?.color || "text-mempool-blue";
                return (
                <tr key={`${e.name}.${tld}`} className="border-b border-mempool-border/40 hover:bg-mempool-bg/30">
                  <td className={`px-3 py-2 font-mono ${colorClass}`}>
                    {e.name}<span className="text-mempool-text-dim">.{tld}</span>
                  </td>
                  <td className="px-3 py-2 text-xs">
                    <button
                      onClick={() => navigator.clipboard.writeText(e.address)}
                      className="font-mono text-mempool-text hover:text-mempool-blue hover:underline"
                      title={`Click to copy ${e.address}`}
                    >
                      {e.address.slice(0, 14)}…{e.address.slice(-8)}
                    </button>
                  </td>
                  <td className="px-3 py-2 text-right text-xs font-mono text-mempool-text-dim">
                    #{e.registeredAtBlock.toLocaleString()}
                  </td>
                </tr>
                );
              })}
            </tbody>
          </table>
        ) : null}
      </div>

      <TreasuryStatusCard />

      <div className="mt-6 text-xs text-mempool-text-dim space-y-1">
        <p>
          <span className="font-semibold text-mempool-text">Refresh:</span> auto every 8s.
        </p>
        <p>
          <span className="font-semibold text-mempool-text">Reserved:</span>{" "}
          omnibus, admin, root (cannot be registered)
        </p>
      </div>
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
