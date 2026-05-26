/**
 * IdentityDIDPage.tsx
 *
 * Displays the OmniBus identity layer for the connected wallet:
 *   Tab 1 — DID & OBM  : decentralized identifier + 1-byte binary capability map
 *   Tab 2 — Facets      : social / professional / cultural / economic profile status
 *   Tab 3 — Selective Disclosure : generate Merkle proofs for individual items
 *   Tab 4 — MiCA Compliance : KYC/AML attestations per MiCA regulation
 *
 * All data is fetched from the node via JSON-RPC 2.0 (rpc.request_raw).
 */

import { useEffect, useState, useCallback } from "react";
import { rpc } from "../../api/rpc-client";
import { useWallet } from "../../api/use-wallet";
import { CopyButton } from "../common/CopyButton";


// ── RPC response types ────────────────────────────────────────────────────────

interface DidResult {
  address: string;
  did: string;
}

interface ObmResult {
  address: string;
  obm: number;
  love_badge: boolean;
  food_badge: boolean;
  rent_badge: boolean;
  vacation_badge: boolean;
  has_pq_key: boolean;
  has_dns_name: boolean;
  is_validator: boolean;
  is_zen_tier: boolean;
}

interface FacetInfo {
  populated: boolean;
  root_hex: string;
}

interface FacetsResult {
  address: string;
  social: FacetInfo;
  professional: FacetInfo;
  cultural: FacetInfo;
  economic: FacetInfo;
}

interface DisclosePostResult {
  post_hash: string;
  timestamp: number;
  is_public: boolean;
  proof: string[];
}

interface DiscloseCertResult {
  issuer_did: string;
  credential_kind: string;
  valid_from: number;
  valid_until: number;
  hash: string;
  proof: string[];
}

interface DiscloseWorkResult {
  content_hash: string;
  work_kind: string;
  notarized_at: number;
  is_public: boolean;
  proof: string[];
}

interface MicaAttestation {
  kind: string;
  issuer_did: string;
  signature_hex: string;
  timestamp: number;
}

interface MicaDiscloseResult {
  address: string;
  attestations: MicaAttestation[];
  is_mica_issuer: boolean;
  risk_category: string;
}

// ── type guards ───────────────────────────────────────────────────────────────

function isDidResult(v: unknown): v is DidResult {
  return (
    typeof v === "object" &&
    v !== null &&
    typeof (v as Record<string, unknown>).did === "string" &&
    typeof (v as Record<string, unknown>).address === "string"
  );
}

function isObmResult(v: unknown): v is ObmResult {
  return (
    typeof v === "object" &&
    v !== null &&
    typeof (v as Record<string, unknown>).obm === "number"
  );
}

function isFacetInfo(v: unknown): v is FacetInfo {
  return (
    typeof v === "object" &&
    v !== null &&
    typeof (v as Record<string, unknown>).populated === "boolean"
  );
}

function isFacetsResult(v: unknown): v is FacetsResult {
  if (typeof v !== "object" || v === null) return false;
  const r = v as Record<string, unknown>;
  return (
    isFacetInfo(r.social) &&
    isFacetInfo(r.professional) &&
    isFacetInfo(r.cultural) &&
    isFacetInfo(r.economic)
  );
}

function isDisclosePostResult(v: unknown): v is DisclosePostResult {
  if (typeof v !== "object" || v === null) return false;
  const r = v as Record<string, unknown>;
  return (
    typeof r.post_hash === "string" &&
    typeof r.timestamp === "number" &&
    Array.isArray(r.proof)
  );
}

function isDiscloseCertResult(v: unknown): v is DiscloseCertResult {
  if (typeof v !== "object" || v === null) return false;
  const r = v as Record<string, unknown>;
  return typeof r.issuer_did === "string" && Array.isArray(r.proof);
}

function isDiscloseWorkResult(v: unknown): v is DiscloseWorkResult {
  if (typeof v !== "object" || v === null) return false;
  const r = v as Record<string, unknown>;
  return typeof r.content_hash === "string" && Array.isArray(r.proof);
}

