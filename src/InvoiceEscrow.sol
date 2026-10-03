// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Implemented by contracts (e.g. the AdvancePool) that hold invoice NFTs
///         and need to be told when a milestone they are entitled to settles.
interface IReceivableHolder {
    function onMilestoneSettled(uint256 invoiceId, uint256 faceAmount, uint256 paidToHolder) external;
}

/// @title InvoiceEscrow
/// @notice Milestone-based stablecoin (USDG) escrow where every invoice is an ERC-721.
///         The NFT owner is the *payee*; the original `seller` is the *performer*.
///         Selling the NFT therefore sells the right to be paid, which is what makes
///         instant advances (see AdvancePool) possible without changing the escrow rules.
///
/// Lifecycle of a milestone:
///   Pending --submit(seller)--> Submitted --approve(buyer)------------> Settled (pay payee)
///                                   |--- autoRelease(anyone, +7d) ----> Settled (pay payee)
///                                   '--- dispute(buyer, <7d) --> Disputed --resolve(arbiter)--> Settled (split)
///                                                                     '--- resolveExpired(+14d) -> Settled (50/50)
///   Pending --reclaimUnsubmitted(buyer, after deadline + grace)------> Settled (refund buyer)
contract InvoiceEscrow is ERC721, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ types

    enum InvoiceStatus { None, Created, Funded, Closed, Cancelled }
    enum MilestoneStatus { Pending, Submitted, Disputed, Settled }
    enum Outcome { Clean, Disputed, Defaulted, AutoReleased }

    struct Milestone {
        uint128 amount;
        uint40 deadline;
        uint40 submittedAt;
        uint40 disputedAt;
        uint40 settledAt;
        MilestoneStatus status;
    }

    struct Invoice {
        address seller;      // performer: submits milestones
        address buyer;       // payer: funds, approves, disputes
        address arbiter;     // resolves disputes
        InvoiceStatus status;
        uint16 feeBps;       // protocol fee snapshot taken at creation
        uint8 openMilestones;
        uint8 openDisputes;
        uint128 total;
        uint128 remaining;   // sum of unsettled milestone amounts
        bytes32 docHash;     // hash of the off-chain invoice document
    }

    /// @dev Counts of settled milestones per address; feeds the pool's risk pricing.
    struct Reputation {
        uint32 clean;
        uint32 disputed;
        uint32 defaulted;
    }

    // -------------------------------------------------------------- constants

    uint256 public constant REVIEW_PERIOD = 7 days;     // buyer window to approve/dispute
    uint256 public constant ARBITER_TIMEOUT = 14 days;  // after this anyone can force a 50/50 split
    uint256 public constant DELIVERY_GRACE = 3 days;    // buffer after a deadline before a refund
    uint256 public constant MAX_MILESTONES = 12;
    uint16 public constant MAX_FEE_BPS = 100;           // protocol fee hard cap: 1%
    uint256 private constant BPS = 10_000;
    uint256 private constant HOLDER_CALLBACK_GAS = 300_000;

    // ---------------------------------------------------------------- storage

    IERC20 public immutable token;
    uint256 public nextInvoiceId = 1;
    uint16 public feeBps;
    address public feeRecipient;

    mapping(uint256 => Invoice) private _invoices;
    mapping(uint256 => Milestone[]) private _milestones;
    mapping(address => Reputation) public reputation;
    /// @notice Payouts whose token transfer failed (e.g. recipient blocklisted by the issuer).
    mapping(address => uint256) public claimable;

    // ----------------------------------------------------------------- events

    event InvoiceCreated(uint256 indexed id, address indexed seller, address indexed buyer, address arbiter, uint256 total, bytes32 docHash);
    event InvoiceCancelled(uint256 indexed id);
    event InvoiceFunded(uint256 indexed id, uint256 total);
    event MilestoneSubmitted(uint256 indexed id, uint256 indexed index);
    event MilestoneDisputed(uint256 indexed id, uint256 indexed index);
    event MilestoneSettled(uint256 indexed id, uint256 indexed index, Outcome outcome, address payee, uint256 toPayee, uint256 fee, uint256 toBuyer);
    event PayoutDeferred(address indexed to, uint256 amount);
    event Claimed(address indexed account, address indexed to, uint256 amount);
    event FeeUpdated(uint16 feeBps, address feeRecipient);

    // ----------------------------------------------------------------- errors

    error InvalidMilestones();
    error InvalidParties();
    error InvalidFee();
    error BadInvoiceStatus();
    error BadMilestoneStatus();
    error NotSeller();
    error NotBuyer();
    error NotArbiter();
    error UnknownMilestone();
    error PreviousNotSettled();
    error TooEarly();
    error TooLate();
    error AmountTooLarge();
    error TransferMismatch();
    error NothingToClaim();

    // ------------------------------------------------------------ constructor

    constructor(IERC20 token_, address owner_, address feeRecipient_, uint16 feeBps_)
        ERC721("Invoice Receivable", "INVR")
        Ownable(owner_)
    {
        token = token_;
        _setFee(feeBps_, feeRecipient_);
    }

    // ------------------------------------------------------------- seller API

    /// @notice Create an invoice. The caller becomes the seller and receives the receivable NFT.
    /// @param amounts   milestone amounts in token units (sum is what the buyer must fund)
    /// @param deadlines strictly increasing delivery deadlines (unix seconds), first one in the future
    function createInvoice(
        address buyer,
        address arbiter,
        uint128[] calldata amounts,
        uint40[] calldata deadlines,
        bytes32 docHash
    ) external whenNotPaused returns (uint256 id) {
        uint256 n = amounts.length;
        if (n == 0 || n > MAX_MILESTONES || n != deadlines.length) revert InvalidMilestones();
        if (
            buyer == address(0) || arbiter == address(0) || buyer == msg.sender || arbiter == msg.sender
                || arbiter == buyer
        ) revert InvalidParties();

        id = nextInvoiceId++;

        uint128 total;
        uint40 previous = uint40(block.timestamp);
        for (uint256 i; i < n; ++i) {
            if (amounts[i] == 0 || deadlines[i] <= previous) revert InvalidMilestones();
            previous = deadlines[i];
            total += amounts[i];
            _milestones[id].push(
                Milestone({
                    amount: amounts[i],
                    deadline: deadlines[i],
                    submittedAt: 0,
                    disputedAt: 0,
                    settledAt: 0,
                    status: MilestoneStatus.Pending
                })
            );
        }

        _invoices[id] = Invoice({
            seller: msg.sender,
            buyer: buyer,
            arbiter: arbiter,
            status: InvoiceStatus.Created,
            feeBps: feeBps,
            openMilestones: uint8(n),
            openDisputes: 0,
            total: total,
            remaining: total,
            docHash: docHash
        });

        _mint(msg.sender, id);
        emit InvoiceCreated(id, msg.sender, buyer, arbiter, total, docHash);
    }

    /// @notice Cancel an invoice the buyer has not funded yet.
    function cancelInvoice(uint256 id) external {
        Invoice storage inv = _invoices[id];
        if (msg.sender != inv.seller) revert NotSeller();
        if (inv.status != InvoiceStatus.Created) revert BadInvoiceStatus();
        inv.status = InvoiceStatus.Cancelled;
        emit InvoiceCancelled(id);
    }

    /// @notice Seller marks a milestone as delivered, starting the buyer's review window.
    /// @dev Refused once the delivery grace has passed: a late submission would otherwise close the
    ///      buyer's `reclaimUnsubmitted` path and hand a non-delivery to the arbiter instead of the buyer.
    function submitMilestone(uint256 id, uint256 index) external {
        Invoice storage inv = _fundedInvoice(id);
        if (msg.sender != inv.seller) revert NotSeller();
        Milestone storage m = _milestone(id, index);
        if (m.status != MilestoneStatus.Pending) revert BadMilestoneStatus();
        if (block.timestamp > uint256(m.deadline) + DELIVERY_GRACE) revert TooLate();
        if (index > 0 && _milestones[id][index - 1].status != MilestoneStatus.Settled) revert PreviousNotSettled();

        m.status = MilestoneStatus.Submitted;
        m.submittedAt = uint40(block.timestamp);
        emit MilestoneSubmitted(id, index);
    }

    // -------------------------------------------------------------- buyer API

    /// @notice Buyer locks the full invoice amount in escrow.
    function fund(uint256 id) external nonReentrant whenNotPaused {
        Invoice storage inv = _invoices[id];
        if (inv.status != InvoiceStatus.Created) revert BadInvoiceStatus();
        if (msg.sender != inv.buyer) revert NotBuyer();
        if (_milestones[id][0].deadline <= block.timestamp) revert TooLate();

        inv.status = InvoiceStatus.Funded;

        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), inv.total);
        if (token.balanceOf(address(this)) - balanceBefore != inv.total) revert TransferMismatch();

        emit InvoiceFunded(id, inv.total);
    }

    /// @notice Buyer accepts a delivered milestone; funds go to the current NFT owner.
    function approveMilestone(uint256 id, uint256 index) external nonReentrant {
        Invoice storage inv = _fundedInvoice(id);
        if (msg.sender != inv.buyer) revert NotBuyer();
        Milestone storage m = _milestone(id, index);
        if (m.status != MilestoneStatus.Submitted) revert BadMilestoneStatus();
        _settle(id, index, m.amount, 0, Outcome.Clean);
    }

    /// @notice Buyer contests a delivered milestone within the review window.
    function disputeMilestone(uint256 id, uint256 index) external {
        Invoice storage inv = _fundedInvoice(id);
        if (msg.sender != inv.buyer) revert NotBuyer();
        Milestone storage m = _milestone(id, index);
        if (m.status != MilestoneStatus.Submitted) revert BadMilestoneStatus();
        if (block.timestamp >= uint256(m.submittedAt) + REVIEW_PERIOD) revert TooLate();

        m.status = MilestoneStatus.Disputed;
        m.disputedAt = uint40(block.timestamp);
        inv.openDisputes += 1;
        emit MilestoneDisputed(id, index);
    }

    /// @notice Buyer recovers a milestone the seller never delivered, once the deadline
    ///         (or the moment the previous milestone settled, whichever is later) plus grace has passed.
    /// @dev Callable by anyone: the refund always goes to the buyer, so an incapable or silent buyer can
    ///      never lock the seller's receivable or a pool's deployed capital open forever.
    function reclaimUnsubmitted(uint256 id, uint256 index) external nonReentrant {
        Invoice storage inv = _fundedInvoice(id);
        Milestone storage m = _milestone(id, index);
        if (m.status != MilestoneStatus.Pending) revert BadMilestoneStatus();

        uint256 clockStart = m.deadline;
        if (index > 0) {
            Milestone storage prev = _milestones[id][index - 1];
            if (prev.status != MilestoneStatus.Settled) revert PreviousNotSettled();
            // Only restart the clock if the previous milestone was actually delivered (so the seller could not
            // start this one earlier). If it was itself refunded for non-delivery, no extra time is owed.
            if (prev.submittedAt != 0 && prev.settledAt > clockStart) clockStart = prev.settledAt;
        }
        if (block.timestamp <= clockStart + DELIVERY_GRACE) revert TooEarly();

        _settle(id, index, 0, m.amount, Outcome.Defaulted);
    }

    // ------------------------------------------------------- permissionless API

    /// @notice If the buyer stays silent past the review window, anyone can release payment.
    function autoRelease(uint256 id, uint256 index) external nonReentrant {
        _fundedInvoice(id);
        Milestone storage m = _milestone(id, index);
        if (m.status != MilestoneStatus.Submitted) revert BadMilestoneStatus();
        if (block.timestamp < uint256(m.submittedAt) + REVIEW_PERIOD) revert TooEarly();
        _settle(id, index, m.amount, 0, Outcome.AutoReleased);
    }

    /// @notice If the arbiter never rules, anyone can force an even split after ARBITER_TIMEOUT.
    function resolveExpiredDispute(uint256 id, uint256 index) external nonReentrant {
        Invoice storage inv = _fundedInvoice(id);
        Milestone storage m = _milestone(id, index);
        if (m.status != MilestoneStatus.Disputed) revert BadMilestoneStatus();
        if (block.timestamp < uint256(m.disputedAt) + ARBITER_TIMEOUT) revert TooEarly();

        inv.openDisputes -= 1;
        uint256 toBuyer = m.amount / 2;
        _settle(id, index, m.amount - toBuyer, toBuyer, Outcome.Disputed);
    }

    // ------------------------------------------------------------ arbiter API

    /// @notice Arbiter splits a disputed milestone. `sellerAmount` goes to the payee, the rest back to the buyer.
    function resolveDispute(uint256 id, uint256 index, uint256 sellerAmount) external nonReentrant {
        Invoice storage inv = _fundedInvoice(id);
        if (msg.sender != inv.arbiter) revert NotArbiter();
        Milestone storage m = _milestone(id, index);
        if (m.status != MilestoneStatus.Disputed) revert BadMilestoneStatus();
        if (sellerAmount > m.amount) revert AmountTooLarge();

        inv.openDisputes -= 1;
        _settle(id, index, sellerAmount, m.amount - sellerAmount, Outcome.Disputed);
    }

    // ---------------------------------------------------------------- payouts

    /// @notice Pull funds whose push-payment failed earlier; `to` lets a blocklisted
    ///         address redirect its balance to a clean one.
    function claim(address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert NothingToClaim();
        amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        token.safeTransfer(to, amount);
        emit Claimed(msg.sender, to, amount);
    }

    // ------------------------------------------------------------------ admin

    function setFee(uint16 feeBps_, address feeRecipient_) external onlyOwner {
        _setFee(feeBps_, feeRecipient_);
    }

    /// @dev Pausing only blocks new invoices and new funding. Settlement and refunds are never paused.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ------------------------------------------------------------------ views

    function getInvoice(uint256 id) external view returns (Invoice memory) {
        return _invoices[id];
    }

    function getMilestones(uint256 id) external view returns (Milestone[] memory) {
        return _milestones[id];
    }

    function lastDeadline(uint256 id) external view returns (uint256) {
        Milestone[] storage ms = _milestones[id];
        return ms.length == 0 ? 0 : ms[ms.length - 1].deadline;
    }

    // --------------------------------------------------------------- internals

    function _setFee(uint16 feeBps_, address feeRecipient_) private {
        // The recipient is never the zero address: an invoice snapshots the rate, so clearing the live
        // recipient while old invoices still carry a rate would strand those fees in claimable[0].
        if (feeRecipient_ == address(0)) revert InvalidFee();
        if (feeBps_ > MAX_FEE_BPS) revert InvalidFee();
        feeBps = feeBps_;
        feeRecipient = feeRecipient_;
        emit FeeUpdated(feeBps_, feeRecipient_);
    }

    function _fundedInvoice(uint256 id) private view returns (Invoice storage inv) {
        inv = _invoices[id];
        if (inv.status != InvoiceStatus.Funded) revert BadInvoiceStatus();
    }

    function _milestone(uint256 id, uint256 index) private view returns (Milestone storage) {
        if (index >= _milestones[id].length) revert UnknownMilestone();
        return _milestones[id][index];
    }

    /// @dev Checks-effects-interactions: all state is final before any token transfer or callback.
    function _settle(uint256 id, uint256 index, uint256 toPayee, uint256 toBuyer, Outcome outcome) private {
        uint128 amount = _finalize(id, index, outcome);
        _payOut(id, index, amount, toPayee, toBuyer, outcome);
    }

    /// @dev Effects only: mark the milestone settled and update invoice + reputation state.
    function _finalize(uint256 id, uint256 index, Outcome outcome) private returns (uint128 amount) {
        Invoice storage inv = _invoices[id];
        Milestone storage m = _milestones[id][index];
        amount = m.amount;

        m.status = MilestoneStatus.Settled;
        m.settledAt = uint40(block.timestamp);
        inv.remaining -= amount;
        inv.openMilestones -= 1;
        if (inv.openMilestones == 0) inv.status = InvoiceStatus.Closed;

        _recordReputation(inv.seller, inv.buyer, outcome);
    }

    /// @dev Interactions only: pay payee / fee recipient / buyer, then notify a contract payee.
    function _payOut(uint256 id, uint256 index, uint128 amount, uint256 toPayee, uint256 toBuyer, Outcome outcome)
        private
    {
        Invoice storage inv = _invoices[id];
        address payee = _ownerOf(id);
        uint256 fee = (toPayee * inv.feeBps) / BPS;

        uint256 before = claimable[payee];
        uint256 paid = _push(payee, toPayee - fee);
        uint256 deferred = claimable[payee] - before;
        _push(feeRecipient, fee);
        _push(inv.buyer, toBuyer);

        emit MilestoneSettled(id, index, outcome, payee, toPayee - fee, fee, toBuyer);
        // The holder is credited with what it now owns: tokens delivered plus anything parked in
        // `claimable` for it. Counting a deferred payout as zero would make the pool write off a
        // receivable whose cash it can still claim.
        _notifyHolder(payee, id, amount, paid + deferred);
    }

    function _recordReputation(address seller, address buyer, Outcome outcome) private {
        if (outcome == Outcome.Clean) {
            reputation[seller].clean += 1;
            reputation[buyer].clean += 1;
        } else if (outcome == Outcome.AutoReleased) {
            // The buyer took no action, so the clean mark belongs to the seller only. Otherwise a pair
            // can clear both newcomer premiums with three idle invoices.
            reputation[seller].clean += 1;
        } else if (outcome == Outcome.Disputed) {
            reputation[seller].disputed += 1;
            reputation[buyer].disputed += 1;
        } else {
            // Both sides are recorded: the buyer who takes every refund back is priced like a virgin
            // otherwise, because `defaulted` is only written on the seller today.
            reputation[seller].defaulted += 1;
            reputation[buyer].defaulted += 1;
        }
    }

    /// @dev Never reverts. A failed transfer (e.g. blocklisted recipient) is parked in `claimable`
    ///      so one bad address cannot freeze settlement for the counterparty or a pool. Two shapes are
    ///      treated as "not delivered" and parked rather than trusted: a call to the escrow itself, which
    ///      would leave the payout in this contract with no path out, and a return word that is neither
    ///      empty nor exactly 1, which a non-canonical token can use to freeze settlement entirely.
    function _push(address to, uint256 amount) private returns (uint256 paid) {
        if (amount == 0 || to == address(this)) {
            if (amount != 0) {
                claimable[to] += amount;
                emit PayoutDeferred(to, amount);
            }
            return 0;
        }
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok) {
            if (ret.length == 0) return amount;
            if (ret.length >= 32 && _isTrue(ret)) return amount;
        }
        claimable[to] += amount;
        emit PayoutDeferred(to, amount);
        return 0;
    }

    /// @dev Reads the return word as a uint256, so a value that is neither 0 nor 1 cannot revert here.
    function _isTrue(bytes memory ret) private pure returns (bool) {
        uint256 word;
        // forge-lint: disable-next-line(unsafe-typecast)
        assembly {
            word := mload(add(ret, 0x20))
        }
        return word == 1;
    }

    /// @dev Best-effort, gas-capped notification so a holder contract can update its books atomically.
    ///      A reverting or gas-guzzling holder cannot block settlement.
    function _notifyHolder(address holder, uint256 id, uint256 faceAmount, uint256 paid) private {
        if (holder.code.length == 0) return;
        try IReceivableHolder(holder).onMilestoneSettled{gas: HOLDER_CALLBACK_GAS}(id, faceAmount, paid) {} catch {}
    }
}
