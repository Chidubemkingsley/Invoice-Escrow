# Invoice escrow — frontend

React + Vite app for the invoice escrow and instant-advance protocol, reading and writing the **verified
testnet deployments** of `InvoiceEscrow` and `AdvancePool`.

## Run it

```bash
# from the repository root (pnpm workspace)
pnpm install

cd artifacts/invoice-escrow
pnpm run dev        # http://localhost:5173
pnpm run build      # production bundle into dist/public
pnpm run typecheck  # tsc --noEmit
```

`PORT` and `BASE_PATH` default to `5173` and `/`, so no environment variables are needed locally. Both are
still honoured if a host sets them.

## Networks

| Network | Chain ID | RPC | Explorer |
|---|---|---|---|
| Arbitrum Sepolia | 421614 | https://sepolia-rollup.arbitrum.io/rpc | https://arbitrum-sepolia.blockscout.com |
| Robinhood Chain Testnet | 46630 | https://rpc.testnet.chain.robinhood.com | https://explorer.testnet.chain.robinhood.com |

Switch either in the wallet; the app reads the matching deployment file. USDG is 6 decimals on both chains.

## Contract wiring

| Path | What it holds |
|---|---|
| `src/abis/` | Typed ABI modules: `USDG`, `InvoiceEscrow`, `AdvancePool`, plus `SIGNATURES.md` with every function, event and custom error |
| `deployments/<chainId>.json` | `token`, `escrow`, `pool`, `owner` and faucet URLs for one chain |
| `src/contract-adapter.ts` | `getContracts(chainId)`, typed `reads`, `writes` as request objects for `useWriteContract`, and the `events` used by the feed |
| `src/hooks/useEscrowData.ts` | react-query hooks: invoices, milestones, reputation, pool state, quotes, decoded logs |
| `src/components/contract-ui.tsx` | Amount formatting, chain-aware explorer links, countdowns, and `useContractWrite` with decoded revert messages |

The ABIs come from the verified sources: USDG from the explorer API for the verified token implementation,
the two contracts from the Foundry build of the sources verified on both explorers. Reverts are surfaced
with human copy (`src/lib/contract-errors.ts`) instead of a raw selector.

## Pages

| Route | Reads | Writes |
|---|---|---|
| `/` | Pool assets, share price, escrowed value, invoice count, recent events | — |
| `/dashboard` | Invoices where the wallet is seller, buyer or arbiter, with the next action per invoice | — |
| `/create` | Token decimals | `createInvoice` |
| `/market` | Funded, undisputed invoices and live `quote(id)` | `approve`, `advance` |
| `/pool` | Assets, idle, deployed, face outstanding, share price, shares, `maxWithdraw`, risk parameters | `deposit`, `withdraw` |
| `/arbiter` | Open disputes decoded from milestones | `resolveDispute`, `resolveExpiredDispute` |
| `/reputation` | `reputation(address)` counters and a pricing verdict | — |
| `/admin` | Owner check, pause state, current parameters | `setApprovedArbiter`, `setSellerCreditLimit`, `setParams`, `setFee`, `pause`/`unpause` |
| `/activity` | Decoded logs from both contracts, filtered by type, address and block range | — |
| `/invoice/:id` | Invoice, milestones, parties, payee, doc hash, role-gated actions | `submitMilestone`, `approveMilestone`, `disputeMilestone`, `reclaimUnsubmitted`, `autoRelease`, `fund`, `claim` |

## Notes

- Actions are gated by the connected wallet's role and by contract rules; buttons that cannot succeed are
  disabled with a reason rather than failing on-chain.
- Pool and activity data refresh every 15–20 seconds; invoice state refreshes so countdowns stay honest.
- Empty states are expected on a fresh deployment. Populate it by running the demo script from the
  contracts directory: `./deploy.sh demo arbitrum_sepecolia`.
- Testnet only. USDG has no value; use the faucets linked in each deployment file.