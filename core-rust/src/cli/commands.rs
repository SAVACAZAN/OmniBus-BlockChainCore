//! commands — all CLI subcommand handlers.
//!
//! Each `cmd_*` function maps 1:1 to a Zig handler in core/cli/common.zig.
//! Read commands call `rpc_call` and pretty-print the result; write commands
//! additionally require `--yes` and a signing key (resolved from `--mnemonic`
//! / `OMNIBUS_MNEMONIC` / `--privkey` / `--keyfile`).
//!
//! Ported from core/cli/common.zig (subcommand sections, 2026-06-02).

use serde_json::{json, Value};
use std::collections::HashMap;

use super::common::{
    format_omni, json_str, json_u64, parse_day, print_usage, resolve_endpoint,
    rpc_call, CliArgs, Colors, RpcError,
};

// ─── Entry point ──────────────────────────────────────────────────────────────

/// Top-level dispatcher. Returns the process exit code (0 = ok, 1 = error,
/// 2 = usage error).
pub async fn run(args: CliArgs) -> i32 {
    let col = Colors::new(!args.no_color);
    let ep = resolve_endpoint(&args);

    match args.cmd.as_str() {
        "" | "help" | "-h" | "--help" => {
            print_usage();
            0
        }

        // ── read commands ─────────────────────────────────────────────────
        "health" => cmd_health(&ep, &args, &col).await,

        "balance" => {
            let addr = match args.pos.first() {
                Some(a) => a.clone(),
                None => {
                    eprintln!("{}error:{} balance <addr>", col.red(), col.reset());
                    return 2;
                }
            };
            cmd_balance(&ep, &addr, &args, &col).await
        }

        "wallet-summary" => {
            let addr = match args.pos.first() {
                Some(a) => a.clone(),
                None => {
                    eprintln!("{}error:{} wallet-summary <addr>", col.red(), col.reset());
                    return 2;
                }
            };
            cmd_wallet_summary(&ep, &addr, &args, &col).await
        }

        "stake" => {
            let addr = match args.pos.first() {
                Some(a) => a.clone(),
                None => {
                    eprintln!("{}error:{} stake <addr>", col.red(), col.reset());
                    return 2;
                }
            };
            cmd_stake(&ep, &addr, &args, &col).await
        }

        "reputation" => {
            let addr = match args.pos.first() {
                Some(a) => a.clone(),
                None => {
                    eprintln!("{}error:{} reputation <addr>", col.red(), col.reset());
                    return 2;
                }
            };
            cmd_reputation(&ep, &addr, &args, &col).await
        }

        "daily" => {
            let addr = match args.pos.first() {
                Some(a) => a.clone(),
                None => {
                    eprintln!("{}error:{} daily <addr> [days]", col.red(), col.reset());
                    return 2;
                }
            };
            let days: u64 = args.pos.get(1).and_then(|d| d.parse().ok()).unwrap_or(30);
            cmd_daily(&ep, &addr, days, &args, &col).await
        }

        "validators" => cmd_validators(&ep, &args, &col).await,

        "stakers" => {
            let limit: u64 = args.pos.first().and_then(|d| d.parse().ok()).unwrap_or(10);
            cmd_stakers(&ep, limit, &args, &col).await
        }

        "history" => {
            let addr = match args.pos.first() {
                Some(a) => a.clone(),
                None => {
                    eprintln!("{}error:{} history <addr> [filter]", col.red(), col.reset());
                    return 2;
                }
            };
            let filter = args.pos.get(1).cloned().unwrap_or_else(|| "all".into());
            cmd_history(&ep, &addr, &filter, &args, &col).await
        }

        "verify" => {
            let addr = match args.pos.first() {
                Some(a) => a.clone(),
                None => {
                    eprintln!("{}error:{} verify <addr>", col.red(), col.reset());
                    return 2;
                }
            };
            cmd_verify(&ep, &addr, &args, &col).await
        }

        // ── wallet commands ───────────────────────────────────────────────
        "derive-key" => {
            let idx: u32 = args.pos.first().and_then(|v| v.parse().ok()).unwrap_or(0);
            cmd_derive_key(idx, &args, &col).await
        }

        "wallet-list" => {
            let count: u32 = args.pos.first().and_then(|v| v.parse().ok()).unwrap_or(10);
            cmd_wallet_list(count, &args, &col).await
        }

        // ── advanced passthrough commands ─────────────────────────────────
        "ns"       => cmd_passthrough(&ep, "ns",       &args, &col).await,
        "oracle"   => cmd_passthrough(&ep, "oracle",   &args, &col).await,
        "grid"     => cmd_passthrough(&ep, "grid",     &args, &col).await,
        "agents"   => cmd_passthrough(&ep, "agents",   &args, &col).await,
        "pq"       => cmd_passthrough(&ep, "pq",       &args, &col).await,
        "htlc"     => cmd_passthrough(&ep, "htlc",     &args, &col).await,
        "escrow"   => cmd_passthrough(&ep, "escrow",   &args, &col).await,
        "mining"   => cmd_passthrough(&ep, "mining",   &args, &col).await,
        "exchange" => cmd_passthrough(&ep, "exchange", &args, &col).await,
        "gov"      => cmd_passthrough(&ep, "gov",      &args, &col).await,
        "social"   => cmd_passthrough(&ep, "social",   &args, &col).await,
        "notarize" => cmd_passthrough(&ep, "notarize", &args, &col).await,
        "audit"    => cmd_passthrough(&ep, "audit",    &args, &col).await,
        "admin"    => cmd_passthrough(&ep, "admin",    &args, &col).await,

        // ── New sprint-2026-06-02 commands (JSON-object params) ───────────
        // `omnibus spark status`
        // `omnibus spark votes --block_hash=<hex64>`
        "spark" => cmd_passthrough_kv(&ep, "spark", &args, &col).await,
        // `omnibus strategy register --agent_id=N --owner=ob1q --name=... --type=grid --params={}`
        // `omnibus strategy activate --id=N`
        // `omnibus strategy get --id=N`
        // `omnibus strategy list --owner=ob1q   (or --agent_id=N)`
        "strategy" => cmd_passthrough_kv(&ep, "strategy", &args, &col).await,
        // `omnibus slot-calendar` → 60 pre-computed leader slots
        "slot-calendar" => cmd_slot_calendar(&ep, &args, &col).await,

        other => {
            eprintln!("{}error:{} unknown subcommand `{other}`. Try --help.",
                      col.red(), col.reset());
            2
        }
    }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Print a `RpcError` in a consistent format and return exit code 1.
fn print_rpc_err(e: &RpcError, col: &Colors) -> i32 {
    eprintln!("{}RPC error:{} {e}", col.red(), col.reset());
    1
}

/// Print raw JSON response when `--json` flag is set.
fn dump_json(v: &Value) {
    println!("{v}");
}

// ─── Subcommand: health ───────────────────────────────────────────────────────

async fn cmd_health(ep: &super::common::Endpoint, args: &CliArgs, col: &Colors) -> i32 {
    let result = rpc_call(ep, "getchainmetrics", json!([])).await;
    match result {
        Err(e) => print_rpc_err(&e, col),
        Ok(v) => {
            if args.json { dump_json(&v); return 0; }

            println!("{}=== Chain Health ==={}", col.bold(), col.reset());
            println!("Height:           {}{}{}", col.green(), json_u64(&v, "height"), col.reset());
            if let Some(th) = v.get("tipHash").and_then(|x| x.as_str()) {
                println!("Tip hash:         {th}");
            }
            let supply = json_u64(&v, "totalSupply");
            println!("Total supply:     {} OMNI", format_omni(supply));
            println!("Addresses w/bal:  {}", json_u64(&v, "addressesWithBalance"));
            println!("Validators:       {}", json_u64(&v, "validators"));
            println!("Mempool size:     {}", json_u64(&v, "mempoolSize"));
            println!("Peers:            {}", json_u64(&v, "peerCount"));
            let reward = json_u64(&v, "currentBlockReward");
            println!("Block reward:     {} OMNI", format_omni(reward));

            // Sync status — best-effort
            if let Ok(sv) = rpc_call(ep, "getsyncstatus", json!([])).await {
                let synced = sv.get("synced").and_then(|b| b.as_bool()).unwrap_or(false);
                let local  = json_u64(&sv, "localHeight");
                let peer   = json_u64(&sv, "peerHeight");
                let tag    = if synced { "SYNCED" } else { "SYNCING" };
                let c      = if synced { col.green() } else { col.yellow() };
                println!("Sync status:      {}{}{} (local={local} peer={peer})", c, tag, col.reset());
            }
            0
        }
    }
}

// ─── Subcommand: balance ──────────────────────────────────────────────────────

async fn cmd_balance(
    ep: &super::common::Endpoint,
    addr: &str,
    args: &CliArgs,
    col: &Colors,
) -> i32 {
    let bal_fut   = rpc_call(ep, "getbalance",    json!([addr]));
    let stake_fut = rpc_call(ep, "getstake",      json!({"address": addr}));
    let rep_fut   = rpc_call(ep, "getreputation", json!([addr]));

    let (bal_r, stake_r, rep_r) = tokio::join!(bal_fut, stake_fut, rep_fut);

    if args.json {
        let bal   = bal_r.as_ref().unwrap_or(&Value::Null);
        let stake = stake_r.as_ref().unwrap_or(&Value::Null);
        let rep   = rep_r.as_ref().unwrap_or(&Value::Null);
        println!("{{\"balance\":{bal},\"stake\":{stake},\"reputation\":{rep}}}");
        return 0;
    }

    println!("{}=== Balance: {addr} ==={}", col.bold(), col.reset());

    // Wallet balance
    let bal_sat = match bal_r {
        Err(ref e) => { print_rpc_err(e, col); return 1; }
        Ok(ref v)  => json_u64(v, "balance"),
    };

    // Staked total
    let stake_sat: u64 = stake_r.as_ref()
        .ok()
        .and_then(|r| r.get("stakes"))
        .and_then(|arr| arr.as_array())
        .map(|arr| arr.iter().map(|s| json_u64(s, "amount_sat")).sum())
        .unwrap_or(0);

    println!("Wallet:    {}{}{} OMNI", col.green(), format_omni(bal_sat), col.reset());
    if stake_sat > 0 {
        println!("Staked:    {}{}{} OMNI {}(active){}",
                 col.yellow(), format_omni(stake_sat), col.reset(),
                 col.gray(), col.reset());
        let avail = bal_sat.saturating_sub(stake_sat);
        println!("Available: {} OMNI", format_omni(avail));
    } else {
        println!("Staked:    0.0000 OMNI");
        println!("Available: {} OMNI", format_omni(bal_sat));
    }

    // Reputation
    if let Ok(r) = rep_r {
        let total = json_u64(&r, "total");
        let tier  = json_str(&r, "tier");
        let tier  = if tier.is_empty() { "OMNI" } else { tier };
        println!("\nReputation: {}{}{} / 1,000,000  Tier {}{}{}",
                 col.cyan(), total, col.reset(),
                 col.magenta(), tier, col.reset());
        if let Some(cups) = r.get("cups") {
            let love = json_str(cups, "love");
            let food = json_str(cups, "food");
            let rent = json_str(cups, "rent");
            let vac  = json_str(cups, "vacation");
            let fmt  = |s: &str| if s.is_empty() { "0.00".to_string() } else { s.to_string() };
            println!("  LOVE:     {} / 100", fmt(love));
            println!("  FOOD:     {} / 100", fmt(food));
            println!("  RENT:     {} / 100", fmt(rent));
            println!("  VACATION: {} / 100", fmt(vac));
        }
    }
    0
}

// ─── Subcommand: wallet-summary ────────────────────────────────────────────────

async fn cmd_wallet_summary(
    ep: &super::common::Endpoint,
    addr: &str,
    args: &CliArgs,
    col: &Colors,
) -> i32 {
    match rpc_call(ep, "getwalletsummary", json!([addr])).await {
        Err(e) => print_rpc_err(&e, col),
        Ok(r) => {
            if args.json { dump_json(&r); return 0; }

            let wallet_sat  = json_u64(&r, "wallet_sat");
            let staked_sat  = json_u64(&r, "staked_sat");
            let in_orders   = json_u64(&r, "in_orders_sat");
            let available   = json_u64(&r, "available_sat");
            let height      = json_u64(&r, "height");

            println!("{}=== Wallet summary: {addr} ==={}", col.bold(), col.reset());
            println!("Block height : {height}");
            println!("Wallet       : {}{}{} OMNI  (total on chain)",
                     col.bold(), format_omni(wallet_sat), col.reset());
            println!("Staked       : {}{}{} OMNI  (locked, earning votes)",
                     col.magenta(), format_omni(staked_sat), col.reset());
            println!("In orders    : {}{}{} OMNI  (active sell orders)",
                     col.yellow(), format_omni(in_orders), col.reset());
            println!("Available    : {}{}{} OMNI  (spendable now)",
                     col.green(), format_omni(available), col.reset());

            if let Some(stakes) = r.get("stakes").and_then(|s| s.as_array()) {
                if !stakes.is_empty() {
                    println!("\n{}Stake locks:{}", col.bold(), col.reset());
                    for s in stakes {
                        let sid   = json_u64(s, "id");
                        let amt   = json_u64(s, "amount_sat");
                        let sblk  = json_u64(s, "started_at_block");
                        let lockb = json_u64(s, "lock_blocks");
                        let days  = json_u64(s, "days_locked");
                        let stat  = json_str(s, "status");
                        println!("  #{sid}: {} OMNI · {days}d · started @{sblk} · lock {lockb} blocks · {stat}",
                                 format_omni(amt));
                    }
                }
            }

            if let Some(orders) = r.get("open_sell_orders").and_then(|o| o.as_array()) {
                if !orders.is_empty() {
                    println!("\n{}Open sell orders:{}", col.bold(), col.reset());
                    for o in orders {
                        let oid   = json_u64(o, "order_id");
                        let pid   = json_u64(o, "pair_id");
                        let rem   = json_u64(o, "remaining_sat");
                        let price = json_u64(o, "price_micro_usd");
                        println!("  order #{oid} · pair {pid} · {} OMNI @ {price} µUSD",
                                 format_omni(rem));
                    }
                }
            }
            0
        }
    }
}

// ─── Subcommand: stake ────────────────────────────────────────────────────────

async fn cmd_stake(
    ep: &super::common::Endpoint,
    addr: &str,
    args: &CliArgs,
    col: &Colors,
) -> i32 {
    let stake_fut = rpc_call(ep, "getstake",         json!({"address": addr}));
    let hist_fut  = rpc_call(ep, "getaddresshistory", json!([addr]));
    let (stake_r, hist_r) = tokio::join!(stake_fut, hist_fut);

    if args.json {
        let s = stake_r.as_ref().unwrap_or(&Value::Null);
        let h = hist_r.as_ref().unwrap_or(&Value::Null);
        println!("{{\"stake\":{s},\"history\":{h}}}");
        return 0;
    }

    println!("{}=== Stake: {addr} ==={}", col.bold(), col.reset());

    let stake_sat: u64 = stake_r.as_ref().ok()
        .and_then(|r| r.get("stakes"))
        .and_then(|arr| arr.as_array())
        .map(|arr| arr.iter().map(|s| json_u64(s, "amount_sat")).sum())
        .unwrap_or(0);

    println!("Current stake: {}{}{} OMNI {}(active){}",
             col.yellow(), format_omni(stake_sat), col.reset(),
             col.gray(), col.reset());

    let mut sum_stake: u64 = 0;
    let mut sum_unstake: u64 = 0;
    println!("\nRecent stake activity:");

    if let Ok(hist) = hist_r {
        if let Some(txs) = hist.get("transactions").and_then(|t| t.as_array()) {
            let mut found = false;
            for tx in txs {
                let kind = json_str(tx, "kind");
                let is_stake   = kind == "stake";
                let is_unstake = kind == "unstake";
                if !is_stake && !is_unstake { continue; }
                found = true;
                let amt = json_u64(tx, "amount");
                if is_stake { sum_stake += amt; } else { sum_unstake += amt; }
                let sign = if is_unstake { "-" } else { "+" };
                let c    = if is_unstake { col.red() } else { col.green() };
                let txid_full = json_str(tx, "txid");
                let txid = if txid_full.len() > 8 { &txid_full[..8] } else { txid_full };
                let bh = json_u64(tx, "blockHeight");
                let kind_up = kind.to_uppercase();
                println!("  block {bh:>7}  {c}{sign}{} OMNI  {kind_up}  {txid}...", col.reset());
            }
            if !found { println!("  (no stake/unstake TXs found)"); }
        }
    }

    let computed = sum_stake.saturating_sub(sum_unstake);
    print!("\nRunning total: {} OMNI", format_omni(computed));
    if computed == stake_sat {
        println!(" {}(matches chain){}", col.green(), col.reset());
    } else {
        println!(" {}(MISMATCH chain={} OMNI){}",
                 col.red(), format_omni(stake_sat), col.reset());
    }
    0
}

// ─── Subcommand: reputation ────────────────────────────────────────────────────

async fn cmd_reputation(
    ep: &super::common::Endpoint,
    addr: &str,
    args: &CliArgs,
    col: &Colors,
) -> i32 {
    match rpc_call(ep, "getreputation", json!([addr])).await {
        Err(e) => print_rpc_err(&e, col),
        Ok(r) => {
            if args.json { dump_json(&r); return 0; }

            println!("{}=== Reputation: {addr} ==={}", col.bold(), col.reset());
            let total = json_u64(&r, "total");
            let tier  = json_str(&r, "tier");
            let tier  = if tier.is_empty() { "OMNI" } else { tier };
            println!("Total: {}{}{} / 1,000,000", col.cyan(), total, col.reset());
            println!("Tier:  {}{}{}", col.magenta(), tier, col.reset());

            if let Some(cups) = r.get("cups") {
                fn cup(s: &str) -> &str { if s.is_empty() { "0.00" } else { s } }
                println!("\nCups:");
                println!("  LOVE:     {} / 100", cup(json_str(cups, "love")));
                println!("  FOOD:     {} / 100", cup(json_str(cups, "food")));
                println!("  RENT:     {} / 100", cup(json_str(cups, "rent")));
                println!("  VACATION: {} / 100", cup(json_str(cups, "vacation")));
            }
            println!("\nFirst block: {}", json_u64(&r, "first_active_block"));
            println!("Last block:  {}", json_u64(&r, "last_active_block"));
            println!("Mined:       {}", json_u64(&r, "total_blocks_mined"));
            println!("Violations:  {}", json_u64(&r, "violations"));
            0
        }
    }
}

// ─── Subcommand: daily ────────────────────────────────────────────────────────

#[derive(Default)]
struct DayBucket {
    day: u64,
    count: u64,
    sent: u64,
    received: u64,
    mined: u64,
    fees: u64,
    stake_delta: i128,
}

async fn cmd_daily(
    ep: &super::common::Endpoint,
    addr: &str,
    days: u64,
    args: &CliArgs,
    col: &Colors,
) -> i32 {
    match rpc_call(ep, "getaddresshistory", json!([addr])).await {
        Err(e) => print_rpc_err(&e, col),
        Ok(r) => {
            if args.json { dump_json(&r); return 0; }

            let mut buckets: HashMap<u64, DayBucket> = HashMap::new();
            if let Some(txs) = r.get("transactions").and_then(|t| t.as_array()) {
                for tx in txs {
                    let bh = json_u64(tx, "blockHeight");
                    if bh == 0 { continue; } // pending
                    let day = parse_day(bh);
                    let b = buckets.entry(day).or_insert(DayBucket { day, ..Default::default() });
                    b.count += 1;
                    let amount = json_u64(tx, "amount");
                    let fee    = json_u64(tx, "fee");
                    let dir    = json_str(tx, "direction");
                    let kind   = json_str(tx, "kind");
                    if dir == "sent" {
                        b.sent += amount;
                        b.fees += fee;
                    } else {
                        b.received += amount;
                        if matches!(kind, "coinbase" | "mined" | "block_reward") {
                            b.mined += amount;
                        }
                    }
                    match kind {
                        "stake"   => b.stake_delta += amount as i128,
                        "unstake" => b.stake_delta -= amount as i128,
                        _ => {}
                    }
                }
            }

            // Sort by day desc
            let mut entries: Vec<DayBucket> = buckets.into_values().collect();
            entries.sort_by(|a, b| b.day.cmp(&a.day));

            println!("{}=== Daily breakdown: {addr} (last {days} days w/ activity) ==={}",
                     col.bold(), col.reset());
            println!("{}{:<8} {:>6} {:>14} {:>14} {:>14} {:>10} {:>14}{}",
                     col.gray(), "Day#", "TXs", "Sent", "Received", "Mined", "Fees", "StakeDelta",
                     col.reset());

            let mut tot = DayBucket::default();
            let mut shown: u64 = 0;
            for b in &entries {
                if shown >= days { break; }
                let stake_abs  = b.stake_delta.unsigned_abs() as u64;
                let stake_sign = if b.stake_delta < 0 { "-" } else { "+" };
                println!("{:<8} {:>6} {:>14} {:>14} {:>14} {:>10} {}{:>13}",
                         b.day, b.count,
                         format_omni(b.sent),
                         format_omni(b.received),
                         format_omni(b.mined),
                         format_omni(b.fees),
                         stake_sign,
                         format_omni(stake_abs));
                tot.count       += b.count;
                tot.sent        += b.sent;
                tot.received    += b.received;
                tot.mined       += b.mined;
                tot.fees        += b.fees;
                tot.stake_delta += b.stake_delta;
                shown += 1;
            }
            let tot_abs  = tot.stake_delta.unsigned_abs() as u64;
            let tot_sign = if tot.stake_delta < 0 { "-" } else { "+" };
            println!("{}{:<8} {:>6} {:>14} {:>14} {:>14} {:>10} {}{:>13}{}",
                     col.bold(), "Total", tot.count,
                     format_omni(tot.sent),
                     format_omni(tot.received),
                     format_omni(tot.mined),
                     format_omni(tot.fees),
                     tot_sign, format_omni(tot_abs),
                     col.reset());
            0
        }
    }
}

// ─── Subcommand: validators ────────────────────────────────────────────────────

async fn cmd_validators(
    ep: &super::common::Endpoint,
    args: &CliArgs,
    col: &Colors,
) -> i32 {
    match rpc_call(ep, "getvalidators", json!([])).await {
        Err(e) => print_rpc_err(&e, col),
        Ok(r) => {
            if args.json { dump_json(&r); return 0; }
            println!("{}=== Validators ({}) ==={}", col.bold(), json_u64(&r, "count"), col.reset());
            if let Some(vs) = r.get("validators").and_then(|v| v.as_array()) {
                for (i, v) in vs.iter().enumerate() {
                    println!("{:>4}. {:<48} weight={:<6} since_h={}",
                             i + 1,
                             json_str(v, "address"),
                             json_u64(v, "weight"),
                             json_u64(v, "since_height"));
                }
            }
            0
        }
    }
}

// ─── Subcommand: stakers ──────────────────────────────────────────────────────

async fn cmd_stakers(
    ep: &super::common::Endpoint,
    limit: u64,
    args: &CliArgs,
    col: &Colors,
) -> i32 {
    match rpc_call(ep, "getstakers", json!({"limit": limit})).await {
        Err(e) => print_rpc_err(&e, col),
        Ok(r) => {
            if args.json { dump_json(&r); return 0; }
            println!("{}=== Top Stakers (limit {limit}) ==={}", col.bold(), col.reset());

            let mut entries: Vec<(String, u64)> = r.get("stakers")
                .and_then(|s| s.as_array())
                .map(|arr| arr.iter().map(|s| {
                    (json_str(s, "address").to_string(), json_u64(s, "amount_sat"))
                }).collect())
                .unwrap_or_default();

            entries.sort_by(|a, b| b.1.cmp(&a.1));

            if entries.is_empty() {
                println!("(no stakers)");
            } else {
                for (i, (addr, sat)) in entries.iter().enumerate() {
                    println!("{:>4}. {:<48} {} OMNI", i + 1, addr, format_omni(*sat));
                }
            }
            0
        }
    }
}

// ─── Subcommand: history ──────────────────────────────────────────────────────

async fn cmd_history(
    ep: &super::common::Endpoint,
    addr: &str,
    filter: &str,
    args: &CliArgs,
    col: &Colors,
) -> i32 {
    match rpc_call(ep, "getaddresshistory", json!([addr])).await {
        Err(e) => print_rpc_err(&e, col),
        Ok(r) => {
            if args.json { dump_json(&r); return 0; }
            println!("{}=== History: {addr} (filter={filter}) ==={}", col.bold(), col.reset());

            if let Some(txs) = r.get("transactions").and_then(|t| t.as_array()) {
                let mut shown = 0usize;
                for tx in txs {
                    let dir  = json_str(tx, "direction");
                    let kind = json_str(tx, "kind");

                    // Apply filter
                    if filter != "all" {
                        let keep = match filter {
                            "stake"    => kind == "stake" || kind == "unstake",
                            "sent"     => dir == "sent",
                            "received" => dir == "received",
                            "mined"    => matches!(kind, "coinbase" | "mined" | "block_reward"),
                            _          => true,
                        };
                        if !keep { continue; }
                    }

                    let txid_full = json_str(tx, "txid");
                    let txid = if txid_full.len() > 12 { &txid_full[..12] } else { txid_full };
                    let bh   = json_u64(tx, "blockHeight");
                    let amt  = json_u64(tx, "amount");
                    println!("  block {bh:>7}  {kind:<10} {dir:<8}  {} OMNI  {txid}...",
                             format_omni(amt));
                    shown += 1;
                    if shown >= 200 {
                        println!("  ... (truncated at 200)");
                        break;
                    }
                }
                if shown == 0 { println!("(no matching TXs)"); }
            }
            0
        }
    }
}

// ─── Subcommand: verify ───────────────────────────────────────────────────────

async fn cmd_verify(
    ep: &super::common::Endpoint,
    addr: &str,
    args: &CliArgs,
    col: &Colors,
) -> i32 {
    let stake_fut = rpc_call(ep, "getstake",         json!({"address": addr}));
    let hist_fut  = rpc_call(ep, "getaddresshistory", json!([addr]));
    let (stake_r, hist_r) = tokio::join!(stake_fut, hist_fut);

    let chain_stake: u64 = stake_r.as_ref().ok()
        .and_then(|r| r.get("stakes"))
        .and_then(|arr| arr.as_array())
        .map(|arr| arr.iter().map(|s| json_u64(s, "amount_sat")).sum())
        .unwrap_or(0);

    let (sum_stake, sum_unstake) = hist_r.as_ref().ok()
        .and_then(|r| r.get("transactions"))
        .and_then(|t| t.as_array())
        .map(|txs| {
            txs.iter().fold((0u64, 0u64), |(s, u), tx| {
                let amt = json_u64(tx, "amount");
                match json_str(tx, "kind") {
                    "stake"   => (s + amt, u),
                    "unstake" => (s, u + amt),
                    _         => (s, u),
                }
            })
        })
        .unwrap_or((0, 0));

    let computed = sum_stake.saturating_sub(sum_unstake);

    if args.json {
        println!(
            "{{\"chain_stake_sat\":{chain_stake},\"sum_stake_sat\":{sum_stake},\
             \"sum_unstake_sat\":{sum_unstake},\"computed_sat\":{computed},\
             \"match\":{}}}",
            computed == chain_stake
        );
        return if computed == chain_stake { 0 } else { 1 };
    }

    println!("{}=== Sanity check: {addr} ==={}", col.bold(), col.reset());
    println!("================================");
    println!("Chain stake_amounts:    {} OMNI  (from getstake)", format_omni(chain_stake));
    println!("Sum of STAKE TXs:       {} OMNI  (from getaddresshistory, kind=stake)", format_omni(sum_stake));
    println!("Sum of UNSTAKE TXs:     {} OMNI", format_omni(sum_unstake));
    println!("Computed = stake - unstake = {} OMNI", format_omni(computed));

    if computed == chain_stake {
        println!("Chain == Computed: {}MATCH (in sync){}", col.green(), col.reset());
        0
    } else {
        println!("Chain == Computed: {}MISMATCH{}", col.red(), col.reset());
        println!(
            "\n  {}Chain shows {} but TXs sum to {}.{} Possible causes:",
            col.yellow(), format_omni(chain_stake), format_omni(computed), col.reset()
        );
        println!("    - Restart wiped state before TX replay");
        println!("    - applyOpReturnRoles bug");
        println!("    - Recommend: SSH restart node to force replay");
        1
    }
}

// ─── Subcommand: derive-key ───────────────────────────────────────────────────

async fn cmd_derive_key(idx: u32, args: &CliArgs, col: &Colors) -> i32 {
    // Key derivation requires the omnibus-crypto-core crate (Rust impl).
    // For now emit a clear error; the Zig CLI (`zig-out/bin/omnibus-cli`) or
    // the full wallet module should be used for derivation.
    eprintln!(
        "{}note:{} derive-key requires omnibus-crypto-core integration.\n\
         Use `omnibus-cli` (Zig) or the wallet module for key derivation at index {idx}.\n\
         Alternatively pass --privkey / OMNIBUS_PRIVKEY for signing operations.",
        col.yellow(), col.reset()
    );
    if args.json {
        println!("{{\"error\":\"derive-key not yet wired in the Rust CLI\",\"index\":{idx}}}");
    }
    2
}

// ─── Subcommand: wallet-list ──────────────────────────────────────────────────

async fn cmd_wallet_list(count: u32, args: &CliArgs, col: &Colors) -> i32 {
    eprintln!(
        "{}note:{} wallet-list requires omnibus-crypto-core integration.\n\
         Use `omnibus-cli` (Zig) for offline BIP-44 derivation of {count} addresses.",
        col.yellow(), col.reset()
    );
    if args.json {
        println!("{{\"error\":\"wallet-list not yet wired in the Rust CLI\",\"count\":{count}}}");
    }
    2
}

// ─── Advanced passthrough commands ───────────────────────────────────────────

/// Generic passthrough: the first positional arg is the sub-sub-command, which
/// we map to a JSON-RPC method name (`{group}_{sub}`) and forward any remaining
/// positional args as the params array.
///
/// Example:
///   omnibus-cli ns lookup foo.omnibus
///   → rpc_call("ns_lookup", ["foo.omnibus"])
async fn cmd_passthrough(
    ep: &super::common::Endpoint,
    group: &str,
    args: &CliArgs,
    col: &Colors,
) -> i32 {
    let sub = match args.pos.first() {
        Some(s) => s.clone(),
        None => {
            eprintln!("{}error:{} `{group}` requires a sub-command. Try --help.",
                      col.red(), col.reset());
            return 2;
        }
    };

    let method = format!("{group}_{sub}");
    // Remaining positionals become the params array (as strings).
    let params: Value = args.pos.iter().skip(1)
        .map(|s| Value::String(s.clone()))
        .collect::<Vec<_>>()
        .into();

    match rpc_call(ep, &method, params).await {
        Err(e) => print_rpc_err(&e, col),
        Ok(v) => {
            // Always dump JSON for passthrough commands — we don't know the schema.
            println!("{v}");
            0
        }
    }
}

// ─── Object-param passthrough (new in 2026-06-02 sprint) ─────────────────────

/// JSON-object passthrough: builds RPC params from `--key=value` flags.
///
/// Example:
///   `omnibus strategy register --agent_id=1 --owner=ob1q --name=g --type=grid`
///   →  method = "strategy_register",
///      params = {"agent_id":"1", "owner":"ob1q", "name":"g", "type":"grid"}
///
/// Numbers are converted to JSON numbers; everything else stays as a string.
/// Pass `--json-params=<raw>` to inject a raw JSON object verbatim (for
/// nested fields like the `params` blob in `strategy_register`).
async fn cmd_passthrough_kv(
    ep: &super::common::Endpoint,
    group: &str,
    args: &CliArgs,
    col: &Colors,
) -> i32 {
    let sub = match args.pos.first() {
        Some(s) => s.clone(),
        None => {
            eprintln!("{}error:{} `{group}` requires a sub-command. Try --help.",
                      col.red(), col.reset());
            return 2;
        }
    };
    let method = format!("{group}_{sub}");

    // Build params object from --key=value flags.
    let mut obj = serde_json::Map::new();
    for (k, v) in &args.kvs {
        // Try to parse as number first; fall back to string.
        let val: Value = if let Ok(n) = v.parse::<i64>() {
            json!(n)
        } else if let Ok(f) = v.parse::<f64>() {
            json!(f)
        } else {
            json!(v)
        };
        obj.insert(k.clone(), val);
    }

    let params = Value::Object(obj);

    match rpc_call(ep, &method, params).await {
        Err(e) => print_rpc_err(&e, col),
        Ok(v) => {
            println!("{v}");
            0
        }
    }
}

// ─── slot-calendar (custom: pretty-prints the 60 slots) ──────────────────────

async fn cmd_slot_calendar(
    ep: &super::common::Endpoint,
    args: &CliArgs,
    col: &Colors,
) -> i32 {
    match rpc_call(ep, "getslotcalendar", json!([])).await {
        Err(e) => print_rpc_err(&e, col),
        Ok(v) => {
            if args.json {
                dump_json(&v);
                return 0;
            }
            let head = json_u64(&v, "head_slot");
            let interval = json_u64(&v, "slot_interval_ms");
            let tip = json_u64(&v, "tip_height");
            println!("{}=== Slot Calendar ==={}", col.bold(), col.reset());
            println!("Tip height:      {tip}");
            println!("Head slot:       {head}");
            println!("Slot interval:   {interval} ms");
            let empty: Vec<Value> = vec![];
            let entries = v.get("entries").and_then(|e| e.as_array()).unwrap_or(&empty);
            println!("Entries:         {}", entries.len());
            for (i, e) in entries.iter().take(10).enumerate() {
                let sid = json_u64(e, "slot_id");
                let leader = json_str(e, "leader");
                let state = json_str(e, "state");
                let arrival = json_u64(e, "expected_arrival_ms");
                println!(
                    "  [{i:>2}] slot={sid:>10} state={state:<10} leader=0x{leader} arrival_ms={arrival}"
                );
            }
            if entries.len() > 10 {
                println!("{}  … {} more (use --json for full output){}",
                         col.gray(), entries.len() - 10, col.reset());
            }
            0
        }
    }
}
