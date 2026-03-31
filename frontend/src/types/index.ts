// ── WebSocket Events (from ws_server.zig) ───────────────────────────────────

export interface WsNewBlockEvent {
  event: "new_block";
  height: number;
  hash: string;
  reward_sat: number;
  difficulty: number;
  mempool_size: number;
  timestamp: number;
}

export interface WsNewTxEvent {
  event: "new_tx";
  txid: string;
  from: string;
  amount_sat: number;
}

export interface WsStatusEvent {
  event: "status";
  height: number;
  difficulty: number;
}

export type WsEvent = WsNewBlockEvent | WsNewTxEvent | WsStatusEvent;

// ── RPC Response Shapes ─────────────────────────────────────────────────────

export interface BlockData {
  height: number;
  hash: string;
  previousHash?: string;
  timestamp: number;
  nonce?: number;
  txCount: number;
  miner?: string;
  rewardSAT?: number;
}

export interface TransactionData {
  txid: string;
  from: string;
  to: string;
  amount: number;
  timestamp?: number;
  blockHeight?: number;
  status: "pending" | "confirmed";
  direction?: "sent" | "received";
}

export interface MempoolStats {
  size: number;
  maxTx: number;
  maxBytes: number;
  bytes: number;
}

export interface MinerInfo {
  miner: string;
  blocksMined: number;
  totalRewardSAT: number;
  currentBalanceSAT: number;
}

export interface PeerInfo {
  id: string;
  host: string;
  port: number;
  alive: boolean;
}

export interface NetworkInfo {
  chain: string;
  version: string;
  blockHeight: number;
  blockRewardSAT: number;
  difficulty: number;
  mempoolSize: number;
  peerCount: number;
  nodeAddress: string;
  nodeBalance: number;
  halvingInterval: number;
  maxSupply: number;
  blockTimeMs: number;
  subBlocksPerBlock: number;
}

export interface WalletInfo {
  address: string;
  balance: number;
  balanceOMNI: string;
  nodeHeight: number;
}

// ── New RPC Response Types ─────────────────────────────────────────────────

export interface TransactionDetail {
  txid: string;
  from: string;
  to: string;
  amount: number;
  fee: number;
  confirmations: number;
  blockHeight: number;
  status: "pending" | "confirmed";
  locktime?: number;
  op_return?: string;
}

export interface AddressHistoryEntry {
  txid: string;
  from: string;
  to: string;
  amount: number;
  fee: number;
  direction: "sent" | "received";
  confirmations: number;
  blockHeight: number;
  status: "pending" | "confirmed";
  timestamp?: number;
}

export interface FeeEstimate {
  medianFee: number;
  minFee: number;
  burnPct: number;
}

export interface NonceInfo {
  address: string;
  nonce: number;
}

// ── Store State ─────────────────────────────────────────────────────────────

export interface BlockchainState {
  blockCount: number;
  difficulty: number;
  mempoolSize: number;
  mempoolStats: MempoolStats | null;
  balance: number;
  balanceOMNI: string;
  address: string;
  recentBlocks: BlockData[];
  pendingTxs: PendingTx[];
  miners: MinerInfo[];
  peers: PeerInfo[];
  networkInfo: NetworkInfo | null;
  wsConnected: boolean;
  lastBlockTimestamp: number | null;
  isMining: boolean;
}

export interface PendingTx {
  txid: string;
  from: string;
  amount_sat: number;
  timestamp: number;
}

// ── Store Actions ───────────────────────────────────────────────────────────

export type BlockchainAction =
  | { type: "SET_INITIAL_DATA"; payload: Partial<BlockchainState> }
  | { type: "WS_NEW_BLOCK"; payload: WsNewBlockEvent }
  | { type: "WS_NEW_TX"; payload: WsNewTxEvent }
  | { type: "WS_STATUS"; payload: WsStatusEvent }
  | { type: "SET_WS_CONNECTED"; payload: boolean }
  | { type: "UPDATE_MEMPOOL_STATS"; payload: MempoolStats }
  | { type: "UPDATE_MINERS"; payload: MinerInfo[] }
  | { type: "UPDATE_PEERS"; payload: PeerInfo[] }
  | { type: "UPDATE_NETWORK"; payload: NetworkInfo }
  | { type: "UPDATE_BALANCE"; payload: { balance: number; balanceOMNI: string } };
