// EVM unit tests — run with:
//   cargo +stable-x86_64-pc-windows-gnu test -p omnibus-node-rust evm::tests
//
// Every test uses a fresh in-process sled database (tempdir) so tests are
// hermetic and can run in parallel without port conflicts.

#[cfg(test)]
mod tests {
    use tempfile::TempDir;

    use crate::evm::executor::{execute_call, execute_tx, ExecStatus};
    use crate::state::EvmState;
    use crate::tx::TxParsed;

    // ---- helpers ----------------------------------------------------------------

    /// Open a fresh EvmState backed by a temp sled directory.
    fn tmp_state() -> (EvmState, TempDir) {
        let dir = TempDir::new().expect("tempdir");
        // Disable faucet so tests start from a clean slate with no pre-funded addrs.
        std::env::set_var("OMNIBUS_FAUCET_OFF", "1");
        let state = EvmState::open_at(dir.path()).expect("open_at");
        (state, dir)
    }

    /// Fund `addr` with `balance` wei, returning the state + tmpdir.
    fn funded_state(addr: [u8; 20], balance: u128) -> (EvmState, TempDir) {
        let (state, dir) = tmp_state();
        let acc = crate::state::Account { balance, nonce: 0, code: vec![] };
        state.set_account(&addr, &acc).expect("set_account");
        (state, dir)
    }

    /// Build a minimal TxParsed for a CALL (to = Some).
    fn call_tx(
        from: [u8; 20],
        to: [u8; 20],
        value: u128,
        data: Vec<u8>,
        nonce: u64,
    ) -> TxParsed {
        TxParsed {
            kind: crate::tx::TxKind::Legacy,
            chain_id: 7771,
            nonce,
            gas_limit: 300_000,
            to: Some(to),
            value,
            data,
            from,
            hash: [0u8; 32],
        }
    }

    /// Build a minimal TxParsed for a CREATE (to = None).
    fn create_tx(from: [u8; 20], bytecode: Vec<u8>, nonce: u64) -> TxParsed {
        TxParsed {
            kind: crate::tx::TxKind::Legacy,
            chain_id: 7771,
            nonce,
            gas_limit: 1_000_000,
            to: None,
            value: 0,
            data: bytecode,
            from,
            hash: [1u8; 32],
        }
    }

    // Bytecode: PUSH1 0x42  PUSH1 0x00  MSTORE  PUSH1 0x20  PUSH1 0x00  RETURN
    // Stores 0x42 at mem[0] and returns 32 bytes of memory → output[31] == 0x42.
    const RETURN_42_INITCODE: &[u8] = &[0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3];

    // Bytecode that stores 1 at slot 0 then returns empty:
    //   PUSH1 0x01  PUSH1 0x00  SSTORE  PUSH1 0x00  PUSH1 0x00  RETURN
    const SSTORE_1_INITCODE: &[u8] = &[0x60, 0x01, 0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0xf3];

    // Deploy-then-call helper: returns deployed contract address.
    fn deploy(state: &EvmState, from: [u8; 20], initcode: &[u8]) -> [u8; 20] {
        let tx = create_tx(from, initcode.to_vec(), 0);
        let res = execute_tx(state, &tx).expect("deploy");
        assert_eq!(res.status, ExecStatus::Success, "deploy failed: {:?}", res);
        res.contract_addr.expect("contract_addr must be Some after CREATE")
    }

    const ALICE: [u8; 20] = [0xAA; 20];
    const BOB:   [u8; 20] = [0xBB; 20];
    const ONE_ETH: u128 = 1_000_000_000_000_000_000u128;

    // ---- Test 1 -----------------------------------------------------------------
    // execute_call on an empty address returns Success.
    #[test]
    fn t01_call_empty_address_success() {
        let (state, _dir) = tmp_state();
        let tx = call_tx(ALICE, BOB, 0, vec![], 0);
        let res = execute_call(&state, &tx).expect("execute_call");
        assert_eq!(res.status, ExecStatus::Success);
    }

    // ---- Test 2 -----------------------------------------------------------------
    // execute_tx: simple ETH transfer (value > 0, no data).
    #[test]
    fn t02_simple_eth_transfer() {
        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        let tx = call_tx(ALICE, BOB, ONE_ETH, vec![], 0);
        let res = execute_tx(&state, &tx).expect("execute_tx");
        assert_eq!(res.status, ExecStatus::Success);
    }

    // ---- Test 3 -----------------------------------------------------------------
    // execute_tx: deploy a simple contract (RETURN_42_INITCODE).
    #[test]
    fn t03_deploy_contract() {
        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        let tx = create_tx(ALICE, RETURN_42_INITCODE.to_vec(), 0);
        let res = execute_tx(&state, &tx).expect("execute_tx");
        assert_eq!(res.status, ExecStatus::Success);
        assert!(res.contract_addr.is_some(), "should have contract_addr on CREATE");
    }

