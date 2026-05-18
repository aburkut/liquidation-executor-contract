// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Mimics USDT's approval quirk: `approve(spender, amount)` reverts
/// when called with a non-zero amount while an existing non-zero
/// allowance is set. Forces callers into the
/// `approve(0) → approve(amount)` reset pattern.
///
/// Used to verify that CurveV1Lib / BalancerV2Lib's `forceApprove`
/// flow tolerates Tether-style tokens (`forceApprove` internally
/// resets to zero before setting the new value).
contract MockTetherStyleERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @dev Tether quirk: revert when both the current allowance AND
    /// the requested amount are non-zero. Forces zero-reset pattern.
    function approve(address spender, uint256 amount) external returns (bool) {
        require(amount == 0 || allowance[msg.sender][spender] == 0, "USDT: approve nonzero with nonzero allowance");
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "USDT: insufficient balance");
        unchecked {
            balanceOf[msg.sender] -= amount;
        }
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "USDT: insufficient balance");
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "USDT: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        unchecked {
            balanceOf[from] -= amount;
        }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
