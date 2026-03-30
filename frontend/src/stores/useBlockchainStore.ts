import { createContext, useContext, useReducer, type Dispatch } from "react";
import type { BlockchainState, BlockchainAction, BlockData } from "../types";

const MAX_RECENT_BLOCKS = 10;
const MAX_PENDING_TXS = 50;

export const initialState: BlockchainState = {
  blockCount: 0,
  difficulty: 4,
  mempoolSize: 0,
  mempoolStats: null,
  balance: 0,
  balanceOMNI: "0.0000",
  address: "",
  recentBlocks: [],
  pendingTxs: [],
  miners: [],
  peers: [],
  networkInfo: null,
  wsConnected: false,
  lastBlockTimestamp: null,
  isMining: false,
};

export function blockchainReducer(
  state: BlockchainState,
  action: BlockchainAction
): BlockchainState {
  switch (action.type) {
    case "SET_INITIAL_DATA":
      return { ...state, ...action.payload };

    case "WS_NEW_BLOCK": {
      const evt = action.payload;
      const newBlock: BlockData = {
        height: evt.height,
        hash: evt.hash,
        timestamp: evt.timestamp,
        txCount: 0,
        rewardSAT: evt.reward_sat,
      };
      const blocks = [newBlock, ...state.recentBlocks].slice(
        0,
        MAX_RECENT_BLOCKS
      );
      return {
        ...state,
        blockCount: evt.height + 1,
        difficulty: evt.difficulty,
        mempoolSize: evt.mempool_size,
        recentBlocks: blocks,
        pendingTxs: [], // mined — clear pending
        lastBlockTimestamp: evt.timestamp,
        isMining: true,
      };
    }

    case "WS_NEW_TX": {
      const tx = action.payload;
      const pending = [
        { txid: tx.txid, from: tx.from, amount_sat: tx.amount_sat, timestamp: Date.now() },
        ...state.pendingTxs,
      ].slice(0, MAX_PENDING_TXS);
      return {
        ...state,
        pendingTxs: pending,
        mempoolSize: state.mempoolSize + 1,
      };
    }

    case "WS_STATUS":
      return {
        ...state,
        blockCount: action.payload.height + 1,
        difficulty: action.payload.difficulty,
      };

    case "SET_WS_CONNECTED":
      return { ...state, wsConnected: action.payload };

    case "UPDATE_MEMPOOL_STATS":
      return { ...state, mempoolStats: action.payload, mempoolSize: action.payload.size };

    case "UPDATE_MINERS":
      return { ...state, miners: action.payload };

    case "UPDATE_PEERS":
      return { ...state, peers: action.payload };

    case "UPDATE_NETWORK":
      return { ...state, networkInfo: action.payload };

    case "UPDATE_BALANCE":
      return { ...state, balance: action.payload.balance, balanceOMNI: action.payload.balanceOMNI };

    default:
      return state;
  }
}

// ── Context ─────────────────────────────────────────────────────────────────

interface StoreCtx {
  state: BlockchainState;
  dispatch: Dispatch<BlockchainAction>;
}

export const BlockchainContext = createContext<StoreCtx>({
  state: initialState,
  dispatch: () => {},
});

export function useBlockchain() {
  return useContext(BlockchainContext);
}

export { useReducer };
