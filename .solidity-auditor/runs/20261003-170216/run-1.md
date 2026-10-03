# Run 1 — solidity-auditor

<!--RUN pass=1 of=5 stamp=20261003-170216 sha=3d16cd4 agents=10/12-->

Pass 1 of 5 · 2026-10-03 · `3d16cd4` · 10/12 agents returned — one access-control spawn aborted, one runtime error.

## Findings

<!--F key=advancepool|onmilestonesettled|silent-callback-failure-accounting-corruption conf=85 kind=FINDING agents=4-->

[85] **Gas-capped pool callback silently dropped, breaking advance accounting**

`AdvancePool.onMilestoneSettled` · Confidence: 85

**Description**
The escrow swallows a failed holder callback, so the pool never retires cost and the share price counts cash and basis twice.

**Fix**

```diff
- try IReceivableHolder(holder).onMilestoneSettled{gas: HOLDER_CALLBACK_GAS}(id, faceAmount, paid) {} catch {}
+ bool ok = IReceivableHolder(holder).onMilestoneSettled(id, faceAmount, paid);
+ if (!ok) emit HolderCallbackFailed(holder, id);
```

<!--/F-->

<!--F key=invoiceescrow|submitmilestone|late-submission-defeats-refund conf=80 kind=FINDING agents=2-->

[80] **Late milestone submission erases the buyer refund path**

`InvoiceEscrow.submitMilestone` · Confidence: 80

**Description**
The seller can submit after the deadline, so reclaimUnsubmitted always reverts and the seller can be paid for a late delivery.

**Fix**

```diff
  Milestone storage m = _milestone(id, index);
+ if (block.timestamp > uint256(m.deadline) + DELIVERY_GRACE) revert TooLate();
  if (m.status != MilestoneStatus.Pending) revert BadMilestoneStatus();
```

<!--/F-->

<!--F key=advancepool|quote|missing-delinquency-check conf=80 kind=FINDING agents=1-->

[80] **Pool prices an already-late invoice near its full face**

`AdvancePool.quote` · Confidence: 80

**Description**
The pool checks no milestone deadline, so a whitelisted seller can sell a delinquent invoice at near face and the buyer can then reclaim it.

**Fix**

```diff
+ if (any unsettled milestone's deadline + DELIVERY_GRACE < block.timestamp) revert NotFunded();
```

<!--/F-->

<!--F key=advancepool|sweepdeferred|blocked-rescue-path conf=75 kind=FINDING agents=2-->

[75] **Pool cannot rescue deferred payouts when its own address is blocked**

`AdvancePool.sweepDeferred` · Confidence: 75

**Description**
If the USDG issuer blocks the pool, escrow.claim can only pay back to the blocked pool, so deferred payouts are trapped.

**Fix**

```diff
- return escrow.claim(address(this));
+ return escrow.claim(rescueRecipient);  // admin-set, outside the frozen pool path
```

<!--/F-->

<!--F key=advancepool|quote|tenor-underestimate conf=75 kind=FINDING agents=2-->

[75] **Pool prices a lockup shorter than the real one**

`AdvancePool.quote` · Confidence: 75

**Description**
The quote assumes release at lastDeadline + review period, but late submission or a dispute arbiter timeout extends the real lockup.

**Fix**

```diff
- uint256 tenor = releaseAt > block.timestamp ? releaseAt - block.timestamp : 0;
+ include worst-case extension (+ ARBITER_TIMEOUT) or late-submit margin in releaseAt
```

<!--/F-->

<!--F key=advancepool|totalassets|deferred-payout-nav-dip conf=75 kind=FINDING agents=3-->

[75] **A deferred payout depresses the pool share price until swept**

`AdvancePool.totalAssets` · Confidence: 75

**Description**
When a payout to the pool is parked in escrow.claimable, totalAssets drops because deployed already retired, until someone calls sweepDeferred.

**Fix**

```diff
- return IERC20(asset()).balanceOf(address(this)) + deployed;
+ return IERC20(asset()).balanceOf(address(this)) + deployed + escrow.claimable(address(this));
```

<!--/F-->

## Leads

<!--F key=advancepool|setparams|missing-param-validation kind=LEAD agents=1-->

[Lead] **Invalid params brick quoting**

`AdvancePool.setParams` · Code smells: minHistory = 0 allowed, baseAprBps unbounded · A minHistory of 0 makes _premium divide by zero for fresh addresses, so every quote reverts; an oversized baseAprBps pins every quote at RiskTooHigh. What remains unverified: whether the owner would ever set these values.

<!--/F-->

<!--F key=advancepool|_premium|boundary-flat-newcomer-premium kind=LEAD agents=1-->

[Lead] **Newcomer band ignores settled outcomes**

`AdvancePool._premium` · Code smells: flat premium below minHistory · A seller with two defaulted milestones pays the same 300 bps as a clean newcomer until the third event. What remains unverified: whether an operator relies on the premium to price bad actors early.

<!--/F-->

<!--F key=advancepool|advance|zero-cost-advance-bookkeeping kind=LEAD agents=1-->

[Lead] **A zero-cost advance records no bookkeeping**

