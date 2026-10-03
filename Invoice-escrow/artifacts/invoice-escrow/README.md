# Invoice-escrow

Wallet-connected frontend for invoice escrow and receivables financing on
Arbitrum Sepolia and Robinhood Chain Testnet.

## Run

From the workspace root:

```sh
pnpm --filter @workspace/invoice-escrow run dev
pnpm --filter @workspace/invoice-escrow run typecheck
```

## Required contract setup

The frontend specification did not include deployment addresses, verified
contract ABIs, or Solidity tuple/event definitions. The app deliberately makes
no simulated financial data and keeps contract actions disabled until those
verified artifacts are added.

1. Add a verified `deployments/<chainId>.json` file. See
   `deployments/README.md` for its schema.
2. Add the audited token, escrow, and pool ABIs and implement their exact
   read/write/event adapters in `src/contract-adapter.ts`.
3. Enable contract integration only after checking each ABI against the
   deployed contracts on its stated chain.

Supported chain definitions and public RPC endpoints are in `src/lib/chains.ts`.
The app uses RainbowKit, wagmi, and viem for wallet connection and network
context. No database or API server is used for contract data.