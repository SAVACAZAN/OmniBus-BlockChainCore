/**
 * MicaPanel.tsx — MiCA (EU Markets in Crypto-Assets) compliance subpanel.
 *
 * Lives at the bottom of EconomicTab. Shows three pillars:
 *   • KYC status — verified or not, with valid_until expiry
 *   • AML / sanctions screening result
 *   • Optional "MiCA issuer" declaration with white_paper_hash + risk
 *
 * "Attest" calls `mica_attest`; "View disclosures" calls `mica_disclose`.
 */

import { useEffect, useState } from "react";
import { rpc, type MicaAttestation, type MicaDisclosure } from "../../api/rpc-client";
import {
  signMicaAttestPayload,
} from "../../api/exchange-sign";
import { nextNonce } from "../../api/wallet-keystore";


function fmtDate(ts?: number): string {
  if (!ts) return "—";
  try {
    return new Date(ts).toISOString().slice(0, 10);
  } catch {
    return "—";
  }
}

function StatusBadge({ att }: { att?: MicaAttestation }) {
  if (!att) {
    return <span className="text-mempool-red">✕ Not verified</span>;
  }
  const ok = att.status === "valid";
  return (
    <span className={ok ? "text-mempool-green" : "text-mempool-red"}>
      {ok ? "✓ Valid" : "✕ " + att.status}
      <span className="text-mempool-text-dim text-[10px] ml-1">
        (until {fmtDate(att.valid_until)})
      </span>
    </span>
  );
}