`AdvancePool.advance` · Code smells: no revert when advance rounds to 0 · With discount at the 50% cap on a 1-wei face, cost is 0, AlreadyFinanced is unguarded, and onMilestoneSettled early-returns, so the payout cash lands with no deployed tracking. What remains unverified: whether meaningful USDG cash can flow through such an advance.

<!--/F-->

<!--F key=advancepool|advance|exposure-attribution-mismatch kind=LEAD agents=1-->

[Lead] **Credit limit charged to the performer, paid to the NFT owner**

`AdvancePool.advance` · Code smells: sellerExposure keyed on getInvoice().seller but cash goes to msg.sender · An NFT owner can spend the performer's credit limit and shape their price history. What remains unverified: whether the pool's operator credit process catches it.

<!--/F-->

<!--F key=advancepool|deposit|jit-deposit-nav-dilution kind=LEAD agents=1-->

[Lead] **Same-block deposit dilutes settlement profit**

`AdvancePool.deposit` · Code smells: discrete NAV, no holding epoch · A depositor watching settlement txs shares the profit of those txs and can redeem immediately. What remains unverified: MEV bundling needed to land such a deposit atomically before the settle.

<!--/F-->

<!--F key=invoiceescrow|_recordreputation|washable-reputation kind=LEAD agents=2-->

[Lead] **Clean reputation is farmable**

`InvoiceEscrow._recordReputation` · Code smells: colluding create/fund/submit/approve adds clean to both sides · Three round trips remove the 300 bps newcomer premium from future quotes. What remains unverified: whether colluding counterparty cash (~gas + escrow float) is priced into an attack that beats that premium.

<!--/F-->

<!--F key=invoiceescrow|_recordreputation|asymmetric-counter-updates kind=LEAD agents=2-->

[Lead] **Reputation counters charge buyers asymmetrically**

`InvoiceEscrow._recordReputation` · Code smells: Disputed increments both sides, Defaulted only seller, buyer reclaims record nothing · An honest buyer who wins a full refund via dispute pays a mark a reclaim-path refund does not impose. What remains unverified: a concrete loss path from this mark into pricing.

<!--/F-->

<!--F key=invoiceescrow|_payout|live-fee-recipient kind=LEAD agents=2-->

[Lead] **Fee rate snapshotted, recipient live**

`InvoiceEscrow._payOut` · Code smells: inv.feeBps frozen at creation, feeRecipient read at settlement · An owner rotation reroutes the fees of every open invoice to the new recipient. What remains unverified: whether this is an admin-behavior complaint rather than an exploit.

<!--/F-->

<!--F key=invoiceescrow|reclaimunsubmitted|silent-buyer-deadlock kind=LEAD agents=1-->

[Lead] **A silent buyer permanently locks settled-cost capital**

`InvoiceEscrow.reclaimUnsubmitted` · Code smells: buyer-only refund trigger, no permissionless failsafe · If the buyer is incapacitated, the escrowed USDG and the pool's deployed slice on that invoice stay locked and totalAssets overstates value forever. What remains unverified: probability of an incapacitated buyer.

<!--/F-->

<!--F key=invoiceescrow|reclaimunsubmitted|clock-restart-only-on-delivery kind=LEAD agents=2-->

[Lead] **Previous refund does not compress next milestone window**

`InvoiceEscrow.reclaimUnsubmitted` · Code smells: next clock restarts only when the previous milestone had been submitted · A delayed first reclaim leaves the seller no time to deliver the next milestone, so a second default follows one cause. What remains unverified: whether this can be sequenced for real loss.

<!--/F-->

<!--F key=invoiceescrow|claim|no-sweep-for-stray-token kind=LEAD agents=1-->

[Lead] **No recovery for tokens sent to the escrow by mistake**

`InvoiceEscrow.claim` · Code smells: only parked payouts are pulled · USDG sent directly to the escrow address is stuck with no sweep. What remains unverified: tokens actually sent in error.

<!--/F-->

<!--F key=deploy|run|truncated-fee-env kind=LEAD agents=1-->

[Lead] **FEE_BPS env truncates above 65535**

`Deploy.run` · Code smells: uint16(vm.envOr("FEE_BPS", ...)) before the cap check · FEE_BPS=65537 silently deploys feeBps=1. What remains unverified: an operator actually entering a value above 65535.

<!--/F-->

<!--F key=deploy|run|predictable-arbiter-default kind=LEAD agents=2-->

[Lead] **Demo default arbiter key is derivable**

`Demo._load` · Code smells: vm.addr(keccak256("invoice-advance-demo-arbiter")) as default · Anyone can compute that private key and rule on demo disputes. What remains unverified: real funds at stake on demo deployments.

<!--/F-->

<!--F key=invoiceescrow|constructor|single-step-owner kind=LEAD agents=1-->

[Lead] **Mistyped owner bricks admin forever**

`InvoiceEscrow.constructor` · Code smells: Ownable2Step not exercised at deploy · A typo in the OWNER env locks setFee, pause and setParams to an address nobody controls. What remains unverified: a deploy-time typo actually happening.

<!--/F-->

## Completeness

Raw unique (Contract, function) pairs: 24; covered: 24.
