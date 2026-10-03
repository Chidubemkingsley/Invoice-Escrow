# Run 4 — solidity-auditor

<!--RUN pass=4 of=5 stamp=20261003-170216 sha=3d16cd4 agents=5/6-->

Pass 4 of 5 · 2026-10-03 · `3d16cd4` · 5/6 agents returned — one spawn aborted.

## Findings

<!--F key=invoiceescrow|_setfee|fee-recipient-zeroed-after-snapshot conf=85 kind=FINDING agents=3-->

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

<!--F key=advancepool|onmilestonesettled|bad-debt-frees-credit-limit conf=85 kind=FINDING agents=4-->

[85] **Cost retires on gross face, not on cash received, so bad debt frees the credit limit**

`AdvancePool.onMilestoneSettled` · Confidence: 85

**Description**
The callback ignores paidToHolder and retires pro-rata cost on the milestone face, so a half-paid or unpaid milestone retires full cost, resets the seller exposure and repeats.

**Fix**

```diff
- uint128 retire = a.faceSettled >= a.face ? a.cost - a.costReleased : uint128((uint256(a.cost) * faceAmount) / a.face);
+ uint128 retire = uint128(Math.min(uint256(a.cost) * paidToHolder / a.face, a.cost - a.costReleased));
```

<!--/F-->

<!--F key=advancepool|maxwithdraw|utilization-cap-defeated-by-withdrawal conf=85 kind=FINDING agents=3-->

[85] **A seller who is also a liquidity provider withdraws before the default lands**

`AdvancePool.maxWithdraw` · Confidence: 85

**Description**
Withdrawals are bounded by idle cash only, so a seller-LP exits at the pre-default price and the loss lands on the providers who stayed, 41.4% of the pool in the measured run.

**Fix**

```diff
- return Math.min(super.maxWithdraw(owner_), IERC20(asset()).balanceOf(address(this)));
+ return Math.min(super.maxWithdraw(owner_), Math.min(IERC20(asset()).balanceOf(address(this)), idleAfterReserve()));
```

<!--/F-->

<!--F key=invoiceescrow|_push|payout-burned-in-escrow conf=80 kind=FINDING agents=1-->

[80] **Paying a payee that is the escrow contract succeeds, so the payout stays locked**

`InvoiceEscrow._push` · Confidence: 80

**Description**
A holder can transfer the invoice NFT to the escrow itself, the payout transfer then succeeds into an address with no withdrawal path, and no escrow function returns it.

**Fix**

```diff
+ if (to == address(this)) { claimable[to] += amount; return 0; }   // never pay the escrow itself
```

<!--/F-->

<!--F key=advancepool|quote|tenor-underestimate conf=80 kind=FINDING agents=3-->

[80] **Milestone count is a free multiplier on the priced lockup**

`AdvancePool.quote` · Confidence: 80

**Description**
Tenor is measured from the last deadline alone, so twelve one-second-apart milestones price as seven days while settling sequentially can take up to 252 days.

**Fix**

```diff
- uint256 tenor = releaseAt > block.timestamp ? releaseAt - block.timestamp : 0;
+ uint256 tenor = releaseAt > block.timestamp ? releaseAt - block.timestamp : 0;
+ tenor += uint256(escrow.getMilestoneCount(id)) * (REVIEW_PERIOD + ARBITER_TIMEOUT);
```

<!--/F-->

<!--F key=advancepool|_setparams|missing-param-validation conf=75 kind=FINDING agents=2-->

[75] **minHistory of zero divides by zero and kills every quote**

`AdvancePool._setParams` · Confidence: 75

**Description**
Setting minHistory to zero skips the newcomer branch for a fresh address and divides by a zero event count, so quote reverts forever for any new counterparty.

**Fix**

```diff
+ if (p.minHistory == 0 || p.baseAprBps > 5000 || p.newcomerPremiumBps > 5000) revert InvalidParams();
```

<!--/F-->

<!--F key=invoiceescrow|reclaimunsubmitted|silent-buyer-deadlock conf=75 kind=FINDING agents=1-->

[75] **Only the buyer can refund an undelivered milestone**

`InvoiceEscrow.reclaimUnsubmitted` · Confidence: 75

**Description**
Every other exit needs Submitted or Disputed status, so a seller that stops performing leaves the escrow balance and the pool's deployed capital open until the buyer acts.

**Fix**

