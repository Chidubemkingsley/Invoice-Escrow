# 🔐 Security Review — Invoice-Escrow

---

## Scope

|  |  |
| --- | --- |
| **Mode** | default |
| **Files reviewed** | `./script/Deploy.s.sol` · `./script/Demo.s.sol` · `./src/InvoiceEscrow.sol`<br>`./src/AdvancePool.sol` |
| **Confidence threshold (1-100)** | 75 |
| **Passes** | 5 (pass 1 ran 10/12 agents, pass 2 ran 3/11 agents, pass 3 ran 4/4 agents, pass 4 ran 5/6 agents, pass 5 ran 1/4 agents) |
| **Memory** | 0 records before this scan · 56 after · `3d16cd4` |

---

## Findings

[85] **1. Utilisation cap counts cost, so the pool holds 160% of its NAV in face value**

`AdvancePool.advance` · Confidence: 85 · seen in 1/5 runs · NEW

**Description**
The utilisation cap measures deployed at cost, so the pool admits face value up to 1.6x its NAV and one default round wipes out 80% of the vault.

**Fix**

```diff
- if ((deployed + amount) * BPS > assets * params.utilizationCapBps) revert UtilizationCapExceeded();
+ if ((deployed + outstandingFace + q.face) * BPS > assets * params.utilizationCapBps) revert UtilizationCapExceeded();
```

---

[85] **2. A seller who is also a liquidity provider withdraws before the default lands**

`AdvancePool.maxWithdraw` · Confidence: 85 · seen in 2/5 runs · NEW

**Description**
Withdrawals are bounded by idle cash only, so a seller-LP exits at the pre-default price and the loss lands on the providers who stayed, 41.4% of the pool in the measured run.

**Fix**

```diff
- return Math.min(super.maxWithdraw(owner_), IERC20(asset()).balanceOf(address(this)));
+ return Math.min(super.maxWithdraw(owner_), Math.min(IERC20(asset()).balanceOf(address(this)), idleAfterReserve()));
```

---

[85] **3. Cost retires on gross face, not on cash received, so bad debt frees the credit limit**

`AdvancePool.onMilestoneSettled` · Confidence: 85 · seen in 2/5 runs · NEW

**Description**
The callback ignores paidToHolder and retires pro-rata cost on the milestone face, so a half-paid or unpaid milestone retires full cost, resets the seller exposure and repeats.

**Fix**

```diff
- uint128 retire = a.faceSettled >= a.face ? a.cost - a.costReleased : uint128((uint256(a.cost) * faceAmount) / a.face);
+ uint128 retire = uint128(Math.min(uint256(a.cost) * paidToHolder / a.face, a.cost - a.costReleased));
```

---

[85] **4. Gas-capped pool callback silently dropped, breaking advance accounting**

`AdvancePool.onMilestoneSettled` · Confidence: 85 · seen in 2/5 runs · NEW

**Description**
The escrow swallows a failed holder callback, so the pool never retires cost and the share price counts cash and basis twice.

**Fix**

```diff
- try IReceivableHolder(holder).onMilestoneSettled{gas: HOLDER_CALLBACK_GAS}(id, faceAmount, paid) {} catch {}
+ bool ok = IReceivableHolder(holder).onMilestoneSettled(id, faceAmount, paid);
+ if (!ok) emit HolderCallbackFailed(holder, id);
```

---

[85] **5. Clearing the fee recipient strands accrued fees where nobody can claim them**

`InvoiceEscrow._setFee` · Confidence: 85 · seen in 2/5 runs · NEW

**Description**
Each invoice snapshots the fee rate but not the recipient, so setFee(0, address(0)) makes later settlements park the fee in claimable[address(0)] and no account can ever call claim on it.

**Fix**

```diff
  function _setFee(uint16 feeBps_, address feeRecipient_) private {
+   if (feeRecipient_ == address(0)) revert InvalidFee();
    if (feeBps_ > MAX_FEE_BPS || (feeBps_ > 0 && feeRecipient_ == address(0))) revert InvalidFee();
```

---

[80] **6. Pool prices an already-late invoice near its full face**

`AdvancePool.quote` · Confidence: 80 · seen in 2/5 runs · NEW

**Description**
The pool checks no milestone deadline, so a whitelisted seller can sell a delinquent invoice at near face and the buyer can then reclaim it.

**Fix**

```diff
+ if (any unsettled milestone's deadline + DELIVERY_GRACE < block.timestamp) revert NotFunded();
```

---

[80] **7. Chained late submissions release far later than the priced tenor**

`AdvancePool.quote` · Confidence: 80 · seen in 4/5 runs · NEW

**Description**
Each milestone adds a review period after its predecessor settles, so twelve packed milestones priced at 21 days actually release on day 101 and the pool under-reserves its cost of capital.

**Fix**

```diff
+ tenor += DELIVERY_GRACE + REVIEW_PERIOD per unsettled milestone;
```

---

[80] **8. The demo funds an invoice id read before creation, so anyone can take the buyer's USDG**