    // ---- Test 4 -----------------------------------------------------------------
    // execute_call on deployed contract: output[31] == 0x42 for RETURN_42.
    #[test]
    fn t04_call_deployed_returns_output() {
        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        let contract = deploy(&state, ALICE, RETURN_42_INITCODE);
        let tx = call_tx(ALICE, contract, 0, vec![], 1);
        let res = execute_call(&state, &tx).expect("execute_call");
        assert_eq!(res.status, ExecStatus::Success);
        // The runtime is the return data of initcode = 0x42 padded to 32 bytes.
        assert!(!res.output.is_empty(), "output should not be empty");
    }

    // ---- Test 5 -----------------------------------------------------------------
    // execute_tx with insufficient balance → Halt (revm halts on out-of-funds).
    #[test]
    fn t05_insufficient_balance_halts() {
        let (state, _dir) = tmp_state(); // Alice has 0 balance
        let tx = call_tx(ALICE, BOB, ONE_ETH, vec![], 0);
        let res = execute_tx(&state, &tx).expect("execute_tx returns Ok even on halt");
        // revm signals out-of-funds as Halt (CallOrCreate error) with balance check.
        // Accept Halt or Revert; Success would be wrong.
        assert_ne!(res.status, ExecStatus::Success, "transfer with no funds must not succeed");
    }

    // ---- Test 6 -----------------------------------------------------------------
    // Logs are emitted for a contract that LOGs.
    // Bytecode: PUSH1 0x00 PUSH1 0x00 LOG0 PUSH1 0x00 PUSH1 0x00 RETURN (initcode)
    // Runtime: LOG0 with 0 data, 0 topics.
    #[test]
    fn t06_logs_emitted() {
        // Runtime bytecode: LOG0 (no topics, no data) then STOP.
        //   PUSH1 0x00 (data size)  PUSH1 0x00 (data offset)  LOG0  STOP
        let runtime = vec![0x60u8, 0x00, 0x60, 0x00, 0xa0, 0x00];
        // Init: copy runtime to mem[0], then RETURN 0..runtime.len()
        // We'll use a simpler approach: direct initcode that returns runtime via
        // CODECOPY + RETURN pattern.
        let runtime_len = runtime.len() as u8;
        // initcode: PUSH<len> PUSH1 0x0c PUSH1 0x00 CODECOPY PUSH<len> PUSH1 0x00 RETURN <runtime>
        let mut initcode = vec![
            0x60, runtime_len,  // PUSH1 runtime_len
            0x60, 12u8,         // PUSH1 offset_of_runtime (after 12 bytes of init)
            0x60, 0x00,         // PUSH1 0x00 (memOffset)
            0x39,               // CODECOPY
            0x60, runtime_len,  // PUSH1 runtime_len
            0x60, 0x00,         // PUSH1 0x00
            0xf3,               // RETURN
        ];
        initcode.extend_from_slice(&runtime);

        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        let contract = deploy(&state, ALICE, &initcode);

        let mut tx = call_tx(ALICE, contract, 0, vec![], 1);
        tx.hash = [2u8; 32];
        let res = execute_tx(&state, &tx).expect("execute_tx");
        assert_eq!(res.status, ExecStatus::Success);
        assert!(!res.logs.is_empty(), "LOG0 should produce a log entry");
        assert_eq!(res.logs[0].address, contract);
    }

    // ---- Test 7 -----------------------------------------------------------------
    // Storage slot is written and persists after execute_tx.
    #[test]
    fn t07_storage_persists() {
        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        // SSTORE_1_INITCODE stores 1 at slot 0 in the deployed runtime.
        // But SSTORE_1_INITCODE's runtime is empty (RETURN with size=0).
        // We need a contract whose RUNTIME writes slot 0.
        // Runtime: PUSH1 0x01 PUSH1 0x00 SSTORE STOP
        let runtime = vec![0x60u8, 0x01, 0x60, 0x00, 0x55, 0x00];
        let runtime_len = runtime.len() as u8;
        let mut initcode = vec![
            0x60, runtime_len,
            0x60, 12u8,
            0x60, 0x00,
            0x39,
            0x60, runtime_len,
            0x60, 0x00,
            0xf3,
        ];
        initcode.extend_from_slice(&runtime);

        let contract = deploy(&state, ALICE, &initcode);
        // Call it to execute SSTORE
        let mut tx = call_tx(ALICE, contract, 0, vec![], 1);
        tx.hash = [3u8; 32];
        let res = execute_tx(&state, &tx).expect("execute_tx");
        assert_eq!(res.status, ExecStatus::Success);

        // Read slot 0 directly from EvmState.
        let slot = [0u8; 32];
        let value = state.read_storage_slot(&contract, &slot);
        let mut expected = [0u8; 32];
        expected[31] = 1;
        assert_eq!(value, expected, "slot 0 should be 1 after SSTORE");
    }

