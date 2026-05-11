/**
 * SocialTab.tsx — Social facet editor / viewer.
 * Fields: handle, bio, avatar URL, links[].
 * Each field has a PublicToggle for per-field visibility.
 */

import { useEffect, useState } from "react";
import type { ProfileFull, ProfileSocial } from "../../api/rpc-client";
import { PublicToggle, PublicBadge, type FieldVisibility } from "./PublicToggle";

export interface SocialTabProps {
  profile: ProfileFull;
  editable: boolean;
  onSave: (
    fields: ProfileSocial,
    mask: Record<string, FieldVisibility>,
  ) => Promise<void>;
}

const FIELD_KEYS = ["handle", "bio", "avatar", "links"] as const;
type SocialKey = (typeof FIELD_KEYS)[number];

function readMask(profile: ProfileFull): Record<SocialKey, FieldVisibility> {
  const m: Record<string, FieldVisibility> = {};
  const stored = profile.visibility_mask || {};
  for (const k of FIELD_KEYS) {
    const v = stored[`social.${k}`];
    m[k] = v === "private" ? "private" : "public";
  }
  return m as Record<SocialKey, FieldVisibility>;
}

export function SocialTab({ profile, editable, onSave }: SocialTabProps) {
  const social: ProfileSocial = profile.social || {};
  const [handle, setHandle] = useState(social.handle || "");
  const [bio, setBio] = useState(social.bio || "");
  const [avatar, setAvatar] = useState(social.avatar || "");
  const [links, setLinks] = useState<Array<{ label: string; url: string }>>(
    social.links || [],
  );
  const [mask, setMask] = useState<Record<SocialKey, FieldVisibility>>(() => readMask(profile));
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    const s = profile.social || {};
    setHandle(s.handle || "");
    setBio(s.bio || "");
    setAvatar(s.avatar || "");
    setLinks(s.links || []);
    setMask(readMask(profile));
  }, [profile]);

  const setMaskFor = (k: SocialKey, v: FieldVisibility) =>
    setMask((cur) => ({ ...cur, [k]: v }));

  const save = async () => {
    setSaving(true);
    setMsg(null);
    setErr(null);
    try {
      const fields: ProfileSocial = { handle, bio, avatar, links };
      const fullMask: Record<string, FieldVisibility> = {};
      for (const k of FIELD_KEYS) fullMask[`social.${k}`] = mask[k];
      await onSave(fields, fullMask);
      setMsg("Social profile updated");
    } catch (e: unknown) {
      const m = e instanceof Error ? e.message : String(e);
      setErr(m || "Save failed");
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-4">
      <FieldRow
        label="Handle"
        hint="Public nickname, e.g. @alex"
        visibility={mask.handle}
        onVisibility={(v) => setMaskFor("handle", v)}
        editable={editable}
      >
        {editable ? (
          <input
            value={handle}
            onChange={(e) => setHandle(e.target.value)}
            maxLength={32}
            placeholder="alex"
            className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-sm text-mempool-text focus:outline-none focus:border-mempool-blue"
          />
        ) : (
          <ReadOnly value={handle} mask={mask.handle} />
        )}
      </FieldRow>

      <FieldRow
        label="Bio"
        visibility={mask.bio}
        onVisibility={(v) => setMaskFor("bio", v)}
        editable={editable}
      >
        {editable ? (
          <textarea
            value={bio}
            onChange={(e) => setBio(e.target.value)}
            rows={3}
            maxLength={280}
            placeholder="Short bio…"
            className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-sm text-mempool-text resize-none focus:outline-none focus:border-mempool-blue"
          />
        ) : (
          <ReadOnly value={bio} mask={mask.bio} multiline />
        )}
      </FieldRow>

      <FieldRow
        label="Avatar URL"
        visibility={mask.avatar}
        onVisibility={(v) => setMaskFor("avatar", v)}
        editable={editable}
      >
        {editable ? (
          <input
            value={avatar}
            onChange={(e) => setAvatar(e.target.value)}
            placeholder="https://…"
            className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-sm font-mono text-mempool-text focus:outline-none focus:border-mempool-blue"
          />
        ) : (
          <ReadOnly value={avatar} mask={mask.avatar} mono />
        )}
      </FieldRow>

      <FieldRow
        label="Links"
        visibility={mask.links}
        onVisibility={(v) => setMaskFor("links", v)}
        editable={editable}
      >
        <div className="space-y-2">
          {links.map((l, i) => (
            <div key={i} className="flex gap-2 items-center">
              {editable ? (
                <>
                  <input
                    value={l.label}
                    onChange={(e) => {
                      const next = links.slice();
                      next[i] = { ...l, label: e.target.value };
                      setLinks(next);
                    }}
                    placeholder="Label"
                    className="w-32 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text"
                  />
                  <input
                    value={l.url}
                    onChange={(e) => {
                      const next = links.slice();
                      next[i] = { ...l, url: e.target.value };
                      setLinks(next);
                    }}
                    placeholder="https://…"
                    className="flex-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1 text-xs font-mono text-mempool-text"
                  />
                  <button
                    onClick={() => setLinks(links.filter((_, j) => j !== i))}
                    className="text-xs text-mempool-text-dim hover:text-mempool-red"
                  >
                    ✕
                  </button>
                </>
              ) : (
                <a
                  href={l.url}
                  target="_blank"
                  rel="noreferrer"
                  className="text-xs text-mempool-blue hover:underline break-all"
                >
                  {l.label || l.url}
                </a>
              )}
            </div>
          ))}
          {editable && (
            <button
              onClick={() => setLinks([...links, { label: "", url: "" }])}
              className="text-xs text-mempool-blue hover:underline"
            >
              + Add link
            </button>
          )}
          {!editable && links.length === 0 && (
            <div className="text-xs text-mempool-text-dim italic">No links</div>
          )}
        </div>
      </FieldRow>

      {editable && (
        <div className="flex items-center gap-3 pt-2 border-t border-mempool-border">
          <button
            onClick={save}
            disabled={saving}
            className="bg-mempool-blue hover:bg-mempool-blue/80 disabled:opacity-50 text-white text-sm font-semibold rounded-lg px-4 py-2"
          >
            {saving ? "Saving…" : "Save Social"}
          </button>
          {msg && <span className="text-xs text-mempool-green">{msg}</span>}
          {err && <span className="text-xs text-mempool-red">{err}</span>}
        </div>
      )}
    </div>
  );
}

