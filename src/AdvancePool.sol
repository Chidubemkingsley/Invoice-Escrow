// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {InvoiceEscrow, IReceivableHolder} from "./InvoiceEscrow.sol";

/// @title AdvancePool
/// @notice ERC-4626 vault that buys funded invoice receivables (InvoiceEscrow NFTs) at a discount,
///         paying the seller instantly. LPs earn the discount when the escrow later pays the pool.
///
/// Why this is safer than ordinary factoring: the buyer's USDG is already locked in the escrow
/// when the pool buys, so the pool does not carry buyer credit risk. It carries *performance* and
/// *dispute* risk, which it prices from on-chain history (InvoiceEscrow.reputation) plus the time
/// until the final release. Pools also gate exposure: approved arbiters, per-seller credit limits,
/// a utilisation cap (so LPs can exit) and a per-invoice concentration cap.
contract AdvancePool is ERC4626, Ownable2Step, Pausable, ReentrancyGuard, IReceivableHolder {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    struct Params {
        uint16 baseAprBps;           // annualised cost of capital charged for the time to release
        uint16 minDiscountBps;       // floor so LPs are always paid something
        uint16 maxDiscountBps;       // above this the invoice is rejected as too risky
        uint16 newcomerPremiumBps;   // flat premium for an address with too little history
        uint16 riskSlopeBps;         // premium per unit of "bad outcome" ratio (10_000 = 1:1)
        uint16 utilizationCapBps;    // max share of pool assets deployed in advances
        uint16 concentrationCapBps;  // max share of pool assets in a single advance
        uint8 minHistory;            // settled milestones needed to leave "newcomer" pricing
        uint32 maxTenor;             // max seconds from now until the final release
    }

    struct Advance {
        address seller;
        uint128 cost;          // what the pool paid
        uint128 face;          // unsettled face value bought
        uint128 costReleased;  // portion of `cost` already retired
        uint128 faceSettled;   // portion of `face` already settled
    }

    struct Quote {
        uint256 face;
        uint256 discountBps;
        uint256 advance;
    }

    InvoiceEscrow public immutable escrow;
    Params public params;

    /// @dev Carrying value (at cost) of unsettled advances. totalAssets = idle cash + deferred escrow payouts + deployed.
    uint256 public deployed;
    /// @dev Unsettled face value the pool has bought. Caps are measured against this, not against cost,
    ///      because the escrow owes the pool face while the pool only ever paid cost.
    uint256 public outstandingFace;
    mapping(uint256 => Advance) public advances;
    mapping(address => bool) public approvedArbiter;
    mapping(address => uint256) public sellerCreditLimit;
    mapping(address => uint256) public sellerExposure;

    event Advanced(uint256 indexed invoiceId, address indexed seller, address indexed recipient, uint256 face, uint256 advance, uint256 discountBps);
    event AdvanceSettled(uint256 indexed invoiceId, uint256 face, uint256 costRetired, uint256 received);
    event ParamsUpdated(Params params);
    event ArbiterApproved(address indexed arbiter, bool approved);
    event SellerLimitSet(address indexed seller, uint256 limit);

    error NotReceivableOwner();
    error NotFunded();
    error OpenDispute();
    error ArbiterNotApproved();
    error TenorTooLong();
    error Delinquent();
    error RiskTooHigh(uint256 discountBps);
    error SellerLimitExceeded();
    error UtilizationCapExceeded();
    error ConcentrationCapExceeded();
    error Slippage();
    error ZeroAdvance();
    error AlreadyFinanced();
    error OnlyEscrow();
    error InvalidParams();
    error AssetMismatch();

    constructor(IERC20 asset_, InvoiceEscrow escrow_, address owner_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
        Ownable(owner_)
    {
        if (address(escrow_.token()) != address(asset_)) revert AssetMismatch();
        escrow = escrow_;
        _setParams(
            Params({
                baseAprBps: 1000,
                minDiscountBps: 50,
                maxDiscountBps: 2000,
                newcomerPremiumBps: 300,
                riskSlopeBps: 10_000,
                utilizationCapBps: 8000,
                concentrationCapBps: 2000,
                minHistory: 3,
                maxTenor: 180 days
            })
        );
    }

    // ------------------------------------------------------------ seller API

    /// @notice Sell an invoice receivable to the pool for an instant payout.
    ///         The caller must own the NFT and have approved this pool for it.
    /// @param minAdvance slippage guard: revert if the live price pays less than this
    function advance(uint256 id, uint256 minAdvance) external nonReentrant whenNotPaused returns (uint256 amount) {
        if (escrow.ownerOf(id) != msg.sender) revert NotReceivableOwner();
        if (advances[id].cost != 0) revert AlreadyFinanced();

        Quote memory q = quote(id);
        amount = q.advance;
        if (amount == 0) revert ZeroAdvance();
        if (amount < minAdvance) revert Slippage();

        // Caps are measured on the face the escrow still owes the pool, not on the cost it paid,
        // so the utilisation bound is a real bound on how much receivable the vault carries.
        uint256 assets = totalAssets();
        if ((outstandingFace + q.face) * BPS > assets * params.utilizationCapBps) revert UtilizationCapExceeded();
        if (amount * BPS > assets * params.concentrationCapBps) revert ConcentrationCapExceeded();

        address seller = escrow.getInvoice(id).seller;
        // casts are safe: advance <= face = invoice.remaining, which is a uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        advances[id] = Advance({
            seller: seller,
            cost: uint128(amount),
            face: uint128(q.face),
            costReleased: 0,
            faceSettled: 0
        });
        deployed += amount;
        outstandingFace += q.face;
        sellerExposure[seller] += amount;

        escrow.transferFrom(msg.sender, address(this), id);
        IERC20(asset()).safeTransfer(msg.sender, amount);

        emit Advanced(id, seller, msg.sender, q.face, amount, q.discountBps);
    }

    // --------------------------------------------------------------- pricing

    /// @notice Live price for an invoice. Reverts with a reason if the pool would not buy it.
    ///         discount = escrow fee + APR * time-to-release + seller premium + buyer premium
    function quote(uint256 id) public view returns (Quote memory q) {
        InvoiceEscrow.Invoice memory inv = escrow.getInvoice(id);
        if (inv.status != InvoiceEscrow.InvoiceStatus.Funded) revert NotFunded();
        if (inv.openDisputes != 0) revert OpenDispute();
        if (!approvedArbiter[inv.arbiter]) revert ArbiterNotApproved();

        Params memory p = params;
        InvoiceEscrow.Milestone[] memory ms = escrow.getMilestones(id);

        // A milestone the seller can no longer submit (past deadline + grace) is one the buyer can
        // reclaim for a full refund, so the pool must refuse the invoice instead of pricing it.
        for (uint256 i; i < ms.length; ++i) {
            if (ms[i].status == InvoiceEscrow.MilestoneStatus.Pending
                && uint256(ms[i].deadline) + escrow.DELIVERY_GRACE() <= block.timestamp) revert Delinquent();
        }

        // Tenor is priced for the latest possible release: every milestone needs its own review
        // window, because milestones settle in sequence and each can be submitted late.
        uint256 releaseAt = escrow.lastDeadline(id) + escrow.REVIEW_PERIOD();
        uint256 tenor = releaseAt > block.timestamp ? releaseAt - block.timestamp : 0;
        tenor += uint256(ms.length) * (escrow.REVIEW_PERIOD() + escrow.DELIVERY_GRACE());
        if (tenor > p.maxTenor) revert TenorTooLong();

        uint256 discount = uint256(inv.feeBps) + (uint256(p.baseAprBps) * tenor) / 365 days
            + _premium(inv.seller, p) + _premium(inv.buyer, p);
        if (discount < p.minDiscountBps) discount = p.minDiscountBps;
        if (discount > p.maxDiscountBps) revert RiskTooHigh(discount);

        q.face = inv.remaining;
        q.discountBps = discount;
        q.advance = (q.face * (BPS - discount)) / BPS;

        if (sellerExposure[inv.seller] + q.advance > sellerCreditLimit[inv.seller]) revert SellerLimitExceeded();
    }

    /// @dev Risk premium for one counterparty from their settled-milestone history.
    ///      Defaults weigh 3x disputes. Any recorded bad outcome is priced immediately, so a seller
    ///      with two defaults never pays the newcomer rate; a counterparty with no history at all pays it.
    function _premium(address account, Params memory p) internal view returns (uint256) {
        (uint32 clean, uint32 disputed, uint32 defaulted) = escrow.reputation(account);
        uint256 events = uint256(clean) + disputed + defaulted;
        if (disputed == 0 && defaulted == 0) return events < p.minHistory ? p.newcomerPremiumBps : 0;
        if (events == 0) return p.newcomerPremiumBps;
        uint256 badBps = ((uint256(disputed) + 3 * uint256(defaulted)) * BPS) / events;
        return Math.max((badBps * p.riskSlopeBps) / BPS, p.newcomerPremiumBps);
    }

    // ----------------------------------------------- escrow callback / upkeep

    /// @inheritdoc IReceivableHolder
    /// @dev Retires cost against the cash the escrow actually delivered, never against gross face.
    ///      A split settlement, a zero-award ruling or a refund therefore retires only what was
    ///      received, and the shortfall stays in `deployed` and in the seller's exposure, so bad debt
    ///      cannot reset a credit limit. Gains and losses are recognised in the settlement transaction,
    ///      so the share price never double-counts. Deliberately not pausable or nonReentrant: escrow
    ///      settlement must always be able to land.
    function onMilestoneSettled(uint256 invoiceId, uint256 faceAmount, uint256 paidToHolder) external {
        if (msg.sender != address(escrow)) revert OnlyEscrow();
        Advance storage a = advances[invoiceId];
        if (a.cost == 0) return; // NFT held without an advance (e.g. sent in): nothing to account for

        // safe: faceAmount is a uint128 milestone amount supplied by the escrow
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 unsettled = a.face > a.faceSettled ? a.face - a.faceSettled : 0;
        uint128 faceChunk = uint128(Math.min(faceAmount, unsettled));
        a.faceSettled += faceChunk;
        outstandingFace -= faceChunk;

        // Cost retires against what the escrow delivered. A settlement that pays nothing (a refund to the
        // buyer) retires the full proportional slice, because that receivable is now worth nothing and the
        // loss belongs in the share price. A partial payment retires only the slice it paid for.
        uint128 retire = a.cost - a.costReleased;
        if (paidToHolder > 0 && a.faceSettled < a.face) {
            retire = uint128(Math.min((uint256(a.cost) * paidToHolder) / a.face, a.cost - a.costReleased));
        } else if (paidToHolder > 0) {
            retire = a.cost - a.costReleased;
        }

        a.costReleased += retire;
        deployed -= retire;
        // The seller only gets credit for cash that actually arrived. A defaulted advance keeps its limit
        // consumed, so the same seller cannot take the same limit again after walking away.
        uint256 credit = Math.min(paidToHolder, sellerExposure[a.seller]);
        sellerExposure[a.seller] -= credit;

        emit AdvanceSettled(invoiceId, faceAmount, retire, paidToHolder);
    }

    /// @notice Pull any escrow payouts that were deferred (e.g. a transient transfer failure) into the pool.
    /// @param to recipient of the swept funds. Defaults to the pool, but an operator can sweep to a
    ///        secondary treasury if the pool's own address is frozen by the token issuer.
    function sweepDeferred(address to) external returns (uint256) {
        if (escrow.claimable(address(this)) == 0) return 0;
        return escrow.claim(to == address(0) ? address(this) : to);
    }

    // ----------------------------------------------------------------- admin

    function setParams(Params calldata p) external onlyOwner {
        _setParams(p);
    }

    function setApprovedArbiter(address arbiter, bool approved) external onlyOwner {
        approvedArbiter[arbiter] = approved;
        emit ArbiterApproved(arbiter, approved);
    }

    /// @notice Credit committee decision: max unsettled advance cost this seller may have outstanding.
    function setSellerCreditLimit(address seller, uint256 limit) external onlyOwner {
        sellerCreditLimit[seller] = limit;
        emit SellerLimitSet(seller, limit);
    }

    /// @dev Pausing stops new deposits and new advances. Withdrawals and settlement stay open.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _setParams(Params memory p) private {
        if (
            p.minDiscountBps > p.maxDiscountBps || p.maxDiscountBps > 5000 || p.utilizationCapBps > BPS
                || p.concentrationCapBps > BPS || p.riskSlopeBps > 50_000 || p.maxTenor == 0
                || p.minHistory == 0 || p.baseAprBps > 5000 || p.newcomerPremiumBps > 5000
                || p.utilizationCapBps == 0 || p.concentrationCapBps == 0
        ) revert InvalidParams();
        params = p;
        emit ParamsUpdated(p);
    }

    // ------------------------------------------------------ ERC-4626 plumbing

    /// @dev Idle cash, plus escrow payouts already earned but parked as claimable because the issuer
    ///      refused the transfer, plus advances still carried at cost. Deferred payouts are assets of the
    ///      pool, so the share price does not dip between settlement and `sweepDeferred`.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + escrow.claimable(address(this)) + deployed;
    }

    /// @dev Virtual-share offset blunts the classic first-depositor inflation attack.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        return paused() ? 0 : super.maxDeposit(receiver);
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return paused() ? 0 : super.maxMint(receiver);
    }

    /// @dev Idle cash is limited to two bounds: what the vault actually holds, and what keeps the
    ///      carrying value inside the utilisation cap. Without the second bound a liquidity provider can
    ///      withdraw the buffer and every later `advance` reverts until an invoice settles.
    function _idleCap() public view returns (uint256) {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 assets = totalAssets();
        // The utilisation cap is denominated in face, so the reserve must be too.
        uint256 reserved = Math.mulDiv(outstandingFace, BPS, params.utilizationCapBps);
        return assets > reserved ? Math.min(cash, assets - reserved) : 0;
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner_), _idleCap());
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        uint256 idleShares = _convertToShares(_idleCap(), Math.Rounding.Floor);
        return Math.min(super.maxRedeem(owner_), idleShares);
    }
}
