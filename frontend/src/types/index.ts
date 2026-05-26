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

export interface WsHeartbeatEvent {
  event: "heartbeat";
  timestamp: number;
}

export interface WsNewTradeEvent {
  event: "new_trade";
  pair_id: number;
  pair: string;
  price_sat: number;
  qty_sat: number;
  side: "buy" | "sell";
  height: number;
  timestamp: number;
}

export interface WsOrderbookUpdateEvent {
  event: "orderbook_update";
  pair_id: number;
  pair: string;
  best_bid: number;
  best_ask: number;
  spread: number;
  order_count: number;
  height: number;
}

export interface WsOraclePriceEvent {
  event: "oracle_price";
  pair: string;       // "BTC/USD" | "LCX/USD"
  price_usd: number;  // float from "12345.6789"
  sources: number;
  timestamp: number;
}

export interface WsTxConfirmedEvent {
  event: "tx_confirmed";
  hash: string;
  blockHeight: number;
  blockHash: string;
}

export interface WsNameRegisteredEvent {
  event: "name_registered";
  name: string;
  tld: string;
  fullLabel: string;       // "alice.omnibus"
  address: string;
  years: number;
  timestamp: number;
}

export interface WsNameRenewedEvent {
  event: "name_renewed";
  name: string;
  tld: string;
  fullLabel: string;
  address: string;
  years: number;
  timestamp: number;
}

export interface WsPeerConnectEvent {
  event: "peer_connect";
  nodeId: string;
  address: string;          // "host:port"
  timestamp: number;
}

export interface WsPeerDisconnectEvent {
  event: "peer_disconnect";
  nodeId: string;
  address: string;
  timestamp: number;
}

export interface WsIbdProgressEvent {
  event: "ibd_progress";
  local_height: number;
  peer_height: number;
  behind: number;
  progress: number;  // 0–100
  active: boolean;
}

export type WsEvent =
  | WsNewBlockEvent
  | WsNewTxEvent
  | WsStatusEvent
  | WsHeartbeatEvent
  | WsNewTradeEvent
  | WsOrderbookUpdateEvent
  | WsOraclePriceEvent
  | WsTxConfirmedEvent
  | WsNameRegisteredEvent
  | WsNameRenewedEvent
  | WsPeerConnectEvent
  | WsPeerDisconnectEvent
  | WsIbdProgressEvent;

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
  /// Optional oracle price snapshot captured at mining time. Up to 21 slots
  /// (7 IMPORTANT_PAIRS x 3 exchanges) — empty/zero entries are filtered
  /// server-side.
  prices?: BlockPriceSnapshot[];
  /// SHA-256 of the canonical prices encoding, mixed into block hash via
  /// `prices_root`. 64-char lowercase hex. All-zero = "no prices recorded".
  pricesRoot?: string;
  /// True iff the server recomputed pricesRoot from `prices` and it matched
  /// the on-chain commitment. UI uses this to surface tamper-evident status.
  pricesValidated?: boolean;
}

export interface BlockPriceSnapshot {
  exchange: string;       // "Coinbase" | "Kraken" | "LCX"
  pair: string;           // "BTC/USD" | "LCX/USD"
  bidMicroUsd: number;    // 1 USD = 1_000_000
  askMicroUsd: number;
  timestampMs: number;
  success: boolean;
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
  scheme?: string;
  nonce?: number;
  kind?: string;
  memo?: string;
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

export interface OraclePrice {
  pair: string;
  price_usd: number;
  sources: number;
  timestamp: number;
}

export interface OrderbookSnapshot {
  pair_id: number;
  pair: string;
  best_bid: number;
  best_ask: number;
  spread: number;
  order_count: number;
  height: number;
}

export interface TradeRecord {
  pair: string;
  price_sat: number;
  qty_sat: number;
  side: "buy" | "sell";
  height: number;
  timestamp: number;
}

export interface IbdProgress {
  local_height: number;
  peer_height: number;
  behind: number;
  progress: number;
  active: boolean;
}

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
  oraclePrices: Record<string, OraclePrice>;       // keyed by pair "BTC/USD"
  orderbookSnapshots: Record<number, OrderbookSnapshot>; // keyed by pair_id
  recentTrades: TradeRecord[];                     // last 50 trades
  ibdProgress: IbdProgress | null;                 // IBD sync progress (null = synced)
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
  | { type: "WS_NEW_TRADE"; payload: WsNewTradeEvent }
  | { type: "WS_ORDERBOOK_UPDATE"; payload: WsOrderbookUpdateEvent }
  | { type: "WS_ORACLE_PRICE"; payload: WsOraclePriceEvent }
  | { type: "WS_IBD_PROGRESS"; payload: WsIbdProgressEvent }
  | { type: "WS_PEER_CONNECT"; payload: WsPeerConnectEvent }
  | { type: "WS_PEER_DISCONNECT"; payload: WsPeerDisconnectEvent }
  | { type: "SET_WS_CONNECTED"; payload: boolean }
  | { type: "UPDATE_MEMPOOL_STATS"; payload: MempoolStats }
  | { type: "UPDATE_MINERS"; payload: MinerInfo[] }
  | { type: "UPDATE_PEERS"; payload: PeerInfo[] }
  | { type: "UPDATE_NETWORK"; payload: NetworkInfo }
  | { type: "UPDATE_BALANCE"; payload: { balance: number; balanceOMNI: string } };
