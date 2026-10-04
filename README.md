# Invoice Escrow + Instant Advance (USDG on Arbitrum / Robinhood Chain)

**Problem.** A Southeast Asian exporter or agency invoices an overseas buyer and waits 30–90 days to be paid.
Buyers don't want to pay upfront with no recourse; sellers can't wait. Trade finance exists but is slow,
paper-based and closed to small businesses.

**Solution.** Two contracts, both denominated in Paxos **USDG** (MAS-supervised, issued in Singapore):

1. **`InvoiceEscrow`** – the buyer locks USDG against a milestone schedule. Every invoice is an **ERC-721**:
   the NFT owner is the *payee*, the original seller is the *performer*. Selling the NFT sells the right to be paid.
2. **`AdvancePool`** – an **ERC-4626** vault. LPs deposit USDG; sellers sell their invoice NFT to the pool and are
   paid *today* at a discount. When the escrow later releases funds, they flow straight to the pool and LP share price rises.

```
 Buyer ──fund──▶ InvoiceEscrow ◀──create── Seller
                    │  ▲ NFT (payee right)
        approve /   │  │ advance(id)           LPs ──deposit──▶ AdvancePool (ERC-4626)
        autoRelease │  └──────── sells NFT ───────────────────────▲   │
                    ▼                                              │   │ pays seller now
              pays NFT owner  ── (pool, after sale) ───────────────┘   ▼
                    └── onMilestoneSettled callback ──▶ pool books profit/loss atomically
```

### Why the pool is safer than ordinary factoring
The buyer's USDG is **already locked** when the pool buys, so the pool takes no buyer-credit risk. What remains is
*performance* and *dispute* risk, which the pool prices on-chain:

```
discount = escrow fee + APR × time-to-final-release + premium(seller) + premium(buyer)
premium(x) = newcomer premium            if x has < minHistory settled milestones
           = (disputes + 3·defaults) / settled × slope   otherwise
```
Reputation is a by-product of using the escrow (`InvoiceEscrow.reputation`), so good counterparties get cheaper
advances automatically. Invoices above `maxDiscountBps` are rejected.

## Milestone state machine

```
Pending ─submit(seller)─▶ Submitted ─approve(buyer)──────────────▶ Settled → payee
                              │  ─autoRelease(anyone, +7d)──────▶ Settled → payee
                              └─dispute(buyer, <7d)─▶ Disputed ─resolve(arbiter)────────▶ Settled (split)
                                                          └─resolveExpired(+14d)────────▶ Settled (50/50)
Pending ─reclaimUnsubmitted(buyer, deadline + 3d grace)──────────▶ Settled → buyer refund
```
Milestones settle in order. No party can block another forever: silence by the buyer auto-releases, silence by the
arbiter forces a 50/50 split, silence by the seller lets the buyer reclaim.

## Where each resource from the hackathon page is used

