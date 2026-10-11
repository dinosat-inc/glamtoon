// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";

/// The price curve: a hundredth of an ether, stepping up by that again every two
/// and a half thousand sold. Four tiers, and the fifth must not exist.
contract PricingTest is BaseTest {
    function test_startsAtOneHundredth() public view {
        assertEq(nft.currentPrice(), 0.01 ether, "opening price");
    }

    function test_everyTierBoundary() public pure {
        uint256[8] memory sold = [uint256(0), 2499, 2500, 4999, 5000, 7499, 7500, 9999];
        uint256[8] memory want =
            [uint256(0.01 ether), 0.01 ether, 0.02 ether, 0.02 ether, 0.03 ether, 0.03 ether, 0.04 ether, 0.04 ether];
        for (uint256 i = 0; i < sold.length; ++i) {
            assertEq(_expectedPrice(sold[i]), want[i], "tier table");
        }
    }

    function test_contractAgreesWithTheStatedRule() public view {
        uint256[8] memory sold = [uint256(0), 2499, 2500, 4999, 5000, 7499, 7500, 9999];
        for (uint256 i = 0; i < sold.length; ++i) {
            assertEq(nft.priceAt(sold[i]), _expectedPrice(sold[i]), "contract vs rule");
        }
    }

    function testFuzz_matchesTheStatedRule(uint256 sold) public view {
        sold = bound(sold, 0, BLUE_SUPPLY - 1);
        assertEq(nft.priceAt(sold), _expectedPrice(sold), "price formula");
    }

    function testFuzz_neverBelowFloorNorAboveCeiling(uint256 sold) public view {
        sold = bound(sold, 0, BLUE_SUPPLY - 1);
        uint256 price = nft.priceAt(sold);
        assertGe(price, 0.01 ether, "never below the opening price");
        assertLe(price, 0.04 ether, "never above the last tier");
    }

    function testFuzz_neverFalls(uint256 sold) public view {
        sold = bound(sold, 0, BLUE_SUPPLY - 2);
        assertGe(nft.priceAt(sold + 1), nft.priceAt(sold), "price must not fall");
    }

    function test_soldOutHasNoPrice() public {
        // The tier past the end would read 0.05 ether. No token is ever charged it
        // and no interface should ever show it.
        vm.expectRevert(GlamToon.SoldOut.selector);
        nft.priceAt(BLUE_SUPPLY);
    }

    function test_priceStepsUpAcrossTheFirstBoundary() public {
        _sell(2499);
        assertEq(nft.currentPrice(), 0.01 ether, "still tier one at 2499 sold");
        _buy(alice, 2500);
        assertEq(nft.blueMinted(), 2500, "two and a half thousand sold");
        assertEq(nft.currentPrice(), 0.02 ether, "tier two");
    }

    /// The whole sale, one token at a time, checking every single price against
    /// the rule and totalling what the collection takes.
    function test_fullSellOutTakesTwoHundredAndFifty() public {
        uint256 total;
        for (uint256 id = 0; id < BLUE_SUPPLY; ++id) {
            uint256 price = nft.currentPrice();
            assertEq(price, _expectedPrice(id), "price at each step");
            vm.prank(alice);
            nft.mintBlue{value: price}(id, price);
            total += price;
        }

        assertEq(nft.blueMinted(), BLUE_SUPPLY, "all sold");
        assertEq(total, 250 ether, "total raised");
        assertEq(address(nft).balance, 250 ether, "all of it held");

        vm.expectRevert(GlamToon.SoldOut.selector);
        nft.currentPrice();
    }

    /// The permanent terminal state of the sale. currentPrice reverting was
    /// covered; a mint after sellout was not, and that is the branch a buyer
    /// actually reaches.
    function test_mintAfterSellOutReverts() public {
        for (uint256 id = 0; id < BLUE_SUPPLY; ++id) {
            uint256 price = nft.currentPrice();
            vm.prank(alice);
            nft.mintBlue{value: price}(id, price);
        }

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(GlamToon.SoldOut.selector);
        nft.mintBlue{value: 0.04 ether}(0, type(uint256).max);
    }
}
