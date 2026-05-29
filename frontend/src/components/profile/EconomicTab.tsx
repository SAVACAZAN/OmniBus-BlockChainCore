/**
 * EconomicTab.tsx — Economic facet + MiCA panel.
 * Fields: addresses, donations, volume + per-field visibility.
 */

import { useEffect, useState } from "react";
import type { ProfileFull, ProfileEconomic } from "../../api/clients/rpc-client";
import { PublicToggle, PublicBadge, type FieldVisibility } from "./PublicToggle";
import { MicaPanel } from "./MicaPanel";

const FIELDS = ["addresses", "donations", "total_volume"] as const;
type EcoKey = (typeof FIELDS)[number];

function readMask(profile: ProfileFull): Record<EcoKey, FieldVisibility> {
  const stored = profile.visibility_mask || {};
  const m: Record<string, FieldVisibility> = {};
  for (const k of FIELDS) {
    const v = stored[`economic.${k}`];
    m[k] = v === "private" ? "private" : "public";
  }
  return m as Record<EcoKey, FieldVisibility>;
}

export function EconomicTab({
  profile,
  editable,
  privateKey,
  onSave,
}: {
  profile: ProfileFull;
  editable: boolean;
  privateKey: string | null;
  onSave: (
    fields: ProfileEconomic,
    mask: Record<string, FieldVisibility>,
  ) => Promise<void>;
}) {
  const eco: ProfileEconomic = profile.economic || {};
  const [addresses, setAddresses] = useState(eco.addresses || []);
  const [donations] = useState(eco.donations || []); // read-only — sourced from chain
  const [mask, setMask] = useState(() => readMask(profile));
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    const e = profile.economic || {};
    setAddresses(e.addresses || []);
    setMask(readMask(profile));
  }, [profile]);

  const setMaskFor = (k: EcoKey, v: FieldVisibility) =>
    setMask((cur) => ({ ...cur, [k]: v }));

  const save = async () => {
    setSaving(true);
    setMsg(null);
    setErr(null);
    try {
      const fields: ProfileEconomic = { addresses };
      const fullMask: Record<string, FieldVisibility> = {};
      for (const k of FIELDS) fullMask[`economic.${k}`] = mask[k];
      await onSave(fields, fullMask);
      setMsg("Economic profile updated");
    } catch (e: unknown) {
      const m = e instanceof Error ? e.message : String(e);
      setErr(m || "Save failed");
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-5">
      <Section
        label="Linked addresses"
        visibility={mask.addresses}
        onVisibility={(v) => setMaskFor("addresses", v)}
        editable={editable}
      >
        {mask.addresses === "private" && !editable ? (
          <div className="text-xs text-mempool-text-dim italic">🔒 Hidden by owner</div>
        ) : (
          <>
            {addresses.length === 0 && !editable && (
              <div className="text-xs text-mempool-text-dim italic">No linked addresses</div>
            )}
            {addresses.map((a, i) => (
              <div key={`addr-${i}`} className="flex gap-2 items-center">
                {editable ? (
                  <>
                    <input
                      value={a.chain}
                      onChange={(e) => {
                        const arr = addresses.slice();
                        arr[i] = { ...a, chain: e.target.value };
                        setAddresses(arr);
                      }}
                      placeholder="Chain"
                      className="w-24 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text"
                    />
                    <input
                      value={a.address}
                      onChange={(e) => {
                        const arr = addresses.slice();
                        arr[i] = { ...a, address: e.target.value };
                        setAddresses(arr);
                      }}
                      placeholder="Address"
                      className="flex-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs font-mono text-mempool-text"
                    />
                    <button
                      onClick={() => setAddresses(addresses.filter((_, j) => j !== i))}
                      className="text-mempool-text-dim hover:text-mempool-red text-xs"
                    >
                      ✕
                    </button>
                  </>
                ) : (
                  <div className="text-xs text-mempool-text flex gap-2 items-center">
                    <span className="font-semibold uppercase">{a.chain}</span>
                    <span className="font-mono break-all">{a.address}</span>
                  </div>
                )}
              </div>
            ))}
            {editable && (
              <button
                onClick={() => setAddresses([...addresses, { chain: "", address: "" }])}
                className="text-xs text-mempool-blue hover:underline"
              >
                + Add address
              </button>
            )}
          </>
        )}
      </Section>

      <Section
        label="Donations (chain-sourced)"
        visibility={mask.donations}
        onVisibility={(v) => setMaskFor("donations", v)}
        editable={editable}
      >
        {mask.donations === "private" && !editable ? (
          <div className="text-xs text-mempool-text-dim italic">🔒 Hidden by owner</div>
        ) : donations.length === 0 ? (
          <div className="text-xs text-mempool-text-dim italic">No donations recorded</div>
        ) : (
          <div className="space-y-1">
            {donations.map((d, i) => (
              <div key={`donation-${i}`} className="flex justify-between text-xs">
                <span className="font-mono text-mempool-text truncate flex-1">
                  → {d.to}
                </span>
                <span className="text-mempool-green ml-2">
                  {d.amount.toLocaleString()} OMNI
                </span>
              </div>
            ))}
          </div>
        )}
      </Section>

      <Section
        label="Total volume"
        visibility={mask.total_volume}
        onVisibility={(v) => setMaskFor("total_volume", v)}
        editable={editable}
      >
        {mask.total_volume === "private" && !editable ? (
          <div className="text-xs text-mempool-text-dim italic">🔒 Hidden by owner</div>
        ) : (
          <div className="text-sm font-mono text-mempool-text">
            {(eco.total_volume ?? 0).toLocaleString()} OMNI
          </div>
        )}
      </Section>

      {editable && (
        <div className="flex items-center gap-3 pt-2 border-t border-mempool-border">
          <button
            onClick={save}
            disabled={saving}
            className="bg-mempool-blue hover:bg-mempool-blue/80 disabled:opacity-50 text-white text-sm font-semibold rounded-lg px-4 py-2"
          >
            {saving ? "Saving…" : "Save Economic"}
          </button>
          {msg && <span className="text-xs text-mempool-green">{msg}</span>}
          {err && <span className="text-xs text-mempool-red">{err}</span>}
        </div>
      )}

      <MicaPanel address={profile.address} privateKey={privateKey} editable={editable} />
    </div>
  );
}

function Section({
  label,
  visibility,
  onVisibility,
  editable,
  children,
}: {
  label: string;
  visibility: FieldVisibility;
  onVisibility: (v: FieldVisibility) => void;
  editable: boolean;
  children: React.ReactNode;
}) {
  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between">
        <span className="text-[10px] text-mempool-text-dim uppercase tracking-wider">
          {label}
        </span>
        {editable ? (
          <PublicToggle value={visibility} onChange={onVisibility} />
        ) : (
          <PublicBadge value={visibility} />
        )}
      </div>
      <div className="space-y-1.5">{children}</div>
    </div>
  );
}