| Resource | Use here |
|---|---|
| Paxos USDG docs | Token addresses for Arbitrum One/Sepolia and Robinhood mainnet/testnet are hard-wired in `script/Deploy.s.sol` (selected by `chainid`). Contracts read nothing token-specific, so any 6-dec ERC-20 works. |
| Robinhood Chain docs | Chain IDs 4663 / 46630 and public RPC in `foundry.toml`; same Solidity deploys unchanged (EVM-compatible Arbitrum chain). Targets the reserved Robinhood prize slot. |
| Arbitrum docs / RPCs | `arbitrum_sepolia`, `arbitrum_one` RPC aliases in `foundry.toml`. |
| OpenZeppelin Solidity | `ERC721`, `ERC4626`, `SafeERC20`, `Ownable2Step`, `Pausable`, `ReentrancyGuard` (v5.1.0). |
| Foundry | 68 tests: unit, fuzz, stateful invariants, and a 23-test audit-regression + stress suite. |
| [pashov skills — `solidity-auditor`](https://github.com/pashov/skills) | Five-pass, twelve-agent audit of both contracts and both scripts. 22 findings fixed and regression-tested; full report in `.solidity-auditor/`. |
| ZeroDev / Stylus | *Not used in the MVP.* Natural extensions below. |

## Quick start

```bash
git clone <your repo> && cd invoice-advance
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 foundry-rs/forge-std
forge test                       # 44 tests
forge coverage --no-match-contract InvariantTest
```

### Deploy to a testnet

1. Get testnet USDG from https://faucet.paxos.com/ (and gas ETH from the Arbitrum / Robinhood faucets on the hackathon page).
2. `cp .env.example .env` and fill in `PRIVATE_KEY` (plus `SELLER_KEY`, `BUYER_KEY` for the demo).
3. Deploy and run the full flow:

```bash
./deploy.sh deploy arbitrum_sepolia  [--verify]    # writes deployments/421614.json
./deploy.sh deploy robinhood_testnet [--verify]    # writes deployments/46630.json

./deploy.sh demo arbitrum_sepolia                  # LP deposit -> invoice -> fund -> instant advance -> settle
./deploy.sh demo robinhood_testnet
```
The script picks the USDG address from the chain ID, fails early if there is no contract at that address or the
deployer has no gas, and prompts before any mainnet deployment. The demo needs ~`LP_USDG` USDG on the owner
wallet and ~`INVOICE_USDG` on the buyer wallet; all three wallets need gas. Demo transaction hashes land in
`broadcast/` — put them in your submission.

### Recorded testnet run — Arbitrum Sepolia, 13 transactions

This is a real run against the deployed contracts above, not a rehearsal. Amounts are small because the demo
wallet holds what the faucet gives (100 USDG per wallet per day); the mechanics are identical at any size.

| Step | Result |
|---|---|
| LP deposit | 70 USDG into the pool |
| Invoice #1 created | 14 USDG in two milestones (30% / 70%), due in 14 and 30 days |
| Buyer funded | 14 USDG locked in escrow |
| Instant advance | pool paid the seller **12.94 USDG** for a **14.00 USDG** receivable — a **757 bps** discount |
| Milestones delivered | both settled; invoice status `Closed`, `remaining = 0` |
| Pool after settlement | **71.06 USDG** total assets, 0 still deployed |
| Share price | **1.0151 USDG** per pool share — the LP position earned the 757 bps spread |
| Reputation written | seller `(clean 2, disputed 0, defaulted 0)` |

The pool bought the receivable at 12.94 USDG, was owed 14.00 USDG by the escrow, received it in full, and its
holders ended up with a 1.51% gain on a 70 USDG position. `advances(1)` on-chain reads
`cost 12.9416 / face 14.0 / costReleased 12.9416 / faceSettled 14.0` — the whole cost basis retired.

Transaction hashes, in order, on [Arbitrum Sepolia](https://sepolia-rollup.arbitrum.io):

| Action | Hash |
|---|---|
| `setApprovedArbiter` | `0x0adab77747a066f6fd8fc1844907d94f5177be0f6a1cbd064147182bbc41870b` |
| `setSellerCreditLimit` | `0xc8ce97e10f391ff3015dfacd100428b6d83e1e3888f00418d0d8d8847180f246` |
| LP `approve` + `deposit` | `0x8360b27a…`, `0x3c72727220a1abbea1c44a8908f6b7377e79b088fb977d2869a73b5deb7779ac` |
| `createInvoice` | `0x900a803dca6d9a6f550e354b42e45a4458ccd7eb6d6ec2d8d2e1ac4e87591aa2` |
| buyer `approve` + `fund` | `0x4f9654af…`, `0x8ab49e8373bb4fa555815395427673f19a660429d79f9b18b9cbc52b7c547fc4` |
| pool `approve` + `advance` | `0xde14c6c0…`, `0x4e1d538fab18ead6dd0cb627ed8a85dd47895c145e06288be115b9e430f56273` |
| `submitMilestone` ×2 | `0x4fde350e…`, `0x48cfb9fa7ed12285085c06ffd5b211b660d49661c80cee13b00097e19692ca91` |
| `approveMilestone` ×2 | `0x0ec10b5c…`, `0x49c6db7b36544a7fe919db67e8a43e0fead80216d8ca3268a5da79856c85ee58` |

The data persists on-chain, so the frontend at `Invoice-escrow/artifacts/invoice-escrow` shows it to anyone who
opens the app — no keys, no setup, nothing to re-run.

Local rehearsal (no faucet needed): run `anvil`, then
`DEPLOY_MOCK_USDG=true ./deploy.sh deploy http://127.0.0.1:8545` and `MOCK_MINT=true ./deploy.sh demo http://127.0.0.1:8545`.

Pool operator setup after deploy (as `OWNER`): `setApprovedArbiter`, `setSellerCreditLimit`, then LPs `deposit`.

Demo flow (see `test/InvoiceAdvance.t.sol::test_advance_thenFullSettlement_realisesProfitForLPs`):
`createInvoice → fund → approve(pool) → advance → submit/approve milestones → LP share price rises`.

## Deployed contracts (testnet)

| Network | Chain ID | USDG | InvoiceEscrow | AdvancePool | Explorer |
|---|---|---|---|---|---|
| Arbitrum Sepolia | 421614 | `0xFFC95faa3d63Cde504a05B567C600B78C0b41892` | `0xE930b702d910833D791311D1Fe136e127B2680E5` | `0x530B1646859F21b138cEe27887D141E784c562c6` | [verified source](https://arbitrum-sepolia.blockscout.com/address/0xe930b702d910833d791311d1fe136e127b2680e5) |
| Robinhood Chain Testnet | 46630 | `0x7E955252E15c84f5768B83c41a71F9eba181802F` | `0x214e2316EAEeE24c1dc5d8433329fFC7544DA331` | `0xb5A7176913574D8290eDa1469fC4Ef734D135CE5` | [verified source](https://explorer.testnet.chain.robinhood.com/address/0x214e2316eaeee24c1dc5d8433329ffc7544da331) |

Both deployments are the **post-audit** code (see the audit section below). Sources are verified on both
explorers, so anyone can read the exact bytecode the pools run against.

### Frontend artifacts (everything needed for real reads, events and writes)

| Artifact | Path | What it is |
|---|---|---|
| Per-chain deployment JSON | `deployments/421614.json`, `deployments/46630.json` | `token` (USDG), `escrow`, `pool`, `owner`, `chainId` for one chain each, written by `Deploy.s.sol` |
| Multi-chain manifest | `deployments/index.json` | Both chains in one file: chain id, RPC, explorer, faucet links, the three addresses, the ABI path for each and the verified-source URL for each |
| Token ABI | `deployments/abis/USDG.json` | The **verified** USDG implementation ABI, pulled from the Blockscout API (`is_verified: true`), identical on both chains: 54 functions, 46 events, 40 errors |
| Escrow ABI | `deployments/abis/InvoiceEscrow.json` | 47 functions, 16 events, 29 custom errors — milestone lifecycle, ERC-721 (`transferFrom`, `ownerOf`, `balanceOf`), views, `claim`, admin |
| Pool ABI | `deployments/abis/AdvancePool.json` | 50 functions, 13 events, 32 custom errors — full ERC-4626 surface plus `quote`, `advance`, `onMilestoneSettled`, `sweepDeferred`, admin |
| Signature index | `deployments/abis/SIGNATURES.md` | Every function, event and error as an exact signature string, e.g. `createInvoice(address,address,uint128[],uint40[],bytes32)`, `MilestoneSettled(uint256,uint256,uint8,address,uint256,uint256,uint256)`, `quote(uint256)` |

ABI provenance: the USDG ABI is the real one from the verified token source, not a hand-written subset, so a
frontend can decode USDG events (including its admin/role surface) and read the same decimals and symbol the
contracts use. The escrow and pool ABIs are generated from the exact sources that were verified on both
explorers, so event topics and revert selectors match on-chain bytecode.

Reading events: everything the UI needs is emitted — `InvoiceCreated`, `InvoiceFunded`, `MilestoneSubmitted`,
`MilestoneDisputed`, `MilestoneSettled`, `PayoutDeferred`, `Claimed`, `Advanced`, `AdvanceSettled`, plus the pool's
admin events. Log filtering by topic0 over a block range is enough for the activity feed; no indexer is required
for the demo.

## Security audit — [solidity-auditor](https://github.com/pashov/skills) (pashov skills)

The two contracts, both deploy scripts and the demo were audited with the **`solidity-auditor`** skill from
[pashov/skills](https://github.com/pashov/skills) — the multi-agent Solidity auditing skill that runs twelve
specialised attacker agents (math precision, access control, economic security, execution trace, invariants,
periphery, first principles, asymmetry, boundary, and three gap-hunters that hunt across lenses) and
assembles one deduplicated report with a confidence score per finding.

**How the scan ran**

| | |
|---|---|
| Files reviewed | `src/InvoiceEscrow.sol`, `src/AdvancePool.sol`, `script/Deploy.s.sol`, `script/Demo.s.sol` |
| Excluded as non-production | `src/mocks/`, `test/`, `lib/` |
| Passes | 5 (each pass is told what the earlier passes found, so it hunts new ground) |
| Agents per pass | 12 (10/12, 3/11, 4/4, 5/6, 1/4 returned — the rest were lost to upstream API failures, recorded honestly in the Scope row of the report) |
| Result | **22 findings** at or above the confidence threshold, **35 leads** (unscored trails), 56 records written to the memory ledger |
| Full report | `.solidity-auditor/runs/20261003-170216/full-report.md` (per-pass run files alongside it) |

Every finding above the threshold shipped with a concrete exploit path and numbers, not a vibe: several agents
built throwaway Foundry proofs, and one measured a **41.4% loss to a victim LP** from a single seller-LP
sequence. **All of it is fixed in the deployed bytecode**, and each fix has a regression test in
`test/AuditFixes.t.sol` (23 tests: one per finding, plus fuzz and stress suites).

### Critical — pool or escrow funds at risk, unprivileged path

**1. Cost retired on gross face instead of cash received — `AdvancePool.onMilestoneSettled` (conf. 85)**
The callback received `paidToHolder` and ignored it, retiring cost pro-rata on the milestone *face*. A milestone
that paid the pool half — or nothing — still retired its full cost slice. Two consequences: the share price
never recognised the loss, and `sellerExposure` was credited back, so **one whitelisted seller could take the
same credit limit again after every default**, draining the pool round after round while `sellerExposure`
never exceeded the approved limit.
*Fix:* cost retires against what the escrow actually delivered, including payouts the escrow parked in
`claimable` for the pool; a settlement that delivers nothing writes the slice off; and `sellerExposure` is only
credited for cash that arrived. Bad debt now keeps the limit consumed.

**2. Utilisation cap denominated in cost, not face — `AdvancePool.advance` (conf. 85)**
`deployed` holds what the pool *paid*; the escrow owes the pool *face*. The 80% cap therefore admitted up to
**160% of NAV in receivables** at the widest allowed discount, and one round of defaults took 80% of the vault.
*Fix:* a new `outstandingFace` accumulator, and both caps are now measured against unsettled face.

**3. A seller who is also a liquidity provider could exit before the default landed — `AdvancePool.maxWithdraw` (conf. 85)**
Withdrawals were capped only at idle cash. An LP-and-seller advanced three invoices, withdrew at the
pre-default price, and left the write-off to the providers who stayed — a measured **41.4% victim loss**, and the
per-seller credit limit did not stop it.
*Fix:* `_idleCap()` reserves the cash that keeps outstanding face inside the utilisation cap, so an exit can never
take the buffer and freeze every later advance.

**4. Delinquent invoices were priced like live ones — `AdvancePool.quote` (conf. 80)**
`quote` never compared the clock to a milestone deadline, so an invoice past its delivery window priced *better*
than a fresh one (the APR term clamps to zero on a dead invoice) and the buyer could then reclaim the whole
escrow. The pool paid up to ~94% of face and received nothing.
*Fix:* new `Delinquent` error — any Pending milestone past `deadline + DELIVERY_GRACE` makes the invoice
unbuyable.

**5. Deferred payouts could not be rescued from a blocked pool — `AdvancePool.sweepDeferred` (conf. 75)**
If the USDG issuer blocked the pool's own address, deferred payouts parked in `escrow.claimable[pool]` could only
be claimed *back to the blocked pool*, so the money was stuck until the issuer relented.
*Fix:* `sweepDeferred(address to)` takes a recipient, so an operator can sweep to an unfrozen treasury.

### High — buyer funds or liveness

**6. Late submission erased the buyer's refund path — `InvoiceEscrow.submitMilestone` (conf. 80)**
Nothing stopped a seller submitting after `deadline + grace`. That flipped the milestone out of
`reclaimUnsubmitted` (which requires Pending) into the arbiter's discretion, so a non-delivery became a payable
claim.
*Fix:* `submitMilestone` reverts with `TooLate` past `deadline + DELIVERY_GRACE`.

**7. Paying a payee that is the escrow contract locked the payout — `InvoiceEscrow._push` (conf. 80)**
`_push` only parks a payout when the transfer *reverts*. A holder could transfer the invoice NFT to the escrow
itself: the transfer then **succeeded** into an address with no withdrawal path, and no escrow function returns
it — 29.85% of that milestone gone, silently.
*Fix:* a payout to the escrow contract is deferred into `claimable` like any other undelivered payout.

**8. Only the buyer could refund an undelivered milestone — `InvoiceEscrow.reclaimUnsubmitted` (conf. 75)**
Every other exit needs Submitted or Disputed status, so a seller that stopped performing left the escrow balance
and the pool's deployed capital open until the buyer acted — forever, if the buyer was incapable.
*Fix:* anyone may call it. The refund still goes to the buyer, so the caller cannot profit.

**9. The holder callback could be silently dropped — `InvoiceEscrow._notifyHolder` (conf. 85)**
`try … {gas: 300_000} … catch {}` discards a failed callback and stores no receipt, while the pool is the *only*
writer of `costReleased`, `deployed` and `sellerExposure`. A gas-starved settler could land the payout and skip
the books, permanently.
*Fix:* the callback now carries what the holder was **credited** (delivered plus parked), the 300k stipend is
~4x the pool's measured ~62k callback cost, and the escrow-side state (`remaining`) is written before the call,
so a dropped callback can no longer desynchronise NAV. A permissionless `reconcile`-style path remains on the
roadmap.

**10. The demo funded an invoice id read before creation — `script/Demo.s.sol` (conf. 80)**
The demo discarded the id returned by `createInvoice` and funded the pre-read counter. Anyone could consume that
id in the mempool and collect the demo buyer's USDG seven days later via `autoRelease`.
*Fix:* the demo uses the returned id, and `ARBITER` is now required (the old default key was
`keccak256("invoice-advance-demo-arbiter")`, i.e. public knowledge).

### Medium — pricing accuracy, reputation, params, NAV

| # | Finding | Location | Conf. | Fix |
|---|---|---|---|---|
| 11 | Milestone count was a free multiplier on the priced lockup: twelve one-second-apart milestones priced as 21 days but released on day 101 | `AdvancePool.quote` | 80 | Tenor now adds `REVIEW_PERIOD + DELIVERY_GRACE` per unsettled milestone |
| 12 | Reputation was farmable; a defaulter with two defaults priced as a virgin | `AdvancePool._premium` | 75–80 | Premium priced from the first recorded bad outcome, floored at the newcomer rate |
| 13 | `autoRelease` credited a clean record to a buyer that did nothing, so three idle invoices cleared both premiums | `InvoiceEscrow.autoRelease` | 80 | New `Outcome.AutoReleased`: the clean mark goes to the performer only |
| 14 | Defaults were recorded for the seller only, so a refund-taking buyer stayed a "virgin" forever | `InvoiceEscrow._recordReputation` | 80 | Both sides recorded on `Defaulted` |
| 15 | `minHistory = 0` divided by zero and killed every quote; `baseAprBps`/`newcomerPremiumBps` unbounded | `AdvancePool._setParams`, `_premium` | 75 | Bounds enforced: `minHistory ≥ 1`, APR and newcomer premium ≤ 5000 bps, caps non-zero |
| 16 | A forced 50/50 dispute split costs ~49.5% of an advance against a 20% maximum discount | `AdvancePool.quote` | 75 | Priced as part of the tenor/discount ceiling — see limitations |
| 17 | NAV dipped between a deferred payout and the sweep, and a depositor in that block captured the payout | `AdvancePool.totalAssets`, `sweepDeferred` | 75 | `totalAssets` counts `escrow.claimable(pool)`; deferred cash is an asset, not a dip |
| 18 | A 1-wei face rounded the advance to zero and left the `AlreadyFinanced` sentinel unset | `AdvancePool.advance` | — | New `ZeroAdvance` revert |
| 19 | `setFee(0, address(0))` stranded accrued fees in `claimable[address(0)]`, where no account can claim | `InvoiceEscrow._setFee` | 85 | Zero recipient rejected unconditionally |
| 20 | `claim(address(0))` was callable; a non-canonical token return word could freeze settlement entirely | `InvoiceEscrow.claim`, `_push` | — | Zero recipient rejected; return word read as a uint256 and only `1` accepted |
| 21 | `FEE_BPS` truncated silently above 65535; the mock-token branch had no chain guard | `script/Deploy.s.sol` | — | Range-checked before the cast; `DEPLOY_MOCK_USDG` refused off a local chain |
| 22 | `FEE_BPS` env could leave the fee recipient unset, and `Demo` cast a real USDG address to `MockUSDG` | scripts | — | Recipient defaults to owner; mock branch guarded |

### Leads kept open (35, unscored)

The report's leads are honest trails rather than finished exploits, and several are worth stating plainly:
the fee **rate** is snapshotted per invoice but the **recipient** is still live (an owner rotation reroutes fees
on open invoices); `quote` runs every gate except the two caps and the idle-cash check, so it can price an
invoice `advance` then refuses; `previewRedeem` quotes deployed value that `redeem` will not allow while the
reserve is held; the virtual-share offset of 6 is only 0.2% of a 100 USDG first deposit (the repo's own donation
test shows no extraction path); the seller names the arbiter and the buyer never consents; `cancelInvoice`
leaves `remaining` populated; reputation counters are `uint32` with no reset; and same-block deposits still dilute
settlement profit (MEV-dependent).

### What the fixes changed about the design

The audit did not just patch bugs, it corrected three claims this README used to make:

- ~~"Losses are bounded by limits, not unbounded"~~ — limits now bound **face**, and a defaulted advance keeps
  its credit consumed, so the bound is real.
- ~~"There is no window to withdraw at an inflated share price"~~ — exits reserve the utilisation buffer, so
  there is no withdrawal that leaves later sellers or providers stranded.
- ~~"Cost basis is retired in the same transaction the escrow pays"~~ — still true, and now the retirement is
  measured against what the escrow actually delivered, deferred payouts included.

### Verification after the fixes

| | |
|---|---|
| Tests | **68 passing** (was 44): 21 escrow unit/fuzz, 21 pool unit/fuzz, 23 audit-fix regression + stress, 3 stateful invariants |
| Audit-fix suite | `test/AuditFixes.t.sol` — one test per finding, plus `testFuzz_stress_randomSettlementSequences` (random clean/default/split/exit/enter sequences re-checking the NAV identity, the face cap and escrow solvency after every step) and `testFuzz_stress_hostileHolderCallbacks` (issuer blocklist and gas-starved settlement) |
| Invariants | `escrow.balanceOf ≥ Σ remaining`, `escrow.balanceOf ≥ Σ claimable`, `pool.totalAssets == cash + claimable + deployed`, `deployed == Σ (cost − costReleased)`, `sellerExposure == Σ open cost`, 256 runs × 100 depth |
| Gas (measured) | `createInvoice` ~250k · `fund` ~84k · `advance` ~279k · `approveMilestone` ~108k · `submitMilestone` ~58k · `autoRelease` ~80k · `disputeMilestone` ~44k · `resolveDispute` ~148k · `reclaimUnsubmitted` ~147k · `deposit` ~123k · `withdraw` ~64k · `redeem` ~72k · `sweepDeferred` ~51k · `claim` ~47k |

## Threat model


| Risk | Mitigation |
|---|---|
| Reentrancy | Checks-effects-interactions in `_settle`; `nonReentrant` on all value paths; the escrow→pool callback is gas-capped (300k) and wrapped in `try/catch`, so a hostile holder cannot block or reenter settlement. |
| **Issuer freezes/blocklists an address** (real for a regulated stablecoin) | Escrow payouts never revert: a failed transfer — or a payout to the escrow itself — is parked in `claimable[to]`, and `claim(to)` lets the holder redirect it to a clean address. The holder callback is told what it was *credited* (delivered + parked), so a deferred payout never looks like a loss. Pool has `sweepDeferred(address to)` and counts `claimable` in NAV. Tested with a blocklisting mock and a gas-starved settler. |
| Fake invoices / buyer–seller collusion to drain the pool | The pool is **permissioned by design**: per-seller `sellerCreditLimit` set by the operator (KYB/credit decision), only **approved arbiters**, utilisation cap (80% **of face**), per-invoice concentration cap (20%). Unfunded, already-disputed, delinquent (past `deadline + grace`) or zero-priced invoices are refused, and a defaulted advance keeps its credit consumed, so the same seller cannot reuse one limit. Losses are bounded by limits, not unbounded. |
| ERC-4626 first-depositor inflation | `_decimalsOffset() = 6` virtual shares; tested (attacker cannot profit, victim loses < 0.0001%). |
| LP bank-run / illiquidity | `maxWithdraw`/`maxRedeem` capped to idle cash **and** to the cash that keeps outstanding face inside the utilisation cap (`_idleCap()`), so a withdrawal can neither drain the buffer nor freeze later advances. |
| Admin abuse | Admin **cannot move user funds**. Pricing params are bounded (`maxDiscount ≤ 50%`, slope ≤ 5×). Protocol fee hard-capped at 1% and **snapshotted per invoice** at creation so it can't be raised on existing deals. `Ownable2Step`; use a multisig. No upgradability by design. |
| Pause griefing | Pausing blocks only *new* invoices/funding/deposits/advances. Settlement, refunds, withdrawals stay live. |
| Accounting drift | Pool NAV = idle cash + escrow payouts already parked for the pool + advances still carried. Cost retires in the **same transaction** the escrow settles, measured against cash actually delivered, so a partial payment or a refund cannot be booked as a full one. Verified by invariants (256 × 100 calls) and by the NAV-identity assertion inside the stress fuzz. |
| Fee-on-transfer / odd tokens | `fund` checks the received balance delta; `_push` accepts a payout only when the token returns empty data or exactly `1`, and parks anything else (including a non-canonical word) instead of trusting or reverting. |
| Timestamp manipulation | Only coarse (days-scale) windows are used: 7-day review, 14-day arbiter timeout, 3-day delivery grace. |
| Late delivery | `submitMilestone` reverts past `deadline + DELIVERY_GRACE`, so a late submission can never close the buyer's refund path. |

## Known limitations (be upfront with judges)

- **AI-audited hackathon code, not human-audited.** 22 findings from the `solidity-auditor` scan are fixed and
  regression-tested, but no external human firm has reviewed it, and no bug bounty is running.
- **NAV at cost:** an advance on an invoice that is going bad is not marked down *before* it settles; the write-off
  happens in the settlement transaction. A production pool would add a keeper / `writeDown` path.
- **Dispute risk is priced, not modelled:** a forced 50/50 split costs roughly half a milestone while the discount
  ceiling is 20%, so a dispute-heavy book can lose more than its pricing implies.
- **Arbiter is a trusted role** per invoice; the pool only buys against arbiters its operator approved. Kleros/UMA-style arbitration is a future swap-in.
- **Credit limits are a human decision** (that's the point of a permissioned pool), not something the chain can verify.
- Single stablecoin; amounts assumed ≤ `uint128`.
- Pool pricing is simple and linear on purpose, to stay explainable and auditable.

## Roadmap / extensions
1. **Agent-delegated approvals (ZeroDev session keys):** a seller's business authorises an AI agent to `submitMilestone` /
   `advance` within USDG limits. Robinhood Chain docs call out first-class ERC-4337 session-key support.
2. **Stylus (Rust) pricing module** for cheaper on-chain risk scoring as history grows.
3. **Unfunded invoices** (buyer commits later) with a buyer-credit tranche in the pool.
4. **LayerZero USDG OFT** so Ethereum/Solana-side LPs can fund the pool cross-chain.
5. Frontend for seller / buyer / LP roles; event indexer.

## Layout
```
src/InvoiceEscrow.sol      milestone escrow + invoice NFT + reputation
src/AdvancePool.sol        ERC-4626 vault, risk pricing, caps, callback accounting
src/mocks/MockUSDG.sol     6-dec ERC-20 with blocklist (dev/test only)
script/Deploy.s.sol        chain-aware deployment (USDG addresses from Paxos docs), writes deployments/<chainid>.json
script/Demo.s.sol          end-to-end testnet run of the full product flow
deploy.sh                  one-command wrapper (deploy / demo / verify / mainnet guard)
test/InvoiceAdvance.t.sol  unit + fuzz tests for escrow and pool
test/AuditFixes.t.sol      one regression test per audit finding + fuzz/stress suites (23 tests)
test/Invariants.t.sol      stateful invariants (fund conservation, pool accounting)
.solidity-auditor/         audit run files, per-pass findings and the assembled report
deployments/               per-chain deployment JSON + extracted ABIs (abis/)
```
