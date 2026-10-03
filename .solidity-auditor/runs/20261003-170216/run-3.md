# Run 3 — solidity-auditor

<!--RUN pass=3 of=5 stamp=20261003-170216 sha=3d16cd4 agents=4/4-->

Pass 3 of 5 · 2026-10-03 · `3d16cd4` · 4/4 agents returned.

## Findings

<!--F key=advancepool|onmilestonesettled|bad-debt-frees-credit-limit conf=85 kind=FINDING agents=1-->

[85] **A defaulted advance frees the seller credit limit, so the drain repeats**

`AdvancePool.onMilestoneSettled` · Confidence: 85

**Description**
A defaulted advance retires the full cost from sellerExposure, so one approved seller reuses the same limit every round and takes 47.9% of LP capital.

**Fix**

```diff
- sellerExposure[a.seller] -= retire;
+ if (paidToHolder < retire) sellerExposure[a.seller] -= paidToHolder;  // keep the shortfall on the seller
```

<!--/F-->

<!--F key=advancepool|advance|cap-denominated-in-cost-basis conf=85 kind=FINDING agents=1-->

[85] **Utilisation cap counts cost, so the pool holds 160% of its NAV in face value**

`AdvancePool.advance` · Confidence: 85

**Description**
The utilisation cap measures deployed at cost, so the pool admits face value up to 1.6x its NAV and one default round wipes out 80% of the vault.

**Fix**

```diff
- if ((deployed + amount) * BPS > assets * params.utilizationCapBps) revert UtilizationCapExceeded();
+ if ((deployed + outstandingFace + q.face) * BPS > assets * params.utilizationCapBps) revert UtilizationCapExceeded();
```

<!--/F-->

<!--F key=advancepool|maxwithdraw|utilization-cap-defeated-by-withdrawal conf=80 kind=FINDING agents=1-->

[80] **Any LP can withdraw idle cash and freeze all new advances**

`AdvancePool.maxWithdraw` · Confidence: 80

**Description**
Withdrawals are capped only at idle cash, so one LP withdrawing cash pushes deployed above the utilisation cap and every later advance reverts.

**Fix**

```diff
- return Math.min(super.maxWithdraw(owner_), IERC20(asset()).balanceOf(address(this)));
+ return Math.min(super.maxWithdraw(owner_), Math.min(IERC20(asset()).balanceOf(address(this)), deployedCashBuffer()));
```

<!--/F-->

<!--F key=demo|_issueandfund|stale-id-read-wrong-invoice conf=80 kind=FINDING agents=1-->

[80] **The demo funds an invoice id read before creation, so anyone can take the buyer's USDG**

`Demo._issueAndFund` · Confidence: 80

**Description**
The demo discards the id returned by createInvoice and funds the pre-read counter, so a front-runner can consume that id and collect the demo buyer's USDG.

**Fix**

```diff
- id = c.escrow.nextInvoiceId();
- c.escrow.createInvoice(c.buyer, c.arbiter, amounts, deadlines, docHash);
+ id = c.escrow.createInvoice(c.buyer, c.arbiter, amounts, deadlines, docHash);
  c.escrow.fund(id);
```

<!--/F-->

<!--F key=advancepool|_premium|washable-reputation conf=75 kind=FINDING agents=2-->

[75] **Three self-dealt settlements buy a zero risk premium**

`AdvancePool._premium` · Confidence: 75

**Description**
A colluding pair farms clean milestones until minHistory is met, so the pool pays 600 bps more face value per invoice for no reduction in risk.

**Fix**

```diff
- if (events < p.minHistory) return p.newcomerPremiumBps;
+ weight the premium by settled face value, and count only counterparties the owner approves
```

<!--/F-->

<!--F key=advancepool|quote|timeout-split-pricing-gap conf=75 kind=FINDING agents=2-->

[75] **A forced 50/50 split erases seven advances' worth of discount**

`AdvancePool.quote` · Confidence: 75

**Description**
resolveExpiredDispute returns half the face while the quote charges at most 20%, so one expired dispute costs the pool 49.5% of an advance.

**Fix**

```diff
- (pool-side) price the per-milestone dispute probability, or haircut cost basis by paidToHolder on a split
```

<!--/F-->

<!--F key=advancepool|sweepdeferred|deferred-payout-nav-dip conf=75 kind=FINDING agents=2-->

[75] **A depositor in a deferred-payout block captures the whole payout**

`AdvancePool.sweepDeferred` · Confidence: 75

