// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {InvoiceEscrow} from "../src/InvoiceEscrow.sol";
import {AdvancePool} from "../src/AdvancePool.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";

abstract contract Base is Test {
    uint256 constant U = 1e6; // 1 USDG (6 decimals)

    MockUSDG usdg;
    InvoiceEscrow escrow;
    AdvancePool pool;

    address owner = makeAddr("owner");
    address feeTo = makeAddr("feeTo");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address arbiter = makeAddr("arbiter");
    address lp = makeAddr("lp");
    address stranger = makeAddr("stranger");

    function setUp() public virtual {
        usdg = new MockUSDG();
        escrow = new InvoiceEscrow(IERC20(address(usdg)), owner, feeTo, 0);
        pool = new AdvancePool(IERC20(address(usdg)), escrow, owner, "Invoice Advance Pool", "iaUSDG");

        usdg.mint(buyer, 1_000_000 * U);
        usdg.mint(lp, 1_000_000 * U);
        vm.prank(buyer);
        usdg.approve(address(escrow), type(uint256).max);
        vm.prank(lp);
        usdg.approve(address(pool), type(uint256).max);

        vm.startPrank(owner);
        pool.setApprovedArbiter(arbiter, true);
        pool.setSellerCreditLimit(seller, 500_000 * U);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- helpers

    function _amounts(uint256 a, uint256 b) internal pure returns (uint128[] memory r) {
        r = new uint128[](2);
        r[0] = uint128(a);
        r[1] = uint128(b);
    }

    function _deadlines(uint40 d0, uint40 d1) internal pure returns (uint40[] memory r) {
        r = new uint40[](2);
        r[0] = d0;
        r[1] = d1;
    }

    /// 2 milestones: 3_000 + 7_000 USDG, due in 14 and 30 days.
    function _create() internal returns (uint256 id) {
        vm.prank(seller);
        id = escrow.createInvoice(
            buyer,
            arbiter,
            _amounts(uint128(3_000 * U), uint128(7_000 * U)),
            _deadlines(uint40(block.timestamp + 14 days), uint40(block.timestamp + 30 days)),
            keccak256("INV-2026-001")
        );
    }

    function _createFunded() internal returns (uint256 id) {
        id = _create();
        vm.prank(buyer);
        escrow.fund(id);
    }

    function _deliverAndApprove(uint256 id, uint256 index) internal {
        vm.prank(seller);
        escrow.submitMilestone(id, index);
        vm.prank(buyer);
        escrow.approveMilestone(id, index);
    }

    function _seedPool(uint256 amount) internal {
        vm.prank(lp);
        pool.deposit(amount, lp);
    }
}

// =====================================================================================
// Escrow
// =====================================================================================
contract EscrowTest is Base {
    function test_createInvoice_mintsNftToSeller() public {
        uint256 id = _create();
        assertEq(escrow.ownerOf(id), seller);
        InvoiceEscrow.Invoice memory inv = escrow.getInvoice(id);
        assertEq(inv.total, 10_000 * U);
        assertEq(uint8(inv.status), uint8(InvoiceEscrow.InvoiceStatus.Created));
        assertEq(escrow.getMilestones(id).length, 2);
    }

    function test_createInvoice_rejectsBadInput() public {
        uint40 t = uint40(block.timestamp);
        vm.startPrank(seller);
        vm.expectRevert(InvoiceEscrow.InvalidMilestones.selector);
        escrow.createInvoice(buyer, arbiter, new uint128[](0), new uint40[](0), 0);

        vm.expectRevert(InvoiceEscrow.InvalidMilestones.selector); // zero amount
        escrow.createInvoice(buyer, arbiter, _amounts(0, 1), _deadlines(t + 1 days, t + 2 days), 0);

        vm.expectRevert(InvoiceEscrow.InvalidMilestones.selector); // non-increasing deadlines
        escrow.createInvoice(buyer, arbiter, _amounts(1, 1), _deadlines(t + 2 days, t + 2 days), 0);

        vm.expectRevert(InvoiceEscrow.InvalidMilestones.selector); // deadline in the past
        escrow.createInvoice(buyer, arbiter, _amounts(1, 1), _deadlines(t, t + 2 days), 0);

        vm.expectRevert(InvoiceEscrow.InvalidParties.selector); // buyer == seller
        escrow.createInvoice(seller, arbiter, _amounts(1, 1), _deadlines(t + 1 days, t + 2 days), 0);

        vm.expectRevert(InvoiceEscrow.InvalidParties.selector); // arbiter == buyer
        escrow.createInvoice(buyer, buyer, _amounts(1, 1), _deadlines(t + 1 days, t + 2 days), 0);
        vm.stopPrank();
    }

    function test_fund_locksTotal_onlyBuyer() public {
        uint256 id = _create();
        vm.prank(stranger);
        vm.expectRevert(InvoiceEscrow.NotBuyer.selector);
        escrow.fund(id);

        vm.prank(buyer);
        escrow.fund(id);
        assertEq(usdg.balanceOf(address(escrow)), 10_000 * U);

        vm.prank(buyer);
        vm.expectRevert(InvoiceEscrow.BadInvoiceStatus.selector); // cannot fund twice
        escrow.fund(id);
    }

    function test_fund_failsAfterFirstDeadline() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 15 days);
        vm.prank(buyer);
        vm.expectRevert(InvoiceEscrow.TooLate.selector);
        escrow.fund(id);
    }

    function test_cancel_onlyBeforeFunding() public {
        uint256 id = _create();
        vm.prank(stranger);
        vm.expectRevert(InvoiceEscrow.NotSeller.selector);
        escrow.cancelInvoice(id);

        vm.prank(seller);
        escrow.cancelInvoice(id);
        vm.prank(buyer);
        vm.expectRevert(InvoiceEscrow.BadInvoiceStatus.selector);
        escrow.fund(id);

        uint256 id2 = _createFunded();
        vm.prank(seller);
        vm.expectRevert(InvoiceEscrow.BadInvoiceStatus.selector);
        escrow.cancelInvoice(id2);
    }

    function test_happyPath_paysSellerAndCloses() public {
        uint256 id = _createFunded();
        _deliverAndApprove(id, 0);
        assertEq(usdg.balanceOf(seller), 3_000 * U);
        _deliverAndApprove(id, 1);
        assertEq(usdg.balanceOf(seller), 10_000 * U);
        assertEq(usdg.balanceOf(address(escrow)), 0);

        InvoiceEscrow.Invoice memory inv = escrow.getInvoice(id);
        assertEq(uint8(inv.status), uint8(InvoiceEscrow.InvoiceStatus.Closed));
        assertEq(inv.remaining, 0);

        (uint32 clean,,) = escrow.reputation(seller);
        (uint32 buyerClean,,) = escrow.reputation(buyer);
        assertEq(clean, 2);
        assertEq(buyerClean, 2);
    }

    function test_milestones_mustBeSequential() public {
        uint256 id = _createFunded();
        vm.prank(seller);
        vm.expectRevert(InvoiceEscrow.PreviousNotSettled.selector);
        escrow.submitMilestone(id, 1);
    }

    function test_onlySellerSubmits_onlyBuyerApproves() public {
        uint256 id = _createFunded();
        vm.prank(stranger);
        vm.expectRevert(InvoiceEscrow.NotSeller.selector);
        escrow.submitMilestone(id, 0);

        vm.prank(seller);
        escrow.submitMilestone(id, 0);
        vm.prank(seller);
        vm.expectRevert(InvoiceEscrow.NotBuyer.selector);
        escrow.approveMilestone(id, 0);

        vm.prank(seller);
        vm.expectRevert(InvoiceEscrow.UnknownMilestone.selector);
        escrow.submitMilestone(id, 9);
    }

    function test_autoRelease_afterReviewPeriod() public {
        uint256 id = _createFunded();
        vm.prank(seller);
        escrow.submitMilestone(id, 0);

        vm.prank(stranger);
        vm.expectRevert(InvoiceEscrow.TooEarly.selector);
        escrow.autoRelease(id, 0);

        vm.warp(block.timestamp + 7 days);
        vm.prank(stranger);
        escrow.autoRelease(id, 0);
        assertEq(usdg.balanceOf(seller), 3_000 * U);
    }

    function test_dispute_arbiterSplits() public {
        uint256 id = _createFunded();
        vm.prank(seller);
        escrow.submitMilestone(id, 0);
        vm.prank(buyer);
        escrow.disputeMilestone(id, 0);
        assertEq(escrow.getInvoice(id).openDisputes, 1);

        vm.prank(stranger);
        vm.expectRevert(InvoiceEscrow.NotArbiter.selector);
        escrow.resolveDispute(id, 0, 1);

        vm.prank(arbiter);
        vm.expectRevert(InvoiceEscrow.AmountTooLarge.selector);
        escrow.resolveDispute(id, 0, 3_001 * U);

        uint256 buyerBefore = usdg.balanceOf(buyer);
        vm.prank(arbiter);
        escrow.resolveDispute(id, 0, 2_000 * U);
        assertEq(usdg.balanceOf(seller), 2_000 * U);
        assertEq(usdg.balanceOf(buyer) - buyerBefore, 1_000 * U);
        assertEq(escrow.getInvoice(id).openDisputes, 0);

        (, uint32 disputed,) = escrow.reputation(seller);
        assertEq(disputed, 1);
    }

    function test_dispute_cannotBeOpenedAfterReviewWindow() public {
        uint256 id = _createFunded();
        vm.prank(seller);
        escrow.submitMilestone(id, 0);
        vm.warp(block.timestamp + 7 days);
        vm.prank(buyer);
        vm.expectRevert(InvoiceEscrow.TooLate.selector);
        escrow.disputeMilestone(id, 0);
    }

    function test_dispute_expiredArbiterForcesEvenSplit() public {
        uint256 id = _createFunded();
        vm.prank(seller);
        escrow.submitMilestone(id, 0);
        vm.prank(buyer);
        escrow.disputeMilestone(id, 0);

        vm.expectRevert(InvoiceEscrow.TooEarly.selector);
        escrow.resolveExpiredDispute(id, 0);

        uint256 buyerBefore = usdg.balanceOf(buyer);
        vm.warp(block.timestamp + 14 days);
        escrow.resolveExpiredDispute(id, 0);
        assertEq(usdg.balanceOf(seller), 1_500 * U);
        assertEq(usdg.balanceOf(buyer) - buyerBefore, 1_500 * U);
    }

    function test_reclaimUnsubmitted_afterDeadlinePlusGrace() public {
        uint256 id = _createFunded();
        vm.prank(buyer);
        vm.expectRevert(InvoiceEscrow.TooEarly.selector);
        escrow.reclaimUnsubmitted(id, 0);

        vm.warp(block.timestamp + 14 days + 3 days);
        vm.prank(buyer);
        vm.expectRevert(InvoiceEscrow.TooEarly.selector); // boundary: still inside grace
        escrow.reclaimUnsubmitted(id, 0);

        vm.warp(block.timestamp + 1);
        uint256 before = usdg.balanceOf(buyer);
        vm.prank(buyer);
        escrow.reclaimUnsubmitted(id, 0);
        assertEq(usdg.balanceOf(buyer) - before, 3_000 * U);

        (,, uint32 defaulted) = escrow.reputation(seller);
        assertEq(defaulted, 1);
    }

    function test_reclaim_clockStartsWhenPreviousMilestoneSettles() public {
        uint256 id = _createFunded();
        // Milestone 0 (deadline day 14) is delivered on time and settles on day 12.
        vm.warp(block.timestamp + 12 days);
        vm.prank(seller);
        escrow.submitMilestone(id, 0);
        vm.prank(buyer);
        escrow.approveMilestone(id, 0);

        // Milestone 1's deadline is day 30, so its refund clock is max(day 30, day 12) + 3d.
        vm.warp(block.timestamp + 19 days); // day 31: past the deadline, still inside the 3d grace
        vm.prank(buyer);
        vm.expectRevert(InvoiceEscrow.TooEarly.selector);
        escrow.reclaimUnsubmitted(id, 1);
    }

    function test_lateSubmit_isRejected_andBuyerKeepsRefund() public {
        uint256 id = _createFunded();
        uint256 buyerBefore = usdg.balanceOf(buyer);
        vm.warp(block.timestamp + 18 days); // milestone 0 deadline (day 14) + 3d grace + 1s

        // A late submission would close the buyer's refund path, so it is refused outright.
        vm.prank(seller);
        vm.expectRevert(InvoiceEscrow.TooLate.selector);
        escrow.submitMilestone(id, 0);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(buyer);
        escrow.reclaimUnsubmitted(id, 0);
        assertEq(usdg.balanceOf(buyer), buyerBefore + 3_000 * U, "buyer keeps the undelivered milestone");
        assertEq(escrow.getInvoice(id).openMilestones, 1);
    }

    function test_protocolFee_snapshotAtCreation() public {
        vm.prank(owner);
        escrow.setFee(50, feeTo); // 0.5%
        uint256 id = _createFunded();

        vm.prank(owner);
        escrow.setFee(100, feeTo); // later change must not affect existing invoice

        _deliverAndApprove(id, 0);
        assertEq(usdg.balanceOf(feeTo), 15 * U); // 0.5% of 3,000
        assertEq(usdg.balanceOf(seller), 2_985 * U);
    }

    function test_setFee_enforcesCapAndRecipient() public {
        vm.startPrank(owner);
        vm.expectRevert(InvoiceEscrow.InvalidFee.selector);
        escrow.setFee(101, feeTo);
        vm.expectRevert(InvoiceEscrow.InvalidFee.selector);
        escrow.setFee(10, address(0));
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert();
        escrow.setFee(10, feeTo);
    }

    function test_payoutGoesToCurrentNftOwner() public {
        uint256 id = _createFunded();
        address newOwner = makeAddr("factor");
        vm.prank(seller);
        escrow.transferFrom(seller, newOwner, id);

        _deliverAndApprove(id, 0);
        assertEq(usdg.balanceOf(newOwner), 3_000 * U);
        assertEq(usdg.balanceOf(seller), 0);
    }

    function test_blocklistedPayee_doesNotFreezeSettlement_andCanClaimElsewhere() public {
        uint256 id = _createFunded();
        usdg.setBlocked(seller, true);

        uint256 buyerBefore = usdg.balanceOf(buyer);
        _deliverAndApprove(id, 0); // must not revert even though the payout transfer fails
        assertEq(usdg.balanceOf(seller), 0);
        assertEq(escrow.claimable(seller), 3_000 * U);
        assertEq(usdg.balanceOf(buyer), buyerBefore);

        address clean = makeAddr("cleanWallet");
        vm.prank(seller);
        escrow.claim(clean);
        assertEq(usdg.balanceOf(clean), 3_000 * U);
        assertEq(escrow.claimable(seller), 0);

        vm.prank(seller);
        vm.expectRevert(InvoiceEscrow.NothingToClaim.selector);
        escrow.claim(clean);
    }

    function test_pause_blocksNewWorkButNotSettlement() public {
        uint256 id = _createFunded();
        vm.prank(owner);
        escrow.pause();

        vm.prank(seller);
        vm.expectRevert();
        escrow.createInvoice(buyer, arbiter, _amounts(1, 1), _deadlines(uint40(block.timestamp + 1), uint40(block.timestamp + 2)), 0);

        _deliverAndApprove(id, 0); // settlement still works while paused
        assertEq(usdg.balanceOf(seller), 3_000 * U);
    }

    /// Whatever path each milestone takes, total paid out equals total funded and escrow ends empty.
    function testFuzz_fundsConserved(uint128 a, uint128 b, uint8 pathA, uint8 pathB, uint256 split) public {
        a = uint128(bound(a, 1, 100_000 * U));
        b = uint128(bound(b, 1, 100_000 * U));
        // Deadlines far enough out that a submit is never inside the delivery grace of the fuzz warps.
        vm.prank(seller);
        uint256 id = escrow.createInvoice(
            buyer,
            arbiter,
            _amounts(a, b),
            _deadlines(uint40(block.timestamp + 365 days), uint40(block.timestamp + 400 days)),
            0
        );
        vm.prank(buyer);
        escrow.fund(id);
        uint256 total = uint256(a) + b;
        uint256 totalBefore = usdg.balanceOf(seller) + usdg.balanceOf(buyer) + usdg.balanceOf(address(escrow));

        _runPath(id, 0, a, pathA % 3, split);
        _runPath(id, 1, b, pathB % 3, split >> 7);

        assertEq(usdg.balanceOf(address(escrow)), 0, "escrow not drained");
        assertEq(escrow.getInvoice(id).remaining, 0);
        assertEq(usdg.balanceOf(seller) + usdg.balanceOf(buyer) + usdg.balanceOf(address(escrow)), totalBefore);
        assertLe(total, totalBefore);
    }

    function _runPath(uint256 id, uint256 index, uint128 amount, uint8 path, uint256 split) internal {
        if (path == 0) {
            _deliverAndApprove(id, index);
        } else if (path == 1) {
            vm.prank(seller);
            escrow.submitMilestone(id, index);
            vm.prank(buyer);
            escrow.disputeMilestone(id, index);
            vm.prank(arbiter);
            escrow.resolveDispute(id, index, bound(split, 0, amount));
        } else {
            InvoiceEscrow.Milestone[] memory ms = escrow.getMilestones(id);
            vm.warp(uint256(ms[index].deadline) + escrow.DELIVERY_GRACE() + 1);
            vm.prank(buyer);
            escrow.reclaimUnsubmitted(id, index);
        }
    }
}

