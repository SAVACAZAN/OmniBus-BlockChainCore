# Pull Request: OmniBus BlockChainCore

## Summary

<!-- 1-2 sentences describing what this PR does and why -->

**Type of change:**
- [ ] Feature (new functionality)
- [ ] Enhancement (improvement to existing code)
- [ ] Bug fix (resolves an issue)
- [ ] Refactoring (no behavioral change)
- [ ] Documentation
- [ ] DevOps (CI/CD, scripts, Docker)

## Test Plan

<!-- What testing was done? How can reviewers verify this works? -->

- [ ] Unit tests pass: `zig build test`
- [ ] Integration tests pass: `zig build test-chain`
- [ ] Frontend builds: `npm run build` in `frontend/`
- [ ] TypeScript checks pass: `npx tsc --noEmit` in `frontend/`
- [ ] Manual testing completed:
  - [ ] Seed node starts: `./zig-out/bin/omnibus-node --mode seed --node-id test-1 --port 9001`
  - [ ] Miner connects and syncs: `./zig-out/bin/omnibus-node --mode miner --node-id miner-1 --seed-host 127.0.0.1 --seed-port 9001`
  - [ ] RPC responds: `curl -s -X POST http://127.0.0.1:8332 -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":1}'`

## Inventory Delta

<!-- Auto-filled by CI: changes to core modules, config, or tooling -->

Modules modified:
- [ ] core/secp256k1.zig
- [ ] core/blockchain.zig
- [ ] core/consensus.zig
- [ ] core/wallet.zig (requires liboqs)
- [ ] core/p2p.zig
- [ ] core/rpc_server.zig
- [ ] core/mining_pool.zig
- [ ] frontend/src/
- [ ] build.zig
- [ ] Dockerfile / docker-compose

Other changes:
- [ ] New module(s): `core/*.zig` (list names)
- [ ] Removed module(s): (list names)
- [ ] New dependency (update build.zig or package.json)
- [ ] Breaking change to RPC API
- [ ] Database schema change

## Checklist

- [ ] Code follows the project style (Zig conventions, TypeScript strict mode)
- [ ] Comments added for complex logic
- [ ] No debug prints left (`std.debug.print`, `console.log`)
- [ ] No unused imports
- [ ] Build passes without warnings: `zig build 2>&1 | grep -i warn`
- [ ] All test suites pass
- [ ] Git commits are clean and descriptive
- [ ] No merge conflicts

## Notes for Reviewers

<!-- Anything reviewers should know? -->

- **Risk level:** Low / Medium / High
- **Performance impact:** None / Negligible / Significant (describe)
- **Database migration needed:** Yes / No (if yes, describe migration)
- **Requires VPS redeploy:** Yes / No (if yes, use `bash scripts/deploy-vps.sh --testnet --build`)

## Related Issues

<!-- Link to Gitea/GitHub issues, if any -->

Closes #123
Relates to #456

---

**CI Status:** (auto-filled)
- [ ] Build: ✓ Passed
- [ ] Tests: ✓ Passed (crypto, chain, net, shard, storage, light, econ)
- [ ] Frontend: ✓ Passed
- [ ] Inventory: ✓ Updated
