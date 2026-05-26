/**
 * CulturalTab.tsx — Cultural facet.
 * POAPs, notarized works, languages, badges.
 */

import { useEffect, useState } from "react";
import type { ProfileFull, ProfileCultural } from "../../api/rpc-client";
import { PublicToggle, PublicBadge, type FieldVisibility } from "./PublicToggle";

const FIELDS = ["poaps", "notarized_works", "languages", "badges"] as const;
type CulKey = (typeof FIELDS)[number];

function readMask(profile: ProfileFull): Record<CulKey, FieldVisibility> {
  const stored = profile.visibility_mask || {};
  const m: Record<string, FieldVisibility> = {};
  for (const k of FIELDS) {
    const v = stored[`cultural.${k}`];
    m[k] = v === "private" ? "private" : "public";
  }
  return m as Record<CulKey, FieldVisibility>;
}

export function CulturalTab({
  profile,
  editable,
  onSave,
}: {
  profile: ProfileFull;
  editable: boolean;
  onSave: (
    fields: ProfileCultural,
    mask: Record<string, FieldVisibility>,
  ) => Promise<void>;
}) {
  const cul: ProfileCultural = profile.cultural || {};
  const [poaps, setPoaps] = useState(cul.poaps || []);
  const [notarized, setNotarized] = useState(cul.notarized_works || []);
  const [languages, setLanguages] = useState<string[]>(cul.languages || []);
  const [langInput, setLangInput] = useState("");
  const [mask, setMask] = useState(() => readMask(profile));
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const badges = cul.badges || []; // read-only — chain-issued

  useEffect(() => {
    const c = profile.cultural || {};
    setPoaps(c.poaps || []);
    setNotarized(c.notarized_works || []);
    setLanguages(c.languages || []);
    setMask(readMask(profile));
  }, [profile]);

  const setMaskFor = (k: CulKey, v: FieldVisibility) =>
    setMask((cur) => ({ ...cur, [k]: v }));

  const save = async () => {
    setSaving(true);
    setMsg(null);
    setErr(null);
    try {
      const fields: ProfileCultural = {
        poaps,
        notarized_works: notarized,
        languages,
      };
      const fullMask: Record<string, FieldVisibility> = {};
      for (const k of FIELDS) fullMask[`cultural.${k}`] = mask[k];
      await onSave(fields, fullMask);
      setMsg("Cultural profile updated");
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
        label="POAPs / Event proofs"
        visibility={mask.poaps}
        onVisibility={(v) => setMaskFor("poaps", v)}
        editable={editable}
      >
        {mask.poaps === "private" && !editable ? (
          <div className="text-xs text-mempool-text-dim italic">🔒 Hidden by owner</div>
        ) : (
          <>
            {poaps.length === 0 && !editable && (
              <div className="text-xs text-mempool-text-dim italic">No POAPs yet</div>
            )}
            {poaps.map((p, i) => (
              <div key={`poap-${i}`} className="flex gap-2 items-center">
                {editable ? (
                  <>
                    <input
                      value={p.event}
                      onChange={(e) => {
                        const n = poaps.slice();
                        n[i] = { ...p, event: e.target.value };
                        setPoaps(n);
                      }}
                      placeholder="Event"
                      className="w-48 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text"
                    />
                    <input
                      value={p.date || ""}
                      onChange={(e) => {
                        const n = poaps.slice();
                        n[i] = { ...p, date: e.target.value };
                        setPoaps(n);
                      }}
                      placeholder="YYYY-MM-DD"
                      className="w-32 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text"
                    />
                    <input
                      value={p.proof || ""}
                      onChange={(e) => {
                        const n = poaps.slice();
                        n[i] = { ...p, proof: e.target.value };
                        setPoaps(n);
                      }}
                      placeholder="Proof URL / hash"
                      className="flex-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs font-mono text-mempool-text"
                    />
                    <button
                      onClick={() => setPoaps(poaps.filter((_, j) => j !== i))}
                      className="text-mempool-text-dim hover:text-mempool-red text-xs"
                    >
                      ✕
                    </button>
                  </>
                ) : (
                  <div className="text-sm text-mempool-text">
                    <span className="font-semibold">{p.event}</span>
                    {p.date && <span className="text-mempool-text-dim text-xs ml-2">{p.date}</span>}
                  </div>
                )}
              </div>
            ))}
            {editable && (
              <button
                onClick={() => setPoaps([...poaps, { event: "" }])}
                className="text-xs text-mempool-blue hover:underline"
              >
                + Add POAP
              </button>
            )}
          </>
        )}
      </Section>

      <Section
        label="Notarized works"
        visibility={mask.notarized_works}
        onVisibility={(v) => setMaskFor("notarized_works", v)}
        editable={editable}
      >
        {mask.notarized_works === "private" && !editable ? (
          <div className="text-xs text-mempool-text-dim italic">🔒 Hidden by owner</div>
        ) : (
          <>
            {notarized.length === 0 && !editable && (
              <div className="text-xs text-mempool-text-dim italic">No notarized works</div>
            )}
            {notarized.map((n, i) => (
              <div key={`notarized-${i}`} className="flex gap-2 items-center">
                {editable ? (
                  <>
                    <input
                      value={n.title}
                      onChange={(e) => {
                        const arr = notarized.slice();
                        arr[i] = { ...n, title: e.target.value };
                        setNotarized(arr);
                      }}
                      placeholder="Title"
                      className="w-40 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text"
                    />
                    <input
                      value={n.hash}
                      onChange={(e) => {
                        const arr = notarized.slice();
                        arr[i] = { ...n, hash: e.target.value };
                        setNotarized(arr);
                      }}
                      placeholder="SHA256 hash"
                      className="flex-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs font-mono text-mempool-text"
                    />
                    <input
                      type="number"
                      value={n.year || ""}
                      onChange={(e) => {
                        const arr = notarized.slice();
                        arr[i] = { ...n, year: e.target.value ? Number(e.target.value) : undefined };
                        setNotarized(arr);
                      }}
                      placeholder="Year"
                      className="w-20 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text"
                    />
                    <button
                      onClick={() => setNotarized(notarized.filter((_, j) => j !== i))}
                      className="text-mempool-text-dim hover:text-mempool-red text-xs"
                    >
                      ✕
                    </button>
                  </>
                ) : (
                  <div className="text-sm text-mempool-text">
                    <span className="font-semibold">{n.title}</span>
                    <span className="font-mono text-[10px] text-mempool-text-dim ml-2 truncate">
                      {n.hash.slice(0, 16)}…
                    </span>
                    {n.year && <span className="text-mempool-text-dim text-xs ml-2">({n.year})</span>}
                  </div>
                )}
              </div>
            ))}
            {editable && (
              <button
                onClick={() => setNotarized([...notarized, { title: "", hash: "" }])}
                className="text-xs text-mempool-blue hover:underline"
              >
                + Add work
              </button>
            )}
          </>
        )}
      </Section>

      <Section
        label="Languages"
        visibility={mask.languages}
        onVisibility={(v) => setMaskFor("languages", v)}
        editable={editable}
      >
        {mask.languages === "private" && !editable ? (
          <div className="text-xs text-mempool-text-dim italic">🔒 Hidden by owner</div>
        ) : (
          <>
            <div className="flex flex-wrap gap-1.5">
              {languages.map((l, i) => (
                <span
                  key={l}
                  className="inline-flex items-center gap-1 bg-mempool-bg border border-mempool-border rounded-full px-2 py-0.5 text-xs text-mempool-text"
                >
                  {l}
                  {editable && (
                    <button
                      onClick={() => setLanguages(languages.filter((_, j) => j !== i))}
                      className="text-mempool-text-dim hover:text-mempool-red"
                    >
                      ×
                    </button>
                  )}
                </span>
              ))}
              {languages.length === 0 && !editable && (
                <span className="text-xs text-mempool-text-dim italic">No languages</span>
              )}
            </div>
            {editable && (
              <input
                value={langInput}
                onChange={(e) => setLangInput(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && langInput.trim()) {
                    setLanguages([...languages, langInput.trim()]);
                    setLangInput("");
                  }
                }}
                placeholder="Add language + Enter (e.g. ro, en)"
                className="mt-2 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text w-full sm:w-64"
              />
            )}
          </>
        )}
      </Section>

      <Section
        label="Badges (chain-issued)"
        visibility={mask.badges}
        onVisibility={(v) => setMaskFor("badges", v)}
        editable={editable}
      >
        <div className="flex flex-wrap gap-1.5">
          {badges.length === 0 && (
            <span className="text-xs text-mempool-text-dim italic">No badges yet</span>
          )}
          {badges.map((b, i) => (
            <span
              key={`badge-${i}`}
              className="inline-flex items-center bg-gradient-to-br from-amber-500/20 to-orange-600/20 border border-amber-500/40 text-amber-300 rounded-full px-2 py-0.5 text-xs font-medium"
            >
              🏅 {b}
            </span>
          ))}
        </div>
      </Section>

      {editable && (
        <div className="flex items-center gap-3 pt-2 border-t border-mempool-border">
          <button
            onClick={save}
            disabled={saving}
            className="bg-mempool-blue hover:bg-mempool-blue/80 disabled:opacity-50 text-white text-sm font-semibold rounded-lg px-4 py-2"
          >
            {saving ? "Saving…" : "Save Cultural"}
          </button>
          {msg && <span className="text-xs text-mempool-green">{msg}</span>}
          {err && <span className="text-xs text-mempool-red">{err}</span>}
        </div>
      )}
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
