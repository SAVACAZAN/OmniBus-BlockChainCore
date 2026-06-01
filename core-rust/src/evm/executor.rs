// Thin wrapper over revm::Evm — two entry points:
//   * execute_call  → read-only eth_call / eth_estimateGas (no state commit)
//   * execute_tx    → eth_sendRawTransaction (commits new accounts/code/storage)
//
// Result types are deliberately plain (no revm leakage) so callers don't depend
// on the revm crate. If we later swap revm for a Zig EVM, only this file
// and db.rs change.

use revm::primitives::{Bytes, ExecutionResult, Output, TxKind, U256};
use revm::Evm;

use crate::evm::db::{addr_to, EvmStateDb, EvmStateDbRef};
use crate::evm::logs::Log;
use crate::state::EvmState;
use crate::tx::TxParsed;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExecStatus { Success, Revert, Halt }

#[derive(Debug, Clone)]
pub struct ExecResult {
    pub gas_used: u64,
    pub status: ExecStatus,
    /// Call: return-data; Create: deployed runtime code.
    pub output: Vec<u8>,
    pub contract_addr: Option<[u8; 20]>,
    pub logs: Vec<Log>,
}

#[derive(Debug, Clone)]
pub struct CallResult {
    pub gas_used: u64,
    pub status: ExecStatus,
    pub output: Vec<u8>,
}

fn convert_logs(revm_logs: Vec<revm::primitives::Log>, block: u64, tx_hash: [u8; 32]) -> Vec<Log> {
    revm_logs.into_iter().map(|l| {
        let addr = l.address.into_array();
        let (topics, data) = l.data.split();
        let topics_vec: Vec<[u8; 32]> = topics.iter().map(|t| t.0).collect();
        Log {
            address: addr,
            topics: topics_vec,
            data: data.to_vec(),
            block,
            tx_hash,
        }
    }).collect()
}

fn configure_tx(env_tx: &mut revm::primitives::TxEnv, tx: &TxParsed, chain_id: u64) {
    env_tx.caller = addr_to(tx.from);
    env_tx.gas_limit = tx.gas_limit.max(21_000);
    env_tx.gas_price = U256::from(1_000_000_000u64); // 1 gwei placeholder
    env_tx.transact_to = match tx.to {
        Some(a) => TxKind::Call(addr_to(a)),
        None    => TxKind::Create,
    };
    env_tx.value = U256::from(tx.value);
    env_tx.data = Bytes::from(tx.data.clone());
    env_tx.nonce = Some(tx.nonce);
    env_tx.chain_id = Some(chain_id);
    env_tx.access_list.clear();
    env_tx.blob_hashes.clear();
    env_tx.max_fee_per_blob_gas = None;
    env_tx.gas_priority_fee = None;
    env_tx.authorization_list = None;
}

/// Read-only execution. Used by eth_call + eth_estimateGas.
/// `tx.from` may be `[0;20]`; `tx.nonce` is ignored (we disable nonce check).
pub fn execute_call(state: &EvmState, tx: &TxParsed) -> Result<CallResult, String> {
    let db = EvmStateDbRef::new(state);
    let chain_id = state.chain_id();
    let block_num = state.block_number();

    let mut evm = Evm::builder()
        .with_ref_db(db)
        .modify_cfg_env(|c| {
            c.chain_id = chain_id;
            // Note: revm 14 moved `disable_nonce_check`/`disable_balance_check`/
            // `disable_base_fee`/`disable_block_gas_limit` off CfgEnv; for
            // eth_call we approximate by skipping nonce in modify_tx_env below.
        })
        .modify_block_env(|b| {
            b.number = U256::from(block_num);
            b.gas_limit = U256::from(u64::MAX / 2);
        })
        .modify_tx_env(|t| {
            configure_tx(t, tx, chain_id);
            // eth_call: caller may not have balance — leave nonce unset.
            t.nonce = None;
        })
        .build();

    let res = evm.transact().map_err(|e| format!("evm call: {e:?}"))?;
    let (status, output, gas_used) = match res.result {
        ExecutionResult::Success { gas_used, output, .. } => {
            let bytes = match output { Output::Call(b) => b, Output::Create(b, _) => b };
            (ExecStatus::Success, bytes.to_vec(), gas_used)
        }
        ExecutionResult::Revert { gas_used, output } =>
            (ExecStatus::Revert, output.to_vec(), gas_used),
        ExecutionResult::Halt { gas_used, .. } =>
            (ExecStatus::Halt, Vec::new(), gas_used),
    };
    Ok(CallResult { gas_used, status, output })
}

/// State-mutating execution. Used by block_exec for eth_sendRawTransaction.
/// Commits account / code / storage changes via DatabaseCommit.
pub fn execute_tx(state: &EvmState, tx: &TxParsed) -> Result<ExecResult, String> {
    let chain_id = state.chain_id();
    let block_num = state.block_number().saturating_add(1);

    let db = EvmStateDb::new(state);
    let mut evm = Evm::builder()
        .with_db(db)
        .modify_cfg_env(|c| {
            c.chain_id = chain_id;
            // revm 14: disable_* moved off CfgEnv (see note in execute_call).
        })
        .modify_block_env(|b| {
            b.number = U256::from(block_num);
            b.gas_limit = U256::from(u64::MAX / 2);
        })
        .modify_tx_env(|t| configure_tx(t, tx, chain_id))
        .build();

    let exec_result = evm.transact_commit().map_err(|e| format!("evm tx: {e:?}"))?;

    let (status, gas_used, output, contract_addr, revm_logs) = match exec_result {
        ExecutionResult::Success { gas_used, output, logs, .. } => {
            let (out_bytes, contract) = match output {
                Output::Call(b)            => (b.to_vec(), None),
                Output::Create(b, addr)    => (b.to_vec(), addr.map(|a| a.into_array())),
            };
            (ExecStatus::Success, gas_used, out_bytes, contract, logs)
        }
        ExecutionResult::Revert { gas_used, output } =>
            (ExecStatus::Revert, gas_used, output.to_vec(), None, Vec::new()),
        ExecutionResult::Halt { gas_used, .. } =>
            (ExecStatus::Halt, gas_used, Vec::new(), None, Vec::new()),
    };

    let logs = convert_logs(revm_logs, block_num, tx.hash);

    Ok(ExecResult { gas_used, status, output, contract_addr, logs })
}
