/**
 * ProfessionalTab.tsx — Professional facet editor / viewer.
 * Fields: certifications[], work_history[], skills[], visibility per field.
 */

import { useEffect, useState } from "react";
import type { ProfileFull, ProfileProfessional } from "../../api/rpc-client";
import { PublicToggle, PublicBadge, type FieldVisibility } from "./PublicToggle";

const FIELDS = ["certifications", "work_history", "skills"] as const;
type ProKey = (typeof FIELDS)[number];

function readMask(profile: ProfileFull): Record<ProKey, FieldVisibility> {
  const stored = profile.visibility_mask || {};
  const m: Record<string, FieldVisibility> = {};
  for (const k of FIELDS) {
    const v = stored[`professional.${k}`];
    m[k] = v === "private" ? "private" : "public";
  }
  return m as Record<ProKey, FieldVisibility>;
}

export function ProfessionalTab({
  profile,
  editable,
  onSave,
}: {
  profile: ProfileFull;
  editable: boolean;
  onSave: (
    fields: ProfileProfessional,
    mask: Record<string, FieldVisibility>,
  ) => Promise<void>;
}) {
  const pro: ProfileProfessional = profile.professional || {};
  const [certs, setCerts] = useState(pro.certifications || []);
  const [work, setWork] = useState(pro.work_history || []);
  const [skills, setSkills] = useState<string[]>(pro.skills || []);
  const [skillInput, setSkillInput] = useState("");
  const [mask, setMask] = useState(() => readMask(profile));
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    const p = profile.professional || {};
    setCerts(p.certifications || []);
    setWork(p.work_history || []);
    setSkills(p.skills || []);
    setMask(readMask(profile));
  }, [profile]);

  const setMaskFor = (k: ProKey, v: FieldVisibility) =>
    setMask((cur) => ({ ...cur, [k]: v }));

  const save = async () => {
    setSaving(true);
    setMsg(null);
    setErr(null);
    try {
      const fields: ProfileProfessional = {
        certifications: certs,
        work_history: work,
        skills,
      };
      const fullMask: Record<string, FieldVisibility> = {};
      for (const k of FIELDS) fullMask[`professional.${k}`] = mask[k];
      await onSave(fields, fullMask);
      setMsg("Professional profile updated");
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
        label="Certifications"
        visibility={mask.certifications}
        onVisibility={(v) => setMaskFor("certifications", v)}
        editable={editable}
      >
        {certs.length === 0 && !editable && (
          <div className="text-xs text-mempool-text-dim italic">No certifications</div>
        )}
        {mask.certifications === "private" && !editable ? (
          <div className="text-xs text-mempool-text-dim italic">🔒 Hidden by owner</div>
        ) : (
          <>
            {certs.map((c, i) => (
              <div key={`cert-${i}`} className="flex gap-2 items-center">
                {editable ? (
                  <>
                    <input
                      value={c.issuer}
                      onChange={(e) => {
                        const n = certs.slice();
                        n[i] = { ...c, issuer: e.target.value };
                        setCerts(n);
                      }}
                      placeholder="Issuer"
                      className="w-40 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text"
                    />
                    <input
                      value={c.title}
                      onChange={(e) => {
                        const n = certs.slice();
                        n[i] = { ...c, title: e.target.value };
                        setCerts(n);
                      }}
                      placeholder="Title"
                      className="flex-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text"
                    />
                    <input
                      type="number"
                      value={c.year || ""}
                      onChange={(e) => {
                        const n = certs.slice();
                        n[i] = { ...c, year: e.target.value ? Number(e.target.value) : undefined };
                        setCerts(n);
                      }}
                      placeholder="Year"
                      className="w-20 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text"
                    />
                    <button
                      onClick={() => setCerts(certs.filter((_, j) => j !== i))}
                      className="text-mempool-text-dim hover:text-mempool-red text-xs"
                    >
                      ✕
                    </button>
                  </>
                ) : (
                  <div className="text-sm text-mempool-text">
                    <span className="font-semibold">{c.title}</span>
                    {" — "}
                    <span className="text-mempool-text-dim">{c.issuer}</span>
                    {c.year && <span className="text-mempool-text-dim"> ({c.year})</span>}
                  </div>
                )}
              </div>
            ))}
            {editable && (
              <button
                onClick={() => setCerts([...certs, { issuer: "", title: "" }])}
                className="text-xs text-mempool-blue hover:underline"
              >
                + Add certification
              </button>
            )}
          </>
        )}
      </Section>

      <Section
        label="Work history"
        visibility={mask.work_history}
        onVisibility={(v) => setMaskFor("work_history", v)}
        editable={editable}
      >
        {work.length === 0 && !editable && (
          <div className="text-xs text-mempool-text-dim italic">No work history</div>
        )}
        {mask.work_history === "private" && !editable ? (
          <div className="text-xs text-mempool-text-dim italic">🔒 Hidden by owner</div>
        ) : (
          <>
            {work.map((w, i) => (
              <div key={`work-${i}`} className="flex gap-2 items-center flex-wrap">
                {editable ? (
                  <>
                    <input
                      value={w.org}
                      onChange={(e) => {
                        const n = work.slice();
                        n[i] = { ...w, org: e.target.value };
                        setWork(n);
                      }}
                      placeholder="Organization"
                      className="w-40 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text"
                    />
                    <input
                      value={w.role}
                      onChange={(e) => {
                        const n = work.slice();
                        n[i] = { ...w, role: e.target.value };
                        setWork(n);
                      }}
                      placeholder="Role"
                      className="w-40 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text"
                    />
                    <input
                      value={w.start || ""}
                      onChange={(e) => {
                        const n = work.slice();
                        n[i] = { ...w, start: e.target.value };
                        setWork(n);
                      }}
                      placeholder="YYYY-MM"
                      className="w-24 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text"
                    />
                    <input
                      value={w.end || ""}
                      onChange={(e) => {
                        const n = work.slice();
                        n[i] = { ...w, end: e.target.value };
                        setWork(n);
                      }}
                      placeholder="YYYY-MM"
                      className="w-24 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text"
                    />
                    <button
                      onClick={() => setWork(work.filter((_, j) => j !== i))}
                      className="text-mempool-text-dim hover:text-mempool-red text-xs"
                    >
                      ✕
                    </button>
                  </>
                ) : (
                  <div className="text-sm text-mempool-text">
                    <span className="font-semibold">{w.role}</span>
                    {" @ "}
                    <span>{w.org}</span>
                    {(w.start || w.end) && (
                      <span className="text-mempool-text-dim text-xs ml-2">
                        ({w.start || "?"} → {w.end || "now"})
                      </span>
                    )}
                  </div>
                )}
              </div>
            ))}
            {editable && (
              <button
                onClick={() => setWork([...work, { org: "", role: "" }])}
                className="text-xs text-mempool-blue hover:underline"
              >
                + Add role
              </button>
            )}
          </>
        )}
      </Section>

      <Section
        label="Skills"
        visibility={mask.skills}
        onVisibility={(v) => setMaskFor("skills", v)}
        editable={editable}
      >
        {mask.skills === "private" && !editable ? (
          <div className="text-xs text-mempool-text-dim italic">🔒 Hidden by owner</div>
        ) : (
          <>
            <div className="flex flex-wrap gap-1.5">
              {skills.map((s, i) => (
                <span
                  key={`skill-${i}`}
                  className="inline-flex items-center gap-1 bg-mempool-bg border border-mempool-border rounded-full px-2 py-0.5 text-xs text-mempool-text"
                >
                  {s}
                  {editable && (
                    <button
                      onClick={() => setSkills(skills.filter((_, j) => j !== i))}
                      className="text-mempool-text-dim hover:text-mempool-red"
                    >
                      ×
                    </button>
                  )}
                </span>
              ))}
              {skills.length === 0 && !editable && (
                <span className="text-xs text-mempool-text-dim italic">No skills</span>
              )}
            </div>
            {editable && (
              <div className="flex gap-2 mt-2">
                <input
                  value={skillInput}
                  onChange={(e) => setSkillInput(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" && skillInput.trim()) {
                      setSkills([...skills, skillInput.trim()]);
                      setSkillInput("");
                    }
                  }}
                  placeholder="Add skill + Enter"
                  className="flex-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text"
                />
              </div>
            )}
          </>
        )}
      </Section>

      {editable && (
        <div className="flex items-center gap-3 pt-2 border-t border-mempool-border">
          <button
            onClick={save}
            disabled={saving}
            className="bg-mempool-blue hover:bg-mempool-blue/80 disabled:opacity-50 text-white text-sm font-semibold rounded-lg px-4 py-2"
          >
            {saving ? "Saving…" : "Save Professional"}
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
