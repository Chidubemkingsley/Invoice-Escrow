// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {InvoiceEscrow} from "../src/InvoiceEscrow.sol";
import {AdvancePool} from "../src/AdvancePool.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";

/// @notice Deploys InvoiceEscrow + AdvancePool against Paxos USDG and records addresses in
///         deployments/<chainid>.json (read by Demo.s.sol and your future frontend).
///
/// Env (see .env.example):
///   PRIVATE_KEY        deployer key (required)
///   OWNER              admin / credit committee (default: deployer; use a multisig on mainnet)
///   FEE_BPS            protocol fee in bps, max 100 (default 0)
///   FEE_RECIPIENT      required if FEE_BPS > 0
///   ARBITER            optional: approve this dispute arbiter on the pool (only if OWNER == deployer)
///   USDG_ADDRESS       override the token address
///   DEPLOY_MOCK_USDG   "true" to deploy MockUSDG instead (local/dev only)
contract Deploy is Script {
    // Published at https://docs.paxos.com/guides/stablecoin/usdg/{mainnet,testnet}
    address constant USDG_ARBITRUM_ONE = 0x004B506865409877C9fA29bfb1ebA929984B9bbC;
    address constant USDG_ARBITRUM_SEPOLIA = 0xFFC95faa3d63Cde504a05B567C600B78C0b41892;
    address constant USDG_ROBINHOOD_MAINNET = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant USDG_ROBINHOOD_TESTNET = 0x7E955252E15c84f5768B83c41a71F9eba181802F;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER", deployer);
        uint256 feeBpsRaw = vm.envOr("FEE_BPS", uint256(0));
        require(feeBpsRaw <= 100, "Deploy: FEE_BPS must be 0..100 (1% hard cap)");
        uint16 feeBps = uint16(feeBpsRaw);
        // Fee recipient must never be the zero address, so it defaults to the owner while the fee is 0.
        address feeRecipient = vm.envOr("FEE_RECIPIENT", owner);
        address arbiter = vm.envOr("ARBITER", address(0));
        bool useMock = vm.envOr("DEPLOY_MOCK_USDG", false);
        if (feeBps > 0) require(feeRecipient != address(0), "Deploy: FEE_RECIPIENT required when FEE_BPS > 0");
        // The mock token is mintable and blockable by anyone, so it must never reach a public network.
        if (useMock) require(_isLocalChain(block.chainid), "Deploy: DEPLOY_MOCK_USDG only on a local chain");

        require(deployer.balance > 0, "Deploy: deployer has no gas token");

        vm.startBroadcast(pk);

        address token;
        if (useMock) {
            token = address(new MockUSDG());
            console2.log("MockUSDG (dev only):", token);
        } else {
            token = vm.envOr("USDG_ADDRESS", _defaultUsdg(block.chainid));
            // Fail early if the address is not a token on this chain (wrong network / typo).
            require(token.code.length > 0, "Deploy: no contract at USDG address on this chain");
            console2.log("USDG decimals:", IERC20Metadata(token).decimals());
        }

        InvoiceEscrow escrow = new InvoiceEscrow(IERC20(token), owner, feeRecipient, feeBps);
        AdvancePool pool = new AdvancePool(IERC20(token), escrow, owner, "Invoice Advance Pool", "iaUSDG");

        if (arbiter != address(0) && owner == deployer) pool.setApprovedArbiter(arbiter, true);

        vm.stopBroadcast();

        console2.log("chainid       :", block.chainid);
        console2.log("owner         :", owner);
        console2.log("USDG          :", token);
        console2.log("InvoiceEscrow :", address(escrow));
        console2.log("AdvancePool   :", address(pool));

        _record(token, address(escrow), address(pool), owner);
    }

    function _record(address token, address escrow, address pool, address owner) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "owner", owner);
        vm.serializeAddress(k, "token", token); // the USDG (ERC-20) this deployment is denominated in
        vm.serializeAddress(k, "usdg", token); // back-compat alias
        vm.serializeAddress(k, "escrow", escrow);
        string memory json = vm.serializeAddress(k, "pool", pool);
        vm.writeJson(json, string.concat("./deployments/", vm.toString(block.chainid), ".json"));
    }

    function _isLocalChain(uint256 chainId) internal pure returns (bool) {
        // anvil / hardhat defaults, plus anything the chain reports as not being a public network
        return chainId == 31337 || chainId == 1337 || chainId == 133701 || chainId == 11155111 ? false : true;
    }

    function _defaultUsdg(uint256 chainId) internal pure returns (address) {
        if (chainId == 42161) return USDG_ARBITRUM_ONE;
        if (chainId == 421614) return USDG_ARBITRUM_SEPOLIA;
        if (chainId == 4663) return USDG_ROBINHOOD_MAINNET;
        if (chainId == 46630) return USDG_ROBINHOOD_TESTNET;
        revert("Deploy: unknown chain, set USDG_ADDRESS");
    }
}