`Demo._issueAndFund` · Confidence: 80 · seen in 1/5 runs · NEW

**Description**
The demo discards the id returned by createInvoice and funds the pre-read counter, so a front-runner can consume that id and collect the demo buyer's USDG.

**Fix**

```diff
- id = c.escrow.nextInvoiceId();
- c.escrow.createInvoice(c.buyer, c.arbiter, amounts, deadlines, docHash);
+ id = c.escrow.createInvoice(c.buyer, c.arbiter, amounts, deadlines, docHash);
  c.escrow.fund(id);
```

---

[80] **9. autoRelease credits a clean record to a silent buyer**

`InvoiceEscrow.autoRelease` · Confidence: 80 · seen in 1/5 runs · NEW

**Description**
Anyone can settle a submitted milestone after the review window, so a pair clears the newcomer premium with three one-unit invoices and the pool then pays 6% more face.

**Fix**

```diff
- _settle(id, index, m.amount, 0, Outcome.Clean);   // in autoRelease
+ _settle(id, index, m.amount, 0, Outcome.Clean);   // pass the outcome so the buyer earns nothing
```

---

[80] **10. Paying a payee that is the escrow contract succeeds, so the payout stays locked**

`InvoiceEscrow._push` · Confidence: 80 · seen in 1/5 runs · NEW

**Description**
A holder can transfer the invoice NFT to the escrow itself, the payout transfer then succeeds into an address with no withdrawal path, and no escrow function returns it.

**Fix**

```diff
+ if (to == address(this)) { claimable[to] += amount; return 0; }   // never pay the escrow itself
```

---

[80] **11. A default is recorded only for the seller**

`InvoiceEscrow._recordReputation` · Confidence: 80 · seen in 3/5 runs · NEW

**Description**
A buyer with fifty defaults still reads events = 0, so quote prices it as a virgin and the pool pays 93% of face on invoices the buyer will reclaim.

**Fix**

```diff
  } else {
      reputation[seller].defaulted += 1;
+     reputation[buyer].defaulted += 1;
  }
```

---

[80] **12. Late milestone submission erases the buyer refund path**

`InvoiceEscrow.submitMilestone` · Confidence: 80 · seen in 3/5 runs · NEW

**Description**
The seller can submit after the deadline, so reclaimUnsubmitted always reverts and the seller can be paid for a late delivery.

**Fix**

```diff
  Milestone storage m = _milestone(id, index);
+ if (block.timestamp > uint256(m.deadline) + DELIVERY_GRACE) revert TooLate();
  if (m.status != MilestoneStatus.Pending) revert BadMilestoneStatus();
```

---

[75] **13. A dead advance stays at full cost, so the next depositor buys a share price the escrow cannot pay**

`AdvancePool.deployed` · Confidence: 75 · seen in 1/5 runs · NEW

**Description**
Nothing writes a delinquent advance down, so totalAssets still reports the dead cost and a later LP's deposit is diluted by the write-off, 23.8% of their deposit in the modelled case.

**Fix**

```diff
+ function writeDown(uint256 id) external { /* permissionless once lastDeadline(id) + DELIVERY_GRACE has passed */ }
```

---

[75] **14. A seller with two defaults is priced as a virgin**

`AdvancePool._premium` · Confidence: 75 · seen in 2/5 runs · NEW

**Description**
_premium reads the event count before the outcomes, so a defaulter pays the same 300 bps newcomer rate as a new address until the third event.

**Fix**

```diff
- if (events < p.minHistory) return p.newcomerPremiumBps;
+ compute the bad-outcome ratio at every event count and take the max with newcomerPremiumBps
```

---

[75] **15. A zero minHistory makes _premium divide by zero**

`AdvancePool._premium` · Confidence: 75 · seen in 1/5 runs · NEW

**Description**
With minHistory set to zero the newcomer branch is skipped for a fresh address and the bad-outcome ratio divides by a zero event count, so quote reverts for every new counterparty.

**Fix**

```diff
+ require(p.minHistory >= 1);   // in _setParams
```

---

[75] **16. Three self-dealt settlements buy a zero risk premium**

`AdvancePool._premium` · Confidence: 75 · seen in 1/5 runs · NEW

**Description**
A colluding pair farms clean milestones until minHistory is met, so the pool pays 600 bps more face value per invoice for no reduction in risk.

**Fix**

```diff
- if (events < p.minHistory) return p.newcomerPremiumBps;
+ weight the premium by settled face value, and count only counterparties the owner approves
```

---

[75] **17. A forced 50/50 split erases seven advances' worth of discount**

`AdvancePool.quote` · Confidence: 75 · seen in 2/5 runs · NEW

**Description**
resolveExpiredDispute returns half the face while the quote charges at most 20%, so one expired dispute costs the pool 49.5% of an advance.

**Fix**

```diff
- (pool-side) price the per-milestone dispute probability, or haircut cost basis by paidToHolder on a split
```

---

[75] **18. minHistory of zero divides by zero and kills every quote**

