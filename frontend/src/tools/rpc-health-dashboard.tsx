import React, { useCallback, useEffect, useRef, useState } from "react";

// ---------- Types ----------

interface RPCStatus {
  url: string;
  online: boolean;
  blockHeight: number | null;
  peerCount: number | null;
  latencyMs: number;
  lastCheck: string;
  error?: string;
}

interface Props {
  /** RPC endpoint URL (default: http://127.0.0.1:8332) */
  endpoint?: string;
  /** Auto-refresh interval in ms (default: 5000) */
  refreshInterval?: number;
}

// ---------- JSON-RPC helper ----------

async function rpcCall<T = unknown>(
  url: string,
  method: string,
  params: unknown[] = [],
  timeoutMs = 5000
): Promise<{ result?: T; error?: string }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      signal: controller.signal,
    });
    clearTimeout(timer);

    if (!res.ok) {
      return { error: `HTTP ${res.status}` };
    }
    const data = await res.json();
    if (data.error) {
      return { error: data.error.message || "RPC error" };
    }
    return { result: data.result as T };
  } catch (err: unknown) {
    clearTimeout(timer);
    if (err instanceof DOMException && err.name === "AbortError") {
      return { error: "Timeout" };
    }
    return { error: String(err) };
  }
}

// ---------- Component ----------

