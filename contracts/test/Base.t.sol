// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {GlamToon, ITraitData, ITraitNames} from "../src/GlamToon.sol";
import {Treasury} from "../src/Treasury.sol";
import {TraitData0} from "../src/gen/TraitData0.sol";
import {TraitData1} from "../src/gen/TraitData1.sol";
import {TraitNames} from "../src/gen/TraitNames.sol";

/// Deploys the whole system in the order the deploy script does, so every test
/// runs against the real wiring rather than a stand in: two trait chunks, the
/// name table, a treasury, and the token contract that checks the hash each of
/// the three data contracts reports before pinning them forever. Unlike the
/// script it sends no seed wei and runs no proof sweep, so the treasury starts
/// empty.
abstract contract BaseTest is Test {
    TraitData0 internal chunk0;
    TraitData1 internal chunk1;
    TraitNames internal names;
    Treasury internal treasury;
    GlamToon internal nft;

    address internal treasuryOwner = vm.addr(0xC0);
    address internal beneficiary = vm.addr(0xBE);
    address internal alice = vm.addr(0xA1);
    address internal bob = vm.addr(0xB0);
    address internal carol = vm.addr(0xCA);

    uint64 internal constant SALE_START = 1_700_000_000;

    uint256 internal constant BLUE_SUPPLY = 10_000;
    uint256 internal constant TIER_SIZE = 2500;
    uint256 internal constant PRICE_STEP = 0.01 ether;

    function setUp() public virtual {
        vm.warp(SALE_START);

        chunk0 = new TraitData0();
        chunk1 = new TraitData1();
        names = new TraitNames();

        treasury = new Treasury(treasuryOwner, beneficiary);
        nft = new GlamToon(
            ITraitData(address(chunk0)),
            ITraitData(address(chunk1)),
            ITraitNames(address(names)),
            address(treasury),
            SALE_START
        );

        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 10_000 ether);
        vm.deal(carol, 10_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// Coverage reruns everything on an instrumented build where gas is many
    /// times what it costs in production and the heaviest sweeps run out of it.
    /// A gas assertion there says nothing about the contract, so it stands
    /// aside rather than reporting a failure.
    function _skipUnderCoverage() internal {
        vm.skip(vm.isContext(VmSafe.ForgeContext.Coverage));
    }

    /// The price the contract would charge right now.
    function _price() internal view returns (uint256) {
        return nft.currentPrice();
    }

    /// The price after `sold` genesis tokens, computed independently of the
    /// contract so a test can catch the contract drifting from the stated rule.
    function _expectedPrice(uint256 sold) internal pure returns (uint256) {
        return PRICE_STEP * (1 + sold / TIER_SIZE);
    }

    /// Buy one blue token at whatever it currently costs.
    function _buy(address who, uint256 imageId) internal returns (uint256 paid) {
        paid = nft.currentPrice();
        vm.prank(who);
        nft.mintBlue{value: paid}(imageId, paid);
    }

    /// Take the next green generation of a character.
    function _green(address who, uint256 imageId) internal returns (uint256 tokenId) {
        vm.prank(who);
        nft.mintGreen(imageId);
        tokenId = nft.tokenIdFor(imageId, nft.greenCount(imageId));
    }

    /// Sell `count` blue tokens starting at image 0, so a test can walk the
    /// price up to a tier boundary without repeating itself.
    function _sell(uint256 count) internal {
        for (uint256 i = 0; i < count; ++i) {
            _buy(alice, i);
        }
    }

    /// Accept tokens, so the test contract itself can hold them.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