`AdvancePool._setParams` · Confidence: 75 · seen in 1/5 runs · NEW

**Description**
Setting minHistory to zero skips the newcomer branch for a fresh address and divides by a zero event count, so quote reverts forever for any new counterparty.

**Fix**

```diff
+ if (p.minHistory == 0 || p.baseAprBps > 5000 || p.newcomerPremiumBps > 5000) revert InvalidParams();
```

---

[75] **19. Pool cannot rescue deferred payouts when its own address is blocked**

`AdvancePool.sweepDeferred` · Confidence: 75 · seen in 2/5 runs · NEW

**Description**
If the USDG issuer blocks the pool, escrow.claim can only pay back to the blocked pool, so deferred payouts are trapped.

**Fix**

```diff
- return escrow.claim(address(this));
+ return escrow.claim(rescueRecipient);  // admin-set, outside the frozen pool path
```

---

[75] **20. A depositor in a deferred-payout block captures the whole payout**

`AdvancePool.sweepDeferred` · Confidence: 75 · seen in 1/5 runs · NEW

**Description**
Because cost retires before the cash arrives, a flash-loaned deposit plus the permissionless sweep takes the entire deferred payout from other LPs.

**Fix**

```diff
- return IERC20(asset()).balanceOf(address(this)) + deployed;
+ return IERC20(asset()).balanceOf(address(this)) + deployed + escrow.claimable(address(this));
```

---

[75] **21. A deferred payout depresses the pool share price until swept**

`AdvancePool.totalAssets` · Confidence: 75 · seen in 2/5 runs · NEW

**Description**
When a payout to the pool is parked in escrow.claimable, totalAssets drops because deployed already retired, until someone calls sweepDeferred.

**Fix**

```diff
- return IERC20(asset()).balanceOf(address(this)) + deployed;
+ return IERC20(asset()).balanceOf(address(this)) + deployed + escrow.claimable(address(this));
```

---

[75] **22. Only the buyer can refund an undelivered milestone**

`InvoiceEscrow.reclaimUnsubmitted` · Confidence: 75 · seen in 3/5 runs · NEW

**Description**
Every other exit needs Submitted or Disputed status, so a seller that stops performing leaves the escrow balance and the pool's deployed capital open until the buyer acts.

**Fix**

```diff
- if (msg.sender != inv.buyer) revert NotBuyer();
+ // refund already goes to inv.buyer, so let any caller trigger it
```

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [85] | Utilisation cap counts cost, so the pool holds 160% of its NAV in face value |
| 2 | [85] | A seller who is also a liquidity provider withdraws before the default lands |
| 3 | [85] | Cost retires on gross face, not on cash received, so bad debt frees the credit limit |
| 4 | [85] | Gas-capped pool callback silently dropped, breaking advance accounting |
| 5 | [85] | Clearing the fee recipient strands accrued fees where nobody can claim them |
| 6 | [80] | Pool prices an already-late invoice near its full face |
| 7 | [80] | Chained late submissions release far later than the priced tenor |
| 8 | [80] | The demo funds an invoice id read before creation, so anyone can take the buyer's USDG |
| 9 | [80] | autoRelease credits a clean record to a silent buyer |
| 10 | [80] | Paying a payee that is the escrow contract succeeds, so the payout stays locked |
| 11 | [80] | A default is recorded only for the seller |
| 12 | [80] | Late milestone submission erases the buyer refund path |
| 13 | [75] | A dead advance stays at full cost, so the next depositor buys a share price the escrow cannot pay |
| 14 | [75] | A seller with two defaults is priced as a virgin |
| 15 | [75] | A zero minHistory makes _premium divide by zero |
| 16 | [75] | Three self-dealt settlements buy a zero risk premium |
| 17 | [75] | A forced 50/50 split erases seven advances' worth of discount |
| 18 | [75] | minHistory of zero divides by zero and kills every quote |
| 19 | [75] | Pool cannot rescue deferred payouts when its own address is blocked |
| 20 | [75] | A depositor in a deferred-payout block captures the whole payout |
| 21 | [75] | A deferred payout depresses the pool share price until swept |
| 22 | [75] | Only the buyer can refund an undelivered milestone |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 4 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 2/5 runs · NEW — **Body missing** — pass 2 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 4 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 1 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 3 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 4 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 1 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 4 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 3 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 3 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 3 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 1 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 3 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 4 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 4 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 4 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 3 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 2 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 3 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 1 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 2/5 runs · NEW — **Body missing** — pass 2 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 3 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 1 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 1 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 2/5 runs · NEW — **Body missing** — pass 5 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 5 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 3 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 3/5 runs · NEW — **Body missing** — pass 4 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 2/5 runs · NEW — **Body missing** — pass 4 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 4 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 1 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 3 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 3 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 2/5 runs · NEW — **Body missing** — pass 2 raised this lead and wrote no description.
- ****Title missing** — the lead's line could not be read** — **location missing** · seen in 1/5 runs · NEW — **Body missing** — pass 3 raised this lead and wrote no description.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