export function MicaPanel({
  address,
  privateKey,
  editable,
}: {
  address: string;
  privateKey: string | null;
  editable: boolean;
}) {
  const [discl, setDiscl] = useState<MicaDisclosure | null>(null);
  const [loading, setLoading] = useState(false);
  const [showModal, setShowModal] = useState(false);
  const [issuerToggle, setIssuerToggle] = useState(false);
  const [whitePaperHash, setWhitePaperHash] = useState("");
  const [riskCategory, setRiskCategory] = useState<"low" | "medium" | "high">("low");
  const [attesting, setAttesting] = useState(false);
  const [attestMsg, setAttestMsg] = useState<string | null>(null);
  const [attestErr, setAttestErr] = useState<string | null>(null);

  const refresh = async () => {
    setLoading(true);
    try {
      const d = await rpc.micaDisclose(address);
      setDiscl(d);
      if (d?.issuer) {
        setIssuerToggle(true);
        setWhitePaperHash(d.issuer.white_paper_hash || "");
        const rc = d.issuer.risk_category;
        if (rc === "low" || rc === "medium" || rc === "high") setRiskCategory(rc);
      }
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (address) refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [address]);

  const attestIssuer = async () => {
    if (!privateKey) return;
    setAttesting(true);
    setAttestMsg(null);
    setAttestErr(null);
    try {
      const nonce = nextNonce();
      const validUntil = Date.now() + 365 * 24 * 3600 * 1000;
      const { signature, publicKey } = signMicaAttestPayload({
        privateKeyHex: privateKey,
        address,
        kind: "issuer",
        validUntil,
        extra: whitePaperHash,
        nonce,
      });
      await rpc.micaAttest({
        address,
        kind: "issuer",
        valid_until: validUntil,
        white_paper_hash: whitePaperHash,
        risk_category: riskCategory,
        nonce,
        signature,
        publicKey,
      });
      setAttestMsg("MiCA issuer declaration attested");
      await refresh();
    } catch (e: unknown) {
      const m = e instanceof Error ? e.message : String(e);
      setAttestErr(m || "Attest failed");
    } finally {
      setAttesting(false);
    }
  };

  return (
    <div className="mt-6 border-t border-mempool-border pt-4 space-y-3">
      <div className="flex items-center justify-between">
        <h4 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          🇪🇺 MiCA Compliance
        </h4>
        <button
          onClick={() => { refresh(); setShowModal(true); }}
          className="text-xs text-mempool-blue hover:underline"
        >
          View MiCA Disclosures →
        </button>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-2">
        <Pill label="KYC" att={discl?.kyc} />
        <Pill label="AML" att={discl?.aml} />
        <Pill label="Sanctions" att={discl?.sanctions} />
      </div>

      {editable && (
        <div className="bg-mempool-bg border border-mempool-border rounded-lg p-3 space-y-2 mt-2">
          <label className="flex items-center gap-2 text-xs text-mempool-text cursor-pointer">
            <input
              type="checkbox"
              checked={issuerToggle}
              onChange={(e) => setIssuerToggle(e.target.checked)}
            />
            Declare as MiCA Issuer
          </label>

          {issuerToggle && (
            <div className="space-y-2 pl-5">
              <div>
                <label className="text-[10px] text-mempool-text-dim uppercase tracking-wider">
                  White paper hash
                </label>
                <input
                  value={whitePaperHash}
                  onChange={(e) => setWhitePaperHash(e.target.value)}
                  placeholder="SHA256 of MiCA white paper"
                  className="w-full bg-mempool-bg-elev border border-mempool-border rounded px-2 py-1 text-xs font-mono text-mempool-text mt-1"
                />
              </div>
              <div>
                <label className="text-[10px] text-mempool-text-dim uppercase tracking-wider">
                  Risk category
                </label>
                <select
                  value={riskCategory}
                  onChange={(e) =>
                    setRiskCategory(e.target.value as "low" | "medium" | "high")
                  }
                  className="w-full bg-mempool-bg-elev border border-mempool-border rounded px-2 py-1 text-xs text-mempool-text mt-1"
                >
                  <option value="low">Low</option>
                  <option value="medium">Medium</option>
                  <option value="high">High</option>
                </select>
              </div>
              <div className="flex items-center gap-3 pt-1">
                <button
                  onClick={attestIssuer}
                  disabled={!privateKey || attesting || !whitePaperHash}
                  className="bg-mempool-orange hover:bg-mempool-orange/80 disabled:opacity-50 text-white text-xs font-semibold rounded px-3 py-1.5"
                >
                  {attesting ? "Attesting…" : "Attest"}
                </button>
                {attestMsg && <span className="text-xs text-mempool-green">{attestMsg}</span>}
                {attestErr && <span className="text-xs text-mempool-red">{attestErr}</span>}
              </div>
            </div>
          )}
        </div>
      )}

      {showModal && (
        <div
          className="fixed inset-0 z-[200] bg-black/70 flex items-center justify-center p-4"
          onClick={() => setShowModal(false)}
        >
          <div
            className="bg-mempool-bg-elev border border-mempool-border rounded-xl max-w-lg w-full p-5 space-y-3"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between">
              <h5 className="text-sm font-bold text-mempool-text">
                MiCA Disclosures
              </h5>
              <button
                onClick={() => setShowModal(false)}
                className="text-mempool-text-dim hover:text-mempool-text"
              >
                ×
              </button>
            </div>
            {loading && <div className="text-xs text-mempool-text-dim">Loading…</div>}
            {!loading && !discl && (
              <div className="text-xs text-mempool-text-dim">No disclosures on file.</div>
            )}
            {discl && (
              <div className="space-y-3 text-xs">
                <DisclRow label="KYC" att={discl.kyc} />
                <DisclRow label="AML" att={discl.aml} />
                <DisclRow label="Sanctions" att={discl.sanctions} />
                {discl.issuer && (
                  <div className="bg-mempool-bg rounded p-2 border border-mempool-border">
                    <div className="font-semibold text-mempool-text">MiCA Issuer</div>
                    <div className="mt-1 grid grid-cols-2 gap-1 text-mempool-text-dim">
                      <span>Issued:</span>
                      <span>{fmtDate(discl.issuer.issued)}</span>
                      <span>Valid until:</span>
                      <span>{fmtDate(discl.issuer.valid_until)}</span>
                      <span>Status:</span>
                      <span>{discl.issuer.status}</span>
                      <span>Risk:</span>
                      <span>{discl.issuer.risk_category || "—"}</span>
                    </div>
                    {discl.issuer.white_paper_hash && (
                      <div className="mt-1 font-mono break-all text-mempool-text">
                        {discl.issuer.white_paper_hash}
                      </div>
                    )}
                  </div>
                )}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function Pill({ label, att }: { label: string; att?: MicaAttestation }) {
  return (
    <div className="bg-mempool-bg border border-mempool-border rounded-lg p-2">
      <div className="text-[10px] text-mempool-text-dim uppercase tracking-wider">
        {label}
      </div>
      <div className="text-xs mt-0.5">
        <StatusBadge att={att} />
      </div>
    </div>
  );
}

function DisclRow({ label, att }: { label: string; att?: MicaAttestation }) {
  return (
    <div className="flex items-center justify-between bg-mempool-bg rounded p-2 border border-mempool-border">
      <div>
        <div className="font-semibold text-mempool-text">{label}</div>
        <div className="text-mempool-text-dim text-[10px]">
          Issuer: {att?.issuer || "—"}
        </div>
      </div>
      <StatusBadge att={att} />
    </div>
  );
}