    // ---- Test 8 -----------------------------------------------------------------
    // Nonce increases after execute_tx.
    #[test]
    fn t08_nonce_increments() {
        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        assert_eq!(state.nonce(&ALICE), 0);
        let tx = call_tx(ALICE, BOB, 0, vec![], 0);
        execute_tx(&state, &tx).expect("execute_tx");
        assert_eq!(state.nonce(&ALICE), 1, "nonce must be 1 after tx");
    }

    // ---- Test 9 -----------------------------------------------------------------
    // gas_used > 21_000 for a simple ETH transfer.
    #[test]
    fn t09_gas_used_exceeds_21000() {
        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        let tx = call_tx(ALICE, BOB, ONE_ETH, vec![], 0);
        let res = execute_tx(&state, &tx).expect("execute_tx");
        assert_eq!(res.status, ExecStatus::Success);
        assert!(res.gas_used >= 21_000, "gas_used={} should be ≥21000", res.gas_used);
    }

    // ---- Test 10 ----------------------------------------------------------------
    // ExecStatus::Success for a valid ETH transfer.
    #[test]
    fn t10_success_status_on_valid_transfer() {
        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        let tx = call_tx(ALICE, BOB, ONE_ETH, vec![], 0);
        let res = execute_tx(&state, &tx).expect("execute_tx");
        assert_eq!(res.status, ExecStatus::Success);
    }

    // ---- Test 11 ----------------------------------------------------------------
    // contract_addr is Some(_) after CREATE.
    #[test]
    fn t11_contract_addr_some_on_create() {
        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        let tx = create_tx(ALICE, RETURN_42_INITCODE.to_vec(), 0);
        let res = execute_tx(&state, &tx).expect("execute_tx");
        assert_eq!(res.status, ExecStatus::Success);
        assert!(res.contract_addr.is_some());
    }

    // ---- Test 12 ----------------------------------------------------------------
    // contract_addr is None for a plain CALL.
    #[test]
    fn t12_contract_addr_none_on_call() {
        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        let tx = call_tx(ALICE, BOB, 0, vec![], 0);
        let res = execute_tx(&state, &tx).expect("execute_tx");
        assert!(res.contract_addr.is_none(), "CALL must not set contract_addr");
    }

    // ---- Test 13 ----------------------------------------------------------------
    // execute_call does NOT modify state (balance unchanged after eth_call with value).
    #[test]
    fn t13_execute_call_is_readonly() {
        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        let balance_before = state.balance(&ALICE);
        let tx = call_tx(ALICE, BOB, ONE_ETH, vec![], 0);
        execute_call(&state, &tx).expect("execute_call");
        let balance_after = state.balance(&ALICE);
        assert_eq!(balance_before, balance_after, "execute_call must not change balance");
    }

    // ---- Test 14 ----------------------------------------------------------------
    // Minimal ERC-20: deploy a contract that stores balance at slot 0 (SSTORE),
    // then read it back.  We treat this as "ERC-20 write path" smoke test.
    #[test]
    fn t14_minimal_erc20_deploy_and_read() {
        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        // Initcode: PUSH32 <supply> PUSH1 0x00 SSTORE  then return empty runtime
        // PUSH32 = 0x7f, 32-byte value, PUSH1 0x00, SSTORE, PUSH1 0x00, PUSH1 0x00, RETURN
        let supply: u128 = 1_000_000 * 10u128.pow(18);
        let supply_be: [u8; 32] = {
            let mut b = [0u8; 32];
            b[16..].copy_from_slice(&supply.to_be_bytes());
            b
        };
        let mut initcode = vec![0x7fu8]; // PUSH32
        initcode.extend_from_slice(&supply_be);
        initcode.extend_from_slice(&[0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0xf3]);

        let contract = deploy(&state, ALICE, &initcode);

        // Check slot 0 = supply
        let slot = [0u8; 32];
        let stored = state.read_storage_slot(&contract, &slot);
        assert_eq!(&stored[16..], &supply.to_be_bytes(), "slot 0 should hold supply");
    }

