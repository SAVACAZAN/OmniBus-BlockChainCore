import React, { useEffect, useRef, useReducer, useCallback } from "react";
import {
  BlockchainContext,
  blockchainReducer,
  initialState,
} from "./useBlockchainStore";
import OmniBusRpcClient from "../api/rpc-client";
import type { WsEvent, BlockData } from "../types";

const WS_URL = "ws://127.0.0.1:8334";
const WS_RECONNECT_MS = 3000;
const POLL_INTERVAL_MS = 10000;
const MINER_REFRESH_MS = 30000; // 30s — reduce load with many miners

const rpc = new OmniBusRpcClient("/api");

export function WebSocketProvider({ children }: { children: React.ReactNode }) {
  const [state, dispatch] = useReducer(blockchainReducer, initialState);
  const wsRef = useRef<WebSocket | null>(null);
  const reconnectTimer = useRef<number | null>(null);
  const pollTimer = useRef<number | null>(null);
  const minerTimer = useRef<number | null>(null);

  // ── Initial data fetch ──────────────────────────────────────────────────
  const fetchInitialData = useCallback(async () => {
    try {
      const [balanceData, mempoolStats, minerStats, networkInfo] =
        await Promise.all([
          rpc.getBalance().catch(() => null),
          rpc.getMempoolStats().catch(() => null),
          rpc.request_raw("getminerstats").catch(() => null),
          rpc.getNetworkInfo().catch(() => null),
        ]);

      // Fetch last 8 blocks in parallel
      let blocks: BlockData[] = [];
      try {
        const countData: any = await rpc.getBlockCount();
        const count =
          typeof countData === "object" && countData ? countData.blockCount : countData;
        const height = typeof count === "number" ? count : 0;

        if (height > 0) {
          const start = Math.max(0, height - 8);
          const promises = [];
          for (let i = height - 1; i >= start; i--) {
            promises.push(rpc.getBlock(i).catch(() => null));
          }
          const results = await Promise.all(promises);
          blocks = results.filter(Boolean) as BlockData[];
        }
      } catch {}

      const bal =
        typeof balanceData === "object" && balanceData
          ? balanceData
          : { balance: 0, balanceOMNI: "0.0000", address: "", nodeHeight: 0 };

      dispatch({
        type: "SET_INITIAL_DATA",
        payload: {
          blockCount: bal.nodeHeight || blocks[0]?.height + 1 || 0,
          balance: bal.balance || 0,
          balanceOMNI: bal.balanceOMNI || "0.0000",
          address: bal.address || "",
          mempoolSize: mempoolStats?.size || 0,
          mempoolStats: mempoolStats || null,
          miners: minerStats?.miners || [],
          networkInfo: networkInfo || null,
          recentBlocks: blocks,
          difficulty: networkInfo?.difficulty || 4,
          isMining: (blocks.length > 1) || (minerStats?.totalMiners > 0),
        },
      });
    } catch (err) {
      console.error("[WS Provider] Initial fetch failed:", err);
    }
  }, []);

  // ── WebSocket connection ────────────────────────────────────────────────
  const connectWs = useCallback(() => {
    if (wsRef.current?.readyState === WebSocket.OPEN) return;

    try {
      const ws = new WebSocket(WS_URL);
      wsRef.current = ws;

      ws.onopen = () => {
        dispatch({ type: "SET_WS_CONNECTED", payload: true });
        // Stop fallback poll when WS is live
        if (pollTimer.current) {
          clearInterval(pollTimer.current);
          pollTimer.current = null;
        }
      };

      // Throttle: max 2 updates per second to avoid UI freeze
      let lastUpdate = 0;
      ws.onmessage = (evt) => {
        const now = Date.now();
        if (now - lastUpdate < 500) return; // skip if <500ms since last
        lastUpdate = now;
        try {
          const data: WsEvent = JSON.parse(evt.data);
          switch (data.event) {
            case "new_block":
              dispatch({ type: "WS_NEW_BLOCK", payload: data });
              break;
            case "new_tx":
              dispatch({ type: "WS_NEW_TX", payload: data });
              break;
            case "status":
              dispatch({ type: "WS_STATUS", payload: data });
              break;
          }
        } catch {}
      };

      ws.onclose = () => {
        dispatch({ type: "SET_WS_CONNECTED", payload: false });
        wsRef.current = null;
        // Start fallback polling
        startFallbackPoll();
        // Schedule reconnect
        if (reconnectTimer.current) clearTimeout(reconnectTimer.current);
        reconnectTimer.current = window.setTimeout(
          connectWs,
          WS_RECONNECT_MS
        );
      };

      ws.onerror = () => {
        ws.close();
      };
    } catch {
      dispatch({ type: "SET_WS_CONNECTED", payload: false });
      if (reconnectTimer.current) clearTimeout(reconnectTimer.current);
      reconnectTimer.current = window.setTimeout(connectWs, WS_RECONNECT_MS);
    }
  }, []);

  // ── Fallback HTTP polling (only when WS is down) ───────────────────────
  const startFallbackPoll = useCallback(() => {
    if (pollTimer.current) return;
    pollTimer.current = window.setInterval(async () => {
      try {
        const [balanceData, mempoolStats] = await Promise.all([
          rpc.getBalance().catch(() => null),
          rpc.getMempoolStats().catch(() => null),
        ]);
        if (balanceData) {
          dispatch({
            type: "UPDATE_BALANCE",
            payload: {
              balance: balanceData.balance || 0,
              balanceOMNI: balanceData.balanceOMNI || "0.0000",
            },
          });
        }
        if (mempoolStats) {
          dispatch({ type: "UPDATE_MEMPOOL_STATS", payload: mempoolStats });
        }
      } catch {}
    }, POLL_INTERVAL_MS);
  }, []);

  // ── Miner/network refresh (always runs, not from WS) ──────────────────
  const startMinerRefresh = useCallback(() => {
    minerTimer.current = window.setInterval(async () => {
      try {
        const [minerStats, peers, networkInfo, balanceData] = await Promise.all([
          rpc.request_raw("getminerstats").catch(() => null),
          rpc.getPeers().catch(() => null),
          rpc.getNetworkInfo().catch(() => null),
          rpc.getBalance().catch(() => null),
        ]);
        if (minerStats?.miners) {
          dispatch({ type: "UPDATE_MINERS", payload: minerStats.miners });
        }
        if (peers?.peers) {
          dispatch({ type: "UPDATE_PEERS", payload: peers.peers });
        }
        if (networkInfo) {
          dispatch({ type: "UPDATE_NETWORK", payload: networkInfo });
        }
        if (balanceData) {
          dispatch({
            type: "UPDATE_BALANCE",
            payload: {
              balance: balanceData.balance || 0,
              balanceOMNI: balanceData.balanceOMNI || "0.0000",
            },
          });
        }
      } catch {}
    }, MINER_REFRESH_MS);
  }, []);

  // ── Lifecycle ─────────────────────────────────────────────────────────
  useEffect(() => {
    fetchInitialData();
    connectWs();
    startMinerRefresh();

    return () => {
      wsRef.current?.close();
      if (reconnectTimer.current) clearTimeout(reconnectTimer.current);
      if (pollTimer.current) clearInterval(pollTimer.current);
      if (minerTimer.current) clearInterval(minerTimer.current);
    };
  }, []);

  return (
    <BlockchainContext.Provider value={{ state, dispatch }}>
      {children}
    </BlockchainContext.Provider>
  );
}
