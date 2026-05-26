import { useEffect, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import { getUnlocked, subscribeWallet } from "../../api/wallet-keystore";
import { KycVerifyFlow } from "./KycVerifyFlow";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsNewBlockEvent } from "../../types";

const rpc = new OmniBusRpcClient();

const TIERS = [
  {
    level: 1 as const,
    name: "Starter",
    desc: "Name + date of birth + country of residence.",
    requirements: ["Full legal name", "Date of birth", "Country of residence"],
    unlocks: ["Withdraw real OMNI up to 100/24h", "Place orders > 1000 OMNI notional"],
    biometric: false,
  },
  {
    level: 2 as const,
    name: "Verified",
    desc: "Government-issued photo ID + selfie liveness check.",
    requirements: ["Passport / National ID / Driving license", "Selfie with liveness (blink + smile)"],
    unlocks: ["Withdraw up to 1000 OMNI/24h", "Premium .omnibus names (≤3 chars)"],
    biometric: true,
  },
  {
    level: 3 as const,
    name: "Pro",
    desc: "Proof of address + source of funds.",
    requirements: ["Utility bill or bank statement (< 90 days)", "Source of funds declaration"],
    unlocks: ["Unlimited withdraw", "API access for institutional accounts"],
    biometric: false,
  },
];

/**
 * KYC tier panel — Kraken/LCX-style 3-tier ladder.
 *
 * On chain only the SIGNED ATTESTATION lives (level + issuer + expiry +
 * signature). All PII (name, ID image, selfie, etc.) goes through the
 * issuer's pipeline (off-chain) and is processed entirely in the browser
 * here on testnet (face-api.js + form data, never leaves your machine).
 *
 * On testnet the issuer is the founder's wallet at registrar slot 4
 * (`kyc.omnibus`). On mainnet you can hand the issuer's private key to
 * a real KYC provider (Sumsub/Onfido) without changing anything else.
 */
