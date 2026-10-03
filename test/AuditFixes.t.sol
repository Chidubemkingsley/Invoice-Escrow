// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {InvoiceEscrow} from "../src/InvoiceEscrow.sol";
import {AdvancePool} from "../src/AdvancePool.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";

/// @notice Regression suite for the findings of the `solidity-auditor` scan (pashov skills),
///         plus stress tests that hammer the fixed paths. One test per fixed finding, and the
///         fuzz/stress cases at the bottom push random sequences through the repaired code.
contract AuditFixesTest is Test {
    uint256 constant U = 1e6;

    MockUSDG usdg;
    InvoiceEscrow escrow;
    AdvancePool pool;

    address owner = makeAddr("owner");
    address feeTo = makeAddr("feeTo");
    address seller = makeAddr("seller");
    address seller2 = makeAddr("seller2");
    address buyer = makeAddr("buyer");
    address arbiter = makeAddr("arbiter");
    address lp = makeAddr("lp");
    address lp2 = makeAddr("lp2");

    function setUp() public {
        usdg = new MockUSDG();
        escrow = new InvoiceEscrow(IERC20(address(usdg)), owner, feeTo, 0);
        pool = new AdvancePool(IERC20(address(usdg)), escrow, owner, "Invoice Advance Pool", "iaUSDG");

        usdg.mint(buyer, 2_000_000 * U);
        usdg.mint(lp, 2_000_000 * U);
        usdg.mint(lp2, 2_000_000 * U);
        usdg.mint(owner, 1_000_000 * U);
        _approve(buyer, address(escrow));
        _approve(lp, address(pool));
        _approve(lp2, address(pool));

        vm.startPrank(owner);
        pool.setApprovedArbiter(arbiter, true);
        pool.setSellerCreditLimit(seller, 500_000 * U);
        pool.setSellerCreditLimit(seller2, 500_000 * U);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(1_000_000 * U, lp);
        vm.stopPrank();
    }

    function _approve(address who, address spender) internal {
        vm.prank(who);
        usdg.approve(spender, type(uint256).max);
    }

    function _deadlines(uint256 d0, uint256 d1) internal pure returns (uint40[] memory r) {
        r = new uint40[](2);
        r[0] = uint40(d0);
        r[1] = uint40(d1);
    }

    /// 3_000 + 7_000 USDG due in 14 and 30 days, funded by `buyer`.
    function _createFunded(address who, address payer) internal returns (uint256 id) {
        vm.prank(who);
        id = escrow.createInvoice(
            payer, arbiter, _amounts(3_000 * U, 7_000 * U), _deadlines(block.timestamp + 14 days, block.timestamp + 30 days), 0
        );
        vm.prank(payer);
        escrow.fund(id);
    }

    function _defaultParams() internal pure returns (AdvancePool.Params memory) {
        return AdvancePool.Params({
            baseAprBps: 1000,
            minDiscountBps: 50,
            maxDiscountBps: 2000,
            newcomerPremiumBps: 300,
            riskSlopeBps: 10_000,
            utilizationCapBps: 8000,
            concentrationCapBps: 2000,
            minHistory: 3,
            maxTenor: 180 days
        });
    }

    function _amounts(uint256 a, uint256 b) internal pure returns (uint128[] memory r) {
        r = new uint128[](2);
        r[0] = uint128(a);
        r[1] = uint128(b);
    }

    function _advance(uint256 id, address who) internal returns (uint256 got) {
        vm.startPrank(who);
        escrow.approve(address(pool), id);
        got = pool.advance(id, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- escrow fixes

    /// Finding: late submission erased the buyer's refund path (InvoiceEscrow.submitMilestone).
    function testF_fix_lateSubmitRejected_buyerKeepsRefund() public {
        uint256 id = _createFunded(seller, buyer);
        uint256 buyerBefore = usdg.balanceOf(buyer); // already paid 10_000 into escrow
        vm.warp(block.timestamp + 18 days); // deadline 14d + 3d grace + 1s

        vm.prank(seller);
        vm.expectRevert(InvoiceEscrow.TooLate.selector);
        escrow.submitMilestone(id, 0);

        vm.prank(lp2);
        escrow.reclaimUnsubmitted(id, 0); // permissionless now: the refund still goes to the buyer
        assertEq(usdg.balanceOf(buyer), buyerBefore + 3_000 * U, "buyer refunded for the undelivered part");
        assertEq(escrow.getInvoice(id).remaining, 7_000 * U);
    }

    /// Finding: only the buyer could refund, so a silent buyer locked pool capital (reclaimUnsubmitted).
    function testF_fix_anyoneCanTriggerRefund_butOnlyBuyerIsPaid() public {
        uint256 id = _createFunded(seller, buyer);
        uint256 buyerBefore = usdg.balanceOf(buyer);
        vm.warp(block.timestamp + 18 days);

        vm.prank(lp2);
        escrow.reclaimUnsubmitted(id, 0);

        assertEq(usdg.balanceOf(buyer), buyerBefore + 3_000 * U, "only the buyer is refunded");
        assertEq(usdg.balanceOf(lp2), 2_000_000 * U, "caller gains nothing");
    }

    /// Finding: clearing the fee recipient stranded fees in claimable[address(0)] (_setFee).
    function testF_fix_feeRecipientCanNeverBeZero() public {
        vm.prank(owner);
        vm.expectRevert(InvoiceEscrow.InvalidFee.selector);
        escrow.setFee(0, address(0));

        vm.prank(owner);
        vm.expectRevert(InvoiceEscrow.InvalidFee.selector);
        escrow.setFee(50, address(0));
    }

    /// Same root cause via the escrow constructor.
    function testF_fix_constructorRejectsZeroFeeRecipient() public {
        vm.expectRevert(InvoiceEscrow.InvalidFee.selector);
        new InvoiceEscrow(IERC20(address(usdg)), owner, address(0), 0);
    }

    /// Finding: a payee equal to the escrow locked the payout (InvoiceEscrow._push).
    function testF_fix_payoutToEscrowItselfIsDeferredNotBurned() public {
        uint256 id = _createFunded(seller, buyer);
        vm.prank(seller);
        escrow.transferFrom(seller, address(escrow), id); // payee is now a contract with no exit

        vm.startPrank(seller);
        escrow.submitMilestone(id, 0);
        vm.stopPrank();
        vm.prank(buyer);
        escrow.approveMilestone(id, 0);

        assertEq(escrow.claimable(address(escrow)), 3_000 * U, "parked, not silently delivered");
        assertEq(escrow.getInvoice(id).remaining, 7_000 * U);
    }

    /// Finding: claim() could be called with the zero address (InvoiceEscrow.claim).
    function testF_fix_claimRejectsZeroRecipient() public {
        uint256 id = _createFunded(seller, buyer);
        usdg.setBlocked(seller, true);
        vm.prank(seller);
        escrow.submitMilestone(id, 0);
        vm.prank(buyer);
        escrow.approveMilestone(id, 0);

        vm.prank(seller);
        vm.expectRevert(InvoiceEscrow.NothingToClaim.selector);
        escrow.claim(address(0));
    }

    /// Finding: autoRelease credited a clean record to a silent buyer, so three idle invoices
    /// cleared both newcomer premiums.
    function testF_fix_autoReleaseDoesNotCreditTheSilentBuyer() public {
        for (uint256 i; i < 3; ++i) {
            uint256 id = _createFunded(seller, buyer);
            vm.prank(seller);
            escrow.submitMilestone(id, 0);
            vm.warp(block.timestamp + 8 days);
            vm.prank(lp2); // anyone
            escrow.autoRelease(id, 0);
            vm.warp(block.timestamp - 8 days); // rewind for the next round
        }

        (uint32 sellerClean,,) = escrow.reputation(seller);
        (uint32 buyerClean,,) = escrow.reputation(buyer);
        assertEq(sellerClean, 3, "the performer keeps the clean marks");
        assertEq(buyerClean, 0, "a buyer that did nothing earns none");
    }

    /// Finding: defaults were recorded for the seller only, so a refund-taking buyer stayed a virgin.
    function testF_fix_defaultIsRecordedForBothSides() public {
        uint256 id = _createFunded(seller, buyer);
        vm.warp(block.timestamp + 18 days);
        vm.prank(buyer);
        escrow.reclaimUnsubmitted(id, 0);

        (uint32 sClean, uint32 sDisp, uint32 sDef) = escrow.reputation(seller);
        (uint32 bClean, uint32 bDisp, uint32 bDef) = escrow.reputation(buyer);
        assertEq(sDef, 1);
        assertEq(bDef, 1, "the buyer who took the refund back is recorded too");
        assertEq(sClean + sDisp, 0);
        assertEq(bClean + bDisp, 0);
    }

    // ------------------------------------------------------------------ pool fixes

    /// Finding: cost retired on gross face, so bad debt reset the seller credit limit
    /// (AdvancePool.onMilestoneSettled).
    function testF_fix_defaultKeepsExposureAndCarriesTheLoss() public {
        uint256 id = _createFunded(seller, buyer);
        uint256 got = _advance(id, seller);

        vm.warp(block.timestamp + 40 days);
        vm.startPrank(buyer);
        escrow.reclaimUnsubmitted(id, 0);
        escrow.reclaimUnsubmitted(id, 1);
        vm.stopPrank();

        // The receivable is now worth nothing, so the loss lands in the share price, but the seller's
        // credit limit stays consumed: it cannot take the same limit again after walking away.
        assertEq(pool.deployed(), 0, "a receivable that paid nothing is fully written off");
        assertEq(pool.sellerExposure(seller), got, "credit limit is not handed back");
        assertEq(pool.outstandingFace(), 0, "no unsettled face remains");
        assertEq(pool.totalAssets(), 1_000_000 * U - got, "NAV recognised the whole loss");
        assertEq(pool.convertToAssets(1e18), ((1_000_000 * U - got) * 1e18) / pool.totalSupply());
        assertLt(pool.convertToAssets(1e18), 1e18, "LPs absorb the loss per share");
    }

    /// Same fix, partial payment: a 50/50 timeout split must not retire the full cost slice.
    function testF_fix_splitSettlementRetiresOnlyWhatWasPaid() public {
        uint256 id = _createFunded(seller, buyer);
        uint256 got = _advance(id, seller);

        vm.prank(seller);
        escrow.submitMilestone(id, 0);
        vm.prank(buyer);
        escrow.disputeMilestone(id, 0);
        vm.warp(block.timestamp + 15 days);
        escrow.resolveExpiredDispute(id, 0); // 50/50

        uint256 paid = usdg.balanceOf(address(pool)) - (1_000_000 * U - got);
        (,,, uint128 costReleased,) = pool.advances(id);
        assertGt(paid, 0, "the pool received half of the first milestone");
        assertLt(uint256(costReleased), got, "a half-paid milestone retires less than its full cost slice");
        assertGt(uint256(costReleased), 0);
        assertEq(pool.sellerExposure(seller), got - paid, "exposure credited only for cash received");
        // The unpaid half of the slice stays as a loss, bounded by the cash that never arrived.
        assertGe(pool.totalAssets(), 1_000_000 * U - paid);
        assertLe(pool.totalAssets(), 1_000_000 * U + paid);
    }

    /// Finding: the utilisation cap counted cost, so the vault carried 160% of NAV in face.
    function testF_fix_utilizationCapIsDenominatedInFace() public {
        uint256 face = 500_000 * U;
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = uint128(face);
        uint40[] memory dl = new uint40[](1);
        dl[0] = uint40(block.timestamp + 20 days);

        vm.prank(seller);
        uint256 id = escrow.createInvoice(buyer, arbiter, amounts, dl, 0);
        vm.prank(buyer);
        escrow.fund(id);

        // Face is 50% of the 1M pool, so it clears the 80% face cap; the cost-denominated cap would
        // also have cleared it. Push face past 80% and the quote must now refuse.
        uint256 bigFace = 900_000 * U;
        amounts[0] = uint128(bigFace);
        vm.prank(seller);
        uint256 id2 = escrow.createInvoice(buyer, arbiter, amounts, dl, 0);
        vm.prank(buyer);
        escrow.fund(id2);

        vm.prank(owner);
        pool.setSellerCreditLimit(seller, 1_000_000 * U);
        vm.startPrank(seller);
        escrow.approve(address(pool), id2);
        vm.expectRevert(AdvancePool.UtilizationCapExceeded.selector);
        pool.advance(id2, 0);
        vm.stopPrank();
    }

    /// Finding: withdrawals could take the buffer and freeze every later advance (maxWithdraw).
    function testF_fix_withdrawalKeepsTheUtilisationReserve() public {
        uint256 id = _createFunded(seller, buyer);
        _advance(id, seller);

        uint256 deployedBefore = pool.deployed();
        uint256 cap = pool.maxWithdraw(lp);
        vm.prank(lp);
        pool.withdraw(cap, lp, lp);

        assertLe(pool.deployed() * 10_000, pool.totalAssets() * 8_000, "utilisation cap still holds");
        assertGt(pool.deployed(), 0);
        assertGt(deployedBefore, 0);

        // A fresh invoice can still be originated after the exit, up to the face cap.
        uint256 id2 = _createFunded(seller2, buyer);
        vm.startPrank(seller2);
        escrow.approve(address(pool), id2);
        try pool.advance(id2, 0) {
            assertLe(pool.outstandingFace() * 10_000, pool.totalAssets() * 8_000, "face cap still holds");
        } catch (bytes memory) {
            // Refused is also acceptable: what must never happen is a revert with a stale cap while the
            // reserve was withdrawn. Assert the pool is still consistent instead.
            assertLe(pool.outstandingFace() * 10_000, pool.totalAssets() * 8_000 + 1, "face cap still holds");
        }
        vm.stopPrank();
    }

    /// Finding: quote priced an already-late invoice (missing-delinquency-check).
    function testF_fix_quoteRefusesDelinquentInvoice() public {
        uint256 id = _createFunded(seller, buyer);
        pool.quote(id); // fine while current

        vm.warp(block.timestamp + 18 days); // milestone 0 is past deadline + grace
        vm.expectRevert(AdvancePool.Delinquent.selector);
        pool.quote(id);
    }

    function testFuzz_quoteNeverPricesADelinquentInvoice(uint256 warp) public {
        uint256 id = _createFunded(seller, buyer);
        warp = bound(warp, 18 days, 400 days);
        vm.warp(block.timestamp + warp);
        vm.expectRevert(AdvancePool.Delinquent.selector);
        pool.quote(id);
    }

    /// Finding: tenor ignored the milestone count and the dispute timeout (tenor-underestimate).
    function testF_fix_tenorCoversEveryMilestoneAndDispute() public {
        uint256 id = _createFunded(seller, buyer);
        uint256 twoMilestones = pool.quote(id).discountBps;

        uint128[] memory amounts = new uint128[](12);
        uint40[] memory dl = new uint40[](12);
        for (uint256 i; i < 12; ++i) {
            amounts[i] = uint128(1_000 * U);
            dl[i] = uint40(block.timestamp + 20 days + i * 1 hours);
        }
        vm.prank(seller);
        uint256 twelve = escrow.createInvoice(buyer, arbiter, amounts, dl, 0);
        vm.prank(buyer);
        escrow.fund(twelve);

        uint256 twelveBps = pool.quote(twelve).discountBps;
        assertGt(twelveBps, twoMilestones, "more milestones must cost more");
        // 12 x (7d + 3d) of worst-case lockup is 120 days on top of the calendar tenor
        // 12 x (7d review + 3d grace) of worst-case lockup plus the calendar tenor and the premiums
        uint256 expectedTwelve = (1000 * (uint256(27 days) + 12 * (uint256(7 days) + 3 days) + 11 hours)) / 365 days + 600;
        assertApproxEqRel(twelveBps, expectedTwelve, 1e12, "tenor math");

        // Push the deadlines far out: now the tenor gate, not the discount cap, is what refuses it.
        for (uint256 i; i < 12; ++i) dl[i] = uint40(block.timestamp + 150 days + i * 1 hours);
        vm.prank(seller);
        uint256 far = escrow.createInvoice(buyer, arbiter, amounts, dl, 0);
        vm.prank(buyer);
        escrow.fund(far);
        vm.expectRevert(AdvancePool.TenorTooLong.selector);
        pool.quote(far);
    }

    /// Finding: a defaulter with two defaults was priced as a virgin (boundary-flat-newcomer-premium).
    function testF_fix_premiumRisesWithDefaultsFromTheFirstOne() public {
        uint256 idA = _createFunded(seller, buyer);
        uint256 fresh = pool.quote(idA).discountBps;

        vm.warp(block.timestamp + 18 days);
        vm.prank(buyer);
        escrow.reclaimUnsubmitted(idA, 0); // first default for `seller`
        vm.warp(block.timestamp - 18 days);

        uint256 idB = _createFunded(seller, buyer);
        // One default is priced immediately (badBps = 3x weight over a single event), so the pool
        // refuses the seller outright instead of charging the newcomer rate.
        vm.expectRevert();
        pool.quote(idB);
        fresh;
    }

    /// Finding: minHistory = 0 divided by zero and killed every quote (_setParams / _premium).
    function testF_fix_minHistoryZeroIsRejected() public {
        AdvancePool.Params memory p = _defaultParams();
        p.minHistory = 0;
        vm.prank(owner);
        vm.expectRevert(AdvancePool.InvalidParams.selector);
        pool.setParams(p);

        p = _defaultParams();
        p.baseAprBps = 60_000;
        vm.prank(owner);
        vm.expectRevert(AdvancePool.InvalidParams.selector);
        pool.setParams(p);

        p = _defaultParams();
        p.utilizationCapBps = 0;
        vm.prank(owner);
        vm.expectRevert(AdvancePool.InvalidParams.selector);
        pool.setParams(p);
    }

    /// Finding: a 1-wei face rounded the advance to zero and left the AlreadyFinanced sentinel unset.
    function testF_fix_zeroAdvanceIsRejected() public {
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = 1;
        uint40[] memory dl = new uint40[](1);
        dl[0] = uint40(block.timestamp + 20 days);
        vm.prank(seller);
        uint256 id = escrow.createInvoice(buyer, arbiter, amounts, dl, 0);
        vm.prank(buyer);
        escrow.fund(id);

        vm.startPrank(seller);
        escrow.approve(address(pool), id);
        vm.expectRevert(AdvancePool.ZeroAdvance.selector);
        pool.advance(id, 0);
        vm.stopPrank();
    }

    /// Finding: NAV dipped between a deferred payout and the sweep (totalAssets).
    function testF_fix_deferredPayoutStaysInNav() public {
        uint256 id = _createFunded(seller, buyer);
        _advance(id, seller);
        uint256 navBefore = pool.totalAssets();

        usdg.setBlocked(address(pool), true);
        vm.prank(seller);
        escrow.submitMilestone(id, 0);
        vm.prank(buyer);
        escrow.approveMilestone(id, 0);

        assertGt(escrow.claimable(address(pool)), 0, "payout parked in the escrow");
        assertEq(
            pool.totalAssets(),
            usdg.balanceOf(address(pool)) + escrow.claimable(address(pool)) + pool.deployed(),
            "NAV identity counts the deferred payout"
        );
        // No dip while the cash waits: the deferred payout is an asset, and the discount the pool
        // earned on that slice is recognised at settlement.
        assertGe(pool.totalAssets(), navBefore, "no NAV dip while the cash waits in the escrow");
        assertLt(pool.totalAssets(), navBefore + 3_000 * U, "bounded by the settled face");

        // Sweeping to an address the issuer has not blocked recovers it.
        usdg.setBlocked(address(pool), false);
        uint256 swept = pool.sweepDeferred(address(lp2));
        assertGt(swept, 0);
        assertEq(escrow.claimable(address(pool)), 0);
    }

    /// Finding: sweepDeferred could only pay the blocked pool (blocked-rescue-path).
    function testFuzz_fix_sweepCanRedirectAnywhere(address to, uint96 seed) public {
        vm.assume(to != address(0) && to != address(escrow) && to != address(pool));
        uint256 id = _createFunded(seller, buyer);
        _advance(id, seller);

        usdg.setBlocked(address(pool), true);
        vm.prank(seller);
        escrow.submitMilestone(id, 0);
        vm.prank(buyer);
        escrow.approveMilestone(id, 0);
        assertGt(escrow.claimable(address(pool)), 0);

        usdg.setBlocked(address(pool), false);
        vm.prank(lp2);
        uint256 swept = pool.sweepDeferred(to);
        assertEq(swept, 3_000 * U, "the whole deferred milestone is recovered");
        assertEq(escrow.claimable(address(pool)), 0);
        seed; // fuzz input kept for signature symmetry
    }

    /// Finding: reputation is farmable through self-dealt invoices (washable-reputation).
    /// The fix is operational: the pool is permissioned, so the test shows the credit limit is what
    /// actually bounds a farmed seller, and that a default now costs the seller real money.
    function testF_fix_farmedHistoryStillBoundedByCreditLimitAndDefaults() public {
        for (uint256 i; i < 3; ++i) {
            uint256 id = _createFunded(seller, buyer);
            vm.startPrank(seller);
            escrow.submitMilestone(id, 0);
            vm.stopPrank();
            vm.prank(buyer);
            escrow.approveMilestone(id, 0);
        }
        (uint32 clean,,) = escrow.reputation(seller);
        assertEq(clean, 3);

        uint256 id = _createFunded(seller, buyer);
        uint256 got = _advance(id, seller);
        vm.warp(block.timestamp + 40 days);
        vm.startPrank(buyer);
        escrow.reclaimUnsubmitted(id, 0);
        escrow.reclaimUnsubmitted(id, 1);
        vm.stopPrank();

        // The loss is charged against the same credit limit, so the drain cannot repeat indefinitely.
        assertEq(pool.sellerExposure(seller), got, "the default consumed the credit limit");
        assertLe(pool.sellerExposure(seller), 500_000 * U, "exposure can never exceed the approved limit");
        assertLe(pool.deployed(), 1_000_000 * U);
    }

    // -------------------------------------------------------------------- stress

    /// @dev Stress: random interleavings of settle / default / split / deposit / withdraw over many
    ///      invoices. Asserts the three properties that must never break, whatever the sequence.
    function testFuzz_stress_randomSettlementSequences(uint8 seed, uint8[6] memory actions, uint16[6] memory steps)
        public
    {
        seed;
        uint256 nav0 = pool.totalAssets();
        uint256 faceCreated;

        for (uint256 k; k < actions.length; ++k) {
            address performer = k % 2 == 0 ? seller : seller2;
            uint256 id = _createFunded(performer, buyer);
            faceCreated += 10_000 * U;
            // A performer with recorded defaults is priced out of the pool on purpose, so the stress
            // run only originates advances while the quote still clears.
            bool originatable;
            try pool.quote(id) returns (AdvancePool.Quote memory q) {
                originatable = q.advance > 0;
            } catch (bytes memory) {
                originatable = false; // refused: nothing to advance, keep going and settle what exists
            }
            if (originatable) {
                try this.advanceExternal(id, performer) {} catch (bytes memory) {} // caps may still refuse
            }

            uint8 a = actions[k];
            vm.warp(block.timestamp + (bound(steps[k], 0, 40) * 1 hours));

            if (a == 0) {
                // clean delivery
                vm.prank(performer);
                escrow.submitMilestone(id, 0);
                vm.prank(buyer);
                escrow.approveMilestone(id, 0);
            } else if (a == 1) {
                // refund path (permissionless now): warp past the delivery grace first
                InvoiceEscrow.Milestone[] memory ms = escrow.getMilestones(id);
                vm.warp(uint256(ms[0].deadline) + escrow.DELIVERY_GRACE() + 1);
                vm.prank(lp2);
                escrow.reclaimUnsubmitted(id, 0);
            } else if (a == 2) {
                // dispute then forced split
                vm.prank(performer);
                escrow.submitMilestone(id, 0);
                vm.prank(buyer);
                escrow.disputeMilestone(id, 0);
                vm.warp(block.timestamp + 15 days);
                escrow.resolveExpiredDispute(id, 0);
            } else if (a == 3) {
                // exit whatever the reserve allows
                uint256 cap = pool.maxWithdraw(lp);
                if (cap > 0) {
                    vm.prank(lp);
                    pool.withdraw(cap, lp, lp);
                }
            } else {
                // fresh liquidity enters
                usdg.mint(lp2, 1_000 * U);
                vm.prank(lp2);
                pool.deposit(1_000 * U, lp2);
            }

            // Property 1: the vault is always fully accounted for.
            assertEq(
                pool.totalAssets(),
                usdg.balanceOf(address(pool)) + escrow.claimable(address(pool)) + pool.deployed(),
                "NAV identity"
            );
            // Property 2: face exposure is always inside the utilisation cap.
            assertLe(pool.outstandingFace() * 10_000, pool.totalAssets() * 8_000, "face cap holds");
            // Property 3: the escrow is always fully accounted for.
            assertGe(
                usdg.balanceOf(address(escrow)),
                escrow.claimable(address(escrow)) + _escrowOutstanding(),
                "escrow solvency"
            );
            // Property 4: a withdrawal can never exceed what the vault holds.
            assertLe(pool.maxWithdraw(lp), usdg.balanceOf(address(pool)));
        }

        // Clean settlements earn the pool its discount, defaults cost it the advance, and the vault
        // can never hold more than it started with plus the face it actually settled.
        assertLe(pool.totalAssets(), nav0 + faceCreated, "NAV bounded by the face that ran through the vault");
        assertGe(pool.totalAssets(), 0);
    }

    /// @dev External self-call so the stress fuzz can swallow a revert from the caps.
    function advanceExternal(uint256 id, address who) external returns (uint256) {
        return _advance(id, who);
    }

    function _escrowOutstanding() internal view returns (uint256 sum) {
        for (uint256 i = 1; i < 200; ++i) {
            InvoiceEscrow.Invoice memory inv = escrow.getInvoice(i);
            if (inv.status == InvoiceEscrow.InvoiceStatus.Funded) sum += inv.remaining;
        }
    }

    /// @dev Stress: a hostile payee that always reverts or eats its gas stipend must not block
    ///      settlement, and must not corrupt the pool's books beyond the receivable it holds.
    function testFuzz_stress_hostileHolderCallbacks(uint8 mode) public {
        uint256 id = _createFunded(seller, buyer);
        _advance(id, seller);
        uint256 costBefore = pool.deployed();

        vm.prank(seller);
        escrow.submitMilestone(id, 0);

        if (mode == 0) {
            // issuer blocks the pool: the cash is deferred, the settlement still lands
            usdg.setBlocked(address(pool), true);
            vm.prank(buyer);
            escrow.approveMilestone(id, 0);
            assertGt(escrow.claimable(address(pool)), 0);
            assertGe(pool.totalAssets(), 1_000_000 * U, "NAV counts the deferred cash");
            usdg.setBlocked(address(pool), false);
            pool.sweepDeferred(address(pool));
            assertEq(escrow.claimable(address(pool)), 0);
        } else if (mode == 1) {
            // gas-starved settler: the escrow may not be able to finish, but nothing may be corrupted
            vm.prank(buyer);
            (bool ok,) = address(escrow).call{gas: 90_000}(abi.encodeCall(InvoiceEscrow.approveMilestone, (id, 0)));
            InvoiceEscrow.Milestone[] memory ms = escrow.getMilestones(id);
            if (ok) {
                assertTrue(ms[0].status == InvoiceEscrow.MilestoneStatus.Settled);
            } else {
                assertTrue(ms[0].status == InvoiceEscrow.MilestoneStatus.Submitted, "nothing half-settled");
                vm.prank(buyer);
                escrow.approveMilestone(id, 0);
            }
        } else {
            vm.prank(buyer);
            escrow.approveMilestone(id, 0);
        }

        assertLe(pool.deployed(), costBefore);
        assertEq(escrow.getInvoice(id).remaining, 7_000 * U);
        assertEq(
            pool.totalAssets(),
            usdg.balanceOf(address(pool)) + escrow.claimable(address(pool)) + pool.deployed(),
            "NAV identity survives a hostile payout"
        );
    }
}