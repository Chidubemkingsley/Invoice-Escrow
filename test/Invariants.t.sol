// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InvoiceEscrow} from "../src/InvoiceEscrow.sol";
import {AdvancePool} from "../src/AdvancePool.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";

/// @dev Drives random, mostly-valid action sequences against escrow + pool.
contract Handler is Test {
    MockUSDG public usdg;
    InvoiceEscrow public escrow;
    AdvancePool public pool;
    address public seller = address(0x5E11);
    address public buyer = address(0xB0B);
    address public arbiter = address(0xA2B);
    uint256[] public ids;

    constructor(MockUSDG u, InvoiceEscrow e, AdvancePool p) {
        usdg = u; escrow = e; pool = p;
        usdg.mint(buyer, type(uint96).max);
        vm.prank(buyer);
        usdg.approve(address(e), type(uint256).max);
        vm.prank(seller);
        escrow.setApprovalForAll(address(p), true);
    }

    function idsLength() external view returns (uint256) { return ids.length; }

    function create(uint96 a, uint96 b) external {
        a = uint96(bound(a, 1e6, 50_000e6));
        b = uint96(bound(b, 1e6, 50_000e6));
        uint128[] memory amts = new uint128[](2);
        amts[0] = a; amts[1] = b;
        uint40[] memory dls = new uint40[](2);
        dls[0] = uint40(block.timestamp + 10 days);
        dls[1] = uint40(block.timestamp + 20 days);
        vm.prank(seller);
        uint256 id = escrow.createInvoice(buyer, arbiter, amts, dls, 0);
        vm.prank(buyer);
        escrow.fund(id);
        ids.push(id);
    }

    function submit(uint256 seed, uint8 idx) external {
        if (ids.length == 0) return;
        vm.prank(seller);
        try escrow.submitMilestone(ids[seed % ids.length], idx % 2) {} catch {}
    }

    function approve(uint256 seed, uint8 idx) external {
        if (ids.length == 0) return;
        vm.prank(buyer);
        try escrow.approveMilestone(ids[seed % ids.length], idx % 2) {} catch {}
    }

    function dispute(uint256 seed, uint8 idx) external {
        if (ids.length == 0) return;
        vm.prank(buyer);
        try escrow.disputeMilestone(ids[seed % ids.length], idx % 2) {} catch {}
    }

    function resolve(uint256 seed, uint8 idx, uint256 share) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        InvoiceEscrow.Milestone[] memory ms = escrow.getMilestones(id);
        vm.prank(arbiter);
        try escrow.resolveDispute(id, idx % 2, bound(share, 0, ms[idx % 2].amount)) {} catch {}
    }

    function reclaim(uint256 seed, uint8 idx) external {
        if (ids.length == 0) return;
        vm.prank(buyer);
        try escrow.reclaimUnsubmitted(ids[seed % ids.length], idx % 2) {} catch {}
    }

    function autoRelease(uint256 seed, uint8 idx) external {
        if (ids.length == 0) return;
        try escrow.autoRelease(ids[seed % ids.length], idx % 2) {} catch {}
    }

    function expireDispute(uint256 seed, uint8 idx) external {
        if (ids.length == 0) return;
        try escrow.resolveExpiredDispute(ids[seed % ids.length], idx % 2) {} catch {}
    }

    function sellToPool(uint256 seed) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        vm.prank(seller);
        try pool.advance(id, 0) {} catch {}
    }

    function warp(uint32 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 15 days));
    }
}

contract InvariantTest is Test {
    MockUSDG usdg;
    InvoiceEscrow escrow;
    AdvancePool pool;
    Handler handler;
    address lp = address(0x1F);

    function setUp() public {
        usdg = new MockUSDG();
        escrow = new InvoiceEscrow(IERC20(address(usdg)), address(this), address(0xFEE), 25);
        pool = new AdvancePool(IERC20(address(usdg)), escrow, address(this), "pool", "p");
        handler = new Handler(usdg, escrow, pool);

        pool.setApprovedArbiter(handler.arbiter(), true);
        pool.setSellerCreditLimit(handler.seller(), type(uint128).max);
        usdg.mint(lp, 500_000e6);
        vm.startPrank(lp);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(500_000e6, lp);
        vm.stopPrank();

        targetContract(address(handler));
    }

    /// The escrow holds exactly what is still owed: the sum of unsettled milestones of funded invoices.
    function invariant_escrowBalanceEqualsUnsettledAmounts() public view {
        uint256 owed;
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; ++i) owed += escrow.getInvoice(handler.ids(i)).remaining;
        assertEq(usdg.balanceOf(address(escrow)), owed + escrow.claimable(address(pool)));
    }

    /// Pool books never claim more carrying value than cost actually paid out for unsettled advances.
    function invariant_poolDeployedMatchesOpenAdvances() public view {
        uint256 open;
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; ++i) {
            (, uint128 cost,, uint128 released,) = pool.advances(handler.ids(i));
            open += cost - released;
        }
        assertEq(pool.deployed(), open);
        assertEq(pool.totalAssets(), usdg.balanceOf(address(pool)) + open);
    }

    /// LPs can always exit idle cash and the pool never reports negative-equity share pricing.
    function invariant_shareAccountingSane() public view {
        assertGe(pool.totalAssets(), 1);
        assertLe(pool.deployed(), pool.totalAssets());
    }
}