// =====================================================================================
// Pool
// =====================================================================================
contract PoolTest is Base {
    function setUp() public override {
        super.setUp();
        _seedPool(100_000 * U);
    }

    // -------------------------------------------------------------- LP side

    function test_deposit_withdraw_roundTrip() public {
        assertEq(pool.totalAssets(), 100_000 * U);
        uint256 shares = pool.balanceOf(lp);
        vm.prank(lp);
        pool.redeem(shares, lp, lp);
        assertApproxEqAbs(usdg.balanceOf(lp), 1_000_000 * U, 1);
    }

    function test_pausedPool_blocksDeposits_notWithdrawals() public {
        vm.prank(owner);
        pool.pause();
        assertEq(pool.maxDeposit(lp), 0);

        vm.prank(lp);
        vm.expectRevert();
        pool.deposit(1 * U, lp);

        uint256 shares = pool.balanceOf(lp);
        vm.prank(lp);
        pool.redeem(shares / 2, lp, lp);
    }

    // ---------------------------------------------------------------- pricing

    function test_quote_newcomerPricing() public {
        uint256 id = _createFunded();
        AdvancePool.Quote memory q = pool.quote(id);
        assertEq(q.face, 10_000 * U);

        // fee 0 + 10% APR over the worst-case release: last deadline + review period, plus one
        // review period and one delivery grace per milestone, + 300 + 300 newcomer premiums
        uint256 worstCaseTenor = uint256(37 days) + 2 * (uint256(7 days) + 3 days);
        uint256 expectedTime = (1000 * worstCaseTenor) / 365 days;
        assertEq(q.discountBps, expectedTime + 600);
        assertEq(q.advance, (q.face * (10_000 - q.discountBps)) / 10_000);
        assertLt(q.advance, q.face);
    }

    function test_quote_goodHistoryIsCheaperThanNewcomer() public {
        uint256 newcomerBps = pool.quote(_createFunded()).discountBps;

        // build a clean record for both parties (3 settled milestones each)
        for (uint256 i; i < 2; ++i) {
            uint256 prior = _createFunded();
            _deliverAndApprove(prior, 0);
            _deliverAndApprove(prior, 1);
        }
        uint256 id = _createFunded();
        uint256 trustedBps = pool.quote(id).discountBps;
        assertLt(trustedBps, newcomerBps, "history should reduce price");
    }

    function test_quote_badHistoryIsMoreExpensive_andCanBeRejected() public {
        // seller defaults on enough milestones that its premium blows through the max discount
        for (uint256 i; i < 3; ++i) {
            uint256 prior = _createFunded();
            vm.warp(block.timestamp + 40 days);
            vm.prank(buyer);
            escrow.reclaimUnsubmitted(prior, 0);
            vm.prank(buyer);
            escrow.reclaimUnsubmitted(prior, 1);
        }
        uint256 id = _createFunded();
        vm.expectRevert(); // RiskTooHigh(...)
        pool.quote(id);
    }

    function test_quote_rejectsUnapprovedArbiter_unfunded_andDisputed() public {
        uint256 unfunded = _create();
        vm.expectRevert(AdvancePool.NotFunded.selector);
        pool.quote(unfunded);

        vm.prank(owner);
        pool.setApprovedArbiter(arbiter, false);
        uint256 id = _createFunded();
        vm.expectRevert(AdvancePool.ArbiterNotApproved.selector);
        pool.quote(id);

        vm.prank(owner);
        pool.setApprovedArbiter(arbiter, true);
        vm.prank(seller);
        escrow.submitMilestone(id, 0);
        vm.prank(buyer);
        escrow.disputeMilestone(id, 0);
        vm.expectRevert(AdvancePool.OpenDispute.selector);
        pool.quote(id);
    }

    function test_quote_rejectsTenorTooLong() public {
        vm.prank(seller);
        uint256 id = escrow.createInvoice(
            buyer, arbiter, _amounts(1_000 * U, 1_000 * U), _deadlines(uint40(block.timestamp + 100 days), uint40(block.timestamp + 400 days)), 0
        );
        vm.prank(buyer);
        escrow.fund(id);
        vm.expectRevert(AdvancePool.TenorTooLong.selector);
        pool.quote(id);
    }

    // --------------------------------------------------------------- advancing

    function test_advance_paysSellerAndTakesNft() public {
        uint256 id = _createFunded();
        AdvancePool.Quote memory q = pool.quote(id);

        vm.startPrank(seller);
        escrow.approve(address(pool), id);
        uint256 got = pool.advance(id, q.advance);
        vm.stopPrank();

        assertEq(got, q.advance);
        assertEq(usdg.balanceOf(seller), q.advance);
        assertEq(escrow.ownerOf(id), address(pool));
        assertEq(pool.deployed(), q.advance);
        assertEq(pool.sellerExposure(seller), q.advance);
        assertEq(pool.totalAssets(), 100_000 * U, "buying at cost must not move NAV");
    }

    function test_advance_thenFullSettlement_realisesProfitForLPs() public {
        uint256 id = _createFunded();
        AdvancePool.Quote memory q = pool.quote(id);
        vm.startPrank(seller);
        escrow.approve(address(pool), id);
        pool.advance(id, 0);
        vm.stopPrank();

        uint256 pricePerShareBefore = pool.convertToAssets(1e12);

        _deliverAndApprove(id, 0);
        _deliverAndApprove(id, 1);

        uint256 profit = q.face - q.advance;
        assertEq(pool.deployed(), 0, "cost basis fully retired");
        assertEq(pool.sellerExposure(seller), 0);
        assertEq(pool.totalAssets(), 100_000 * U + profit);
        assertGt(pool.convertToAssets(1e12), pricePerShareBefore, "share price rose");
        assertEq(usdg.balanceOf(address(escrow)), 0);
    }

    function test_advance_partialSettlement_retiresProportionalCost() public {
        uint256 id = _createFunded();
        vm.startPrank(seller);
        escrow.approve(address(pool), id);
        pool.advance(id, 0);
        vm.stopPrank();
        (, uint128 cost, uint128 face,,) = pool.advances(id);

        _deliverAndApprove(id, 0); // 3,000 of 10,000 face
        (,,, uint128 released,) = pool.advances(id);
        assertEq(released, (uint256(cost) * 3_000 * U) / face);
        assertEq(pool.deployed(), cost - released);

        _deliverAndApprove(id, 1);
        assertEq(pool.deployed(), 0);
    }

    function test_advance_sellerDefault_socialisesLossToLPs() public {
        uint256 id = _createFunded();
        vm.startPrank(seller);
        escrow.approve(address(pool), id);
        uint256 got = pool.advance(id, 0);
        vm.stopPrank();

        // Seller walks away with the advance; buyer reclaims both milestones.
        vm.warp(block.timestamp + 40 days);
        vm.startPrank(buyer);
        escrow.reclaimUnsubmitted(id, 0);
        escrow.reclaimUnsubmitted(id, 1);
        vm.stopPrank();

        // A receivable that paid nothing is written off, so the loss lands in the share price — but
        // the seller's credit limit stays consumed, so the same seller cannot drain the pool twice.
        assertEq(pool.deployed(), 0, "unpaid receivable written off");
        assertEq(pool.outstandingFace(), 0, "no unsettled face left on the invoice");
        assertEq(pool.totalAssets(), 100_000 * U - got, "NAV recognised the whole advance as a loss");
        assertLt(pool.convertToAssets(1e18), 1e18, "LPs absorb the loss per share");
        assertEq(pool.sellerExposure(seller), got, "credit limit stays consumed by the bad debt");
        // the loss is also reflected in seller's reputation, making their next advance pricier / blocked
        (,, uint32 defaulted) = escrow.reputation(seller);
        assertEq(defaulted, 2);
    }

    function test_advance_partialDispute_retiresCostAndShowsLoss() public {
        uint256 id = _createFunded();
        vm.startPrank(seller);
        escrow.approve(address(pool), id);
        uint256 got = pool.advance(id, 0);
        vm.stopPrank();

        vm.prank(seller);
        escrow.submitMilestone(id, 0);
        vm.prank(buyer);
        escrow.disputeMilestone(id, 0);
        vm.prank(arbiter);
        escrow.resolveDispute(id, 0, 0); // buyer wins milestone 0 entirely

        _deliverAndApprove(id, 1);
        // Pool received only the 7,000 milestone; it paid `got` for 10,000 face.
        assertEq(pool.totalAssets(), 100_000 * U - got + 7_000 * U);
    }

    function test_advance_guards() public {
        uint256 id = _createFunded();

        vm.prank(stranger);
        vm.expectRevert(AdvancePool.NotReceivableOwner.selector);
        pool.advance(id, 0);

        // not approved for the NFT -> ERC721 revert
        vm.prank(seller);
        vm.expectRevert();
        pool.advance(id, 0);

        // slippage
        vm.startPrank(seller);
        escrow.approve(address(pool), id);
        vm.expectRevert(AdvancePool.Slippage.selector);
        pool.advance(id, 10_000 * U);
        vm.stopPrank();
    }

    function test_advance_sellerCreditLimit() public {
        vm.prank(owner);
        pool.setSellerCreditLimit(seller, 1_000 * U);
        uint256 id = _createFunded();
        vm.expectRevert(AdvancePool.SellerLimitExceeded.selector);
        pool.quote(id);
    }

    function test_advance_utilizationAndConcentrationCaps() public {
        // 20% concentration cap on a 100k pool => 20k max single advance
        vm.prank(seller);
        uint256 big = escrow.createInvoice(
            buyer, arbiter, _amounts(30_000 * U, 30_000 * U), _deadlines(uint40(block.timestamp + 10 days), uint40(block.timestamp + 20 days)), 0
        );
        vm.prank(buyer);
        escrow.fund(big);
        vm.startPrank(seller);
        escrow.approve(address(pool), big);
        vm.expectRevert(AdvancePool.ConcentrationCapExceeded.selector);
        pool.advance(big, 0);
        vm.stopPrank();

        // loosen concentration, then hit the 80% utilisation cap
        AdvancePool.Params memory p = _params();
        p.concentrationCapBps = 10_000;
        vm.prank(owner);
        pool.setParams(p);

        vm.prank(seller);
        uint256 huge = escrow.createInvoice(
            buyer, arbiter, _amounts(45_000 * U, 45_000 * U), _deadlines(uint40(block.timestamp + 10 days), uint40(block.timestamp + 20 days)), 0
        );
        vm.prank(buyer);
        escrow.fund(huge);
        vm.startPrank(seller);
        escrow.approve(address(pool), huge);
        vm.expectRevert(AdvancePool.UtilizationCapExceeded.selector); // ~85k of 100k exceeds the 80% cap
        pool.advance(huge, 0);
        vm.stopPrank();
    }

    function test_alreadyFinancedInvoiceCannotBeSoldTwice() public {
        uint256 id = _createFunded();
        vm.startPrank(seller);
        escrow.approve(address(pool), id);
        pool.advance(id, 0);
        vm.stopPrank();

        vm.prank(seller);
        vm.expectRevert(AdvancePool.NotReceivableOwner.selector);
        pool.advance(id, 0);
    }

    function test_withdrawals_limitedToIdleLiquidity() public {
        // Deploy ~16% of the pool, then confirm LP can exit idle cash but not deployed cost.
        vm.prank(seller);
        uint256 id = escrow.createInvoice(
            buyer, arbiter, _amounts(10_000 * U, 10_000 * U), _deadlines(uint40(block.timestamp + 10 days), uint40(block.timestamp + 20 days)), 0
        );
        vm.prank(buyer);
        escrow.fund(id);
        vm.startPrank(seller);
        escrow.approve(address(pool), id);
        pool.advance(id, 0);
        vm.stopPrank();

        uint256 idle = usdg.balanceOf(address(pool));
        assertLt(idle, pool.totalAssets());
        // Exits are capped at idle cash AND at the cash that keeps carrying value inside the
        // utilisation cap, so one LP withdrawing the buffer cannot freeze every later advance.
        assertEq(pool.maxWithdraw(lp), pool._idleCap());
        assertLe(pool.maxWithdraw(lp), idle);
        assertLe(pool.deployed(), (pool.totalAssets() - pool.maxWithdraw(lp)) * 10_000 / 8_000);

        uint256 cap = pool.maxWithdraw(lp); // evaluated before expectRevert, it is an external call
        vm.prank(lp);
        vm.expectRevert();
        pool.withdraw(cap + 1, lp, lp);

        vm.prank(lp);
        pool.withdraw(cap, lp, lp);
        // After the exit the utilisation cap still holds, so new advances are not frozen.
        assertLe(pool.deployed() * 10_000, pool.totalAssets() * 8_000);
    }

    function test_onMilestoneSettled_onlyEscrow() public {
        vm.prank(stranger);
        vm.expectRevert(AdvancePool.OnlyEscrow.selector);
        pool.onMilestoneSettled(1, 1, 1);
    }

    function test_blocklistedPool_doesNotBlockBuyerOrEscrow_andSweepRecovers() public {
        uint256 id = _createFunded();
        vm.startPrank(seller);
        escrow.approve(address(pool), id);
        pool.advance(id, 0);
        vm.stopPrank();

        usdg.setBlocked(address(pool), true);
        _deliverAndApprove(id, 0); // pool payout deferred, settlement still succeeds
        assertEq(escrow.claimable(address(pool)), 3_000 * U);

        usdg.setBlocked(address(pool), false);
        assertEq(pool.sweepDeferred(address(pool)), 3_000 * U);
    }

    function test_inflationAttack_firstDepositorCannotStealFromVictim() public {
        MockUSDG t = new MockUSDG();
        InvoiceEscrow e = new InvoiceEscrow(IERC20(address(t)), owner, feeTo, 0);
        AdvancePool fresh = new AdvancePool(IERC20(address(t)), e, owner, "p", "p");
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        t.mint(attacker, 10_000 * U + 1);
        t.mint(victim, 10_000 * U);

        vm.startPrank(attacker);
        t.approve(address(fresh), type(uint256).max);
        fresh.deposit(1, attacker);
        t.transfer(address(fresh), 10_000 * U); // donation to inflate share price
        vm.stopPrank();

        vm.startPrank(victim);
        t.approve(address(fresh), type(uint256).max);
        fresh.deposit(10_000 * U, victim);
        vm.stopPrank();

        // Victim loses at most rounding dust (< 0.0001%), and the attacker's donation is simply lost to them.
        assertGe(fresh.convertToAssets(fresh.balanceOf(victim)), 10_000 * U - 10_000, "victim keeps ~full value");
        assertLe(fresh.convertToAssets(fresh.balanceOf(attacker)), 10_000 * U + 1, "attacker cannot profit");
    }

    function testFuzz_pricingIsMonotonicInTenor(uint40 d1, uint40 d2) public {
        d1 = uint40(bound(d1, 1 days, 60 days));
        d2 = uint40(bound(d2, d1 + 1 days, 120 days));
        vm.startPrank(seller);
        uint256 shortId = escrow.createInvoice(buyer, arbiter, _amounts(1_000 * U, 1_000 * U), _deadlines(uint40(block.timestamp) + d1, uint40(block.timestamp) + d1 + 1 days), 0);
        uint256 longId = escrow.createInvoice(buyer, arbiter, _amounts(1_000 * U, 1_000 * U), _deadlines(uint40(block.timestamp) + d2, uint40(block.timestamp) + d2 + 1 days), 0);
        vm.stopPrank();
        vm.startPrank(buyer);
        escrow.fund(shortId);
        escrow.fund(longId);
        vm.stopPrank();

        assertLe(pool.quote(shortId).discountBps, pool.quote(longId).discountBps);
    }

    function _params() internal view returns (AdvancePool.Params memory p) {
        (
            uint16 baseAprBps,
            uint16 minDiscountBps,
            uint16 maxDiscountBps,
            uint16 newcomerPremiumBps,
            uint16 riskSlopeBps,
            uint16 utilizationCapBps,
            uint16 concentrationCapBps,
            uint8 minHistory,
            uint32 maxTenor
        ) = pool.params();
        p = AdvancePool.Params(
            baseAprBps, minDiscountBps, maxDiscountBps, newcomerPremiumBps, riskSlopeBps,
            utilizationCapBps, concentrationCapBps, minHistory, maxTenor
        );
    }
}