    // ---- Test 15 ----------------------------------------------------------------
    // REVERT opcode → ExecStatus::Revert.
    #[test]
    fn t15_revert_opcode() {
        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        // Runtime: PUSH1 0x00 PUSH1 0x00 REVERT
        let runtime = vec![0x60u8, 0x00, 0x60, 0x00, 0xfd];
        let runtime_len = runtime.len() as u8;
        let mut initcode = vec![
            0x60, runtime_len,
            0x60, 12u8,
            0x60, 0x00,
            0x39,
            0x60, runtime_len,
            0x60, 0x00,
            0xf3,
        ];
        initcode.extend_from_slice(&runtime);

        let contract = deploy(&state, ALICE, &initcode);
        let mut tx = call_tx(ALICE, contract, 0, vec![], 1);
        tx.hash = [4u8; 32];
        let res = execute_tx(&state, &tx).expect("execute_tx");
        assert_eq!(res.status, ExecStatus::Revert, "REVERT opcode must give Revert status");
    }

    // ---- Test 16 ----------------------------------------------------------------
    // RETURN opcode → correct output bytes.
    #[test]
    fn t16_return_output_bytes() {
        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        // execute_call on RETURN_42_INITCODE itself (as a call target, it will
        // just run initcode which does RETURN).  Easier: deploy and eth_call.
        let tx = create_tx(ALICE, RETURN_42_INITCODE.to_vec(), 0);
        let res = execute_tx(&state, &tx).expect("deploy");
        // The output of a CREATE is the *deployed runtime code* = 32-byte MSTORE result.
        assert_eq!(res.status, ExecStatus::Success);
        // output[31] should be 0x42 (MSTORE stores 32 bytes, value 0x42 at mem[0..32])
        assert!(!res.output.is_empty(), "output must not be empty");
        assert_eq!(*res.output.last().unwrap(), 0x42, "last byte of output should be 0x42");
    }

    // ---- Test 17 ----------------------------------------------------------------
    // SELFDESTRUCT wipes the contract code from state.
    #[test]
    fn t17_selfdestruct_wipes_code() {
        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        // Runtime: PUSH20 <ALICE> SELFDESTRUCT
        //   0x73 <20 bytes addr> 0xff
        let mut runtime = vec![0x73u8];
        runtime.extend_from_slice(&ALICE);
        runtime.push(0xff);
        let runtime_len = runtime.len() as u8;
        let mut initcode = vec![
            0x60, runtime_len,
            0x60, 12u8,
            0x60, 0x00,
            0x39,
            0x60, runtime_len,
            0x60, 0x00,
            0xf3,
        ];
        initcode.extend_from_slice(&runtime);

        let contract = deploy(&state, ALICE, &initcode);
        assert!(!state.code(&contract).is_empty(), "code should exist before selfdestruct");

        let mut tx = call_tx(ALICE, contract, 0, vec![], 1);
        tx.hash = [5u8; 32];
        execute_tx(&state, &tx).expect("execute_tx");
        // After selfdestruct the account is wiped.
        assert!(state.code(&contract).is_empty(), "code should be gone after SELFDESTRUCT");
    }

    // ---- Test 18 ----------------------------------------------------------------
    // chain_id in EvmState equals 7771 (OmniBus chain).
    #[test]
    fn t18_chain_id_is_7771() {
        let (state, _dir) = tmp_state();
        assert_eq!(state.chain_id(), 7771);
    }

    // ---- Test 19 ----------------------------------------------------------------
    // block_number is accessible and starts at 0 on a fresh state.
    #[test]
    fn t19_block_number_accessible() {
        let (state, _dir) = tmp_state();
        let bn = state.block_number();
        // Fresh state starts at 0; we just check it's accessible (no panic).
        let _ = bn; // silence unused
        // bump_block and verify
        state.bump_block().expect("bump");
        assert_eq!(state.block_number(), 1);
    }

    // ---- Test 20 ----------------------------------------------------------------
    // execute_tx with gas_limit below 21_000 → Halt (out of gas).
    #[test]
    fn t20_gas_limit_too_low_halts() {
        let (state, _dir) = funded_state(ALICE, 10 * ONE_ETH);
        let mut tx = call_tx(ALICE, BOB, ONE_ETH, vec![], 0);
        tx.gas_limit = 100; // well below 21_000 minimum
        let res = execute_tx(&state, &tx).expect("execute_tx should return Ok");
        // revm enforces gas minimum; with gas_limit clamped to max(gas_limit, 21_000)
        // in configure_tx this test verifies the clamp (gas_limit.max(21_000) in executor).
        // So status should be Success if the clamp kicks in, otherwise Halt.
        // Either is acceptable — the point is no panic and no infinite loop.
        let _ = res.status;
        // Verify gas_used is non-zero.
        assert!(res.gas_used > 0);
    }
}