function isMicaDiscloseResult(v: unknown): v is MicaDiscloseResult {
  if (typeof v !== "object" || v === null) return false;
  const r = v as Record<string, unknown>;
  return Array.isArray(r.attestations) && typeof r.risk_category === "string";
}

// ── small helpers ─────────────────────────────────────────────────────────────

function ts(unix: number): string {
  if (unix === 0) return "—";
  return new Date(unix * 1000).toLocaleString();
}

function Badge({ active, label }: { active: boolean; label: string }) {
  return (
    <span
      className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${
        active
          ? "bg-green-900/60 text-green-300 border border-green-700/50"
          : "bg-gray-800/60 text-gray-500 border border-gray-700/40"
      }`}
    >
      {label}
    </span>
  );
}

function OBMBit({ active, label, desc }: { active: boolean; label: string; desc: string }) {
  return (
    <div className="flex items-center gap-2 py-1">
      <div
        className={`w-4 h-4 rounded-sm flex-shrink-0 ${
          active ? "bg-green-500" : "bg-gray-700"
        }`}
        title={active ? "active" : "inactive"}
      />
      <span className={`text-sm font-mono ${active ? "text-mempool-text" : "text-mempool-text-dim"}`}>
        {label}
      </span>
      <span className="text-xs text-mempool-text-dim">— {desc}</span>
    </div>
  );
}

function ProofDisplay({
  proof,
  jsonPayload,
}: {
  proof: string[];
  jsonPayload: string;
}) {
  return (
    <div className="mt-3 space-y-2">
      <div className="bg-mempool-bg-elev rounded-lg border border-mempool-border p-3">
        <div className="flex items-center justify-between mb-2">
          <span className="text-xs text-mempool-text-dim font-semibold uppercase tracking-wide">
            Merkle Proof
          </span>
          <CopyButton text={jsonPayload} label="Copy JSON" variant="button" />
        </div>
        {proof.length === 0 ? (
          <span className="text-xs text-mempool-text-dim italic">No siblings (single-leaf tree)</span>
        ) : (
          <ul className="space-y-1">
            {proof.map((sibling, i) => (
              <li key={`${i}:${sibling}`} className="font-mono text-xs text-mempool-text break-all">
                <span className="text-mempool-text-dim mr-2">[{i}]</span>
                {sibling}
              </li>
            ))}
          </ul>
        )}
      </div>
      <p className="text-xs text-mempool-text-dim">
        Share this proof to allow a third party to verify this specific item without
        revealing any other items in the facet.
      </p>
    </div>
  );
}

function LoadingSpinner() {
  return (
    <div className="flex items-center gap-2 text-mempool-text-dim text-sm">
      <svg className="animate-spin w-4 h-4" viewBox="0 0 24 24" fill="none">
        <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
        <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8z" />
      </svg>
      Loading…
    </div>
  );
}

const RISK_COLOR: Record<string, string> = {
  low:    "text-green-400",
  medium: "text-yellow-400",
  high:   "text-red-400",
};

// ── Tab 1: DID & OBM ─────────────────────────────────────────────────────────

const OBM_BITS: { key: keyof ObmResult; label: string; desc: string }[] = [
  { key: "love_badge",    label: "bit 0 — LOVE",      desc: "OMNI wallet active (reputation LOVE)" },
  { key: "food_badge",    label: "bit 1 — FOOD",       desc: "PQ wallet active (reputation FOOD)" },
  { key: "rent_badge",    label: "bit 2 — RENT",       desc: "Staking active (reputation RENT)" },
  { key: "vacation_badge",label: "bit 3 — VACATION",   desc: "Validator active (reputation VACATION)" },
  { key: "has_pq_key",    label: "bit 4 — PQ",         desc: "Post-quantum key registered" },
  { key: "has_dns_name",  label: "bit 5 — ENS",        desc: "ENS / .omnibus name registered" },
  { key: "is_validator",  label: "bit 6 — VALIDATOR",  desc: "Governance voted (≥100 OMNI staked)" },
  { key: "is_zen_tier",   label: "bit 7 — ZEN",        desc: "Oracle / Zen tier node" },
];

function TabDIDOBM({ address }: { address: string }) {
  const [did, setDid] = useState<DidResult | null>(null);
  const [obm, setObm] = useState<ObmResult | null>(null);
  const [facets, setFacets] = useState<FacetsResult | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!address) return;
    setLoading(true);
    setError(null);

    Promise.all([
      rpc.getDid(address),
      rpc.getObm(address),
      rpc.getFacets(address),
    ])
      .then(([d, o, f]) => {
        if (isDidResult(d)) setDid(d);
        if (isObmResult(o)) setObm(o);
        if (isFacetsResult(f)) setFacets(f);
      })
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : String(e));
      })
      .finally(() => setLoading(false));
  }, [address]);

  if (loading) return <LoadingSpinner />;
  if (error) return <p className="text-red-400 text-sm">{error}</p>;

  const activeFacets = facets
    ? (["social", "professional", "cultural", "economic"] as const).filter(
        (k) => facets[k].populated
      )
    : [];

  return (
    <div className="space-y-4">
      {/* DID card */}
      <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4">
        <div className="flex items-center justify-between mb-2">
          <span className="text-sm font-semibold text-mempool-text">Decentralized Identifier (DID)</span>
          {did && <CopyButton text={did.did} label="Copy DID" variant="button" />}
        </div>
        {did ? (
          <p
            className="font-mono text-sm text-mempool-blue break-all"
            style={{ wordBreak: "break-all" }}
          >
            {did.did}
          </p>
        ) : (
          <p className="text-mempool-text-dim text-sm italic">Could not derive DID</p>
        )}
        <p className="text-xs text-mempool-text-dim mt-2">
          Format: <code className="text-mempool-text">did:omnibus:&lt;base58(sha256(h160))&gt;</code>.
          Stable as long as the address does not change.
        </p>
      </div>

      {/* OBM card */}
      <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4">
        <div className="flex items-center gap-3 mb-3">
          <span className="text-sm font-semibold text-mempool-text">OBM — Capability Map</span>
          {obm && (
            <span className="font-mono text-xs bg-mempool-bg px-2 py-0.5 rounded border border-mempool-border text-mempool-text-dim">
              0x{obm.obm.toString(16).padStart(2, "0").toUpperCase()} ({obm.obm})
            </span>
          )}
        </div>
        {obm ? (
          <div className="divide-y divide-mempool-border/30">
            {OBM_BITS.map((bit) => (
              <OBMBit
                key={bit.key}
                active={obm[bit.key] as boolean}
                label={bit.label}
                desc={bit.desc}
              />
            ))}
          </div>
        ) : (
          <p className="text-mempool-text-dim text-sm italic">OBM data unavailable</p>
        )}
      </div>

      {/* Facets summary */}
      <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4">
        <span className="text-sm font-semibold text-mempool-text block mb-2">Active Facets</span>
        <div className="flex flex-wrap gap-2">
          {(["social", "professional", "cultural", "economic"] as const).map((k) => (
            <Badge
              key={k}
              active={facets ? facets[k].populated : false}
              label={k.charAt(0).toUpperCase() + k.slice(1)}
            />
          ))}
        </div>
        {activeFacets.length === 0 && (
          <p className="text-xs text-mempool-text-dim mt-2">
            No on-chain facet evidence yet. Populate your profile to activate facets.
          </p>
        )}
      </div>
    </div>
  );
}

// ── Tab 2: Facets Overview ────────────────────────────────────────────────────

const FACET_META: {
  key: keyof Omit<FacetsResult, "address">;
  label: string;
  desc: string;
  editNote: string;
}[] = [
  {
    key: "social",
    label: "Social",
    desc: "Posts, follows, community activity, content hashes.",
    editNote: "Populate via Profile → Social tab.",
  },
  {
    key: "professional",
    label: "Professional",
    desc: "Certifications, credentials, employment history, KYC proxies.",
    editNote: "Populate via Profile → Professional tab.",
  },
  {
    key: "cultural",
    label: "Cultural",
    desc: "Notarized creative works, POAPs, cultural endorsements.",
    editNote: "Populate via Profile → Cultural tab.",
  },
  {
    key: "economic",
    label: "Economic",
    desc: "MiCA/AML flags, risk category, financial attestations.",
    editNote: "Populate via Profile → Economic tab.",
  },
];

function TabFacets({ address }: { address: string }) {
  const [facets, setFacets] = useState<FacetsResult | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!address) return;
    setLoading(true);
    setError(null);
    rpc
      .getFacets(address)
      .then((f) => {
        if (isFacetsResult(f)) setFacets(f);
      })
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : String(e));
      })
      .finally(() => setLoading(false));
  }, [address]);

  if (loading) return <LoadingSpinner />;
  if (error) return <p className="text-red-400 text-sm">{error}</p>;

  return (
    <div className="space-y-3">
      <p className="text-xs text-mempool-text-dim">
        Facets are off-chain profile data anchored to your address. The chain
        reports only those facets it has evidence for — false negatives are
        expected for off-chain-only data.
      </p>
      {FACET_META.map((meta) => {
        const info = facets ? facets[meta.key] : null;
        const active = info?.populated ?? false;
        return (
          <div
            key={meta.key}
            className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4 flex items-start gap-3"
          >
            <div
              className={`mt-0.5 w-3 h-3 rounded-full flex-shrink-0 ${
                active ? "bg-green-500" : "bg-gray-600"
              }`}
            />
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-2 mb-1">
                <span className="text-sm font-semibold text-mempool-text">{meta.label}</span>
                <Badge active={active} label={active ? "Active" : "Inactive"} />
              </div>
              <p className="text-xs text-mempool-text-dim">{meta.desc}</p>
              {active && info?.root_hex && (
                <p className="mt-1 font-mono text-xs text-mempool-text-dim break-all">
                  Root: <span className="text-mempool-text">{info.root_hex}</span>
                </p>
              )}
              {!active && (
                <p className="mt-1 text-xs text-mempool-text-dim italic">{meta.editNote}</p>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ── Tab 3: Selective Disclosure ───────────────────────────────────────────────

type DisclosureKind = "post" | "cert" | "work";

type DisclosureResult =
  | { kind: "post"; data: DisclosePostResult }
  | { kind: "cert"; data: DiscloseCertResult }
  | { kind: "work"; data: DiscloseWorkResult };

function DisclosureSection({
  address,
  kind,
  title,
  indexLabel,
  paramKey,
  rpcMethod,
}: {
  address: string;
  kind: DisclosureKind;
  title: string;
  indexLabel: string;
  paramKey: string;
  rpcMethod: string;
}) {
  const [index, setIndex] = useState("0");
  const [result, setResult] = useState<DisclosureResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const prove = useCallback(async () => {
    const idx = parseInt(index, 10);
    if (isNaN(idx) || idx < 0) {
      setError("Index must be a non-negative integer");
      return;
    }
    setLoading(true);
    setError(null);
    setResult(null);
    try {
      const raw = await rpc.request_raw(rpcMethod, [
        { address, [paramKey]: idx },
      ]);
      if (kind === "post" && isDisclosePostResult(raw)) {
        setResult({ kind: "post", data: raw });
      } else if (kind === "cert" && isDiscloseCertResult(raw)) {
        setResult({ kind: "cert", data: raw });
      } else if (kind === "work" && isDiscloseWorkResult(raw)) {
        setResult({ kind: "work", data: raw });
      } else {
        setError("Unexpected response from node");
      }
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [address, index, kind, paramKey, rpcMethod]);

  const proofJson = result
    ? JSON.stringify({ address, ...result.data }, null, 2)
    : "";

  return (
    <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4">
      <span className="text-sm font-semibold text-mempool-text block mb-3">{title}</span>
      <div className="flex gap-2 items-center mb-2">
        <input
          type="number"
          min="0"
          value={index}
          onChange={(e) => setIndex(e.target.value)}
          className="bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-sm text-mempool-text w-28"
          placeholder={indexLabel}
        />
        <button
          onClick={prove}
          disabled={loading}
          className="bg-mempool-blue text-white px-4 py-2 rounded-lg text-sm font-semibold hover:opacity-90 disabled:opacity-50"
        >
          {loading ? "Proving…" : "Prove"}
        </button>
      </div>

      {error && <p className="text-red-400 text-xs mt-1">{error}</p>}

      {result && (
        <div className="mt-3 space-y-2">
          {result.kind === "post" && (
            <div className="text-xs space-y-1">
              <div>
                <span className="text-mempool-text-dim">Hash: </span>
                <span className="font-mono text-mempool-text break-all">{result.data.post_hash}</span>
              </div>
              <div>
                <span className="text-mempool-text-dim">Timestamp: </span>
                <span className="text-mempool-text">{ts(result.data.timestamp)}</span>
              </div>
              <div>
                <span className="text-mempool-text-dim">Public: </span>
                <Badge active={result.data.is_public} label={result.data.is_public ? "Yes" : "No"} />
              </div>
            </div>
          )}

          {result.kind === "cert" && (
            <div className="text-xs space-y-1">
              <div>
                <span className="text-mempool-text-dim">Issuer DID: </span>
                <span className="font-mono text-mempool-text break-all">{result.data.issuer_did}</span>
              </div>
              <div>
                <span className="text-mempool-text-dim">Kind: </span>
                <span className="text-mempool-text">{result.data.credential_kind || "—"}</span>
              </div>
              <div>
                <span className="text-mempool-text-dim">Valid from: </span>
                <span className="text-mempool-text">{ts(result.data.valid_from)}</span>
              </div>
              <div>
                <span className="text-mempool-text-dim">Valid until: </span>
                <span className="text-mempool-text">{ts(result.data.valid_until)}</span>
              </div>
              <div>
                <span className="text-mempool-text-dim">Hash: </span>
                <span className="font-mono text-mempool-text break-all">{result.data.hash || "—"}</span>
              </div>
            </div>
          )}

          {result.kind === "work" && (
            <div className="text-xs space-y-1">
              <div>
                <span className="text-mempool-text-dim">Content hash: </span>
                <span className="font-mono text-mempool-text break-all">{result.data.content_hash}</span>
              </div>
              <div>
                <span className="text-mempool-text-dim">Kind: </span>
                <span className="text-mempool-text">{result.data.work_kind || "—"}</span>
              </div>
              <div>
                <span className="text-mempool-text-dim">Notarized: </span>
                <span className="text-mempool-text">{ts(result.data.notarized_at)}</span>
              </div>
              <div>
                <span className="text-mempool-text-dim">Public: </span>
                <Badge active={result.data.is_public} label={result.data.is_public ? "Yes" : "No"} />
              </div>
            </div>
          )}

          <ProofDisplay proof={result.data.proof} jsonPayload={proofJson} />
        </div>
      )}
    </div>
  );
}

function TabSelectiveDisclosure({ address }: { address: string }) {
  return (
    <div className="space-y-4">
      <p className="text-xs text-mempool-text-dim">
        Generate a Merkle proof for a single item in your profile. The proof
        lets a third party verify that specific item without learning anything
        about other items in the same facet.
      </p>
      <DisclosureSection
        address={address}
        kind="post"
        title="Social Posts"
        indexLabel="post index"
        paramKey="post_index"
        rpcMethod="disclose_post"
      />
      <DisclosureSection
        address={address}
        kind="cert"
        title="Professional Certifications"
        indexLabel="cert index"
        paramKey="cert_index"
        rpcMethod="disclose_cert"
      />
      <DisclosureSection
        address={address}
        kind="work"
        title="Cultural Works"
        indexLabel="work index"
        paramKey="work_index"
        rpcMethod="disclose_work"
      />
    </div>
  );
}

// ── Tab 4: MiCA Compliance ────────────────────────────────────────────────────

function TabMiCA({ address }: { address: string }) {
  const [data, setData] = useState<MicaDiscloseResult | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!address) return;
    setLoading(true);
    setError(null);
    rpc
      .micaDisclose(address)
      .then((r) => {
        if (isMicaDiscloseResult(r)) setData(r);
      })
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : String(e));
      })
      .finally(() => setLoading(false));
  }, [address]);

  if (loading) return <LoadingSpinner />;
  if (error) return <p className="text-red-400 text-sm">{error}</p>;

  return (
    <div className="space-y-4">
      {/* Summary */}
      <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4 flex flex-wrap gap-6">
        <div>
          <span className="text-xs text-mempool-text-dim block mb-1">MiCA Issuer</span>
          <Badge
            active={data?.is_mica_issuer ?? false}
            label={data?.is_mica_issuer ? "Yes" : "No"}
          />
        </div>
        <div>
          <span className="text-xs text-mempool-text-dim block mb-1">Risk Category</span>
          <span className={`text-sm font-semibold ${RISK_COLOR[data?.risk_category ?? ""] ?? "text-mempool-text-dim"}`}>
            {data?.risk_category ?? "unknown"}
          </span>
        </div>
        <div>
          <span className="text-xs text-mempool-text-dim block mb-1">Attestations</span>
          <span className="text-sm font-semibold text-mempool-text">
            {data?.attestations.length ?? 0}
          </span>
        </div>
      </div>

      {/* Attestations */}
      {data && data.attestations.length > 0 ? (
        <div className="space-y-3">
          {data.attestations.map((att) => (
            <div
              key={att.signature_hex}
              className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4"
            >
              <div className="flex items-center justify-between mb-2">
                <span className="text-sm font-semibold text-mempool-text capitalize">{att.kind}</span>
                <span className="text-xs text-mempool-text-dim">{ts(att.timestamp)}</span>
              </div>
              <div className="space-y-1 text-xs">
                <div>
                  <span className="text-mempool-text-dim">Issuer DID: </span>
                  <span className="font-mono text-mempool-text break-all">{att.issuer_did}</span>
                </div>
                <div>
                  <span className="text-mempool-text-dim">Signature: </span>
                  <span className="font-mono text-mempool-text break-all">{att.signature_hex}</span>
                </div>
              </div>
              <div className="mt-2">
                <CopyButton
                  text={JSON.stringify(att, null, 2)}
                  label="Copy Attestation"
                  variant="button"
                />
              </div>
            </div>
          ))}
        </div>
      ) : (
        <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4">
          <p className="text-mempool-text-dim text-sm italic">
            No MiCA attestations on record for this address.
          </p>
        </div>
      )}

      <p className="text-xs text-mempool-text-dim">
        MiCA attestations are issued by regulated entities (KYC providers, AML
        checkers) and anchored to your OmniBus ID. They are visible here
        only when marked public in your economic profile.
      </p>
    </div>
  );
}

// ── Tab: Identity Lookup (getidentity) ────────────────────────────────────────

function TabIdentityLookup() {
  const [addr, setAddr] = useState("");
  const [result, setResult] = useState<unknown>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState("");

  const lookup = useCallback(async () => {
    const a = addr.trim();
    if (!a) { setErr("Enter an address"); return; }
    setLoading(true); setErr(""); setResult(null);
    try {
      const r = await rpc.getIdentity(a);
      setResult(r);
    } catch (e) { setErr(String(e)); }
    finally { setLoading(false); }
  }, [addr]);

  const renderField = (key: string, val: unknown) => {
    if (val === null || val === undefined) return null;
    if (typeof val === "object") return null;
    return (
      <div key={key} className="flex justify-between gap-2 text-xs flex-wrap">
        <span className="text-mempool-text-dim">{key}</span>
        <span className="font-mono text-mempool-text break-all text-right max-w-[60%]">{String(val)}</span>
      </div>
    );
  };

  return (
    <div className="space-y-4">
      <p className="text-xs text-mempool-text-dim">
        Full identity snapshot for any address — PQ attestations, EVM links, balance, roles, and name registry.
        Uses <code className="font-mono text-purple-400">getidentity</code>.
      </p>
      <div className="flex gap-2">
        <input
          value={addr}
          onChange={(e) => setAddr(e.target.value)}
          placeholder="ob1q… / 0x… / obk1_…"
          className="flex-1 bg-mempool-bg border border-mempool-border rounded-lg px-3 py-2 text-xs font-mono text-mempool-text"
        />
        <button
          onClick={lookup}
          disabled={loading || !addr}
          className="px-4 py-2 text-xs font-medium bg-mempool-blue/20 hover:bg-mempool-blue/40 text-mempool-blue border border-mempool-blue/30 rounded-lg disabled:opacity-50"
        >
          {loading ? "…" : "Lookup"}
        </button>
      </div>
      {err && <p className="text-xs text-red-400">{err}</p>}
      {result !== null && (
        <div className="rounded-xl border border-mempool-border bg-mempool-bg-elev p-4 space-y-2">
          <h3 className="text-xs font-semibold text-mempool-text-dim uppercase tracking-wider mb-2">Identity Result</h3>
          {typeof result === "object" && result !== null
            ? Object.entries(result as Record<string, unknown>).map(([k, v]) => renderField(k, v))
            : <p className="font-mono text-xs text-mempool-text">{String(result)}</p>
          }
          <details className="mt-2">
            <summary className="text-[10px] text-mempool-text-dim cursor-pointer">Raw JSON</summary>
            <pre className="text-[9px] font-mono text-mempool-text-dim mt-1 overflow-x-auto whitespace-pre-wrap">
              {JSON.stringify(result, null, 2)}
            </pre>
          </details>
        </div>
      )}
    </div>
  );
}

// ── Main page ─────────────────────────────────────────────────────────────────

type TabKey = "did" | "facets" | "disclosure" | "mica" | "lookup";

const TABS: { id: TabKey; label: string }[] = [
  { id: "did",        label: "DID & OBM" },
  { id: "facets",     label: "Facets Overview" },
  { id: "disclosure", label: "Selective Disclosure" },
  { id: "mica",       label: "MiCA Compliance" },
  { id: "lookup",     label: "Identity Lookup" },
];

export function IdentityDIDPage() {
  const wallet = useWallet();
  const [activeTab, setActiveTab] = useState<TabKey>("did");

  if (!wallet?.address) {
    return (
      <div className="flex flex-col items-center justify-center py-16 gap-4">
        <svg
          className="w-12 h-12 text-mempool-text-dim"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          strokeWidth={1.5}
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            d="M15.75 5.25a3 3 0 013 3m3 0a6 6 0 01-7.029 5.912c-.563-.097-1.159.026-1.563.43L10.5 17.25H8.25v2.25H6v2.25H2.25v-2.818c0-.597.237-1.17.659-1.591l6.499-6.499c.404-.404.527-1 .43-1.563A6 6 0 1121.75 8.25z"
          />
        </svg>
        <div className="text-center">
          <p className="text-mempool-text font-semibold mb-1">Wallet not connected</p>
          <p className="text-mempool-text-dim text-sm">
            Connect your wallet to view your OmniBus identity.
          </p>
        </div>
      </div>
    );
  }

  const address = wallet.address;

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4">
        <div className="flex items-start justify-between gap-3 flex-wrap">
          <div>
            <h2 className="text-lg font-bold text-mempool-text mb-1">OmniBus Identity</h2>
            <p className="text-xs text-mempool-text-dim font-mono break-all">{address}</p>
          </div>
          <CopyButton text={address} label="Copy Address" variant="button" />
        </div>
      </div>

      {/* Tab bar */}
      <div className="flex gap-1 flex-wrap">
        {TABS.map((tab) => (
          <button
            key={tab.id}
            onClick={() => setActiveTab(tab.id)}
            className={`px-4 py-2 rounded-lg text-sm font-semibold transition-colors ${
              activeTab === tab.id
                ? "bg-mempool-blue text-white"
                : "bg-mempool-bg-elev text-mempool-text-dim border border-mempool-border hover:text-mempool-text"
            }`}
          >
            {tab.label}
          </button>
        ))}
      </div>

      {/* Tab content */}
      <div>
        {activeTab === "did"        && <TabDIDOBM address={address} />}
        {activeTab === "facets"     && <TabFacets address={address} />}
        {activeTab === "disclosure" && <TabSelectiveDisclosure address={address} />}
        {activeTab === "mica"       && <TabMiCA address={address} />}
        {activeTab === "lookup"     && <TabIdentityLookup />}
      </div>
    </div>
  );
}

export default IdentityDIDPage;