const RpcHealthDashboard: React.FC<Props> = ({
  endpoint = "http://127.0.0.1:8332",
  refreshInterval = 5000,
}) => {
  const [status, setStatus] = useState<RPCStatus | null>(null);
  const [loading, setLoading] = useState(false);
  const [history, setHistory] = useState<RPCStatus[]>([]);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const checkHealth = useCallback(async () => {
    setLoading(true);
    const start = performance.now();

    // Fetch block height
    const blockRes = await rpcCall<number>(endpoint, "getblockcount");
    // Fetch peer count
    const peerRes = await rpcCall<unknown[]>(endpoint, "getpeers");

    const latency = Math.round(performance.now() - start);
    const online = blockRes.result !== undefined;

    let peerCount: number | null = null;
    if (peerRes.result) {
      if (Array.isArray(peerRes.result)) {
        peerCount = peerRes.result.length;
      } else if (typeof peerRes.result === "number") {
        peerCount = peerRes.result;
      }
    }

    const entry: RPCStatus = {
      url: endpoint,
      online,
      blockHeight: blockRes.result ?? null,
      peerCount,
      latencyMs: latency,
      lastCheck: new Date().toLocaleTimeString(),
      error: online ? undefined : blockRes.error,
    };

    setStatus(entry);
    setHistory((prev) => [...prev.slice(-29), entry]); // keep last 30
    setLoading(false);
  }, [endpoint]);

  // Auto-refresh
  useEffect(() => {
    checkHealth();
    intervalRef.current = setInterval(checkHealth, refreshInterval);
    return () => {
      if (intervalRef.current) clearInterval(intervalRef.current);
    };
  }, [checkHealth, refreshInterval]);

  // ---------- Styles ----------

  const theme = {
    bg: "#0b0c10",
    card: "#1f2833",
    border: "#45a29e",
    accent: "#66fcf1",
    text: "#c5c6c7",
    green: "#66fcf1",
    red: "#ff6b6b",
    yellow: "#feca57",
    dim: "#5c6370",
  };

  const containerStyle: React.CSSProperties = {
    padding: "1.5rem",
    fontFamily: "'JetBrains Mono', 'Fira Code', monospace",
    background: theme.bg,
    color: theme.text,
    minHeight: "100vh",
  };

  const cardStyle: React.CSSProperties = {
    background: theme.card,
    border: `1px solid ${theme.border}`,
    borderRadius: "8px",
    padding: "1.5rem",
    marginBottom: "1rem",
  };

  const statusDot = (online: boolean): React.CSSProperties => ({
    display: "inline-block",
    width: "12px",
    height: "12px",
    borderRadius: "50%",
    backgroundColor: online ? theme.green : theme.red,
    marginRight: "0.5rem",
    boxShadow: online ? `0 0 8px ${theme.green}` : `0 0 8px ${theme.red}`,
  });

  const statBox: React.CSSProperties = {
    display: "inline-block",
    background: theme.bg,
    border: `1px solid ${theme.border}`,
    borderRadius: "6px",
    padding: "1rem 1.5rem",
    margin: "0.5rem",
    textAlign: "center",
    minWidth: "140px",
  };

  const btnStyle: React.CSSProperties = {
    padding: "0.5rem 1.2rem",
    background: theme.border,
    border: "none",
    borderRadius: "4px",
    color: "#fff",
    cursor: "pointer",
    fontSize: "0.9rem",
    opacity: loading ? 0.6 : 1,
  };

  // ---------- Render ----------

  return (
    <div style={containerStyle}>
      <h2 style={{ color: theme.accent, marginTop: 0 }}>
        RPC Health Dashboard
      </h2>

      {/* Connection info */}
      <div style={cardStyle}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <div>
            <span style={statusDot(status?.online ?? false)} />
            <strong style={{ color: status?.online ? theme.green : theme.red }}>
              {status?.online ? "ONLINE" : "OFFLINE"}
            </strong>
            <span style={{ color: theme.dim, marginLeft: "1rem" }}>{endpoint}</span>
          </div>
          <button onClick={checkHealth} disabled={loading} style={btnStyle}>
            {loading ? "Checking..." : "Refresh Now"}
          </button>
        </div>

        {status?.error && (
          <div style={{ color: theme.red, marginTop: "0.5rem", fontSize: "0.85rem" }}>
            Error: {status.error}
          </div>
        )}
      </div>

      {/* Stats cards */}
      {status && (
        <div style={{ ...cardStyle, display: "flex", flexWrap: "wrap", gap: "0.5rem" }}>
          <div style={statBox}>
            <div style={{ color: theme.dim, fontSize: "0.75rem", marginBottom: "0.3rem" }}>
              BLOCK HEIGHT
            </div>
            <div style={{ fontSize: "1.5rem", color: theme.accent, fontWeight: "bold" }}>
              {status.blockHeight !== null ? status.blockHeight.toLocaleString() : "--"}
            </div>
          </div>

          <div style={statBox}>
            <div style={{ color: theme.dim, fontSize: "0.75rem", marginBottom: "0.3rem" }}>
              PEERS
            </div>
            <div style={{ fontSize: "1.5rem", color: theme.accent, fontWeight: "bold" }}>
              {status.peerCount !== null ? status.peerCount : "--"}
            </div>
          </div>

          <div style={statBox}>
            <div style={{ color: theme.dim, fontSize: "0.75rem", marginBottom: "0.3rem" }}>
              LATENCY
            </div>
            <div style={{
              fontSize: "1.5rem",
              fontWeight: "bold",
              color: status.latencyMs < 100 ? theme.green :
                     status.latencyMs < 500 ? theme.yellow : theme.red,
            }}>
              {status.latencyMs}ms
            </div>
          </div>

          <div style={statBox}>
            <div style={{ color: theme.dim, fontSize: "0.75rem", marginBottom: "0.3rem" }}>
              STATUS
            </div>
            <div style={{
              fontSize: "1.5rem",
              fontWeight: "bold",
              color: status.online ? theme.green : theme.red,
            }}>
              {status.online ? "OK" : "DOWN"}
            </div>
          </div>

          <div style={statBox}>
            <div style={{ color: theme.dim, fontSize: "0.75rem", marginBottom: "0.3rem" }}>
              LAST CHECK
            </div>
            <div style={{ fontSize: "1rem", color: theme.text }}>
              {status.lastCheck}
            </div>
          </div>
        </div>
      )}

      {/* History sparkline (simple text-based) */}
      {history.length > 1 && (
        <div style={cardStyle}>
          <div style={{ color: theme.dim, fontSize: "0.75rem", marginBottom: "0.5rem" }}>
            UPTIME HISTORY (last {history.length} checks)
          </div>
          <div style={{ fontFamily: "monospace", letterSpacing: "2px" }}>
            {history.map((h, i) => (
              <span
                key={i}
                style={{
                  color: h.online ? theme.green : theme.red,
                  fontSize: "1.2rem",
                }}
                title={`${h.lastCheck}: ${h.online ? "OK" : "DOWN"} - ${h.latencyMs}ms`}
              >
                {h.online ? "\u2588" : "\u2591"}
              </span>
            ))}
          </div>
        </div>
      )}

      {/* Refresh info */}
      <div style={{ color: theme.dim, fontSize: "0.75rem", marginTop: "0.5rem" }}>
        Auto-refreshing every {refreshInterval / 1000}s
      </div>
    </div>
  );
};

export default RpcHealthDashboard;
