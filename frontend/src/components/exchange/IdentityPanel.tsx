import { useEffect, useState } from "react";
import { rpc } from "../../api/clients/rpc-client";
import { signIdentitySetPayload } from "../../api/sign/exchange-sign";
import { getUnlocked, nextNonce, subscribeWallet } from "../../api/wallet/wallet-keystore";


type Visibility = "public" | "private" | "ens_only";

const VISIBILITY_OPTIONS: Visibility[] = ["public", "ens_only", "private"];

/**
 * Public identity panel.
 *
 * Lets the connected wallet set a nickname + a primary `.omnibus` ENS
 * preference + visibility flag. The chain stores nothing private here —
 * just what the user chose to make public. KYC (real-name verification)
 * is the SEPARATE panel <KycPanel/>.
 */
export function IdentityPanel() {
  const [, force] = useState(0);
  useEffect(() => subscribeWallet(() => force((n) => n + 1)), []);
  const u = getUnlocked();

  const [nickname, setNickname] = useState("");
  const [ens, setEns] = useState("");
  const [visibility, setVisibility] = useState<Visibility>("public");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);

  // Pre-fill from chain when wallet connects.
  useEffect(() => {
    if (!u) {
      setNickname("");
      setEns("");
      setVisibility("public");
      setLoaded(false);
      return;
    }
    let cancelled = false;
    rpc.identityGet(u.address)
      .then((cur) => {
        if (cancelled) return;
        if (cur) {
          setNickname(cur.nickname || "");
          setEns(cur.ens || "");
          setVisibility(cur.visibility);
        }
        setLoaded(true);
      })
      .catch(() => { if (!cancelled) setLoaded(true); });
    return () => { cancelled = true; };
  }, [u?.address]);

  const save = async () => {
    if (!u) return;
    setMsg(null);
    setErr(null);
    if (nickname.length > 32) {
      setErr("Nickname too long (max 32 chars)");
      return;
    }
    // Reject non-printable / quote / unicode early so user gets fast feedback.
    if (!/^[\x20-\x7E]*$/.test(nickname) || /["\\]/.test(nickname)) {
      setErr("Nickname must be printable ASCII (no quotes, no control chars, no unicode)");
      return;
    }
    setBusy(true);
    try {
      const nonce = nextNonce();
      const { signature, publicKey } = signIdentitySetPayload({
        privateKeyHex: u.privateKey,
        address: u.address,
        nickname,
        ens,
        visibility,
        nonce,
      });
      await rpc.identitySet({
        address: u.address,
        nickname,
        ens,
        visibility,
        nonce,
        signature,
        publicKey,
      });
      setMsg("Identity saved on chain");
    } catch (e: any) {
      setErr(e?.message || "Save failed");
    } finally {
      setBusy(false);
    }
  };

  if (!u) {
    return (
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
        <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider mb-2">
          Public identity
        </h3>
        <p className="text-xs text-mempool-text-dim">Connect a wallet to set your public identity.</p>
      </div>
    );
  }

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 space-y-3">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          Public identity
        </h3>
        <span className="text-[10px] text-mempool-text-dim">on-chain · public</span>
      </div>

      <p className="text-[11px] text-mempool-text-dim leading-relaxed">
        This is what other users see in Rich List, Recent Transactions, etc.
        Nothing private (no email, no real name, no docs) — those go in the
        KYC panel and stay off-chain.
      </p>

      <div>
        <label className="block text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">
          Nickname (max 32 ASCII chars)
        </label>
        <input
          type="text"
          maxLength={32}
          value={nickname}
          onChange={(e) => setNickname(e.target.value)}
          placeholder="e.g. Alex or Trader42"
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text font-mono text-xs focus:outline-none focus:border-mempool-blue"
          spellCheck={false}
        />
      </div>

      <div>
        <label className="block text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">
          Primary .omnibus ENS (optional)
        </label>
        <input
          type="text"
          maxLength={64}
          value={ens}
          onChange={(e) => setEns(e.target.value.toLowerCase())}
          placeholder="alex.omnibus"
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-mempool-text font-mono text-xs focus:outline-none focus:border-mempool-blue"
          spellCheck={false}
        />
        <p className="text-[10px] text-mempool-text-dim mt-1">
          Pick which of your registered names is shown by default. Register
          names in the .omnibus tab. You can add multiple names per address;
          this only changes which is the &quot;primary&quot;.
        </p>
      </div>

      <div>
        <label className="block text-[10px] uppercase tracking-wider text-mempool-text-dim mb-1">
          Visibility
        </label>
        <div className="grid grid-cols-3 gap-1 text-[11px]">
          {VISIBILITY_OPTIONS.map((v) => (
            <button
              key={v}
              onClick={() => setVisibility(v)}
              className={`px-2 py-1.5 rounded transition-colors ${
                visibility === v
                  ? "bg-mempool-blue text-white font-semibold"
                  : "bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text"
              }`}
            >
              {v === "public" ? "Public" : v === "ens_only" ? "ENS only" : "Private"}
            </button>
          ))}
        </div>
        <p className="text-[10px] text-mempool-text-dim mt-1.5 leading-relaxed">
          {visibility === "public" && "Everyone sees your nickname + primary ENS next to your address."}
          {visibility === "ens_only" && "Others see only your primary .omnibus ENS — nickname is hidden."}
          {visibility === "private" && "No one sees nickname or ENS associated with this address (you still see it on your own panels)."}
        </p>
      </div>

      <button
        onClick={save}
        disabled={busy || !loaded}
        className="w-full px-3 py-1.5 text-xs font-semibold rounded bg-mempool-blue hover:bg-blue-600 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
      >
        {busy ? "Saving on chain…" : loaded ? "Save identity" : "Loading…"}
      </button>

      {msg && (
        <div className="p-2 rounded bg-green-500/10 border border-green-500/30 text-[11px] text-green-200">{msg}</div>
      )}
      {err && (
        <div className="p-2 rounded bg-red-500/10 border border-red-500/30 text-[11px] text-red-300">{err}</div>
      )}
    </div>
  );
}
