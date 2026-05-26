import { useState, useMemo } from "react";
import { RPC_METHODS, RPC_CATEGORIES, type RpcMethod } from "./rpc-reference";

// ── Types ────────────────────────────────────────────────────────────────────

type TopTab = "cli" | "rpc" | "wiki";

interface CliCommand {
  cmd: string;
  category: string;
  description: string;
  params: string;
  example: string;
}

// ── CLI command catalog ───────────────────────────────────────────────────────
// Extracted from core/cli_audit.zig dispatch + help text.

const CLI_COMMANDS: CliCommand[] = [
  // ── Chain / Node ──────────────────────────────────────────────────────────
  { cmd: "health", category: "Node", description: "Chain stats: height, mempool size, peers, sync status.", params: "", example: "omnibus-cli health" },
  { cmd: "chain-info", category: "Node", description: "Full chain info: genesis, supply, halving, difficulty.", params: "", example: "omnibus-cli chain-info" },
  { cmd: "supply", category: "Node", description: "Current circulating supply and max supply.", params: "", example: "omnibus-cli supply" },
  { cmd: "halving", category: "Node", description: "Next halving block and estimated date.", params: "", example: "omnibus-cli halving" },
  { cmd: "mempool", category: "Node", description: "Mempool stats: pending TX count, bytes, fee histogram.", params: "", example: "omnibus-cli mempool" },
  { cmd: "sync-status", category: "Node", description: "IBD sync progress.", params: "", example: "omnibus-cli sync-status" },
  { cmd: "block", category: "Node", description: "Get a block by height.", params: "<height>", example: "omnibus-cli block 42" },
  { cmd: "block-hash", category: "Node", description: "Block hash at a given height.", params: "<height>", example: "omnibus-cli block-hash 42" },
  { cmd: "tx", category: "Node", description: "Transaction details by hash.", params: "<hash>", example: "omnibus-cli tx deadbeef..." },
  { cmd: "prices", category: "Node", description: "Current oracle prices for all tracked pairs.", params: "", example: "omnibus-cli prices" },
  { cmd: "watch", category: "Node", description: "Repeat a command every N seconds.", params: "<command> [interval=5]", example: "omnibus-cli watch health 10" },
  { cmd: "logs", category: "Node", description: "Tail node log file.", params: "[lines=50]", example: "omnibus-cli logs 100" },
  { cmd: "vps-health", category: "Node", description: "Check remote VPS systemd service health via SSH.", params: "", example: "omnibus-cli vps-health" },
  { cmd: "services-status", category: "Node", description: "Status of all OmniBus systemd services (seed/miner/oracle).", params: "", example: "omnibus-cli services-status" },
  { cmd: "service-restart", category: "Node", description: "Restart a named service.", params: "<service-name>", example: "omnibus-cli service-restart omnibus-seed" },
  { cmd: "benchmark", category: "Node", description: "Run a quick TX throughput benchmark.", params: "[txcount=100]", example: "omnibus-cli benchmark 500" },
  { cmd: "stress-quick", category: "Node", description: "Quick stress test: send 10 TX and measure latency.", params: "", example: "omnibus-cli stress-quick" },
  { cmd: "config", category: "Node", description: "Show or edit node config.", params: "[key] [value]", example: "omnibus-cli config\nomnibus-cli config rpc_port 18332" },
  { cmd: "set-rpc-token", category: "Node", description: "Set or rotate the RPC bearer token.", params: "<token>", example: "omnibus-cli set-rpc-token mysecrettoken" },
  // ── Wallet ────────────────────────────────────────────────────────────────
  { cmd: "balance", category: "Wallet", description: "Full balance breakdown: wallet / staked / available / reputation.", params: "<address>", example: "omnibus-cli balance ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0" },
  { cmd: "wallet-summary", category: "Wallet", description: "Atomic wallet snapshot (also: summary / ws).", params: "<address>", example: "omnibus-cli wallet-summary ob1q..." },
  { cmd: "send", category: "Wallet", description: "Send OMNI to an address (requires --privkey or --mnemonic).", params: "<to_address> <amount_omni>", example: "omnibus-cli send ob1q... 1.5 --mnemonic \"word1 word2...\"" },
  { cmd: "derive-key", category: "Wallet", description: "Derive key at BIP-44 index from mnemonic (no seed exposure).", params: "<index>", example: "omnibus-cli derive-key 3 --mnemonic \"...\"" },
  { cmd: "wallet-list", category: "Wallet", description: "List N addresses derived from a mnemonic (also: list-keys).", params: "<count>", example: "omnibus-cli wallet-list 10 --mnemonic \"...\"" },
  { cmd: "wallet-derive", category: "Wallet", description: "Derive child wallet at index with full key metadata.", params: "<index>", example: "omnibus-cli wallet-derive 0" },
  { cmd: "wallet-pq-derive", category: "Wallet", description: "Derive post-quantum soulbound address at scheme+index.", params: "<scheme> <index>", example: "omnibus-cli wallet-pq-derive mldsa87 0" },
  { cmd: "wallet-multichain", category: "Wallet", description: "Show wallet addresses across all 19 supported chains.", params: "[index=0]", example: "omnibus-cli wallet-multichain" },
  { cmd: "wallet-export", category: "Wallet", description: "Export wallet keys to JSON (encrypted).", params: "[output.json]", example: "omnibus-cli wallet-export keys.json" },
  { cmd: "sign-message", category: "Wallet", description: "Sign a message with the node key.", params: "<message>", example: "omnibus-cli sign-message \"hello omnibus\"" },
  { cmd: "verify-signature", category: "Wallet", description: "Verify a signed message.", params: "<message> <address> <sig>", example: "omnibus-cli verify-signature \"hello\" ob1q... sig..." },
  { cmd: "peer-info", category: "Wallet", description: "Info about a specific peer by address.", params: "<peer_addr>", example: "omnibus-cli peer-info ob1q..." },
  { cmd: "miner-stats", category: "Wallet", description: "Mining stats for an address.", params: "<address>", example: "omnibus-cli miner-stats ob1q..." },
  // ── Staking ────────────────────────────────────────────────────────────────
  { cmd: "stake", category: "Staking", description: "Stake OMNI to enter the validator candidate pool.", params: "<address> [stakeinfo]", example: "omnibus-cli stake ob1q..." },
  { cmd: "validators", category: "Staking", description: "List all active validators.", params: "", example: "omnibus-cli validators" },
  { cmd: "stakers", category: "Staking", description: "Top stakers by amount.", params: "[limit=10]", example: "omnibus-cli stakers 20" },
  { cmd: "verify", category: "Staking", description: "Sanity check: chain stake_amounts vs sum of stake TXs.", params: "<address>", example: "omnibus-cli verify ob1q..." },
  // ── Network / Peers ────────────────────────────────────────────────────────
  { cmd: "peers", category: "Network", description: "List connected P2P peers.", params: "", example: "omnibus-cli peers" },
  { cmd: "bans", category: "Network", description: "List banned peers.", params: "", example: "omnibus-cli bans" },
  { cmd: "p2p-stats", category: "Network", description: "P2P network statistics.", params: "", example: "omnibus-cli p2p-stats" },
  { cmd: "connect", category: "Network", description: "Connect to a peer manually.", params: "<host:port>", example: "omnibus-cli connect 1.2.3.4:9000" },
  { cmd: "disconnect", category: "Network", description: "Disconnect from a peer.", params: "<host:port>", example: "omnibus-cli disconnect 1.2.3.4:9000" },
  // ── Mining ────────────────────────────────────────────────────────────────
  { cmd: "mining-status", category: "Mining", description: "Current mining status, hashrate, slot assignment.", params: "", example: "omnibus-cli mining-status" },
  { cmd: "miners", category: "Mining", description: "List registered miners.", params: "", example: "omnibus-cli miners" },
  { cmd: "pool-stats", category: "Mining", description: "Mining pool statistics.", params: "", example: "omnibus-cli pool-stats" },
  { cmd: "slot-leader", category: "Mining", description: "Current slot leader.", params: "", example: "omnibus-cli slot-leader" },
  { cmd: "register-miner", category: "Mining", description: "Register this node as a miner in the network.", params: "<address> <node-id>", example: "omnibus-cli register-miner ob1q... miner-1" },
  // ── Exchange ───────────────────────────────────────────────────────────────
  { cmd: "exchange-pairs", category: "Exchange", description: "List all DEX trading pairs.", params: "", example: "omnibus-cli exchange-pairs" },
  { cmd: "exchange-orderbook", category: "Exchange", description: "Orderbook for a pair.", params: "<pair_id>", example: "omnibus-cli exchange-orderbook 0" },
  { cmd: "exchange-trades", category: "Exchange", description: "Recent trades for a pair.", params: "<pair_id>", example: "omnibus-cli exchange-trades 3" },
  { cmd: "exchange-pair-info", category: "Exchange", description: "Detailed pair info including chains.", params: "<pair_id>", example: "omnibus-cli exchange-pair-info 0" },
  { cmd: "exchange-stats", category: "Exchange", description: "24h stats for a pair.", params: "<pair_id>", example: "omnibus-cli exchange-stats 0" },
  { cmd: "exchange-orders", category: "Exchange", description: "My open orders.", params: "<address>", example: "omnibus-cli exchange-orders ob1q..." },
  { cmd: "exchange-place", category: "Exchange", description: "Place a limit order.", params: "<pair_id> <buy|sell> <price> <amount>", example: "omnibus-cli exchange-place 0 buy 100 1.5" },
  { cmd: "exchange-cancel", category: "Exchange", description: "Cancel an open order.", params: "<order_id>", example: "omnibus-cli exchange-cancel uuid-here" },
  // ── Grid ──────────────────────────────────────────────────────────────────
  { cmd: "grid-list", category: "Grid", description: "List active grid strategies.", params: "[owner_address]", example: "omnibus-cli grid-list ob1q..." },
  { cmd: "grid-status", category: "Grid", description: "Grid details: fills, P&L.", params: "<grid_id>", example: "omnibus-cli grid-status grid-uuid" },
  { cmd: "grid-create", category: "Grid", description: "Create a new grid strategy.", params: "<pair_id> <price_low> <price_high> <levels> <total_base> <total_quote>", example: "omnibus-cli grid-create 0 95 105 5 10 1000" },
  { cmd: "grid-cancel", category: "Grid", description: "Cancel a grid.", params: "<grid_id>", example: "omnibus-cli grid-cancel grid-uuid" },
  // ── HTLC ──────────────────────────────────────────────────────────────────
  { cmd: "htlc-list", category: "HTLC", description: "List my HTLCs.", params: "[address]", example: "omnibus-cli htlc-list ob1q..." },
  { cmd: "htlc-status", category: "HTLC", description: "HTLC status by ID.", params: "<htlc_id>", example: "omnibus-cli htlc-status htlc-uuid" },
  { cmd: "htlc-init", category: "HTLC", description: "Create an HTLC for atomic swap.", params: "<pair_id> <maker> <taker> <amount>", example: "omnibus-cli htlc-init 0 ob1q... 0x... 1000" },
  { cmd: "htlc-claim", category: "HTLC", description: "Claim HTLC with preimage.", params: "<htlc_id> <preimage_hex>", example: "omnibus-cli htlc-claim uuid abc123..." },
  { cmd: "htlc-refund", category: "HTLC", description: "Refund expired HTLC.", params: "<htlc_id>", example: "omnibus-cli htlc-refund uuid" },
  // ── DNS / Names ────────────────────────────────────────────────────────────
  { cmd: "ns-tlds", category: "Names", description: "List supported TLDs.", params: "", example: "omnibus-cli ns-tlds" },
  { cmd: "ns-stats", category: "Names", description: "Registry stats.", params: "", example: "omnibus-cli ns-stats" },
  { cmd: "ns-list", category: "Names", description: "All names, optionally by owner.", params: "[owner_address]", example: "omnibus-cli ns-list ob1q..." },
  { cmd: "ns-resolve", category: "Names", description: "Resolve name to address.", params: "<name>", example: "omnibus-cli ns-resolve alice.omnibus" },
  { cmd: "ns-reverse", category: "Names", description: "Reverse lookup address to name.", params: "<address>", example: "omnibus-cli ns-reverse ob1q..." },
  { cmd: "ns-fee", category: "Names", description: "Registration fee for a TLD.", params: "<tld>", example: "omnibus-cli ns-fee omnibus" },
  { cmd: "ns-expiring", category: "Names", description: "Names expiring within N days.", params: "[days=30]", example: "omnibus-cli ns-expiring 14" },
  { cmd: "ns-by-category", category: "Names", description: "Names filtered by category.", params: "<category>", example: "omnibus-cli ns-by-category defi" },
  { cmd: "ns-register", category: "Names", description: "Register a name on-chain.", params: "--name=alice.omnibus --address=ob1q... --fee-bps=500", example: "omnibus-cli ns-register --name=alice.omnibus --address=ob1q... --mnemonic \"...\"" },
  { cmd: "ns-renew", category: "Names", description: "Renew a name registration.", params: "--name=alice.omnibus", example: "omnibus-cli ns-renew --name=alice.omnibus --mnemonic \"...\"" },
  { cmd: "ns-transfer", category: "Names", description: "Transfer name ownership.", params: "--name=alice.omnibus --to=ob1q...", example: "omnibus-cli ns-transfer --name=alice.omnibus --to=ob1q... --mnemonic \"...\"" },
  // ── Identity ───────────────────────────────────────────────────────────────
  { cmd: "did", category: "Identity", description: "Show DID document for an address.", params: "<address>", example: "omnibus-cli did ob1q..." },
  { cmd: "obm", category: "Identity", description: "Show OBM (8-bit badge map) for an address.", params: "<address>", example: "omnibus-cli obm ob1q..." },
  { cmd: "facets", category: "Identity", description: "Show identity facets (Social/Professional/Cultural/Economic).", params: "<address>", example: "omnibus-cli facets ob1q..." },
  { cmd: "reputation", category: "Identity", description: "Show reputation cups and tier.", params: "<address>", example: "omnibus-cli reputation ob1q..." },
  { cmd: "profile", category: "Identity", description: "Profile subcommands: init / get / wizard / social / professional / cultural / economic.", params: "<subcommand> [args]", example: "omnibus-cli profile init ob1q... --display-name Alice\nomnibus-cli profile get ob1q...\nomnibus-cli profile social ob1q..." },
  { cmd: "mica", category: "Identity", description: "MiCA compliance: attest / disclose.", params: "<attest|disclose> [args]", example: "omnibus-cli mica attest ob1q... --mica-type EMT\nomnibus-cli mica disclose ob1q... --fields mica_type,issuer" },
  { cmd: "pq-schemes", category: "Identity", description: "List available post-quantum signature schemes.", params: "", example: "omnibus-cli pq-schemes" },
  { cmd: "pq-identity", category: "Identity", description: "Show PQ identity (soulbound addresses) for a mnemonic.", params: "[index=0]", example: "omnibus-cli pq-identity" },
  { cmd: "pq-balance", category: "Identity", description: "Balance on a PQ soulbound address.", params: "<pq_address>", example: "omnibus-cli pq-balance obk1_..." },
  { cmd: "pq-attest", category: "Identity", description: "Create pq_attest (7-signature cross-chain identity binding).", params: "<address>", example: "omnibus-cli pq-attest ob1q... --mnemonic \"...\"" },
  // ── Social ────────────────────────────────────────────────────────────────
  { cmd: "follow", category: "Social", description: "Follow another address.", params: "<from_address> <to_address>", example: "omnibus-cli follow ob1q... ob1q..." },
  { cmd: "followers", category: "Social", description: "Show followers of an address.", params: "<address>", example: "omnibus-cli followers ob1q..." },
  { cmd: "following", category: "Social", description: "Show addresses followed by an address.", params: "<address>", example: "omnibus-cli following ob1q..." },
  // ── Agents ────────────────────────────────────────────────────────────────
  { cmd: "agents-list", category: "Agents", description: "List all registered agents.", params: "", example: "omnibus-cli agents-list" },
  { cmd: "agent-info", category: "Agents", description: "Info about a specific agent.", params: "<agent_id>", example: "omnibus-cli agent-info agent-uuid" },
  { cmd: "agent-register", category: "Agents", description: "Register a new agent on-chain.", params: "--name=MyBot --strategy=grid", example: "omnibus-cli agent-register --name=MyBot --strategy=grid --mnemonic \"...\"" },
  { cmd: "agent-unregister", category: "Agents", description: "Remove an agent.", params: "<agent_id>", example: "omnibus-cli agent-unregister agent-uuid" },
  { cmd: "agent-decisions", category: "Agents", description: "Pending decisions for an agent.", params: "<agent_id>", example: "omnibus-cli agent-decisions agent-uuid" },
  { cmd: "agent-follow", category: "Agents", description: "Subscribe to another agent's signals.", params: "<my_agent_id> <target_agent_id>", example: "omnibus-cli agent-follow my-uuid target-uuid" },
  // ── Governance ────────────────────────────────────────────────────────────
  { cmd: "gov-proposals", category: "Governance", description: "List governance proposals.", params: "", example: "omnibus-cli gov-proposals" },
  { cmd: "gov-treasury", category: "Governance", description: "Show treasury balances.", params: "", example: "omnibus-cli gov-treasury" },
  { cmd: "gov-propose", category: "Governance", description: "Submit a proposal.", params: "--title=\"...\" --type=parameter_change", example: "omnibus-cli gov-propose --title=\"Increase reward\" --type=parameter_change" },
  { cmd: "gov-vote", category: "Governance", description: "Vote on a proposal.", params: "<proposal_id> <yes|no|abstain>", example: "omnibus-cli gov-vote 1 yes --mnemonic \"...\"" },
  // ── Audit ────────────────────────────────────────────────────────────────
  { cmd: "daily", category: "Audit", description: "Per-day TX breakdown for an address.", params: "<address> [days=30]", example: "omnibus-cli daily ob1q... 30" },
  { cmd: "history", category: "Audit", description: "TX history with optional filter (stake/sent/received/mined/all).", params: "<address> [filter]", example: "omnibus-cli history ob1q... stake\nomnibus-cli history ob1q... all" },
  { cmd: "audit-totals", category: "Audit", description: "Audit chain totals: supply, fees, stake.", params: "", example: "omnibus-cli audit-totals" },
  { cmd: "audit-stakes", category: "Audit", description: "Verify all stake records.", params: "", example: "omnibus-cli audit-stakes" },
  { cmd: "audit-supply", category: "Audit", description: "Verify total supply integrity.", params: "", example: "omnibus-cli audit-supply" },
  { cmd: "audit-mempool", category: "Audit", description: "Mempool audit.", params: "", example: "omnibus-cli audit-mempool" },
  { cmd: "audit-fees", category: "Audit", description: "Fee audit: collected vs expected.", params: "", example: "omnibus-cli audit-fees" },
  // ── Faucet / Security ────────────────────────────────────────────────────
  { cmd: "faucet-status", category: "Faucet", description: "Faucet balance and recent claims.", params: "", example: "omnibus-cli faucet-status" },
  { cmd: "faucet-claim", category: "Faucet", description: "Claim from faucet.", params: "<address>", example: "omnibus-cli faucet-claim ob1q..." },
  { cmd: "faucet-claims", category: "Faucet", description: "List all faucet claims.", params: "", example: "omnibus-cli faucet-claims" },
  { cmd: "zeroday-events", category: "Security", description: "List 0day security events.", params: "", example: "omnibus-cli zeroday-events" },
  { cmd: "zeroday-report", category: "Security", description: "Report a security event.", params: "--type=... --severity=...", example: "omnibus-cli zeroday-report --type=double_spend --severity=high" },
  { cmd: "sybil-check", category: "Security", description: "Check if an address is flagged as sybil.", params: "<address>", example: "omnibus-cli sybil-check ob1q..." },
  // ── Bridge ────────────────────────────────────────────────────────────────
  { cmd: "bridge-status", category: "Bridge", description: "Bridge status and pending transfers.", params: "", example: "omnibus-cli bridge-status" },
  { cmd: "bridge-lock", category: "Bridge", description: "Lock OMNI for bridge transfer.", params: "<amount> <to_chain> <to_address>", example: "omnibus-cli bridge-lock 1.5 base 0x..." },
  // ── Oracle ────────────────────────────────────────────────────────────────
  { cmd: "oracle-prices", category: "Oracle", description: "All oracle price feeds.", params: "", example: "omnibus-cli oracle-prices" },
  { cmd: "oracle-arbitrage", category: "Oracle", description: "Arbitrage opportunities from oracle.", params: "", example: "omnibus-cli oracle-arbitrage" },
  { cmd: "oracle-feed", category: "Oracle", description: "Real-time exchange price feed.", params: "", example: "omnibus-cli oracle-feed" },
  { cmd: "oracle-restart", category: "Oracle", description: "Restart oracle service on VPS.", params: "[network=mainnet]", example: "omnibus-cli oracle-restart" },
  { cmd: "oracle-snapshot", category: "Oracle", description: "Take price oracle snapshot.", params: "", example: "omnibus-cli oracle-snapshot" },
];

