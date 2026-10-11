// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/// Tokens that do not follow the ERC20 return convention, the two kinds a
/// treasury that sweeps arbitrary tokens will meet sooner or later.

/// Moves balances but returns nothing from transfer, the way USDT does.
contract NoReturnToken {
    mapping(address account => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// Answers false from transfer and moves nothing.
contract FalseToken {
    mapping(address account => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}
