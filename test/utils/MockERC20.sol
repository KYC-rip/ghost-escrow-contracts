// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mintable ERC20 with an optional fee-on-transfer mode (for
///      balance-delta crediting tests).
contract MockERC20 is ERC20 {
    uint8 private _decimals;
    uint256 public transferFeeBps; // 0 = off; 100 = 1%
    bool public feeOn;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeOnTransfer(uint256 bps) external {
        transferFeeBps = bps;
        feeOn = bps > 0;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (feeOn && from != address(0) && to != address(0)) {
            uint256 fee = (value * transferFeeBps) / 10_000;
            super._update(from, address(0), fee); // burn the fee
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