const CLI_CATEGORIES = [
  "Node", "Wallet", "Staking", "Network", "Mining",
  "Exchange", "Grid", "HTLC", "Names", "Identity",
  "Social", "Agents", "Governance", "Audit",
  "Faucet", "Security", "Bridge", "Oracle",
];

// ── Wiki content ─────────────────────────────────────────────────────────────

const WIKI_ARTICLES = [
  {
    id: "omnibus-blockchain",
    title: "What is OmniBus Blockchain?",
    content: `OmniBus is a native Layer-1 blockchain written in pure Zig, designed for high-frequency trading (HFT) and financial applications. It combines Bitcoin-compatible ECDSA addresses (ob1q... bech32 prefix), post-quantum cryptography (ML-DSA-87, Falcon-512, SLH-DSA, ML-KEM-768 via liboqs), and a Casper FFG finality layer on top of Proof-of-Work. Block time is 10 seconds (10 × 0.1s sub-blocks → 1 KeyBlock). Max supply is 21 million OMNI. The RPC server runs on port 8332 (mainnet), 18332 (testnet), 28332 (regtest). 1 OMNI = 1,000,000,000 satoshis.`,
  },
  {
    id: "omnibus-id",
    title: "OmniBus ID / DID",
    content: `Every OmniBus address can have a W3C-compatible Decentralized Identifier (DID). The DID document is stored on-chain and links the address to its public key, identity facets, OBM badges, and cross-chain attestations. DIDs follow the format did:omnibus:ob1q... and are resolved via the getdid RPC. The DID is the root of all identity in the ecosystem — once created it cannot be transferred, only updated.`,
  },
  {
    id: "identity-facets",
    title: "The 4 Identity Facets",
    content: `OmniBus identity is structured into 4 facets stored as Merkle tree leaves, allowing selective disclosure (you can prove one facet without revealing others):

• Social (Leaf 6) — Think LinkedIn profile. Username, bio, social links, follower graph. Real-world analogy: your public persona.

• Professional (Leaf 7) — Think resume. Skills, certifications, work history, registered agents. Real-world analogy: your CV.

• Cultural (Leaf 8) — Think Spotify wrapped + travel passport. Music taste, POAPs (event attendance), community memberships. Real-world analogy: your hobbies.

• Economic (implicit via wallet) — On-chain financial history: balance, staking, trading volume, ENS names owned. Real-world analogy: your credit score.

Each facet has per-item Merkle proofs so you can disclose "I am a professional developer" without revealing your social links.`,
  },
  {
    id: "obm",
    title: "OBM — OmniBus Binary Map",
    content: `The OBM is an 8-bit badge vector that compactly encodes achievements. Each bit represents a milestone:

• Bit 0: Has balance > 0
• Bit 1: Has staked OMNI
• Bit 2: Has registered a .omnibus name
• Bit 3: Has a validator role
• Bit 4: Has run an autonomous agent
• Bit 5: Has completed MiCA attestation
• Bit 6: Has a PQ soulbound address
• Bit 7: Has the Satoshi badge (100/100/100/100 reputation cups)

The OBM is computed on-chain from chain state, not user-submitted. It cannot be faked. Displayed as a bitmask or as colored badge icons in the UI.`,
  },
  {
    id: "reputation-cups",
    title: "Reputation Cups (LOVE / FOOD / RENT / VACATION)",
    content: `Reputation is scored as four independent "cups" each ranging 0–100, for a combined maximum of 400 points (displayed as a score 0–1,000,000 for fine-grained ranking):

• LOVE (0–100) — Community engagement: follows, agents run, governance votes, social interactions.
• FOOD (0–100) — Economic activity: daily volume, DEX trades, staking participation.
• RENT (0–100) — Infrastructure contribution: uptime as validator, mining blocks, running nodes.
• VACATION (0–100) — Cultural engagement: POAPs collected, events attended, name registrations.

A score of 100/100/100/100 = "Satoshi badge" — the highest achievable rank. Reputation is retro-calculated at mainnet launch from genesis activity. Displayed as colored glasses icons in the Profile page.`,
  },
  {
    id: "mica",
    title: "MiCA Compliance",
    content: `MiCA (Markets in Crypto-Assets Regulation) is an EU regulation effective 2024 requiring crypto-asset service providers to meet disclosure, reserve, and governance standards. OmniBus implements on-chain MiCA attestation via the mica_attest RPC. An authorized issuer (KYC provider) signs a structured attestation linking an ob1q address to a MiCA compliance category (EMT = Electronic Money Token, ART = Asset-Referenced Token, etc.). The mica_disclose RPC allows selective disclosure — proving compliance without revealing all personal data (GDPR-compatible). This is voluntary on testnet; required for exchange-listed pairs on mainnet.`,
  },
  {
    id: "soulbound",
    title: "Soulbound vs Transferable Addresses",
    content: `OmniBus has two classes of addresses:

Transferable addresses (ob1q... prefix) are standard Bitcoin-compatible ECDSA addresses. OMNI sent here can be moved. These are used for trading, payments, and exchange operations.

Soulbound addresses (obk1_ / obf5_ / obd5_ / obs3_ prefixes) are post-quantum addresses derived from PQ keypairs. They CANNOT receive inbound transfers from other users. They are used exclusively for:
• Identity attestations (signing claims about yourself)
• Soulbound reputation accumulation (LOVE/FOOD/RENT/VACATION)
• Governance voting power
• Validator authentication

The 4 soulbound domains map to PQ schemes: obk1_ = ML-DSA-87 (LOVE), obf5_ = Falcon-512 (FOOD), obd5_ = SLH-DSA (RENT), obs3_ = ML-KEM-768 (VACATION). They are non-transferable by design — you cannot buy or sell reputation.`,
  },
  {
    id: "dex-grid",
    title: "The DEX and Grid Trading",
    content: `OmniBus has a native on-chain DEX where the blockchain itself is the matching engine (written in Zig). Key design differences from Uniswap/Hyperliquid:

NO deposits: Funds always stay in your wallet. An HTLC (Hash Time-Locked Contract) is only created at the moment an order fills — never before.

Pairs: OMNI/USDC (pair 0), LCX/USDC (pair 2), ETH/USDC (pair 3), OMNI/LCX (pair 5), OMNI/ETH (pair 6). Pair IDs are fixed forever.

Grid trading is automated market-making. You specify a price range, number of levels, and total capital. The chain generates N buy orders + N sell orders. When the price hits a level, it fills automatically and places the opposite order one level away. The grid persists even if your browser is offline — it runs on-chain.

Settlement is atomic via HTLC + SPV proofs across chains (Sepolia, Base Sepolia, Liberty testnet). No bridge deposit/withdraw UX needed.`,
  },
  {
    id: "global-flags",
    title: "CLI Global Flags",
    content: `These flags work with every omnibus-cli command:

--rpc <url>         Override RPC URL (default: http://127.0.0.1:8332)
--chain <c>         mainnet | testnet | regtest (auto-selects port)
--remote            Use VPS endpoint at omnibusblockchain.cc:8443
--token <bearer>    RPC bearer token for authenticated nodes
--json              Raw JSON output (for scripting)
--no-color          Disable ANSI color codes
--yes / -y          Skip confirmation prompts on write commands
--mnemonic "..."    12/24-word BIP-39 mnemonic (or set OMNIBUS_MNEMONIC env)
--passphrase "..."  BIP-39 25th word / passphrase (hidden wallet)
--privkey <hex>     Raw 32-byte private key hex
--keyfile <path>    AES-GCM encrypted keyfile
--key-index <n>     BIP-44 child index (default 0)`,
  },
];

