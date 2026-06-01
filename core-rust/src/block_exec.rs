// Execute a parsed tx against state.
//
// Fast path (M2): plain ETH transfer (to=Some, data empty) → direct balance
// mutation, fixed 21k gas.
//
// Contract path (M3, this commit): contract create (to=None) OR contract call
// (data non-empty) → route into `evm::executor::execute_tx` (revm). Logs are
// persisted via `evm::logs::write_logs`; receipt holds gas_used + status +
// optional contract address; tx record + block index unchanged.

use crate::evm;
use crate::state::{Account, EvmState};
use crate::tx::TxParsed;

#[derive(Debug)]
pub struct ExecOutcome {
    pub block_number: u64,
    pub gas_used: u64,
    pub status: u8,
    pub contract_addr: Option<[u8; 20]>,
}

pub fn apply_tx(state: &EvmState, tx: &TxParsed) -> Result<ExecOutcome, String> {
    if tx.chain_id != 0 && tx.chain_id != state.chain_id() {
        return Err(format!("chainId mismatch: tx={} chain={}", tx.chain_id, state.chain_id()));
    }

    let cur_nonce = state.nonce(&tx.from);
    if tx.nonce != cur_nonce {
        return Err(format!("nonce mismatch: tx={} expected={}", tx.nonce, cur_nonce));
    }

    let is_transfer = tx.to.is_some() && tx.data.is_empty();

    if is_transfer {
        return apply_transfer(state, tx, cur_nonce);
    }

    // Contract create or contract call: hand to revm.
    let res = evm::execute_tx(state, tx)?;

    // Charge gas: gas_used * gas_price (1 gwei placeholder, matches executor).
    // revm already committed balance changes incl. value transfer + storage,
    // but it had `disable_base_fee=true` and we keep gas accounting external
    // for now (Phase: real fee market when L1 settles).
    let gas_price: u128 = 1_000_000_000;
    let gas_cost: u128 = (res.gas_used as u128).saturating_mul(gas_price);
    let from_bal = state.balance(&tx.from);
    let new_bal = from_bal.saturating_sub(gas_cost);
    let from_nonce_post = state.nonce(&tx.from);
    state.set_account(&tx.from, &Account {
        balance: new_bal,
        nonce: from_nonce_post.max(cur_nonce + 1),
        code: state.code(&tx.from),
    }).map_err(|e| format!("persist from: {e}"))?;

    let new_block = state.bump_block()?;
    state.write_tx(&tx.hash, tx, new_block)?;
    let status_byte: u8 = match res.status {
        evm::ExecStatus::Success => 1,
        _ => 0,
    };
    state.write_receipt(&tx.hash, new_block, res.gas_used, status_byte, res.contract_addr)?;

    // Stamp logs with the canonical block number (executor used n+1 too).
    let stamped: Vec<evm::Log> = res.logs.into_iter().map(|mut l| {
        l.block = new_block;
        l.tx_hash = tx.hash;
        l
    }).collect();
    let _ = evm::write_logs(state, &tx.hash, &stamped);

    Ok(ExecOutcome {
        block_number: new_block,
        gas_used: res.gas_used,
        status: status_byte,
        contract_addr: res.contract_addr,
    })
}

fn apply_transfer(state: &EvmState, tx: &TxParsed, cur_nonce: u64) -> Result<ExecOutcome, String> {
    let to = tx.to.expect("apply_transfer requires to=Some");

    let from_bal = state.balance(&tx.from);
    if from_bal < tx.value {
        return Err(format!("insufficient balance: have={} need={}", from_bal, tx.value));
    }

    state.set_account(&tx.from, &Account {
        balance: from_bal - tx.value,
        nonce: cur_nonce + 1,
        code: state.code(&tx.from),
    }).map_err(|e| format!("persist from: {e}"))?;

    let to_bal = state.balance(&to);
    state.set_account(&to, &Account {
        balance: to_bal.saturating_add(tx.value),
        nonce: state.nonce(&to),
        code: state.code(&to),
    }).map_err(|e| format!("persist to: {e}"))?;

    let new_block = state.bump_block()?;
    state.write_tx(&tx.hash, tx, new_block)?;
    state.write_receipt(&tx.hash, new_block, 21_000, 1, None)?;

    Ok(ExecOutcome {
        block_number: new_block,
        gas_used: 21_000,
        status: 1,
        contract_addr: None,
    })
}
