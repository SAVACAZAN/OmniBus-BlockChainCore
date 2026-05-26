// NameManagePanel.tsx — Phase 2 NS owner-side controls.
//
// Drops into the Wallet page, just below the existing MyNamesPanel. Lets
// the wallet owner attach PQ scheme addresses to a name they hold, set
// the category badge, and pick which scheme they want incoming funds
// routed to by default. All state lives on-chain (RPC: setpqaddress /
// setcategory / setpreferredslot).
//
// Render: pick a name from a dropdown → 4 inputs for the obk1_/obf5_/
// obs3_/obd5_ addresses + category select + preferred-slot radios. Each
// row has its own "Save" button; nothing batched, so a partial failure
// only stops one slot at a time.

import { useEffect, useMemo, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";

const rpc = new OmniBusRpcClient();

// Same canon as core/dns_registry.zig:Category.
const CATEGORIES = ["personal", "bank", "gov", "mil", "fin", "edu", "org", "dev", "trading", "none"] as const;
type Category = typeof CATEGORIES[number];

const CATEGORY_LABEL: Record<Category, string> = {
  personal: "Personal",
  bank:     "Bank / financial institution",
  gov:      "Government / state agency",
  mil:      "Military / defense",
  fin:      "Financial trustee / fund",
  edu:      "Academic",
  org:      "Non-profit / NGO",
  dev:      "Developer / open-source",
  trading:  "Trading / market-maker",
  none:     "(unset)",
};

// Slot letters → chain enum names (must match handleSetPqAddress mapping).
const SLOT_INFO: { slot: string; label: string; algoLabel: string; prefix: string }[] = [
  { slot: "ml_dsa",    label: "ML-DSA-87",    algoLabel: "FIPS 204",         prefix: "obk1_" },
  { slot: "falcon",    label: "Falcon-512",   algoLabel: "FIPS 206",         prefix: "obf5_" },
  { slot: "dilithium", label: "Dilithium-5",  algoLabel: "FIPS 204 alias",   prefix: "obs3_" },
  { slot: "slh_dsa",   label: "SLH-DSA-256s", algoLabel: "FIPS 205",         prefix: "obd5_" },
];

interface OwnedName {
  fullLabel: string;
  name: string;
  tld: string;
  registeredAtBlock: number;
}

interface ResolveResp {
  found: boolean;
  name: string;
  tld: string;
  address: string;
  addresses?: {
    primary: string;
    k: string; k_set: boolean;
    f: string; f_set: boolean;
    s: string; s_set: boolean;
    d: string; d_set: boolean;
  };
  category?: string;
  preferred_slot?: number;
  registered_years?: number;
  registered_block?: number;
  expires_block?: number;
}

interface NameManagePanelProps {
  ownerAddress: string;
  ownedNames: OwnedName[];
}

export function NameManagePanel({ ownerAddress, ownedNames }: NameManagePanelProps) {
  const [selected, setSelected] = useState<string>("");
  const [resolved, setResolved] = useState<ResolveResp | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  // PQ slot inputs — local state, only pushed on Save click.
  const [slotInputs, setSlotInputs] = useState<Record<string, string>>({
    ml_dsa: "", falcon: "", dilithium: "", slh_dsa: "",
  });
  const [catInput, setCatInput] = useState<Category>("none");
  const [preferredInput, setPreferredInput] = useState<number>(0);

  // Auto-pick the first name when ownedNames first arrives.
  useEffect(() => {
    if (!selected && ownedNames.length > 0) {
      setSelected(ownedNames[0].fullLabel);
    }
  }, [ownedNames, selected]);

  // When the selected name changes, resolve it on chain to populate the form.
  useEffect(() => {
    if (!selected) {
      setResolved(null);
      return;
    }
    let cancelled = false;
    const run = async () => {
      setLoading(true);
      setMsg(null);
      try {
        const [name, tld] = selected.split(".");
        const r = (await rpc.request_raw("resolvename", [name, tld])) as ResolveResp;
        if (cancelled) return;
        setResolved(r);
        if (r.addresses) {
          setSlotInputs({
            ml_dsa:    r.addresses.k_set ? r.addresses.k : "",
            falcon:    r.addresses.f_set ? r.addresses.f : "",
            dilithium: r.addresses.s_set ? r.addresses.s : "",
            slh_dsa:   r.addresses.d_set ? r.addresses.d : "",
          });
        }
        setCatInput((r.category ?? "none") as Category);
        setPreferredInput(r.preferred_slot ?? 0);
      } catch (e: any) {
        if (!cancelled) setMsg({ ok: false, text: e?.message ?? "resolve failed" });
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    void run();
    return () => { cancelled = true; };
  }, [selected]);

  const reload = async () => {
    if (!selected) return;
    const [name, tld] = selected.split(".");
    try {
      const r = (await rpc.request_raw("resolvename", [name, tld])) as ResolveResp;
      setResolved(r);
    } catch { /* keep existing */ }
  };

  const saveSlot = async (slotKey: string) => {
    if (!selected) return;
    const [name, tld] = selected.split(".");
    setBusy(slotKey);
    setMsg(null);
    try {
      const pqAddr = slotInputs[slotKey].trim();
      // Empty pqAddr = clear the slot (chain accepts "").
      await rpc.request_raw("setpqaddress", [name, tld, slotKey, pqAddr, ownerAddress]);
      setMsg({ ok: true, text: `${slotKey} slot ${pqAddr ? "set to " + pqAddr.slice(0, 16) + "…" : "cleared"}` });
      await reload();
    } catch (e: any) {
      setMsg({ ok: false, text: e?.message ?? "setpqaddress failed" });
    } finally {
      setBusy(null);
    }
  };

  const saveCategory = async () => {
    if (!selected) return;
    const [name, tld] = selected.split(".");
    setBusy("category");
    setMsg(null);
    try {
      await rpc.request_raw("setcategory", [name, tld, catInput, ownerAddress]);
      setMsg({ ok: true, text: `Category set to "${catInput}"` });
      await reload();
    } catch (e: any) {
      setMsg({ ok: false, text: e?.message ?? "setcategory failed" });
    } finally {
      setBusy(null);
    }
  };

  const savePreferred = async () => {
    if (!selected) return;
    const [name, tld] = selected.split(".");
    setBusy("preferred");
    setMsg(null);
    try {
      await rpc.request_raw("setpreferredslot", [
        { name, tld, slot: preferredInput, owner: ownerAddress },
      ]);
      setMsg({ ok: true, text: `Preferred slot set to ${preferredInput} (${preferredInput === 0 ? "primary" : SLOT_INFO[preferredInput - 1]?.label})` });
      await reload();
    } catch (e: any) {
      setMsg({ ok: false, text: e?.message ?? "setpreferredslot failed" });
    } finally {
      setBusy(null);
    }
  };

  if (ownedNames.length === 0) {
    return null; // nothing to manage
  }

  return (
    <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-5 space-y-4 mt-4">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          Manage name (PQ slots · category · preferred)
        </h3>
        <span className="text-[10px] text-mempool-text-dim">Phase 2 NS</span>
      </div>

      <p className="text-[11px] text-mempool-text-dim">
        Attach your post-quantum addresses to one of your names so others can
        send to <span className="font-mono text-mempool-blue">alice.bank</span>{" "}
        instead of the long <span className="font-mono">obk1_…</span> hex.
        Set a category badge for institutional discovery, and pick which
        scheme you want funds routed to by default.
      </p>

      {/* Name picker */}
      <div>
        <label className="block text-[11px] text-mempool-text-dim mb-1">Name</label>
        <select
          value={selected}
          onChange={(e) => setSelected(e.target.value)}
          className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-sm font-mono text-mempool-text"
        >
          {ownedNames.map((n) => (
            <option key={n.fullLabel} value={n.fullLabel}>{n.fullLabel}</option>
          ))}
        </select>
      </div>

      {loading && <p className="text-[11px] text-mempool-text-dim">Loading current state…</p>}

      {msg && (
        <p className={`text-[11px] p-2 rounded ${
          msg.ok ? "bg-green-500/10 text-green-300" : "bg-red-500/10 text-red-300"
        }`}>
          {msg.text}
        </p>
      )}

      {resolved?.found && (
        <>
          {/* Category */}
          <div className="border-t border-mempool-border pt-3">
            <p className="text-[11px] text-mempool-text-dim mb-1">Category badge</p>
            <div className="flex gap-2">
              <select
                value={catInput}
                onChange={(e) => setCatInput(e.target.value as Category)}
                className="flex-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-sm text-mempool-text"
              >
                {CATEGORIES.map((c) => (
                  <option key={c} value={c}>{CATEGORY_LABEL[c]}</option>
                ))}
              </select>
              <button
                onClick={saveCategory}
                disabled={busy !== null || catInput === resolved.category}
                className="px-3 py-1.5 text-xs bg-mempool-blue text-white rounded hover:bg-blue-500 disabled:opacity-40"
              >
                {busy === "category" ? "…" : "Save"}
              </button>
            </div>
            <p className="text-[10px] text-mempool-text-dim mt-1">
              On-chain: <span className="font-mono">{resolved.category ?? "none"}</span>
            </p>
          </div>

          {/* PQ slot pinning */}
          <div className="border-t border-mempool-border pt-3 space-y-2">
            <p className="text-[11px] text-mempool-text-dim">
              PQ scheme address slots — paste your own {SLOT_INFO.map((s) => s.prefix).join(" / ")} addresses.
              Empty + Save = clear that slot (resolver falls back to primary).
            </p>
            {SLOT_INFO.map((info) => {
              const cur = slotInputs[info.slot] ?? "";
              const slotKey = (info.slot.charAt(0) === "m" ? "k" : info.slot.charAt(0) === "f" ? "f" : info.slot.charAt(0) === "d" ? "s" : "d") as "k" | "f" | "s" | "d";
              const onChain = resolved.addresses?.[slotKey];
              const setOnChain = resolved.addresses?.[`${slotKey}_set` as "k_set" | "f_set" | "s_set" | "d_set"];
              void onChain;
              void setOnChain;
              return (
                <div key={info.slot} className="flex gap-2 items-center">
                  <div className="w-32 shrink-0">
                    <p className="text-[11px] text-mempool-text font-semibold">{info.label}</p>
                    <p className="text-[9px] text-mempool-text-dim">{info.algoLabel} · {info.prefix}…</p>
                  </div>
                  <input
                    type="text"
                    value={cur}
                    placeholder={`${info.prefix}…`}
                    onChange={(e) => setSlotInputs({ ...slotInputs, [info.slot]: e.target.value })}
                    className="flex-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs font-mono text-mempool-text"
                  />
                  <button
                    onClick={() => saveSlot(info.slot)}
                    disabled={busy !== null}
                    className="px-2 py-1 text-[11px] bg-mempool-blue/80 text-white rounded hover:bg-mempool-blue disabled:opacity-40"
                  >
                    {busy === info.slot ? "…" : "Save"}
                  </button>
                </div>
              );
            })}
          </div>

          {/* Preferred receiving slot */}
          <div className="border-t border-mempool-border pt-3">
            <p className="text-[11px] text-mempool-text-dim mb-1">
              Preferred receiving scheme — wallets that send to your name pick this scheme by default.
            </p>
            <div className="flex flex-wrap gap-1 mb-2">
              {[
                { idx: 0, label: "Primary (ECDSA)" },
                { idx: 1, label: "ML-DSA-87" },
                { idx: 2, label: "Falcon-512" },
                { idx: 3, label: "Dilithium-5" },
                { idx: 4, label: "SLH-DSA-256s" },
              ].map((opt) => (
                <button
                  key={opt.idx}
                  onClick={() => setPreferredInput(opt.idx)}
                  className={`px-2 py-1 text-[11px] rounded ${
                    preferredInput === opt.idx
                      ? "bg-mempool-blue text-white font-semibold"
                      : "bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text"
                  }`}
                >
                  {opt.label}
                </button>
              ))}
            </div>
            <button
              onClick={savePreferred}
              disabled={busy !== null || preferredInput === resolved.preferred_slot}
              className="px-3 py-1.5 text-xs bg-mempool-blue text-white rounded hover:bg-blue-500 disabled:opacity-40"
            >
              {busy === "preferred" ? "…" : "Save preferred"}
            </button>
            <p className="text-[10px] text-mempool-text-dim mt-1">
              On-chain: slot <span className="font-mono">{resolved.preferred_slot ?? 0}</span>
            </p>
          </div>
        </>
      )}
    </div>
  );
}

// Default export to match the WalletPage import style.
export default NameManagePanel;
