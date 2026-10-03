# Run 2 — solidity-auditor

<!--RUN pass=2 of=5 stamp=20261003-170216 sha=3d16cd4 agents=3/11-->

Pass 2 of 5 · 2026-10-03 · `3d16cd4` · 3/11 agents returned — eight spawns aborted or failed upstream.

## Findings

<!--F key=advancepool|onmilestonesettled|silent-callback-failure-accounting-corruption conf=85 kind=FINDING agents=2-->

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

<!--F key=invoiceescrow|submitmilestone|late-submission-defeats-refund conf=80 kind=FINDING agents=1-->

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

<!--F key=advancepool|sweepdeferred|blocked-rescue-path conf=75 kind=FINDING agents=1-->

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

<!--F key=advancepool|totalassets|deferred-payout-nav-dip conf=75 kind=FINDING agents=1-->

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

<!--F key=advancepool|quote|timeout-split-pricing-gap kind=LEAD agents=1-->

[Lead] **Forced split and newcomer pricing leave the pool a coin-flip**

`AdvancePool.quote` · Code smells: resolveExpiredDispute splits every disputed milestone 50/50, and a fresh pair is capped at the 600 bps newcomer premium · A disputing buyer with a silent arbiter takes half of a pool-held milestone before any reputation counter-premium applies. What remains unverified: how often a dispute reaches the timeout instead of the arbiter.

<!--/F-->

<!--F key=deploy|run|arbiter-approval-skipped kind=LEAD agents=1-->

[Lead] **Deployer role skips arbiter approval for a separate owner**

`Deploy.run` · Code smells: setApprovedArbiter runs only when the deployer is the owner · With OWNER set to a multisig and the ARBITER env dropped, every quote reverts with ArbiterNotApproved. What remains unverified: an operator shipping that combination without reading the log.

<!--/F-->

<!--F key=invoiceescrow|_recordreputation|washable-reputation kind=LEAD agents=1-->

[Lead] **Clean reputation is farmable**

`InvoiceEscrow._recordReputation` · Code smells: colluding create/fund/submit/approve adds clean to both sides · Three round trips remove the 300 bps newcomer premium from future quotes. What remains unverified: whether colluding counterparty cash beats that premium.

<!--/F-->

<!--F key=invoiceescrow|_payout|live-fee-recipient kind=LEAD agents=1-->

[Lead] **Fee rate snapshotted, recipient live**

`InvoiceEscrow._payOut` · Code smells: inv.feeBps frozen at creation, feeRecipient read at settlement · An owner rotation reroutes the fees of every open invoice. What remains unverified: whether this is admin behaviour rather than an exploit.

<!--/F-->

<!--F key=advancepool|advance|exposure-attribution-mismatch kind=LEAD agents=1-->

[Lead] **Credit limit charged to the performer, paid to the NFT owner**

`AdvancePool.advance` · Code smells: sellerExposure keyed on getInvoice().seller but cash goes to msg.sender · An NFT owner can spend the performer's credit limit and shape their price history. What remains unverified: whether the operator credit process catches it.

<!--/F-->

<!--F key=advancepool|quote|tenor-underestimate kind=LEAD agents=1-->

[Lead] **Pool prices a lockup shorter than the real one**

`AdvancePool.quote` · Code smells: releaseAt = lastDeadline + REVIEW_PERIOD ignores ARBITER_TIMEOUT · A dispute filed late in the window pushes real release out by up to 14 days, for about 38 bps of under-charged carry per trade. What remains unverified: the share of invoices that reach a dispute.

<!--/F-->

<!--F key=deploy|run|truncated-fee-env kind=LEAD agents=1-->

[Lead] **FEE_BPS env truncates above 65535**

`Deploy.run` · Code smells: uint16(vm.envOr("FEE_BPS", ...)) before the cap check · FEE_BPS=65537 silently deploys feeBps=1. What remains unverified: an operator entering a value above 65535.

<!--/F-->