**Description**
Because cost retires before the cash arrives, a flash-loaned deposit plus the permissionless sweep takes the entire deferred payout from other LPs.

**Fix**

```diff
- return IERC20(asset()).balanceOf(address(this)) + deployed;
+ return IERC20(asset()).balanceOf(address(this)) + deployed + escrow.claimable(address(this));
```

<!--/F-->

<!--F key=advancepool|_premium|boundary-flat-newcomer-premium conf=75 kind=FINDING agents=2-->

[75] **A seller with two defaults is priced as a virgin**

`AdvancePool._premium` · Confidence: 75

**Description**
_premium reads the event count before the outcomes, so a defaulter pays the same 300 bps newcomer rate as a new address until the third event.

**Fix**

```diff
- if (events < p.minHistory) return p.newcomerPremiumBps;
+ compute the bad-outcome ratio at every event count and take the max with newcomerPremiumBps
```

<!--/F-->

<!--F key=invoiceescrow|reclaimunsubmitted|silent-buyer-deadlock conf=75 kind=FINDING agents=1-->

[75] **Only the buyer can refund an undelivered milestone, so pool capital stays open forever**

`InvoiceEscrow.reclaimUnsubmitted` · Confidence: 75

**Description**
Every other exit needs Submitted or Disputed status, so a seller that never submits leaves the escrow balance and the pool's deployed capital open until the buyer acts.

**Fix**

```diff
- if (msg.sender != inv.buyer) revert NotBuyer();   // in reclaimUnsubmitted
+ // refund already goes to inv.buyer, so let any caller trigger it
```

<!--/F-->

<!--F key=advancepool|deployed|nav-not-marked-down conf=75 kind=FINDING agents=1-->

[75] **A dead advance stays at full cost, so the next depositor buys a share price the escrow cannot pay**

`AdvancePool.deployed` · Confidence: 75

**Description**
Nothing writes a delinquent advance down, so totalAssets still reports the dead cost and a later LP's deposit is diluted by the write-off, 23.8% of their deposit in the modelled case.

**Fix**

```diff
+ function writeDown(uint256 id) external { /* permissionless once lastDeadline(id) + DELIVERY_GRACE has passed */ }
```

<!--/F-->

## Leads

<!--F key=invoiceescrow|_notifyholder|silent-callback-failure-accounting-corruption kind=LEAD agents=1-->

[Lead] **The escrow sends the holder callback once and stores no receipt**

`InvoiceEscrow._notifyHolder` · Code smells: try/catch with a 300k gas cap, no receipt flag, and the holder is the only writer of costReleased, deployed and sellerExposure · The pool's own callback needs about 30k gas, so the reachable case is a future non-pool holder, but the irreversibility is proven: once the catch fires, remaining is already reduced while deployed is not, and nothing re-notifies. What remains unverified: a live way to exceed the cap with the current pool.

<!--/F-->

<!--F key=invoiceescrow|_push|asymmetric-amount-verification kind=LEAD agents=2-->

[Lead] **fund checks the received balance, _push does not**

`InvoiceEscrow._push` · Code smells: fund brackets the transfer with a balanceOf delta and reverts on shortfall, while _push accepts a bare true or empty returndata as full payment · A token that returns true but transfers less makes the escrow pay out more than it holds. What remains unverified: USDG and MockUSDG both return 32 bytes and move the exact amount.

<!--/F-->

<!--F key=invoiceescrow|createinvoice|seller-selects-dispute-resolver kind=LEAD agents=1-->

[Lead] **The seller names the arbiter and the buyer never consents**

`InvoiceEscrow.createInvoice` · Code smells: buyer is bound to the seller's chosen arbiter in fund with no veto, and quote checks only approvedArbiter · A forced 50/50 split on a 25,000 USDG milestone costs the pool 12,500 USDG, more than seven milestones of discount. What remains unverified: the operator vets every approved arbiter.

<!--/F-->

<!--F key=invoiceescrow|_recordreputation|buyer-credit-for-silence kind=LEAD agents=1-->

[Lead] **autoRelease credits the buyer with a clean record**

`InvoiceEscrow._recordReputation` · Code smells: autoRelease settles Outcome.Clean, so a silent buyer gains clean history while defaults are only ever raised on the seller · A silent buyer reaches a zero premium and the pool pays 300 bps more face. What remains unverified: whether a real buyer can stay silent at no cost.

<!--/F-->

<!--F key=invoiceescrow|_recordreputation|unbounded-reputation-counter kind=LEAD agents=1-->