// ── Sub-components ────────────────────────────────────────────────────────────

function CodeBlock({ code }: { code: string }) {
  const [copied, setCopied] = useState(false);

  const handleCopy = () => {
    navigator.clipboard.writeText(code).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  };

  return (
    <div className="relative group">
      <pre className="bg-black/40 border border-mempool-border rounded-lg p-3 text-xs text-green-400 font-mono overflow-x-auto whitespace-pre-wrap break-all">
        {code}
      </pre>
      <button
        onClick={handleCopy}
        className="absolute top-2 right-2 opacity-0 group-hover:opacity-100 transition-opacity text-[10px] text-mempool-text-dim hover:text-mempool-text bg-mempool-bg-elev border border-mempool-border rounded px-1.5 py-0.5"
      >
        {copied ? "copied" : "copy"}
      </button>
    </div>
  );
}

function Badge({ text }: { text: string }) {
  return (
    <span className="text-[10px] font-mono bg-mempool-blue/10 text-mempool-blue border border-mempool-blue/20 rounded px-1.5 py-0.5 whitespace-nowrap">
      {text}
    </span>
  );
}

// ── CLI Tab ───────────────────────────────────────────────────────────────────

function CliTab({ search }: { search: string }) {
  const [activeCategory, setActiveCategory] = useState<string>("Node");

  const filtered = useMemo(() => {
    const q = search.toLowerCase();
    if (!q) return CLI_COMMANDS.filter((c) => c.category === activeCategory);
    return CLI_COMMANDS.filter(
      (c) =>
        c.cmd.toLowerCase().includes(q) ||
        c.description.toLowerCase().includes(q) ||
        c.params.toLowerCase().includes(q)
    );
  }, [search, activeCategory]);

  const showAll = search.length > 0;

  return (
    <div className="flex gap-4 min-h-0">
      {/* Sidebar */}
      {!showAll && (
        <aside className="w-40 flex-shrink-0">
          <div className="flex flex-col gap-0.5">
            {CLI_CATEGORIES.map((cat) => (
              <button
                key={cat}
                onClick={() => setActiveCategory(cat)}
                className={`text-left px-3 py-1.5 rounded text-xs font-medium transition-colors ${
                  activeCategory === cat
                    ? "bg-mempool-blue/15 text-mempool-blue"
                    : "text-mempool-text-dim hover:text-mempool-text hover:bg-mempool-bg-light"
                }`}
              >
                {cat}
              </button>
            ))}
          </div>
        </aside>
      )}

      {/* Content */}
      <div className="flex-1 min-w-0 flex flex-col gap-3">
        {showAll && (
          <p className="text-xs text-mempool-text-dim">
            {filtered.length} command{filtered.length !== 1 ? "s" : ""} matching &ldquo;{search}&rdquo;
          </p>
        )}
        {filtered.length === 0 && (
          <p className="text-mempool-text-dim text-sm">No commands found.</p>
        )}
        {filtered.map((cmd) => (
          <div
            key={cmd.cmd}
            className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4 flex flex-col gap-2"
          >
            <div className="flex items-start gap-2 flex-wrap">
              <span className="font-mono font-semibold text-mempool-blue text-sm">{cmd.cmd}</span>
              {showAll && <Badge text={cmd.category} />}
              {cmd.params && (
                <span className="font-mono text-mempool-text-dim text-xs">{cmd.params}</span>
              )}
            </div>
            <p className="text-sm text-mempool-text leading-relaxed">{cmd.description}</p>
            <CodeBlock code={cmd.example} />
          </div>
        ))}
      </div>
    </div>
  );
}

