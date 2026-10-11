// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {GlamToon, ITraitData, ITraitNames} from "../../src/GlamToon.sol";
import {Treasury} from "../../src/Treasury.sol";
import {TraitData0} from "../../src/gen/TraitData0.sol";
import {TraitData1} from "../../src/gen/TraitData1.sol";
import {TraitNames} from "../../src/gen/TraitNames.sol";

/// Run: FOUNDRY_PROFILE=halmos halmos --contract DeploymentSymbolicTest --function check_ \
///        --forge-build-out out-halmos --solver-timeout-assertion 240000
///
/// Symbolic only. check_ rather than test_ so forge leaves these alone.
///
/// The token and the treasury together, wired the way script/Deploy.s.sol
/// wires them, with the treasury as the payee. What the token hands to the
/// treasury is the label marketplaces read, the royalty, and the takings, and
/// each is proved here for every caller and every amount.
///
/// The script's one wei seed and its sweep are not repeated in setUp, where
/// they would run once for one caller and one amount. DP-3 drives the same two
/// hops as a proof instead, for every caller and every amount.
contract DeploymentSymbolicTest is Test {
    GlamToon internal nft;
    Treasury internal treasury;

    address internal treasuryOwner = address(0x0117E4);
    address internal beneficiary = address(0xB0B);
    uint64 internal constant START = 1000;

    function setUp() public {
        vm.warp(START);
        treasury = new Treasury(treasuryOwner, beneficiary);
        nft = new GlamToon(
            ITraitData(address(new TraitData0())),
            ITraitData(address(new TraitData1())),
            ITraitNames(address(new TraitNames())),
            address(treasury),
            START
        );
    }

    /// DP-1: the label marketplaces read is the treasury's owner. It stays put
    /// while a handover is only offered, and moves when the new owner accepts,
    /// whoever that is.
    function check_the_label_follows_the_treasury_owner(address next) public {
        vm.assume(next != address(0) && next != treasuryOwner);

        assert(nft.owner() == treasuryOwner);
        assert(nft.owner() == treasury.owner());

        vm.prank(treasuryOwner);
        (bool offered,) = address(treasury).call(abi.encodeCall(treasury.transferOwnership, (next)));

        assert(offered);
        assert(treasury.pendingOwner() == next);
        assert(nft.owner() == treasuryOwner);

        vm.prank(next);
        (bool accepted,) = address(treasury).call(abi.encodeCall(treasury.acceptOwnership, ()));

        assert(accepted);
        assert(treasury.owner() == next);
        assert(nft.owner() == next);
    }

    /// DP-2: the royalty is two percent of any sale price, paid to the treasury,
    /// for every token id whether it exists or not. Prices are bounded so the
    /// product stays inside a word, far above anything a sale could be.
    function check_the_royalty_is_two_percent_to_the_treasury(uint256 tokenId, uint256 salePrice) public view {
        vm.assume(salePrice < 2 ** 200);

        (address receiver, uint256 amount) = nft.royaltyInfo(tokenId, salePrice);

        assert(receiver == address(treasury));
        assert(amount == salePrice * 200 / 10_000);
    }

    /// DP-3: the takings reach the beneficiary through the treasury, whoever
    /// pushes them along. A withdraw lands the whole balance in the treasury,
    /// a sweep carries it on, and neither caller keeps a wei of it.
    function check_takings_reach_the_beneficiary_through_the_treasury(
        address withdrawer,
        address sweeper,
        uint256 takings
    ) public {
        vm.assume(withdrawer != address(nft) && withdrawer != address(treasury) && withdrawer != beneficiary);
        vm.assume(sweeper != address(nft) && sweeper != address(treasury) && sweeper != beneficiary);
        vm.assume(takings > 0 && takings < 2 ** 128);

        vm.deal(address(nft), takings);
        uint256 withdrawerBefore = withdrawer.balance;
        uint256 sweeperBefore = sweeper.balance;
        uint256 beneficiaryBefore = beneficiary.balance;

        vm.prank(withdrawer);
        (bool withdrawn,) = address(nft).call(abi.encodeCall(nft.withdraw, ()));

        assert(withdrawn);
        assert(address(nft).balance == 0);
        assert(address(treasury).balance == takings);

        vm.prank(sweeper);
        (bool swept,) = address(treasury).call(abi.encodeCall(treasury.sweep, ()));

        assert(swept);
        assert(address(treasury).balance == 0);
        assert(beneficiary.balance == beneficiaryBefore + takings);
        assert(withdrawer.balance == withdrawerBefore);
        assert(sweeper.balance == sweeperBefore);
    }
}