export function KycPanel() {
  const [, force] = useState(0);
  useEffect(() => subscribeWallet(() => force((n) => n + 1)), []);
  const u = getUnlocked();

  const [status, setStatus] = useState<{
    address: string;
    level: 0 | 1 | 2 | 3;
    label: string;
    issuer?: string;
    expires?: number;
  } | null>(null);
  const [verifyTier, setVerifyTier] = useState<1 | 2 | 3 | null>(null);
  const [issuers, setIssuers] = useState<Array<{ address: string; role: string; slot: number }>>([]);

  useEffect(() => {
    let cancelled = false;
    rpc.request_raw("kyc_listIssuers", [])
      .then((r) => {
        if (!cancelled && Array.isArray(r)) {
          setIssuers(r as Array<{ address: string; role: string; slot: number }>);
        }
      })
      .catch(() => {});
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    if (!u) {
      setStatus(null);
      return;
    }
    let cancelled = false;
    const refresh = async () => {
      const r = await rpc.kycGetStatus(u.address);
      if (!cancelled) setStatus(r);
    };
    void refresh();
    // KYC status changes are rare but critical — use new_block for instant
    // notification when an attestation lands on chain.
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", () => { void refresh(); });
    const id = setInterval(() => { void refresh(); }, 60_000);
    return () => { cancelled = true; clearInterval(id); unsub(); };
  }, [u?.address]);

  if (!u) {
    return (
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
        <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider mb-2">
          KYC verification
        </h3>
        <p className="text-xs text-mempool-text-dim">Connect a wallet to manage KYC.</p>
      </div>
    );
  }

  if (verifyTier !== null) {
    return (
      <KycVerifyFlow
        tier={verifyTier}
        onClose={() => setVerifyTier(null)}
        onAttested={async () => {
          // Re-fetch status after attestation lands.
          if (u) setStatus(await rpc.kycGetStatus(u.address));
          setVerifyTier(null);
        }}
      />
    );
  }

  const currentLevel = status?.level ?? 0;
  const expiresStr =
    status?.expires && status.expires > 0
      ? new Date(status.expires).toLocaleDateString()
      : null;

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 space-y-3">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          KYC verification
        </h3>
        <KycBadge level={currentLevel} />
      </div>

      <p className="text-[11px] text-mempool-text-dim leading-relaxed">
        KYC is <strong>voluntary</strong> on testnet — it gives you a public
        badge and unlocks higher withdraw limits on mainnet. PII (real name,
        ID image, selfie) <strong>never leaves your browser</strong> on
        testnet — only the signed attestation lives on chain.
      </p>

      {status && currentLevel > 0 && (
        <div className="rounded border border-green-500/30 bg-green-500/5 p-2 text-[11px] text-green-200">
          You are currently verified at <strong>Tier {currentLevel} — {status.label}</strong>
          {expiresStr && <> · expires {expiresStr}</>}
          {status.issuer && (
            <div className="font-mono text-[10px] text-mempool-text-dim mt-1 truncate">
              issuer: {status.issuer}
            </div>
          )}
        </div>
      )}

      <div className="space-y-2">
        {TIERS.map((tier) => {
          const reached = currentLevel >= tier.level;
          const next = currentLevel + 1 === tier.level;
          return (
            <div
              key={tier.level}
              className={`rounded border p-3 ${
                reached
                  ? "border-green-500/30 bg-green-500/5"
                  : next
                  ? "border-mempool-blue/40 bg-mempool-blue/5"
                  : "border-mempool-border bg-mempool-bg/40"
              }`}
            >
              <div className="flex items-center justify-between mb-1">
                <div className="flex items-center gap-2">
                  <span className="text-xs font-semibold text-mempool-text">
                    Tier {tier.level} — {tier.name}
                  </span>
                  {reached && <span className="text-[10px] text-green-300">✓ verified</span>}
                  {tier.biometric && (
                    <span className="text-[10px] text-yellow-300">📸 biometric</span>
                  )}
                </div>
                {!reached && next && (
                  <button
                    onClick={() => setVerifyTier(tier.level)}
                    className="px-2 py-0.5 rounded text-[11px] bg-mempool-blue hover:bg-blue-600 text-white"
                  >
                    Verify
                  </button>
                )}
              </div>
              <p className="text-[11px] text-mempool-text-dim mb-1.5">{tier.desc}</p>
              <div className="grid grid-cols-2 gap-x-3 gap-y-1 text-[10px]">
                <div>
                  <div className="text-mempool-text-dim mb-0.5">Requires</div>
                  <ul className="text-mempool-text space-y-0.5">
                    {tier.requirements.map((r) => (
                      <li key={r}>· {r}</li>
                    ))}
                  </ul>
                </div>
                <div>
                  <div className="text-mempool-text-dim mb-0.5">Unlocks</div>
                  <ul className="text-mempool-text space-y-0.5">
                    {tier.unlocks.map((r) => (
                      <li key={r}>· {r}</li>
                    ))}
                  </ul>
                </div>
              </div>
            </div>
          );
        })}
      </div>

      {issuers.length > 0 && (
        <div className="mt-3 pt-3 border-t border-mempool-border">
          <h4 className="text-[10px] uppercase tracking-wider text-mempool-text-dim mb-2">Registered KYC Issuers</h4>
          <div className="space-y-1">
            {issuers.map((iss) => (
              <div key={iss.address} className="flex items-center gap-2 text-[11px]">
                <span className="text-mempool-text-dim">·</span>
                <span className="font-mono text-mempool-text truncate">{iss.address}</span>
                <span className="text-mempool-blue shrink-0">{iss.role}</span>
                <span className="text-mempool-text-dim shrink-0">slot {iss.slot}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      <KycStatusLookup />
    </div>
  );
}

function KycStatusLookup() {
  const [address, setAddress] = useState("");
  const [status, setStatus] = useState<{
    address: string; level: number; label: string;
    issuer: string; issued: number; expires: number;
  } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const onLookup = async () => {
    if (!address) return;
    setLoading(true);
    setErr(null);
    setStatus(null);
    try {
      const r = (await rpc.request_raw("kyc_getStatus", [{ address }])) as typeof status;
      setStatus(r);
    } catch (e: any) {
      setErr(e?.message ?? String(e));
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="mt-4 pt-4 border-t border-mempool-border space-y-3">
      <h4 className="text-[10px] uppercase tracking-wider text-mempool-text-dim">KYC Status Lookup</h4>
      <div className="flex gap-2 items-end">
        <div className="flex-1">
          <input
            value={address}
            onChange={(e) => setAddress(e.target.value)}
            className="w-full bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
            placeholder="ob1q… address"
            onKeyDown={(e) => e.key === "Enter" && onLookup()}
          />
        </div>
        <button
          onClick={onLookup}
          disabled={loading || !address}
          className="px-3 py-1.5 text-xs bg-mempool-blue/20 hover:bg-mempool-blue/30 text-mempool-blue border border-mempool-blue/30 rounded disabled:opacity-50 whitespace-nowrap"
        >
          {loading ? "…" : "Check"}
        </button>
      </div>
      {err && <p className="text-[11px] text-red-400">{err}</p>}
      {status && (
        <div className="grid grid-cols-2 gap-1.5 text-[11px]">
          {[
            ["Level", `L${status.level} ${status.label}`],
            ["Issuer", status.issuer ? status.issuer.slice(0, 16) + "…" : "—"],
            ["Issued", status.issued ? new Date(status.issued * 1000).toLocaleDateString() : "—"],
            ["Expires", status.expires ? new Date(status.expires * 1000).toLocaleDateString() : "—"],
          ].map(([k, v]) => (
            <div key={k} className="bg-mempool-bg rounded p-1.5">
              <div className="text-mempool-text-dim text-[9px]">{k}</div>
              <div className="font-mono text-mempool-text">{v}</div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

export function KycBadge({ level }: { level: 0 | 1 | 2 | 3 }) {
  if (level === 0) {
    return (
      <span className="px-2 py-0.5 rounded text-[10px] bg-mempool-bg-elev text-mempool-text-dim">
        No KYC
      </span>
    );
  }
  const colors = ["", "bg-blue-500/20 text-blue-200", "bg-green-500/20 text-green-200", "bg-purple-500/20 text-purple-200"];
  const labels = ["", "Starter", "Verified", "Pro"];
  return (
    <span className={`px-2 py-0.5 rounded text-[10px] font-semibold ${colors[level]}`}>
      🛡 KYC L{level} · {labels[level]}
    </span>
  );
}
