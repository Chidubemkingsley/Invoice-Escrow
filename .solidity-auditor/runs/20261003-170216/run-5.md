# Run 5 — solidity-auditor

<!--RUN pass=5 of=5 stamp=20261003-170216 sha=3d16cd4 agents=1/4-->

Pass 5 of 5 · 2026-10-03 · `3d16cd4` · 1/4 agents returned — three spawns were interrupted upstream.

## Findings

<!--F key=invoiceescrow|_setfee|fee-recipient-zeroed-after-snapshot conf=85 kind=FINDING agents=1-->

[85] **Clearing the fee recipient strands accrued fees where nobody can claim them**

`InvoiceEscrow._setFee` · Confidence: 85

**Description**
Each invoice snapshots the fee rate but not the recipient, so setFee(0, address(0)) makes later settlements park the fee in claimable[address(0)] and no account can ever call claim on it.

**Fix**

```diff
  function _setFee(uint16 feeBps_, address feeRecipient_) private {
+   if (feeRecipient_ == address(0)) revert InvalidFee();
    if (feeBps_ > MAX_FEE_BPS || (feeBps_ > 0 && feeRecipient_ == address(0))) revert InvalidFee();
```

<!--/F-->

<!--F key=invoiceescrow|autorelease|buyer-credit-for-silence conf=80 kind=FINDING agents=1-->

[80] **autoRelease credits a clean record to a silent buyer**

`InvoiceEscrow.autoRelease` · Confidence: 80

**Description**
Anyone can settle a submitted milestone after the review window, so a pair clears the newcomer premium with three one-unit invoices and the pool then pays 6% more face.

**Fix**

```diff
- _settle(id, index, m.amount, 0, Outcome.Clean);   // in autoRelease
+ _settle(id, index, m.amount, 0, Outcome.Clean);   // pass the outcome so the buyer earns nothing
```

<!--/F-->

<!--F key=advancepool|_premium|missing-param-validation conf=75 kind=FINDING agents=1-->

[75] **A zero minHistory makes _premium divide by zero**

`AdvancePool._premium` · Confidence: 75

**Description**
With minHistory set to zero the newcomer branch is skipped for a fresh address and the bad-outcome ratio divides by a zero event count, so quote reverts for every new counterparty.

**Fix**

```diff
+ require(p.minHistory >= 1);   // in _setParams
```

<!--/F-->

<!--F key=invoiceescrow|_recordreputation|asymmetric-counter-updates conf=80 kind=FINDING agents=1-->

[80] **A default is recorded only for the seller**

`InvoiceEscrow._recordReputation` · Confidence: 80

**Description**
A buyer with fifty defaults still reads events = 0, so quote prices it as a virgin and the pool pays 93% of face on invoices the buyer will reclaim.

**Fix**

```diff
  } else {
      reputation[seller].defaulted += 1;
+     reputation[buyer].defaulted += 1;
  }
```

<!--/F-->

<!--F key=advancepool|quote|tenor-underestimate conf=80 kind=FINDING agents=1-->

[80] **Chained late submissions release far later than the priced tenor**

`AdvancePool.quote` · Confidence: 80

**Description**
Each milestone adds a review period after its predecessor settles, so twelve packed milestones priced at 21 days actually release on day 101 and the pool under-reserves its cost of capital.

**Fix**

```diff
+ tenor += DELIVERY_GRACE + REVIEW_PERIOD per unsettled milestone;
```

<!--/F-->

## Leads

<!--F key=invoiceescrow|createinvoice|seller-selects-dispute-resolver kind=LEAD agents=1-->

[Lead] **One arbiter approval covers every future invoice**

`InvoiceEscrow.createInvoice` · Code smells: the seller names the arbiter, the pool approves arbiters globally, and a contract arbiter is accepted with no interface check · One owner approval therefore covers every invoice any seller names later. What remains unverified: no input found that forces a bad ruling without a wrong owner approval.

<!--/F-->

<!--F key=invoiceescrow|disputemilestone|nav-not-marked-down kind=LEAD agents=1-->

[Lead] **A free dispute holds the pool price above the value the escrow will pay**

`InvoiceEscrow.disputeMilestone` · Code smells: disputing costs the buyer nothing, no arbiter is required, and deployed keeps full cost for the arbiter timeout · totalAssets stays inflated for 14 days. What remains unverified: no deposit can force a redemption before the split lands.

<!--/F-->