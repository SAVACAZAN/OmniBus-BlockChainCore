import { useEffect, useState } from "react";
import { midTrunc } from "../../utils/fmt";
import OmniBusRpcClient, { type ApiKeyInfo } from "../../api/rpc-client";
import {
  signCreateApiKeyPayload,
  signRevokeApiKeyPayload,
} from "../../api/exchange-sign";
import { getUnlocked, nextNonce, subscribeWallet } from "../../api/wallet-keystore";

const rpc = new OmniBusRpcClient();

/**
 * API keys live as long as the chain remembers them — server stores
 * SHA256(secret) only, plaintext is shown ONCE at creation. The user
 * must save it; we don't keep it. Same UX as the aweb3 ExchangeDashboard
 * `user_create_api_key` flow.
 */
export function ApiKeysPanel() {
  const [, force] = useState(0);
  useEffect(() => subscribeWallet(() => force((n) => n + 1)), []);
  const u = getUnlocked();

  const [keys, setKeys] = useState<ApiKeyInfo[]>([]);
  const [loading, setLoading] = useState(false);
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [reveal, setReveal] = useState<{ keyId: string; secret: string } | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!u) {
      setKeys([]);
      return;
    }
    let cancelled = false;
    setLoading(true);
    rpc.exchangeListApiKeys(u.address).then((list) => {
      if (!cancelled) {
        setKeys(list);
        setLoading(false);
      }
    });
    return () => {
      cancelled = true;
    };
  }, [u?.address]);

  const refresh = async () => {
    if (!u) return;
    const list = await rpc.exchangeListApiKeys(u.address);
    setKeys(list);
  };

  const create = async () => {
    if (!u) return;
    setErr(null);
    setReveal(null);
    if (!name.trim()) {
      setErr("Name required");
      return;
    }
    setBusy(true);
    try {
      const nonce = nextNonce();
      const { signature, publicKey } = signCreateApiKeyPayload({
        privateKeyHex: u.privateKey,
        name: name.trim(),
        owner: u.address,
        nonce,
      });
      const r = await rpc.exchangeCreateApiKey({
        owner: u.address,
        name: name.trim(),
        nonce,
        signature,
        publicKey,
      });
      setReveal({ keyId: r.keyId, secret: r.secret });
      setName("");
      await refresh();
    } catch (e: any) {
      setErr(e?.message || "Create failed");
    } finally {
      setBusy(false);
    }
  };

  const revoke = async (keyId: string) => {
    if (!u) return;
    if (!confirm(`Revoke ${keyId}? This cannot be undone.`)) return;
    setErr(null);
    try {
      const nonce = nextNonce();
      const { signature, publicKey } = signRevokeApiKeyPayload({
        privateKeyHex: u.privateKey,
        keyId,
        owner: u.address,
        nonce,
      });
      await rpc.exchangeRevokeApiKey({
        owner: u.address,
        keyId,
        nonce,
        signature,
        publicKey,
      });
      await refresh();
    } catch (e: any) {
      setErr(e?.message || "Revoke failed");
    }
  };

  if (!u) {
    return (
      <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4">
        <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider mb-2">
          API keys
        </h3>
        <p className="text-xs text-mempool-text-dim">Connect a wallet to manage keys.</p>
      </div>
    );
  }

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg-elev p-4 space-y-3">
      <h3 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
        API keys for {midTrunc(u.address, 10, 6)}
      </h3>

      <div className="flex gap-2">
        <input
          type="text"
          placeholder="Key name (e.g. trading-bot)"
          value={name}
          onChange={(e) => setName(e.target.value)}
          maxLength={32}
          className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-1.5 text-mempool-text text-xs focus:outline-none focus:border-mempool-blue"
        />
        <button
          onClick={create}
          disabled={busy || !name.trim()}
          className="px-3 py-1.5 text-xs rounded bg-mempool-blue hover:bg-blue-600 disabled:bg-mempool-bg-elev disabled:text-mempool-text-dim text-white"
        >
          {busy ? "Creating…" : "Generate"}
        </button>
      </div>

      {reveal && (
        <div className="rounded-lg border border-yellow-500/40 bg-yellow-500/10 p-3 text-xs space-y-2">
          <div className="font-semibold text-yellow-200">
            ⚠ Save this secret now — it will NEVER be shown again
          </div>
          <div>
            <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Key ID</div>
            <div className="font-mono text-mempool-text break-all">{reveal.keyId}</div>
          </div>
          <div>
            <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Secret</div>
            <div className="font-mono text-mempool-text break-all">{reveal.secret}</div>
          </div>
          <div className="flex gap-2">
            <button
              onClick={() => navigator.clipboard.writeText(reveal.secret)}
              className="px-2 py-1 text-[11px] rounded bg-mempool-bg-elev hover:bg-mempool-bg text-mempool-text-dim hover:text-mempool-text"
            >
              Copy secret
            </button>
            <button
              onClick={() => setReveal(null)}
              className="px-2 py-1 text-[11px] rounded bg-mempool-bg-elev hover:bg-mempool-bg text-mempool-text-dim hover:text-mempool-text"
            >
              I saved it
            </button>
          </div>
        </div>
      )}

      {err && (
        <div className="text-[11px] text-red-300">{err}</div>
      )}

      <div className="space-y-1">
        {loading ? (
          <p className="text-xs text-mempool-text-dim">Loading…</p>
        ) : keys.length === 0 ? (
          <p className="text-xs text-mempool-text-dim">No API keys yet.</p>
        ) : (
          <>
            <div className="grid grid-cols-12 gap-1 text-[10px] uppercase tracking-wider text-mempool-text-dim px-1">
              <span className="col-span-3">Name</span>
              <span className="col-span-5">Key ID</span>
              <span className="col-span-2 text-right">Created</span>
              <span className="col-span-2 text-right">Action</span>
            </div>
            {keys.map((k) => (
              <div
                key={k.keyId}
                className={`grid grid-cols-12 gap-1 text-xs py-1 px-1 rounded ${
                  k.revoked ? "opacity-40" : "hover:bg-mempool-bg/40"
                }`}
              >
                <span className="col-span-3 text-mempool-text">{k.name}</span>
                <span className="col-span-5 font-mono text-mempool-text-dim truncate" title={k.keyId}>
                  {k.keyId}
                </span>
                <span className="col-span-2 text-right text-mempool-text-dim">
                  {new Date(k.createdMs).toLocaleDateString()}
                </span>
                <span className="col-span-2 text-right">
                  {k.revoked ? (
                    <span className="text-[10px] text-red-300">revoked</span>
                  ) : (
                    <button
                      onClick={() => revoke(k.keyId)}
                      className="px-2 py-0.5 rounded text-[10px] bg-red-500/20 hover:bg-red-500/40 text-red-200"
                    >
                      Revoke
                    </button>
                  )}
                </span>
              </div>
            ))}
          </>
        )}
      </div>
    </div>
  );
}