function FieldRow({
  label,
  hint,
  visibility,
  onVisibility,
  editable,
  children,
}: {
  label: string;
  hint?: string;
  visibility: FieldVisibility;
  onVisibility: (v: FieldVisibility) => void;
  editable: boolean;
  children: React.ReactNode;
}) {
  return (
    <div className="space-y-1">
      <div className="flex items-center justify-between">
        <div>
          <span className="text-[10px] text-mempool-text-dim uppercase tracking-wider">
            {label}
          </span>
          {hint && (
            <span className="text-[10px] text-mempool-text-dim ml-2">{hint}</span>
          )}
        </div>
        {editable ? (
          <PublicToggle value={visibility} onChange={onVisibility} />
        ) : (
          <PublicBadge value={visibility} />
        )}
      </div>
      {children}
    </div>
  );
}

function ReadOnly({
  value,
  mask,
  mono = false,
  multiline = false,
}: {
  value: string;
  mask: FieldVisibility;
  mono?: boolean;
  multiline?: boolean;
}) {
  if (mask === "private") {
    return (
      <div className="text-xs text-mempool-text-dim italic">
        🔒 Hidden by owner
      </div>
    );
  }
  if (!value) {
    return <div className="text-xs text-mempool-text-dim italic">—</div>;
  }
  return (
    <div
      className={`text-sm text-mempool-text break-words ${mono ? "font-mono" : ""} ${
        multiline ? "whitespace-pre-wrap" : ""
      }`}
    >
      {value}
    </div>
  );
}
