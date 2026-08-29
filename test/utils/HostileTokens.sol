// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Deal token that re-enters a target on every transfer (once per arm),
///      to prove the ReentrancyGuard blocks nested state-changing calls.
///      Records whether the nested call succeeded so tests can assert it did NOT.
contract ReentrantToken is ERC20 {
    uint8 private _decimals;
    address public target;
    bytes public payload;
    bool public armed;
    bool public lastReentrySucceeded;
    bool public reentryAttempted;

    constructor(uint8 decimals_) ERC20("Reentrant", "REENT") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
        reentryAttempted = false;
        lastReentrySucceeded = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (armed && from != address(0) && to != address(0)) {
            armed = false; // disarm to avoid infinite recursion
            reentryAttempted = true;
            (bool ok,) = target.call(payload);
            lastReentrySucceeded = ok; // must be false if the guard works
        }
        super._update(from, to, value);
    }
}

/// @dev Non-compliant token that returns `false` from transfer/transferFrom
///      instead of reverting. SafeERC20 must catch this and revert, so the
///      escrow never credits a deposit that did not actually move funds.
contract FalseReturnToken is ERC20 {
    uint8 private _decimals;

    constructor(uint8 decimals_) ERC20("FalseReturn", "FALSE") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev USDT-style token whose transfer/transferFrom return NO data. SafeERC20
///      must treat an empty return from a successful call as success — the
///      escrow should work with such tokens (USDT is the canonical case).
contract NoReturnToken {
    string public name = "NoReturn";
    string public symbol = "NORET";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    // No return value on purpose (assembly return of nothing).
    function transfer(address to, uint256 amount) external {
        _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