```diff
- if (msg.sender != inv.buyer) revert NotBuyer();
+ // refund already goes to inv.buyer, so let any caller trigger it
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

## Leads

<!--F key=invoiceescrow|_push|push-reverts-on-noncanonical-return kind=LEAD agents=1-->

[Lead] **A non-canonical bool return freezes settlement**

`InvoiceEscrow._push` · Code smells: the return word is decoded as bool with no try/catch, so a token returning any other 32-byte value reverts the settlement helper and blocks all five _settle entries · Measured: with such a token the milestone stays Submitted, remaining never moves and no exit is reachable. What remains unverified: USDG returns a canonical true, and only an operator-chosen token could do this.

<!--/F-->

<!--F key=invoiceescrow|_push|asymmetric-amount-verification kind=LEAD agents=3-->

[Lead] **fund checks the received balance, _push does not**

`InvoiceEscrow._push` · Code smells: fund brackets the transfer with a balanceOf delta, while _push accepts an empty return or a bare true as full payment and the event reports the requested amount · A token that returns true but transfers less makes the escrow pay out more than it holds. What remains unverified: USDG and MockUSDG move the exact amount.

<!--/F-->

<!--F key=advancepool|onmilestonesettled|intra-settlement-nav-window kind=LEAD agents=1-->

[Lead] **Cash moves before the callback, so totalAssets is briefly too high**

`AdvancePool.onMilestoneSettled` · Code smells: _payOut pushes the cash, then calls _notifyHolder last · A token with a transfer hook can redeem shares inside the gap at the higher totalAssets. What remains unverified: no hook exists on the deployed token.

<!--/F-->

<!--F key=advancepool|deposit|erc4626-paths-not-guarded kind=LEAD agents=1-->

[Lead] **Only advance arms the reentrancy guard**

`AdvancePool.deposit` · Code smells: deposit, mint, withdraw and redeem keep the unguarded OpenZeppelin bodies, and the asset is an operator choice via USDG_ADDRESS · A hook-enabled asset re-enters redeem while totalAssets still counts the outgoing cash. What remains unverified: USDG has no hook.

<!--/F-->

<!--F key=advancepool|advance|cap-checks-absent-from-quote kind=LEAD agents=2-->

[Lead] **quote prices invoices that advance will reject**

`AdvancePool.advance` · Code smells: both pool caps live only in advance, and advance never compares the payout against the idle cash it holds · A caller acting on a quote can hit UtilizationCapExceeded, ConcentrationCapExceeded or a SafeERC20 shortfall. What remains unverified: no path where this moves tokens.

<!--/F-->

<!--F key=advancepool|advance|split-record-read kind=LEAD agents=1-->

[Lead] **advance prices one copy of the invoice and books exposure against a second read**

`AdvancePool.advance` · Code smells: quote(id) reads the invoice, then getInvoice(id).seller is read again · Safe only because escrow is immutable and stores the record privately. What remains unverified: no live desynchronisation path.

<!--/F-->

<!--F key=demo|_checkbalances|mock-cast-on-real-token kind=LEAD agents=1-->

[Lead] **The demo casts the deployment token to MockUSDG**

`Demo._checkBalances` · Code smells: DEPLOY_MOCK_USDG and MOCK_MINT are independent env vars, so MOCK_MINT against a real USDG deployment reverts with no reason · The operator sees a bare transaction failure. What remains unverified: a run with the two env vars disagreeing.

<!--/F-->

<!--F key=demo|_load|unvalidated-deployment-json kind=LEAD agents=2-->

[Lead] **The demo trusts deployments/<chainid>.json without checking code**

`Demo._load` · Code smells: pool and escrow are parsed and cast, with no code-length or pool.escrow() check, then the demo broadcasts approvals to them · A stale file points the buyer's approval at a contract the demo does not control. What remains unverified: no path that writes a wrong address.

<!--/F-->

<!--F key=demo|run|no-postcondition-assertion kind=LEAD agents=1-->

[Lead] **The demo checks no final balance**

`Demo.run` · Code smells: the script ends with four log lines and asserts nothing · A run where the pool paid for a receivable the escrow never delivers still prints success. What remains unverified: nothing further; the check simply does not exist.

<!--/F-->

<!--F key=invoiceescrow|_payout|live-fee-recipient kind=LEAD agents=3-->

[Lead] **Fee rate snapshotted, recipient live**

`InvoiceEscrow._payOut` · Code smells: inv.feeBps is frozen at creation, feeRecipient is read at settlement · Of the 801 bps the quote promises, the pool realised 701 on a clean settle; the missing 100 bps is face times feeBps, withheld from the payee and retired on gross face. What remains unverified: whether a non-zero fee is ever set in production.

<!--/F-->

<!--F key=invoiceescrow|_recordreputation|asymmetric-counter-updates kind=LEAD agents=2-->

[Lead] **A default records no counter for the buyer**

`InvoiceEscrow._recordReputation` · Code smells: the Defaulted branch increments the seller only, so a buyer that reclaims every invoice keeps reputation (0,0,0) forever and stays on the newcomer premium · Measured: buyer premium stays 300 bps after six defaults while the seller's crosses the cliff at three. What remains unverified: whether the buyer side of the premium is material at pool scale.

<!--/F-->