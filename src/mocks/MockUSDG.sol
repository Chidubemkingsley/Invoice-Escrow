// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test/dev stand-in for Paxos USDG: 6 decimals, open mint, and a blocklist
///         so we can test the "issuer froze an address" failure mode. NEVER use in production.
contract MockUSDG is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Mock Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from] && !blocked[to], "MockUSDG: blocked");
        super._update(from, to, value);
    }
}
