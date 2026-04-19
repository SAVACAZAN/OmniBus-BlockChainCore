import React, { useCallback, useEffect, useState } from "react";

// ---------- Types ----------

interface BlockData {
  height: number;
  hash: string;
  prevHash: string;
  txCount: number;
  timestamp: number;
}

interface Props {
  /** RPC endpoint URL (default: http://127.0.0.1:8332) */
  endpoint?: string;
  /** Number of blocks to display (default: 10) */
  blockCount?: number;
  /** Auto-refresh interval in ms (default: 10000, 0 = disabled) */
  refreshInterval?: number;
}

// ---------- RPC helper ----------

async function rpcCall<T = unknown>(
  url: string,
  method: string,
  params: unknown[] = [],
  timeoutMs = 5000
): Promise<T | null> {
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
    if (!res.ok) return null;
    const data = await res.json();
    if (data.error) return null;
    return data.result as T;
  } catch {
    clearTimeout(timer);
    return null;
  }
}

// ---------- Helpers ----------

function truncateHash(hash: string, len = 8): string {
  if (!hash || hash.length <= len * 2 + 3) return hash || "---";
  return `${hash.slice(0, len)}...${hash.slice(-len)}`;
}

function formatTimestamp(ts: number): string {
  if (!ts) return "---";
  const d = new Date(ts * 1000);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function timeAgo(ts: number): string {
  if (!ts) return "";
  const diff = Math.floor(Date.now() / 1000 - ts);
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  return `${Math.floor(diff / 3600)}h ago`;
}

// ---------- Component ----------

const BlockVisualizer: React.FC<Props> = ({
  endpoint = "http://127.0.0.1:8332",
  blockCount = 10,
  refreshInterval = 10000,
}) => {
  const [blocks, setBlocks] = useState<BlockData[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [lastUpdate, setLastUpdate] = useState<string>("");

  const fetchBlocks = useCallback(async () => {
    setLoading(true);
    setError(null);

    try {
      // Get current block count
      const height = await rpcCall<number>(endpoint, "getblockcount");

      if (height === null || height === undefined) {
        // Fallback: try getblockchaininfo
        const info = await rpcCall<{ blocks?: number; height?: number }>(
          endpoint, "getblockchaininfo"
        );
        if (!info) {
          setError("Cannot connect to RPC endpoint");
          setLoading(false);
          return;
        }
      }

      // Fetch recent blocks via getblocks RPC
      const currentHeight = height ?? 0;
      const fromHeight = Math.max(0, currentHeight - blockCount + 1);

      const blocksData = await rpcCall<BlockData[]>(
        endpoint, "getblocks", [fromHeight, blockCount]
      );

      if (blocksData && Array.isArray(blocksData)) {
        // Sort by height ascending (oldest first -> newest last = left to right)
        const sorted = [...blocksData].sort((a, b) => a.height - b.height);
        setBlocks(sorted);
      } else {
        // Fallback: fetch individual blocks by height
        const fetchedBlocks: BlockData[] = [];
        for (let h = fromHeight; h <= currentHeight && fetchedBlocks.length < blockCount; h++) {
          const block = await rpcCall<BlockData>(endpoint, "getblock", [h]);
          if (block) {
            fetchedBlocks.push({
              height: block.height ?? h,
              hash: block.hash ?? `block-${h}`,
              prevHash: block.prevHash ?? "",
              txCount: block.txCount ?? 0,
              timestamp: block.timestamp ?? 0,
            });
          }
        }
        setBlocks(fetchedBlocks);
      }

      setLastUpdate(new Date().toLocaleTimeString());
    } catch (err) {
      setError(String(err));
    }

    setLoading(false);
  }, [endpoint, blockCount]);

  // Auto-refresh
  useEffect(() => {
    fetchBlocks();
    if (refreshInterval > 0) {
      const id = setInterval(fetchBlocks, refreshInterval);
      return () => clearInterval(id);
    }
  }, [fetchBlocks, refreshInterval]);

  // ---------- Theme ----------

  const theme = {
    bg: "#0b0c10",
    card: "#1f2833",
    border: "#45a29e",
    accent: "#66fcf1",
    text: "#c5c6c7",
    green: "#66fcf1",
    red: "#ff6b6b",
    dim: "#5c6370",
    arrow: "#45a29e",
  };

  const containerStyle: React.CSSProperties = {
    padding: "1.5rem",
    fontFamily: "'JetBrains Mono', 'Fira Code', monospace",
    background: theme.bg,
    color: theme.text,
    minHeight: "100vh",
  };

  const chainStyle: React.CSSProperties = {
    display: "flex",
    alignItems: "center",
    overflowX: "auto",
    padding: "1rem 0",
    gap: "0",
  };

  const blockBoxStyle = (isLatest: boolean): React.CSSProperties => ({
    minWidth: "160px",
    maxWidth: "180px",
    padding: "1rem",
    background: isLatest ? "#1a3a3a" : theme.card,
    border: `2px solid ${isLatest ? theme.accent : theme.border}`,
    borderRadius: "8px",
    textAlign: "center",
    flexShrink: 0,
    boxShadow: isLatest ? `0 0 12px ${theme.accent}40` : "none",
    transition: "transform 0.2s, box-shadow 0.2s",
    cursor: "default",
  });

  const arrowStyle: React.CSSProperties = {
    color: theme.arrow,
    fontSize: "1.5rem",
    margin: "0 0.3rem",
    flexShrink: 0,
    userSelect: "none",
  };

  // ---------- Render ----------

  return (
    <div style={containerStyle}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: "1rem" }}>
        <h2 style={{ color: theme.accent, margin: 0 }}>
          Block Visualizer
        </h2>
        <div>
          {lastUpdate && (
            <span style={{ color: theme.dim, fontSize: "0.8rem", marginRight: "1rem" }}>
              Updated: {lastUpdate}
            </span>
          )}
          <button
            onClick={fetchBlocks}
            disabled={loading}
            style={{
              padding: "0.4rem 1rem",
              background: theme.border,
              border: "none",
              borderRadius: "4px",
              color: "#fff",
              cursor: loading ? "wait" : "pointer",
              opacity: loading ? 0.6 : 1,
            }}
          >
            {loading ? "Loading..." : "Refresh"}
          </button>
        </div>
      </div>

      {error && (
        <div style={{
          background: "#2d1515",
          border: `1px solid ${theme.red}`,
          borderRadius: "6px",
          padding: "0.8rem 1rem",
          color: theme.red,
          marginBottom: "1rem",
        }}>
          {error}
        </div>
      )}

      {blocks.length === 0 && !loading && !error && (
        <div style={{ color: theme.dim, textAlign: "center", padding: "3rem" }}>
          No blocks to display. Is the node running?
        </div>
      )}

      {/* Block chain visualization */}
      <div style={{
        background: theme.card,
        borderRadius: "8px",
        border: `1px solid ${theme.border}`,
        padding: "1rem",
      }}>
        <div style={chainStyle}>
          {blocks.map((block, index) => {
            const isLatest = index === blocks.length - 1;
            return (
              <React.Fragment key={block.hash || block.height}>
                {/* Arrow connector (skip before first block) */}
                {index > 0 && (
                  <span style={arrowStyle} title="linked by prevHash">
                    &#x2192;
                  </span>
                )}

                {/* Block box */}
                <div
                  style={blockBoxStyle(isLatest)}
                  title={`Hash: ${block.hash}\nPrev: ${block.prevHash}\nTxs: ${block.txCount}\nTime: ${new Date(block.timestamp * 1000).toISOString()}`}
                  onMouseEnter={(e) => {
                    (e.currentTarget as HTMLDivElement).style.transform = "scale(1.05)";
                  }}
                  onMouseLeave={(e) => {
                    (e.currentTarget as HTMLDivElement).style.transform = "scale(1)";
                  }}
                >
                  {/* Height */}
                  <div style={{
                    fontWeight: "bold",
                    fontSize: "1.2rem",
                    color: isLatest ? theme.accent : theme.green,
                    marginBottom: "0.4rem",
                  }}>
                    #{block.height.toLocaleString()}
                  </div>

                  {/* Hash */}
                  <div style={{
                    fontSize: "0.7rem",
                    color: theme.dim,
                    wordBreak: "break-all",
                    marginBottom: "0.4rem",
                    fontFamily: "monospace",
                  }}>
                    {truncateHash(block.hash)}
                  </div>

                  {/* Tx count */}
                  <div style={{
                    fontSize: "0.85rem",
                    color: theme.text,
                    marginBottom: "0.2rem",
                  }}>
                    {block.txCount} tx{block.txCount !== 1 ? "s" : ""}
                  </div>

                  {/* Timestamp */}
                  <div style={{
                    fontSize: "0.7rem",
                    color: theme.dim,
                  }}>
                    {formatTimestamp(block.timestamp)}
                    {block.timestamp > 0 && (
                      <span style={{ marginLeft: "0.3rem" }}>
                        ({timeAgo(block.timestamp)})
                      </span>
                    )}
                  </div>

                  {/* Latest badge */}
                  {isLatest && (
                    <div style={{
                      marginTop: "0.5rem",
                      fontSize: "0.65rem",
                      color: theme.accent,
                      textTransform: "uppercase",
                      letterSpacing: "1px",
                    }}>
                      latest
                    </div>
                  )}
                </div>
              </React.Fragment>
            );
          })}
        </div>
      </div>

      {/* Summary bar */}
      {blocks.length > 0 && (
        <div style={{
          display: "flex",
          gap: "2rem",
          marginTop: "1rem",
          color: theme.dim,
          fontSize: "0.8rem",
        }}>
          <span>Blocks shown: {blocks.length}</span>
          <span>
            Height range: #{blocks[0].height.toLocaleString()} - #{blocks[blocks.length - 1].height.toLocaleString()}
          </span>
          <span>
            Total txs: {blocks.reduce((sum, b) => sum + b.txCount, 0).toLocaleString()}
          </span>
          <span>Endpoint: {endpoint}</span>
        </div>
      )}
    </div>
  );
};

export default BlockVisualizer;