// ── RPC Tab ───────────────────────────────────────────────────────────────────

function RpcTab({ search }: { search: string }) {
  const [activeCategory, setActiveCategory] = useState<string>("Chain Info");

  const filtered = useMemo((): RpcMethod[] => {
    const q = search.toLowerCase();
    if (!q) return RPC_METHODS.filter((m) => m.category === activeCategory);
    return RPC_METHODS.filter(
      (m) =>
        m.method.toLowerCase().includes(q) ||
        m.description.toLowerCase().includes(q) ||
        m.params.toLowerCase().includes(q)
    );
  }, [search, activeCategory]);

  const showAll = search.length > 0;

  return (
    <div className="flex gap-4 min-h-0">
      {/* Sidebar */}
      {!showAll && (
        <aside className="w-40 flex-shrink-0">
          <div className="flex flex-col gap-0.5">
            {RPC_CATEGORIES.map((cat) => (
              <button
                key={cat}
                onClick={() => setActiveCategory(cat)}
                className={`text-left px-3 py-1.5 rounded text-xs font-medium transition-colors ${
                  activeCategory === cat
                    ? "bg-mempool-blue/15 text-mempool-blue"
                    : "text-mempool-text-dim hover:text-mempool-text hover:bg-mempool-bg-light"
                }`}
              >
                {cat}
              </button>
            ))}
          </div>
        </aside>
      )}

      {/* Content */}
      <div className="flex-1 min-w-0 flex flex-col gap-3">
        {showAll && (
          <p className="text-xs text-mempool-text-dim">
            {filtered.length} method{filtered.length !== 1 ? "s" : ""} matching &ldquo;{search}&rdquo;
          </p>
        )}
        {filtered.length === 0 && (
          <p className="text-mempool-text-dim text-sm">No methods found.</p>
        )}
        {filtered.map((m) => (
          <div
            key={m.method}
            className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4 flex flex-col gap-2"
          >
            <div className="flex items-start gap-2 flex-wrap">
              <span className="font-mono font-semibold text-mempool-blue text-sm">{m.method}</span>
              {showAll && <Badge text={m.category} />}
            </div>
            <p className="text-sm text-mempool-text leading-relaxed">{m.description}</p>
            {m.params && (
              <div>
                <p className="text-xs text-mempool-text-dim mb-1 uppercase tracking-wide">Params</p>
                <code className="text-xs font-mono text-yellow-400 bg-black/30 px-2 py-0.5 rounded">
                  {m.params}
                </code>
              </div>
            )}
            <div>
              <p className="text-xs text-mempool-text-dim mb-1 uppercase tracking-wide">Example</p>
              <CodeBlock code={m.example} />
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ── Wiki Tab ──────────────────────────────────────────────────────────────────

function WikiTab({ search }: { search: string }) {
  const [activeId, setActiveId] = useState<string>("omnibus-blockchain");

  const filtered = useMemo(() => {
    const q = search.toLowerCase();
    if (!q) return WIKI_ARTICLES;
    return WIKI_ARTICLES.filter(
      (a) =>
        a.title.toLowerCase().includes(q) ||
        a.content.toLowerCase().includes(q)
    );
  }, [search]);

  const active = WIKI_ARTICLES.find((a) => a.id === activeId) ?? WIKI_ARTICLES[0];

  return (
    <div className="flex gap-4 min-h-0">
      {/* Sidebar */}
      <aside className="w-48 flex-shrink-0">
        <div className="flex flex-col gap-0.5">
          {(search ? filtered : WIKI_ARTICLES).map((a) => (
            <button
              key={a.id}
              onClick={() => setActiveId(a.id)}
              className={`text-left px-3 py-1.5 rounded text-xs font-medium transition-colors leading-snug ${
                activeId === a.id && !search
                  ? "bg-mempool-blue/15 text-mempool-blue"
                  : "text-mempool-text-dim hover:text-mempool-text hover:bg-mempool-bg-light"
              }`}
            >
              {a.title}
            </button>
          ))}
        </div>
      </aside>

      {/* Content */}
      <div className="flex-1 min-w-0">
        {search ? (
          // Search mode: show all matches
          <div className="flex flex-col gap-4">
            {filtered.length === 0 && (
              <p className="text-mempool-text-dim text-sm">No articles found.</p>
            )}
            {filtered.map((a) => (
              <article
                key={a.id}
                className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-5"
              >
                <h2 className="text-base font-semibold text-mempool-text mb-3">{a.title}</h2>
                <p className="text-sm text-mempool-text-dim leading-relaxed whitespace-pre-line">
                  {a.content}
                </p>
              </article>
            ))}
          </div>
        ) : (
          // Normal mode: single article
          <article className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-5">
            <h2 className="text-base font-semibold text-mempool-text mb-3">{active.title}</h2>
            <p className="text-sm text-mempool-text-dim leading-relaxed whitespace-pre-line">
              {active.content}
            </p>
          </article>
        )}
      </div>
    </div>
  );
}

// ── Main DocsPage ─────────────────────────────────────────────────────────────

const DOCS_TOP_TABS: { id: TopTab; label: string; count: number }[] = [
  { id: "cli", label: "CLI Reference", count: CLI_COMMANDS.length },
  { id: "rpc", label: "RPC API", count: RPC_METHODS.length },
  { id: "wiki", label: "Wiki", count: WIKI_ARTICLES.length },
];

export function DocsPage() {
  const [topTab, setTopTab] = useState<TopTab>("cli");
  const [search, setSearch] = useState("");

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 flex flex-col gap-4">
      {/* Header */}
      <div className="flex flex-col gap-1">
        <h1 className="text-xl font-bold text-mempool-text">OmniBus Docs</h1>
        <p className="text-sm text-mempool-text-dim">
          CLI commands, JSON-RPC methods, and ecosystem wiki. Search across all categories.
        </p>
      </div>

      {/* Search bar */}
      <div className="relative">
        <svg
          className="absolute left-3 top-1/2 -translate-y-1/2 text-mempool-text-dim"
          width="15"
          height="15"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
        >
          <circle cx="11" cy="11" r="8" />
          <path d="m21 21-4.35-4.35" />
        </svg>
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder={`Search ${topTab === "cli" ? "commands" : topTab === "rpc" ? "RPC methods" : "wiki"}…`}
          className="w-full pl-9 pr-4 py-2.5 bg-mempool-bg-elev border border-mempool-border rounded-xl text-sm text-mempool-text placeholder-mempool-text-dim focus:outline-none focus:border-mempool-blue transition-colors"
        />
        {search && (
          <button
            onClick={() => setSearch("")}
            className="absolute right-3 top-1/2 -translate-y-1/2 text-mempool-text-dim hover:text-mempool-text text-xs"
          >
            clear
          </button>
        )}
      </div>

      {/* Top tab switcher */}
      <div className="flex gap-1 border-b border-mempool-border">
        {DOCS_TOP_TABS.map((tab) => (
          <button
            key={tab.id}
            onClick={() => { setTopTab(tab.id); setSearch(""); }}
            className={`px-4 py-2 text-sm font-medium transition-colors relative flex items-center gap-1.5 ${
              topTab === tab.id
                ? "text-mempool-blue"
                : "text-mempool-text-dim hover:text-mempool-text"
            }`}
          >
            {tab.label}
            <span className="text-[10px] text-mempool-text-dim">{tab.count}</span>
            {topTab === tab.id && (
              <div className="absolute bottom-0 left-0 right-0 h-0.5 bg-mempool-blue rounded-full" />
            )}
          </button>
        ))}
      </div>

      {/* Tab content */}
      <div className="flex-1">
        {topTab === "cli" && <CliTab search={search} />}
        {topTab === "rpc" && <RpcTab search={search} />}
        {topTab === "wiki" && <WikiTab search={search} />}
      </div>
    </div>
  );
}
