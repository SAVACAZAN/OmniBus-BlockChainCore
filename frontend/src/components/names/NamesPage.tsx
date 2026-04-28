import { useEffect, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";

const rpc = new OmniBusRpcClient();

// On-chain DNS / ENS pe blockchain-ul OmniBus (NU Liberty Chain).
// Nume `<label>.omnibus`, label = 3-25 chars [a-z0-9_], must start with letter.
// Vezi rpc_server.zig:handleRegisterName pentru reguli + memory feedback_total_mined_vs_balance.

const VALID_RE = /^[a-z][a-z0-9_]{2,24}$/;

const TLDS = ["omnibus", "arbitraje"] as const;
type Tld = typeof TLDS[number];

const TLD_INFO: Record<Tld, { color: string; desc: string }> = {
  omnibus:   { color: "text-mempool-blue",    desc: "Default OmniBus identity (e.g. alice.omnibus)" },
  arbitraje: { color: "text-amber-400",       desc: "For arbitrage agents / market makers (alice.arbitraje)" },
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

export function NamesPage() {
  const [list, setList] = useState<ListResp | null>(null);
  const [search, setSearch] = useState("");
  const [searchResult, setSearchResult] = useState<ResolveResp | null>(null);
  const [searching, setSearching] = useState(false);

  // Register form
  const [regName, setRegName] = useState("");
  const [regAddr, setRegAddr] = useState("");
  const [regTld, setRegTld] = useState<Tld>("omnibus");
  const [searchTld, setSearchTld] = useState<Tld>("omnibus");
  const [registering, setRegistering] = useState(false);
  const [regResult, setRegResult] = useState<{ ok: boolean; message: string } | null>(null);
  const [feeTxid, setFeeTxid] = useState("");

  const [ensFee, setEnsFee] = useState<EnsFeeResp | null>(null);

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
    loadFee();
    return () => { cancelled = true; };
  }, []);

  const validateName = (n: string): string | null => {
    const clean = n.toLowerCase().replace(".omnibus", "");
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
      // params: [name, address, owner, tld, fee_txid]
      const params: any[] = [clean, regAddr.trim(), regAddr.trim(), regTld];
      if (feeTxid.trim()) {
        params.push(feeTxid.trim());
      }
      const r: any = await rpc.request_raw("registername", params);
      if (r && r.name) {
        const label = r.fullLabel || `${r.name}.${r.tld || regTld}`;
        setRegResult({
          ok: true,
          message: `${label} registered at block ${r.registeredAtBlock} → ${r.address}${r.fee_paid_sat ? ` (fee ${r.fee_paid_sat / 1e9} OMNI)` : ""}`,
        });
        setRegName("");
        setFeeTxid("");
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
      <p className="text-mempool-text-dim text-sm mb-6">
        Native on-chain name registry pe OmniBus. Nume <code>&lt;label&gt;.&lt;tld&gt;</code> mapate la
        adrese bech32. TLD-uri: <span className="text-mempool-blue">.omnibus</span> (default,
        identitate generală) sau <span className="text-amber-400">.arbitraje</span> (agenți de
        arbitraj / market making). Reguli nume: 3–25 chars, lowercase <code>a-z 0-9 _</code>,
        începe cu literă. Persistat pe disc — rămâne după restart.
      </p>

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
              {" — "}
              {searchResult.found ? (
                <span className="text-green-300">TAKEN</span>
              ) : (
                <span className="text-amber-300">AVAILABLE</span>
              )}
            </p>
            {searchResult.found && searchResult.address && (
              <p className="text-xs text-mempool-text-dim mt-1 font-mono break-all">
                → {searchResult.address}
              </p>
            )}
            {searchResult.found && searchResult.registeredAtBlock != null && (
              <p className="text-xs text-mempool-text-dim mt-1">
                registered at block #{searchResult.registeredAtBlock.toLocaleString()}
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

          {/* Fee info */}
          {ensFee && (
            <div className="mb-3 p-3 rounded border border-mempool-border bg-mempool-bg text-xs">
              <p className="text-mempool-text-dim">
                Fee: <span className="text-mempool-text font-semibold">{ensFee.cost_omnibus_omni} OMNI</span> for .omnibus /{" "}
                <span className="text-mempool-text font-semibold">{ensFee.cost_arbitraje_omni} OMNI</span> for .arbitraje
              </p>
              <p className="text-mempool-text-dim mt-1">
                Treasury: <span className="font-mono text-mempool-text">{ensFee.treasury}</span>
              </p>
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
              <label className="block text-xs text-mempool-text-dim mb-1">Resolve to address</label>
              <input
                type="text"
                placeholder="ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"
                value={regAddr}
                onChange={(e) => setRegAddr(e.target.value.trim())}
                className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
              />
            </div>
          </div>

          {/* Fee txid input */}
          <div className="mt-3">
            <label className="block text-xs text-mempool-text-dim mb-1">
              Fee transaction hash (optional on testnet, required on mainnet)
            </label>
            <input
              type="text"
              placeholder="0000000000000000000000000000000000000000000000000000000000000000"
              value={feeTxid}
              onChange={(e) => setFeeTxid(e.target.value.trim())}
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
            />
            <p className="text-[10px] text-mempool-text-dim mt-1">
              Step 1: Send the fee amount to the treasury address above.<br />
              Step 2: Paste the transaction hash here and click Register.
            </p>
          </div>

          <button
            onClick={register}
            disabled={registering || !regName || !regAddr || validateName(regName) !== null}
            className="mt-3 px-4 py-2 text-sm bg-mempool-blue text-white rounded hover:bg-blue-500 disabled:opacity-50"
          >
            {registering ? "Registering…" : "Register on-chain"}
          </button>
          {regResult && (
            <div className={`mt-3 p-3 rounded border text-sm ${regResult.ok ? "border-green-500/40 bg-green-500/10 text-green-300" : "border-red-500/40 bg-red-500/10 text-red-300"}`}>
              {regResult.message}
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
                  <td className="px-3 py-2 font-mono text-xs">
                    <button
                      onClick={() => navigator.clipboard.writeText(e.address)}
                      className="text-mempool-text hover:text-mempool-blue hover:underline"
                      title="Click to copy"
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