[Lead] **Reputation counters are uint32 and never reset**

`InvoiceEscrow._recordReputation` · Code smells: clean, disputed and defaulted are uint32 incremented inside _finalize with no cap · The 4,294,967,296th settlement for one address reverts inside _finalize and locks that escrow. What remains unverified: a way to reach that count.

<!--/F-->

<!--F key=invoiceescrow|cancelinvoice|stale-ledger-after-cancel kind=LEAD agents=1-->

[Lead] **cancelInvoice leaves remaining and openMilestones populated**

`InvoiceEscrow.cancelInvoice` · Code smells: only status is written, so remaining still reports a debt no token backs · An integrator that sums getInvoice(id).remaining reads the escrow as insolvent by the full cancelled amount. What remains unverified: no on-chain path was found where this pays anyone.

<!--/F-->

<!--F key=advancepool|quote|cap-checks-absent-from-quote kind=LEAD agents=1-->

[Lead] **quote prices invoices that advance will reject**

`AdvancePool.quote` · Code smells: the two pool caps live only in advance, so quote reports a price for an invoice advance then reverts on · The demo treats the quote as executable. What remains unverified: no path where this moves tokens.

<!--/F-->

<!--F key=advancepool|quote|view-write-pricing-divergence kind=LEAD agents=1-->

[Lead] **The quote reserves the fee on full face, the payout charges it on the payee's share**

`AdvancePool.quote` · Code smells: quote adds all of inv.feeBps, _payOut computes fee = toPayee * feeBps · On a 50/50 split the pool carries 125 USDG of fee it can never collect on a 100,000 USDG face at 25 bps. What remains unverified: whether a fee above 0 is ever set.

<!--/F-->

<!--F key=advancepool|previewredeem|preview-exceeds-max-redeem kind=LEAD agents=1-->

[Lead] **previewRedeem reports deployed value that redeem then refuses**

`AdvancePool.previewRedeem` · Code smells: previews read totalAssets (cash plus deployed) while maxWithdraw/maxRedeem cap at idle cash · An integrator shows a liquidity provider an amount that always reverts, including a full-balance redeem. What remains unverified: no loss inside the protocol.

<!--/F-->

<!--F key=advancepool|_decimalsoffset|weak-virtual-offset kind=LEAD agents=1-->

[Lead] **Virtual offset of 6 is 0.2% of a 500 USDG first deposit**

`AdvancePool._decimalsOffset` · Code smells: offset fixed at 6 with no MINIMUM_LIQUIDITY lock · The repo's own donation test shows no extraction path, so this only blunts the attack. What remains unverified: nothing further; the attack is unprofitable in the repo's test.

<!--/F-->

<!--F key=deploy|run|missing-asset-identity-check kind=LEAD agents=1-->

[Lead] **The mock-token branch has no chain guard**

`Deploy.run` · Code smells: DEPLOY_MOCK_USDG skips _defaultUsdg, so only require(token.code.length) remains and MockUSDG.mint and setBlocked are unrestricted · A stale env value broadcasts both contracts against a token anyone can mint. What remains unverified: an operator shipping that combination.

<!--/F-->

<!--F key=deploy|_record|unvalidated-deployment-json kind=LEAD agents=1-->

[Lead] **Deployment JSON records escrow and pool without checking their code**

`Deploy._record` · Code smells: the token is checked, the two deployed contracts are not, and Demo reads both addresses back unchecked · A truncated write makes the demo call an address no contract occupies. What remains unverified: this needs a broken or racing local deploy.

<!--/F-->

<!--F key=demo|_advance|stale-quote-no-max-price kind=LEAD agents=1-->

[Lead] **The demo quotes and advances in two transactions, and advance has no maximum price**

`Demo._advance` · Code smells: only minAdvance guards the price, so one direction is unprotected · A settlement that moves the seller across minHistory between the two transactions reprices the advance. What remains unverified: a worse price needs the seller to lose reputation, which needs real disputes.

<!--/F-->

<!--F key=ireceivableholder|onmilestonesettled|callback-drops-outcome kind=LEAD agents=1-->

[Lead] **The settlement callback carries no outcome, so a holder cannot mark a receivable to market**

`IReceivableHolder.onMilestoneSettled` · Code smells: MilestoneSettled emits the full split, but _notifyHolder forwards only (id, faceAmount, paid) · The pool retires full proportional cost on a Defaulted milestone that paid it nothing and cannot tell that case from Clean. What remains unverified: the retirement is the correct loss recognition, so no double count was found.

<!--/F-->