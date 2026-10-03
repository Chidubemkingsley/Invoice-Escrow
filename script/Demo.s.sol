// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {InvoiceEscrow} from "../src/InvoiceEscrow.sol";
import {AdvancePool} from "../src/AdvancePool.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";

/// @notice End-to-end run of the product on a live testnet, using three funded wallets:
///   PRIVATE_KEY (pool owner + liquidity provider), SELLER_KEY, BUYER_KEY.
/// Flow: LP funds pool -> seller invoices -> buyer funds escrow -> seller sells invoice for an
///       instant advance -> seller delivers both milestones -> buyer approves -> pool books profit.
/// Needs: gas token on all three wallets; USDG: LP_USDG (default 500) on the owner wallet and
///        INVOICE_USDG (default 100) on the buyer wallet.
contract Demo is Script {
    struct Ctx {
        InvoiceEscrow escrow;
        AdvancePool pool;
        IERC20 token;
        uint256 unit;
        uint256 ownerKey;
        uint256 sellerKey;
        uint256 buyerKey;
        address seller;
        address buyer;
        address arbiter;
    }

    function run() external {
        Ctx memory c = _load();
        uint256 lp = vm.envOr("LP_USDG", uint256(500)) * c.unit;
        uint256 invoiceAmt = vm.envOr("INVOICE_USDG", uint256(100)) * c.unit;

        _checkBalances(c, lp, invoiceAmt);
        _setupPool(c, lp);
        uint256 id = _issueAndFund(c, invoiceAmt);
        _advance(c, id);
        _deliverAndApprove(c, id);

        console2.log("--- done ---");
        console2.log("pool totalAssets (should exceed LP deposit):", c.pool.totalAssets());
        console2.log("LP deposit                                 :", lp);
        console2.log("seller USDG balance                        :", c.token.balanceOf(c.seller));
    }

    // ------------------------------------------------------------------ steps

    function _load() internal view returns (Ctx memory c) {
        string memory json = vm.readFile(string.concat("./deployments/", vm.toString(block.chainid), ".json"));
        c.escrow = InvoiceEscrow(vm.parseJsonAddress(json, ".escrow"));
        c.pool = AdvancePool(vm.parseJsonAddress(json, ".pool"));
        c.token = c.escrow.token();
        c.unit = 10 ** IERC20Metadata(address(c.token)).decimals();
        c.ownerKey = vm.envUint("PRIVATE_KEY");
        c.sellerKey = vm.envUint("SELLER_KEY");
        c.buyerKey = vm.envUint("BUYER_KEY");
        c.seller = vm.addr(c.sellerKey);
        c.buyer = vm.addr(c.buyerKey);
        // Required: a derived default key would be public knowledge, so anyone could rule on disputes.
        c.arbiter = vm.envOr("ARBITER", address(0));
        require(c.arbiter != address(0), "Demo: set ARBITER to an address you control");
        require(c.seller != c.buyer, "Demo: SELLER_KEY and BUYER_KEY must differ");
    }

    function _checkBalances(Ctx memory c, uint256 lp, uint256 invoiceAmt) internal {
        if (vm.envOr("MOCK_MINT", false)) {
            vm.startBroadcast(c.ownerKey);
            MockUSDG(address(c.token)).mint(vm.addr(c.ownerKey), lp);
            MockUSDG(address(c.token)).mint(c.buyer, invoiceAmt);
            vm.stopBroadcast();
        }
        require(c.token.balanceOf(vm.addr(c.ownerKey)) >= lp, "Demo: owner wallet needs LP_USDG of USDG");
        require(c.token.balanceOf(c.buyer) >= invoiceAmt, "Demo: buyer wallet needs INVOICE_USDG of USDG");
        require(vm.addr(c.ownerKey).balance > 0 && c.seller.balance > 0 && c.buyer.balance > 0, "Demo: all 3 wallets need gas");
    }

    function _setupPool(Ctx memory c, uint256 lp) internal {
        vm.startBroadcast(c.ownerKey);
        c.pool.setApprovedArbiter(c.arbiter, true);
        c.pool.setSellerCreditLimit(c.seller, lp); // credit committee decision
        c.token.approve(address(c.pool), lp);
        c.pool.deposit(lp, vm.addr(c.ownerKey));
        vm.stopBroadcast();
        console2.log("LP deposited:", lp);
    }

    function _issueAndFund(Ctx memory c, uint256 invoiceAmt) internal returns (uint256 id) {
        uint128[] memory amounts = new uint128[](2);
        amounts[0] = uint128((invoiceAmt * 30) / 100);
        amounts[1] = uint128(invoiceAmt - amounts[0]);
        uint40[] memory deadlines = new uint40[](2);
        deadlines[0] = uint40(block.timestamp + 14 days);
        deadlines[1] = uint40(block.timestamp + 30 days);

        vm.startBroadcast(c.sellerKey);
        // Use the id createInvoice returns. A pre-read counter can be consumed by a front-runner
        // between two broadcasts, which would fund a stranger's invoice with the demo buyer's USDG.
        id = c.escrow.createInvoice(c.buyer, c.arbiter, amounts, deadlines, keccak256("DEMO-INV-001"));
        vm.stopBroadcast();

        vm.startBroadcast(c.buyerKey);
        c.token.approve(address(c.escrow), invoiceAmt);
        c.escrow.fund(id);
        vm.stopBroadcast();
        console2.log("invoice created + funded, id:", id);
    }

    function _advance(Ctx memory c, uint256 id) internal {
        AdvancePool.Quote memory q = c.pool.quote(id);
        console2.log("quote: face    :", q.face);
        console2.log("quote: discount bps:", q.discountBps);
        console2.log("quote: advance :", q.advance);

        vm.startBroadcast(c.sellerKey);
        c.escrow.approve(address(c.pool), id);
        c.pool.advance(id, q.advance); // minAdvance = quoted price (slippage guard)
        vm.stopBroadcast();
        console2.log("seller paid instantly:", q.advance);
    }

    function _deliverAndApprove(Ctx memory c, uint256 id) internal {
        for (uint256 i; i < 2; ++i) {
            vm.startBroadcast(c.sellerKey);
            c.escrow.submitMilestone(id, i);
            vm.stopBroadcast();
            vm.startBroadcast(c.buyerKey);
            c.escrow.approveMilestone(id, i);
            vm.stopBroadcast();
        }
    }
}
