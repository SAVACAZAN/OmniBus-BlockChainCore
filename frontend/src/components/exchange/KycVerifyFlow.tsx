import { useEffect, useRef, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import { signKycAttestation } from "../../api/exchange-sign";
import { useWallet } from "../../api/use-wallet";

const rpc = new OmniBusRpcClient();

interface Props {
  tier: 1 | 2 | 3;
  onClose: () => void;
  onAttested: () => void;
}

type Step =
  | { kind: "personal" }
  | { kind: "document" }
  | { kind: "selfie" }
  | { kind: "review" }
  | { kind: "submitting" }
  | { kind: "done"; level: 1 | 2 | 3 };

/**
 * KYC verification wizard — testnet flow.
 *
 * On testnet the chain accepts an attestation signed by the configured
 * issuer wallet (registrar slot 4). On the founder's local node the
 * issuer key is the same mnemonic the user is currently unlocking with,
 * so the wizard can self-sign the attestation as a demo. On a real
 * mainnet deployment the issuer key sits in a separate vault — this
 * component would POST to the issuer's HTTPS API instead and wait for
 * the signed attestation to come back.
 *
 * What stays in the browser (never sent anywhere):
 *   - personal data (name, DOB, country)
 *   - the photographed ID
 *   - the selfie video / liveness samples
 *
 * What goes on chain (public, but PII-free):
 *   - the attestation: {address, level, issuer, issued, expires, sig}
 */
export function KycVerifyFlow({ tier, onClose, onAttested }: Props) {
  // Subscribe to the global keystore — if the user disconnects mid-flow the
  // component re-renders and the submit step bails out instead of trying to
  // sign with a stale snapshot.
  const u = useWallet();
  const [step, setStep] = useState<Step>({ kind: "personal" });
  const [err, setErr] = useState<string | null>(null);

  // Personal data — kept local
  const [fullName, setFullName] = useState("");
  const [dob, setDob] = useState("");
  const [country, setCountry] = useState("");

  // Document — file kept local, only checked client-side
  const [docFile, setDocFile] = useState<File | null>(null);
  const [docPreview, setDocPreview] = useState<string | null>(null);

  // Selfie liveness — webcam stream + mock checks
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const [stream, setStream] = useState<MediaStream | null>(null);
  const [checks, setChecks] = useState({ blink: false, smile: false, turn: false });
  const [livenessScore, setLivenessScore] = useState(0);

  // Cleanup webcam when leaving the selfie step.
  useEffect(() => {
    return () => {
      if (stream) {
        stream.getTracks().forEach((t) => t.stop());
      }
    };
  }, [stream]);

  const startCamera = async () => {
    setErr(null);
    try {
      const s = await navigator.mediaDevices.getUserMedia({
        video: { width: 640, height: 480, facingMode: "user" },
        audio: false,
      });
      setStream(s);
      if (videoRef.current) {
        videoRef.current.srcObject = s;
      }
    } catch (e: any) {
      setErr(e?.message || "Could not access camera");
    }
  };

  // Mock liveness — for testnet we just walk through 3 prompts with a
  // 1.5s delay between, the user clicks "I did it". On mainnet you'd
  // wire face-api.js (or mediapipe) to detect blink / smile / head turn
  // automatically and only enable the next step when detected.
  const markCheck = (which: "blink" | "smile" | "turn") => {
    setChecks((c) => {
      const next = { ...c, [which]: true };
      const score = (next.blink ? 33 : 0) + (next.smile ? 33 : 0) + (next.turn ? 34 : 0);
      setLivenessScore(score);
      return next;
    });
  };

  const onPickDoc = (f: File | null) => {
    if (!f) {
      setDocFile(null);
      setDocPreview(null);
      return;
    }
    if (f.size > 8 * 1024 * 1024) {
      setErr("Document must be < 8 MB");
      return;
    }
    setErr(null);
    setDocFile(f);
    const reader = new FileReader();
    reader.onload = (e) => setDocPreview((e.target?.result as string) || null);
    reader.readAsDataURL(f);
  };

  const submit = async () => {
    if (!u) {
      setErr("Wallet not connected");
      return;
    }
    setErr(null);
    setStep({ kind: "submitting" });
    try {
      // Issuer key on the founder's testnet node = the local wallet's
      // mnemonic-derived slot 4 key. The frontend doesn't have access
      // to that wallet — but the founder unlocked with the same
      // mnemonic, so we can re-derive slot 4 here as a demo. NOTE: this
      // self-signed flow is testnet-only. On mainnet the user's wallet
      // doesn't have the issuer key and would call out to a real KYC
      // provider instead.
      const issuers = await rpc.kycListIssuers();
      const issuer = issuers[0];
      if (!issuer) throw new Error("No KYC issuer registered on this node");

      const issuedMs = Date.now();
      const expiresMs = issuedMs + 365 * 24 * 60 * 60 * 1000; // 1 year

      // The trick for testnet: the demo issuer key is the SAME mnemonic
      // the user unlocked with. So we already have the privkey for slot
      // 0 (the mining wallet). The chain expects slot 4. The founder's
      // local node would normally do this in a CLI tool that has access
      // to the mnemonic. As a frontend demo we self-sign with whatever
      // privkey is unlocked — the chain rejects this if the address
      // doesn't match the issuer, which is the right behavior.
      const { signature, publicKey } = signKycAttestation({
        issuerPrivateKeyHex: u.privateKey,
        subjectAddress: u.address,
        level: tier,
        issuerAddress: issuer.address,
        issuedMs,
        expiresMs,
      });

      await rpc.kycAttest({
        address: u.address,
        level: tier,
        issued: issuedMs,
        expires: expiresMs,
        signature,
        publicKey,
      });

      setStep({ kind: "done", level: tier });
      onAttested();
    } catch (e: any) {
      setErr(
        e?.message?.includes("not the registered KYC issuer")
          ? "Self-attestation failed — your wallet is not the KYC issuer (slot 4 = kyc.omnibus). " +
              "On testnet, ask the operator to run this command from a machine that has the founder mnemonic:\n\n" +
              `  omnibus-cli mica attest kyc --self --address ${u.address} --yes\n\n` +
              "On mainnet, a separate verification service holds the issuer key and issues attestations."
          : e?.message || "Attestation failed",
      );
      setStep({ kind: "review" });
    }
  };

  const personalDone = fullName.trim().length >= 2 && dob.length >= 8 && country.trim().length >= 2;
  const docDone = !!docFile;
  const selfieDone = livenessScore >= 99;

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 space-y-4">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          KYC verification — Tier {tier}
        </h3>
        <button
          onClick={onClose}
          className="text-xs text-mempool-text-dim hover:text-red-300"
        >
          ✕ Close
        </button>
      </div>

      {/* Step indicator */}
      <div className="flex items-center gap-1 text-[10px]">
        {(["personal", "document", "selfie", "review"] as const).map((s, i) => {
          const idx = ["personal", "document", "selfie", "review"].indexOf(step.kind);
          const isCurrent = step.kind === s;
          const isDone = idx > i || step.kind === "done";
          return (
            <div key={s} className="flex items-center gap-1">
              <span
                className={`px-2 py-0.5 rounded ${
                  isCurrent
                    ? "bg-mempool-blue text-white"
                    : isDone
                    ? "bg-green-500/30 text-green-200"
                    : "bg-mempool-bg-elev text-mempool-text-dim"
                }`}
              >
                {i + 1}. {s}
              </span>
              {i < 3 && <span className="text-mempool-text-dim">→</span>}
            </div>
          );
        })}
      </div>

      {step.kind === "personal" && (
        <div className="space-y-2">
          <div>
            <label className="block text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">
              Full legal name
            </label>
            <input
              type="text"
              value={fullName}
              onChange={(e) => setFullName(e.target.value)}
              placeholder="As on your ID"
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text text-xs focus:outline-none focus:border-mempool-blue"
            />
          </div>
          <div>
            <label className="block text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">
              Date of birth
            </label>
            <input
              type="date"
              value={dob}
              onChange={(e) => setDob(e.target.value)}
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text text-xs focus:outline-none focus:border-mempool-blue"
            />
          </div>
          <div>
            <label className="block text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">
              Country of residence
            </label>
            <input
              type="text"
              value={country}
              onChange={(e) => setCountry(e.target.value)}
              placeholder="e.g. Romania"
              className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text text-xs focus:outline-none focus:border-mempool-blue"
            />
          </div>
          <p className="text-[10px] text-mempool-text-dim">
            🔒 This data stays in your browser — it is NOT sent to the chain.
            Only the attestation level (1/2/3) and the issuer signature land on chain.
          </p>
          <div className="flex justify-end gap-2">
            {tier > 1 ? (
              <button
                onClick={() => setStep({ kind: "document" })}
                disabled={!personalDone}
                className="px-3 py-1.5 text-xs font-semibold rounded bg-mempool-blue hover:bg-blue-600 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
              >
                Next: document →
              </button>
            ) : (
              <button
                onClick={() => setStep({ kind: "review" })}
                disabled={!personalDone}
                className="px-3 py-1.5 text-xs font-semibold rounded bg-mempool-blue hover:bg-blue-600 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
              >
                Next: review →
              </button>
            )}
          </div>
        </div>
      )}

      {step.kind === "document" && (
        <div className="space-y-2">
          <p className="text-[11px] text-mempool-text-dim">
            Upload a photo or scan of your government-issued ID (passport, national ID,
            or driving license). PNG / JPG, max 8 MB. Stays in your browser.
          </p>
          <input
            type="file"
            accept="image/*"
            onChange={(e) => onPickDoc(e.target.files?.[0] ?? null)}
            className="w-full text-xs text-mempool-text-dim file:mr-3 file:px-3 file:py-1.5 file:rounded file:border-0 file:bg-mempool-blue file:text-white file:cursor-pointer"
          />
          {docPreview && (
            <img
              src={docPreview}
              alt="ID preview"
              className="max-h-48 rounded border border-mempool-border"
            />
          )}
          <div className="flex justify-between gap-2">
            <button
              onClick={() => setStep({ kind: "personal" })}
              className="px-3 py-1.5 text-xs rounded bg-mempool-bg-elev hover:bg-mempool-bg text-mempool-text-dim"
            >
              ← Back
            </button>
            {tier >= 2 ? (
              <button
                onClick={() => setStep({ kind: "selfie" })}
                disabled={!docDone}
                className="px-3 py-1.5 text-xs font-semibold rounded bg-mempool-blue hover:bg-blue-600 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
              >
                Next: selfie →
              </button>
            ) : (
              <button
                onClick={() => setStep({ kind: "review" })}
                disabled={!docDone}
                className="px-3 py-1.5 text-xs font-semibold rounded bg-mempool-blue hover:bg-blue-600 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
              >
                Next: review →
              </button>
            )}
          </div>
        </div>
      )}

      {step.kind === "selfie" && (
        <div className="space-y-2">
          <p className="text-[11px] text-mempool-text-dim">
            Liveness check — do these 3 things in front of the camera. Video
            stays in your browser; only a liveness score lands on chain.
          </p>
          {!stream ? (
            <button
              onClick={startCamera}
              className="w-full px-3 py-2 text-xs rounded bg-mempool-blue hover:bg-blue-600 text-white"
            >
              📸 Start camera
            </button>
          ) : (
            <video
              ref={videoRef}
              autoPlay
              playsInline
              muted
              className="w-full max-h-72 bg-black rounded border border-mempool-border"
            />
          )}
          <div className="grid grid-cols-3 gap-2 text-[11px]">
            <button
              onClick={() => markCheck("blink")}
              disabled={!stream || checks.blink}
              className={`px-2 py-2 rounded ${
                checks.blink
                  ? "bg-green-500/30 text-green-200"
                  : "bg-mempool-bg-elev hover:bg-mempool-bg text-mempool-text"
              } disabled:opacity-60`}
            >
              {checks.blink ? "✓ Blinked" : "1. Blink"}
            </button>
            <button
              onClick={() => markCheck("smile")}
              disabled={!stream || checks.smile}
              className={`px-2 py-2 rounded ${
                checks.smile
                  ? "bg-green-500/30 text-green-200"
                  : "bg-mempool-bg-elev hover:bg-mempool-bg text-mempool-text"
              } disabled:opacity-60`}
            >
              {checks.smile ? "✓ Smiled" : "2. Smile"}
            </button>
            <button
              onClick={() => markCheck("turn")}
              disabled={!stream || checks.turn}
              className={`px-2 py-2 rounded ${
                checks.turn
                  ? "bg-green-500/30 text-green-200"
                  : "bg-mempool-bg-elev hover:bg-mempool-bg text-mempool-text"
              } disabled:opacity-60`}
            >
              {checks.turn ? "✓ Turned" : "3. Turn head"}
            </button>
          </div>
          <div className="text-[10px] text-mempool-text-dim flex items-center justify-between">
            <span>Liveness score: {livenessScore} / 100</span>
            <span>(testnet: manual confirmation; mainnet: face-api.js auto-detect)</span>
          </div>
          <div className="flex justify-between gap-2">
            <button
              onClick={() => setStep({ kind: "document" })}
              className="px-3 py-1.5 text-xs rounded bg-mempool-bg-elev hover:bg-mempool-bg text-mempool-text-dim"
            >
              ← Back
            </button>
            <button
              onClick={() => setStep({ kind: "review" })}
              disabled={!selfieDone}
              className="px-3 py-1.5 text-xs font-semibold rounded bg-mempool-blue hover:bg-blue-600 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
            >
              Next: review →
            </button>
          </div>
        </div>
      )}

      {step.kind === "review" && (
        <div className="space-y-2">
          <p className="text-[11px] text-mempool-text-dim">
            About to submit a Tier {tier} attestation request for{" "}
            <span className="font-mono text-mempool-text">{u?.address}</span>.
            The chain will record the attestation only — your personal data never leaves
            this browser.
          </p>
          <div className="rounded border border-mempool-border/60 bg-mempool-bg/40 p-2 space-y-1 text-[11px] font-mono">
            <div>name: {fullName || "—"}</div>
            <div>dob: {dob || "—"}</div>
            <div>country: {country || "—"}</div>
            {tier > 1 && <div>document: {docFile ? `${docFile.name} (${(docFile.size / 1024).toFixed(0)} KB)` : "—"}</div>}
            {tier >= 2 && <div>liveness score: {livenessScore} / 100</div>}
          </div>
          <div className="flex justify-between gap-2">
            <button
              onClick={() =>
                setStep({
                  kind: tier >= 2 ? "selfie" : tier > 1 ? "document" : "personal",
                })
              }
              className="px-3 py-1.5 text-xs rounded bg-mempool-bg-elev hover:bg-mempool-bg text-mempool-text-dim"
            >
              ← Back
            </button>
            <button
              onClick={submit}
              className="px-3 py-1.5 text-xs font-semibold rounded bg-mempool-blue hover:bg-blue-600 text-white"
            >
              Submit & sign attestation
            </button>
          </div>
        </div>
      )}

      {step.kind === "submitting" && (
        <div className="p-4 text-center text-mempool-text-dim text-sm">
          Submitting attestation on chain…
        </div>
      )}

      {step.kind === "done" && (
        <div className="p-3 rounded border border-green-500/30 bg-green-500/5 text-[11px] text-green-200">
          ✓ Verified at Tier {step.level}. The badge will show next to your address everywhere.
          <button
            onClick={onClose}
            className="ml-2 underline text-green-300 hover:text-green-100"
          >
            Close
          </button>
        </div>
      )}

      {err && (
        <div className="p-2 rounded bg-red-500/10 border border-red-500/30 text-[11px] text-red-300 break-words whitespace-pre-wrap font-mono">
          {err}
        </div>
      )}
    </div>
  );
}
