# OmnibusDEX deploy harness

Hardhat setup for deploying `evm/contracts/OmnibusDEX.sol` to Sepolia / Base Sepolia / LCX Liberty / mainnets.

## One-time setup

```bash
cd evm/deploy
npm install
npm run compile        # produces artifacts/ — needed before first deploy
cp .env.example .env
# edit .env: paste DEPLOYER_PRIVKEY (slot 6 = tornetwork.omnibus)
chmod 600 .env         # optional on Windows; required on Unix
```

The private key for slot 6 derives from the founder mnemonic at
`m/44'/60'/0'/0/6`. Any BIP-44 tool (ethers, ethers-wallet, the OmniBus
desktop wallet's "Export private key" button) can produce it. **Never
commit `.env`** — the `.gitignore` in this folder excludes it.

## Deploy

```bash
npm run deploy:sepolia        # 11155111 — uses ~0.003 ETH gas
npm run deploy:base-sepolia   # 84532    — uses ~0.001 ETH on Base
npm run deploy:liberty        # 76847801 — uses LCX (slot 6 has 0.0843)
```

The script:
1. Loads `DEPLOYER_PRIVKEY` from `.env`
2. Checks the wallet has at least 0.003 ETH (refuses otherwise)
3. Deploys with constructor arg `_operator = slot 2 EVM address`
4. Writes the deployed address into `evm/deployed_addresses.json` under
   the chain id, so `chains.ts` and the Zig settler can pick it up

After deploy:
- Copy the address into `frontend/src/api/chains.ts → CHAINS[chainId].dexContract`
- Top up slot 2 (operator) with ~0.01 ETH so `settle()` has gas
- Restart the OmniBus node so `dex_settler` reads the new address

## Verify on Etherscan (optional)

```bash
# .env: ETHERSCAN_API_KEY=...
npm run verify:sepolia -- <DEPLOYED_ADDRESS> "0x2680Cf2201300F4eCF3fd8a592D9aA760122C3E0"
```

The constructor arg must match `OPERATOR_EVM_ADDRESS` from the deploy.

## File layout

```
evm/deploy/
├── package.json           — Hardhat + ethers + dotenv
├── hardhat.config.ts      — networks + paths (compiles from ../contracts/)
├── scripts/
│   └── deploy-omnibus-dex.ts
├── .env.example           — template (commit)
├── .env                   — local secrets (NEVER commit)
├── .gitignore
└── README.md
```
