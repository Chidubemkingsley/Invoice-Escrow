# Invoice-escrow

Wallet-connected testnet frontend for milestone invoice escrow, receivables advances, disputes, and liquidity pools.

## Run & Operate

- `pnpm --filter @workspace/api-server run dev` — run the API server (port 5000)
- `pnpm --filter @workspace/invoice-escrow run dev` — run the Invoice-escrow frontend
- `pnpm run typecheck` — full typecheck across all packages
- `pnpm run build` — typecheck + build all packages
- `pnpm --filter @workspace/api-spec run codegen` — regenerate API hooks and Zod schemas from the OpenAPI spec
- `pnpm --filter @workspace/db run push` — push DB schema changes (dev only)
- Required env: `DATABASE_URL` — Postgres connection string

## Stack

- pnpm workspaces, Node.js 24, TypeScript 5.9
- API: Express 5
- DB: PostgreSQL + Drizzle ORM
- Validation: Zod (`zod/v4`), `drizzle-zod`
- API codegen: Orval (from OpenAPI spec)
- Build: esbuild (CJS bundle)

## Where things live

- `artifacts/invoice-escrow/src/lib/chains.ts` — supported wallet chains and wagmi configuration
- `artifacts/invoice-escrow/deployments/` — per-chain deployment JSON files
- `artifacts/invoice-escrow/src/contract-adapter.ts` — verified contract ABI/read/write boundary

## Architecture decisions

- Contract data comes directly from the configured chains; there is no demo dataset or API-backed substitute.
- Financial reads and writes stay blocked until verified chain deployments and exact contract ABIs are supplied.

## Product

The UI covers seller, buyer, arbiter, and liquidity-provider workflows for invoice creation, milestone settlement, receivables financing, disputes, claims, reputation, and protocol administration.

## Gotchas

- Do not add placeholder contract addresses or guessed ABI tuple layouts; keep the UI gated until verified artifacts are available.

## Pointers

- See the `pnpm-workspace` skill for workspace structure, TypeScript setup, and package details
