// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {GlamToon, ITraitData, ITraitNames} from "../../src/GlamToon.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — the whole path the money takes
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract SystemFlowSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract SystemFlowSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev GlamToon to Treasury to beneficiary, as one path across both
///      contracts. A sale's price reaches the beneficiary through a withdraw
///      and a sweep that anybody may push, the buyer keeps its change, and
///      nobody who pushed it keeps a wei.
contract SystemFlowSymbolicTest is DinoSatBase {
    // ════════════════════════════════════════════════
    //  CC-3: the takings reach the beneficiary
    // ════════════════════════════════════════════════

    /// @notice CC-3: for every character, point of the sale and amount sent,
    ///         the price ends up with the beneficiary and the change with the
    ///         buyer, whoever calls withdraw and whoever calls sweep, and
    ///         neither of them gains.
    /// @dev Technique: T14 conservation, across the sale, the withdraw and the sweep.
    /// @dev Classification: DIRECT
    function test_check_sale_proceeds_reach_the_beneficiary(
        uint256 imageId,
        uint256 sold,
        uint256 sent,
        address withdrawer,
        address sweeper
    ) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: _mintBlue reverts with SoldOut unless blueMinted < BLUE_SUPPLY (GlamToon.sol:246)
        vm.assume(sold < N);
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(sent <= MAX_ETHER);
        // Justification: below the price the sale reverts with InsufficientPayment (GlamToon.sol:251)
        vm.assume(sent >= _schedule(sold));
        // Justification: the two pushers are accounts other than the buyer and the beneficiary,
        // whose balances are meant to change
        vm.assume(_isBystander(withdrawer) && _isBystander(sweeper));
        _proceedsReach(imageId, sold, sent, withdrawer, sweeper);
    }

    /// @notice Fuzz wrapper for test_check_sale_proceeds_reach_the_beneficiary
    /// @dev See T17 in test-templates.md
    function test_fuzz_sale_proceeds_reach_the_beneficiary(
        uint256 rawImage,
        uint256 rawSold,
        uint256 rawSent,
        address withdrawer,
        address sweeper
    ) public {
        if (!_isBystander(withdrawer) || !_isBystander(sweeper)) return;
        uint256 sold = bound(rawSold, 0, N - 1);
        _proceedsReach(bound(rawImage, 0, N - 1), sold, bound(rawSent, _schedule(sold), MAX_ETHER), withdrawer, sweeper);
    }

    function _proceedsReach(uint256 imageId, uint256 sold, uint256 sent, address withdrawer, address sweeper) private {
        _setSold(sold);
        uint256 price = _schedule(sold);
        vm.deal(BENEFICIARY, 0);
        vm.deal(withdrawer, 0);
        vm.deal(sweeper, 0);

        (bool bought,) = _tryMintBlue(ALICE, imageId, sent, price);
        vm.prank(withdrawer);
        (bool withdrawn,) = address(nft).call(abi.encodeCall(nft.withdraw, ()));
        vm.prank(sweeper);
        (bool swept,) = address(treasury).call(abi.encodeCall(treasury.sweep, ()));

        assert(bought && withdrawn && swept);
        assert(BENEFICIARY.balance == price);
        assert(ALICE.balance == sent - price);
        assert(address(nft).balance == 0);
        assert(address(treasury).balance == 0);
        assert(withdrawer.balance == 0);
        assert(sweeper.balance == 0);
    }

    /// @notice CC-3: at every step of that path the buyer, the token, the
    ///         treasury and the beneficiary hold between them exactly what the
    ///         buyer started with. No step creates or loses a wei.
    /// @dev Technique: T14 conservation, checked after each of the three steps.
    /// @dev Classification: DIRECT
    function test_check_system_ether_is_conserved(uint256 imageId, uint256 sold, uint256 sent) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: _mintBlue reverts with SoldOut unless blueMinted < BLUE_SUPPLY (GlamToon.sol:246)
        vm.assume(sold < N);
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(sent <= MAX_ETHER);
        // Justification: below the price the sale reverts with InsufficientPayment (GlamToon.sol:251)
        vm.assume(sent >= _schedule(sold));
        _conserved(imageId, sold, sent);
    }

    /// @notice Fuzz wrapper for test_check_system_ether_is_conserved
    /// @dev See T17 in test-templates.md
    function test_fuzz_system_ether_is_conserved(uint256 rawImage, uint256 rawSold, uint256 rawSent) public {
        uint256 sold = bound(rawSold, 0, N - 1);
        _conserved(bound(rawImage, 0, N - 1), sold, bound(rawSent, _schedule(sold), MAX_ETHER));
    }

    function _conserved(uint256 imageId, uint256 sold, uint256 sent) private {
        _setSold(sold);
        vm.deal(BENEFICIARY, 0);

        (bool bought,) = _tryMintBlue(ALICE, imageId, sent, type(uint256).max);
        assert(bought);
        assert(_systemEther() == sent);

        (bool withdrawn,) = address(nft).call(abi.encodeCall(nft.withdraw, ()));
        assert(withdrawn);
        assert(_systemEther() == sent);

        (bool swept,) = address(treasury).call(abi.encodeCall(treasury.sweep, ()));
        assert(swept);
        assert(_systemEther() == sent);
    }

    /// @notice CC-3: once the owner repoints the treasury, the next sale's
    ///         price reaches the new beneficiary and the old one gets nothing.
    ///         The token itself was not touched to do it.
    /// @dev Technique: T14 conservation, across a change of beneficiary.
    /// @dev Classification: DIRECT
    function test_check_a_moved_beneficiary_receives_the_next_takings(address next, uint256 imageId) public {
        // Justification: a beneficiary with code runs on receipt; a plain account is the case proved here
        vm.assume(_isBystander(next));
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        _movedBeneficiary(next, imageId);
    }

    /// @notice Fuzz wrapper for test_check_a_moved_beneficiary_receives_the_next_takings
    /// @dev See T17 in test-templates.md
    function test_fuzz_a_moved_beneficiary_receives_the_next_takings(address next, uint256 rawImage) public {
        if (!_isBystander(next)) return;
        _movedBeneficiary(next, bound(rawImage, 0, N - 1));
    }

    function _movedBeneficiary(address next, uint256 imageId) private {
        vm.deal(BENEFICIARY, 0);
        vm.deal(next, 0);
        vm.prank(TREASURY_OWNER);
        (bool moved,) = address(treasury).call(abi.encodeCall(treasury.setBeneficiary, (next)));

        (bool bought,) = _tryMintBlue(ALICE, imageId, STEP, STEP);
        (bool withdrawn,) = address(nft).call(abi.encodeCall(nft.withdraw, ()));
        (bool swept,) = address(treasury).call(abi.encodeCall(treasury.sweep, ()));

        assert(moved && bought && withdrawn && swept);
        assert(next.balance == STEP);
        assert(BENEFICIARY.balance == 0);
        assert(nft.PAYOUT() == address(treasury));
    }

    // ════════════════════════════════════════════════
    //  AC-2: the treasury's owner is not on the path
    // ════════════════════════════════════════════════

    /// @notice AC-2: the treasury's owner pushing the money along itself gains
    ///         nothing by it. What the key controls is where sweeps go, not a
    ///         way to take them.
    /// @dev Technique: T14 conservation, with the owner as the caller of both steps.
    /// @dev Classification: DIRECT
    function test_check_treasury_owner_gains_nothing_by_pushing(uint256 imageId, uint256 sold) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: _mintBlue reverts with SoldOut unless blueMinted < BLUE_SUPPLY (GlamToon.sol:246)
        vm.assume(sold < N);
        _ownerGainsNothing(imageId, sold);
    }

    /// @notice Fuzz wrapper for test_check_treasury_owner_gains_nothing_by_pushing
    /// @dev See T17 in test-templates.md
    function test_fuzz_treasury_owner_gains_nothing_by_pushing(uint256 rawImage, uint256 rawSold) public {
        _ownerGainsNothing(bound(rawImage, 0, N - 1), bound(rawSold, 0, N - 1));
    }

    function _ownerGainsNothing(uint256 imageId, uint256 sold) private {
        _setSold(sold);
        uint256 price = _schedule(sold);
        vm.deal(BENEFICIARY, 0);
        vm.deal(TREASURY_OWNER, 0);
        (bool bought,) = _tryMintBlue(ALICE, imageId, price, price);

        vm.prank(TREASURY_OWNER);
        (bool withdrawn,) = address(nft).call(abi.encodeCall(nft.withdraw, ()));
        vm.prank(TREASURY_OWNER);
        (bool swept,) = address(treasury).call(abi.encodeCall(treasury.sweep, ()));

        assert(bought && withdrawn && swept);
        assert(TREASURY_OWNER.balance == 0);
        assert(BENEFICIARY.balance == price);
    }

    // ════════════════════════════════════════════════
    //  CC-3: the seed the deploy script sends
    // ════════════════════════════════════════════════

    /// @notice CC-3: what a deployment sends along reaches the beneficiary
    ///         through the treasury, the two hops the deploy script uses to
    ///         prove the treasury can be paid before anybody buys.
    /// @dev Technique: T14 conservation, across the constructor and a sweep.
    /// @dev Classification: DIRECT
    function test_check_a_deployment_seed_reaches_the_beneficiary(uint256 seed) public {
        // Justification: sweep reverts with NothingToSweep at zero (Treasury.sol:89); 2**128 wei is more than exists
        vm.assume(seed >= 1 && seed <= MAX_ETHER);
        _seedReaches(seed);
    }

    /// @notice Fuzz wrapper for test_check_a_deployment_seed_reaches_the_beneficiary
    /// @dev See T17 in test-templates.md
    function test_fuzz_a_deployment_seed_reaches_the_beneficiary(uint256 rawSeed) public {
        _seedReaches(bound(rawSeed, 1, MAX_ETHER));
    }

    function _seedReaches(uint256 seed) private {
        vm.deal(address(this), seed);
        vm.deal(BENEFICIARY, 0);

        try new GlamToon{value: seed}(
            ITraitData(address(chunk0)),
            ITraitData(address(chunk1)),
            ITraitNames(address(names)),
            address(treasury),
            START
        ) returns (
            GlamToon made
        ) {
            assert(address(made).balance == 0);
            assert(address(treasury).balance == seed);
        } catch {
            assert(false);
        }

        (bool swept,) = address(treasury).call(abi.encodeCall(treasury.sweep, ()));
        assert(swept);
        assert(BENEFICIARY.balance == seed);
        assert(address(treasury).balance == 0);
    }

    // ════════════════════════════════════════════════
    //  Helpers
    // ════════════════════════════════════════════════

    /// An account with no part in the sale: not the buyer, and not where the
    /// money is meant to end up.
    function _isBystander(address a) private view returns (bool) {
        return _isAccount(a) && a != ALICE && a != BENEFICIARY;
    }

    /// Everything the four parties to a sale hold between them.
    function _systemEther() private view returns (uint256) {
        return ALICE.balance + address(nft).balance + address(treasury).balance + BENEFICIARY.balance;
    }
}
