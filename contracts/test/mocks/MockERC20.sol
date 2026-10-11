// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";

/// Stands in for wrapped ether, which is how marketplaces settle offers and
/// therefore how royalties often arrive.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
