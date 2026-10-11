// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {GlamToon} from "../../src/GlamToon.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, every reason a blue sale is refused
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonBlueGuardsSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonBlueGuardsSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev One proof per guard in _mintBlue, each asserting the exact error and
///      that the refusal moved no ether and no counter, then one proof that the
///      guards together are the whole condition: a sale settles exactly when
///      all of them pass.
contract GlamToonBlueGuardsSymbolicTest is DinoSatBase {
    // ════════════════════════════════════════════════
    //  SM-1: nothing sells before the sale opens
    // ════════════════════════════════════════════════

    /// @notice SM-1: before SALE_START a sale is refused with NotStarted, for
    ///         every character, amount and ceiling, and the buyer keeps its ether.
    /// @dev Technique: T12 state gating, on block.timestamp.
    /// @dev Classification: DIRECT
    function test_check_refuses_before_the_sale_opens(uint256 t, uint256 imageId, uint256 sent, uint256 maxPrice)
        public
    {
        // Justification: the branch under test, block.timestamp < SALE_START (GlamToon.sol:242)
        vm.assume(t < START);
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(sent <= MAX_ETHER);
        _refusesBeforeOpen(t, imageId, sent, maxPrice);
    }

    /// @notice Fuzz wrapper for test_check_refuses_before_the_sale_opens
    /// @dev See T17 in test-templates.md
    function test_fuzz_refuses_before_the_sale_opens(uint256 rawT, uint256 imageId, uint256 rawSent, uint256 maxPrice)
        public
    {
        _refusesBeforeOpen(bound(rawT, 0, START - 1), imageId, bound(rawSent, 0, MAX_ETHER), maxPrice);
    }

    function _refusesBeforeOpen(uint256 t, uint256 imageId, uint256 sent, uint256 maxPrice) private {
        vm.warp(t);

        (bool ok, bytes memory answer) = _tryMintBlue(ALICE, imageId, sent, maxPrice);

        assert(!ok);
        assert(_is(answer, GlamToon.NotStarted.selector));
        _nothingMoved(0, sent);
    }

    // ════════════════════════════════════════════════
    //  AS: no character outside the collection
    // ════════════════════════════════════════════════

    /// @notice SM-4: a character number of 10,000 or more is refused with
    ///         InvalidImageId, whatever is paid.
    /// @dev Technique: T3 guard.
    /// @dev Classification: DIRECT
    function test_check_refuses_an_unknown_character(uint256 imageId, uint256 sent, uint256 maxPrice) public {
        // Justification: the branch under test, imageId >= IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId >= N);
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(sent <= MAX_ETHER);
        _refusesUnknown(imageId, sent, maxPrice);
    }

    /// @notice Fuzz wrapper for test_check_refuses_an_unknown_character
    /// @dev See T17 in test-templates.md
    function test_fuzz_refuses_an_unknown_character(uint256 rawImage, uint256 rawSent, uint256 maxPrice) public {
        _refusesUnknown(bound(rawImage, N, type(uint256).max), bound(rawSent, 0, MAX_ETHER), maxPrice);
    }

    function _refusesUnknown(uint256 imageId, uint256 sent, uint256 maxPrice) private {
        (bool ok, bytes memory answer) = _tryMintBlue(ALICE, imageId, sent, maxPrice);

        assert(!ok);
        assert(_is(answer, GlamToon.InvalidImageId.selector));
        _nothingMoved(0, sent);
    }

    // ════════════════════════════════════════════════
    //  TOK-3: the supply cap
    // ════════════════════════════════════════════════

    /// @notice TOK-3: once ten thousand blues have sold, no character sells at
    ///         any amount or ceiling. The refusal is SoldOut for every value
    ///         the counter could hold at or past the supply.
    /// @dev Technique: T3 guard, the counter set with vm.store and read back.
    /// @dev Classification: DIRECT
    function test_check_refuses_when_sold_out(uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice) public {
        // Justification: an unknown character is refused earlier, with InvalidImageId (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: the branch under test, blueMinted >= BLUE_SUPPLY (GlamToon.sol:246)
        vm.assume(sold >= N);
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(sent <= MAX_ETHER);
        _refusesSoldOut(imageId, sold, sent, maxPrice);
    }

    /// @notice Fuzz wrapper for test_check_refuses_when_sold_out
    /// @dev See T17 in test-templates.md
    function test_fuzz_refuses_when_sold_out(uint256 rawImage, uint256 rawSold, uint256 rawSent, uint256 maxPrice)
        public
    {
        _refusesSoldOut(
            bound(rawImage, 0, N - 1), bound(rawSold, N, type(uint256).max), bound(rawSent, 0, MAX_ETHER), maxPrice
        );
    }

    function _refusesSoldOut(uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice) private {
        _setSold(sold);

        (bool ok, bytes memory answer) = _tryMintBlue(ALICE, imageId, sent, maxPrice);

        assert(!ok);
        assert(_is(answer, GlamToon.SoldOut.selector));
        _nothingMoved(sold, sent);
    }

    // ════════════════════════════════════════════════
    //  SM-1: one blue per character
    // ════════════════════════════════════════════════

    /// @notice SM-1: a character that has sold cannot be sold again, to any
    ///         account, at any amount or ceiling, and stays with its buyer.
    /// @dev Technique: T12 state gating, on the character's owner.
    /// @dev Classification: DIRECT
    function test_check_refuses_a_second_sale(address second, uint256 imageId, uint256 sent, uint256 maxPrice) public {
        // Justification: a buyer signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(second));
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(sent <= MAX_ETHER);
        _refusesSecondSale(second, imageId, sent, maxPrice);
    }

    /// @notice Fuzz wrapper for test_check_refuses_a_second_sale
    /// @dev See T17 in test-templates.md
    function test_fuzz_refuses_a_second_sale(address second, uint256 rawImage, uint256 rawSent, uint256 maxPrice)
        public
    {
        if (!_isAccount(second)) return;
        _refusesSecondSale(second, bound(rawImage, 0, N - 1), bound(rawSent, 0, MAX_ETHER), maxPrice);
    }

    function _refusesSecondSale(address second, uint256 imageId, uint256 sent, uint256 maxPrice) private {
        (bool first,) = _tryMintBlue(ALICE, imageId, STEP, STEP);
        assert(first);

        (bool ok, bytes memory answer) = _tryMintBlue(second, imageId, sent, maxPrice);

        assert(!ok);
        assert(_is(answer, GlamToon.BlueAlreadyTaken.selector));
        assert(nft.ownerOf(imageId) == ALICE);
        assert(nft.blueMinted() == 1);
        assert(address(nft).balance == STEP);
        assert(second.balance == sent);
    }

    // ════════════════════════════════════════════════
    //  FB-4: the buyer's ceiling
    // ════════════════════════════════════════════════

    /// @notice FB-4: a ceiling below the price refuses the sale with
    ///         PriceTooHigh, however much was sent. This is what protects a
    ///         buyer whose transaction lands after a price step.
    /// @dev Technique: T3 guard.
    /// @dev Classification: DIRECT
    function test_check_refuses_a_price_above_the_ceiling(uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice)
        public
    {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: _mintBlue reverts with SoldOut unless blueMinted < BLUE_SUPPLY (GlamToon.sol:246)
        vm.assume(sold < N);
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(sent <= MAX_ETHER);
        // Justification: the branch under test, price > maxPrice (GlamToon.sol:250)
        vm.assume(maxPrice < _schedule(sold));
        _refusesAboveCeiling(imageId, sold, sent, maxPrice);
    }

    /// @notice Fuzz wrapper for test_check_refuses_a_price_above_the_ceiling
    /// @dev See T17 in test-templates.md
    function test_fuzz_refuses_a_price_above_the_ceiling(
        uint256 rawImage,
        uint256 rawSold,
        uint256 rawSent,
        uint256 rawMax
    ) public {
        uint256 sold = bound(rawSold, 0, N - 1);
        _refusesAboveCeiling(
            bound(rawImage, 0, N - 1), sold, bound(rawSent, 0, MAX_ETHER), bound(rawMax, 0, _schedule(sold) - 1)
        );
    }

    function _refusesAboveCeiling(uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice) private {
        _setSold(sold);

        (bool ok, bytes memory answer) = _tryMintBlue(ALICE, imageId, sent, maxPrice);

        assert(!ok);
        assert(_is(answer, GlamToon.PriceTooHigh.selector));
        _nothingMoved(sold, sent);
    }

    // ════════════════════════════════════════════════
    //  FB-3: the price is a floor
    // ════════════════════════════════════════════════

    /// @notice FB-3: sending less than the price refuses the sale with
    ///         InsufficientPayment and returns everything. Nobody buys a blue
    ///         for less than its tier's price.
    /// @dev Technique: T3 guard.
    /// @dev Classification: DIRECT
    function test_check_refuses_underpayment(uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: _mintBlue reverts with SoldOut unless blueMinted < BLUE_SUPPLY (GlamToon.sol:246)
        vm.assume(sold < N);
        // Justification: a lower ceiling is the PriceTooHigh refusal, which comes first (GlamToon.sol:250)
        vm.assume(maxPrice >= _schedule(sold));
        // Justification: the branch under test, msg.value < price (GlamToon.sol:251)
        vm.assume(sent < _schedule(sold));
        _refusesUnderpayment(imageId, sold, sent, maxPrice);
    }

    /// @notice Fuzz wrapper for test_check_refuses_underpayment
    /// @dev See T17 in test-templates.md
    function test_fuzz_refuses_underpayment(uint256 rawImage, uint256 rawSold, uint256 rawSent, uint256 rawMax) public {
        uint256 sold = bound(rawSold, 0, N - 1);
        uint256 price = _schedule(sold);
        _refusesUnderpayment(
            bound(rawImage, 0, N - 1), sold, bound(rawSent, 0, price - 1), bound(rawMax, price, type(uint256).max)
        );
    }

    function _refusesUnderpayment(uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice) private {
        _setSold(sold);

        (bool ok, bytes memory answer) = _tryMintBlue(ALICE, imageId, sent, maxPrice);

        assert(!ok);
        assert(_is(answer, GlamToon.InsufficientPayment.selector));
        _nothingMoved(sold, sent);
    }

    // ════════════════════════════════════════════════
    //  The guards are the whole condition
    // ════════════════════════════════════════════════

    /// @notice SM-1/TOK-3/FB-3/FB-4: a sale of an unsold character to an account settles exactly when
    ///         every guard passes: the sale is open, the character exists, the
    ///         supply is not exhausted, the ceiling allows the price and the
    ///         price was sent. No other condition can refuse it and none of
    ///         these can be skipped.
    /// @dev Technique: T12 state gating, with every input left symbolic.
    /// @dev Classification: DIRECT
    function test_check_settles_exactly_when_every_guard_passes(
        uint256 t,
        uint256 imageId,
        uint256 sold,
        uint256 sent,
        uint256 maxPrice
    ) public {
        // Justification: block.timestamp is seconds; SALE_START itself is a uint64 (GlamToon.sol:133)
        vm.assume(t <= type(uint64).max);
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(sent <= MAX_ETHER);
        _settlesIff(t, imageId, sold, sent, maxPrice);
    }

    /// @notice Fuzz wrapper for test_check_settles_exactly_when_every_guard_passes
    /// @dev See T17 in test-templates.md
    function test_fuzz_settles_exactly_when_every_guard_passes(
        uint256 rawT,
        uint256 imageId,
        uint256 sold,
        uint256 rawSent,
        uint256 maxPrice
    ) public {
        _settlesIff(bound(rawT, 0, type(uint64).max), imageId, sold, bound(rawSent, 0, MAX_ETHER), maxPrice);
    }

    function _settlesIff(uint256 t, uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice) private {
        vm.warp(t);
        _setSold(sold);

        (bool ok,) = _tryMintBlue(ALICE, imageId, sent, maxPrice);

        bool open = t >= START;
        bool known = imageId < N;
        bool available = sold < N;
        bool affordable = available && maxPrice >= _schedule(sold) && sent >= _schedule(sold);
        assert(ok == (open && known && affordable));
    }

    // ════════════════════════════════════════════════
    //  The order of the reasons
    // ════════════════════════════════════════════════

    /// @notice SM-1/TOK-3/FB-3/FB-4: when more than one guard would refuse a
    ///         sale, the reason given is the first in a fixed order: not
    ///         started, unknown character, sold out, already taken, price above
    ///         the ceiling, underpaid. With none of them, the sale settles.
    ///         For every clock, character, sale count, amount and ceiling, and
    ///         for a character that is taken or free. The website tells a
    ///         buyer why a sale failed from this reason, and a sold out
    ///         collection has to say so rather than call each character taken.
    /// @dev Technique: T12 state gating, with every input left symbolic.
    /// @dev Classification: DIRECT
    function test_check_refusal_reason_follows_the_guard_order(
        uint256 t,
        uint256 imageId,
        uint256 sold,
        uint256 sent,
        uint256 maxPrice,
        bool taken
    ) public {
        // Justification: block.timestamp is seconds; SALE_START itself is a uint64 (GlamToon.sol:133)
        vm.assume(t <= type(uint64).max);
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(sent <= MAX_ETHER);
        _reasonFollowsOrder(t, imageId, sold, sent, maxPrice, taken);
    }

    /// @notice Fuzz wrapper for test_check_refusal_reason_follows_the_guard_order
    /// @dev See T17 in test-templates.md
    function test_fuzz_refusal_reason_follows_the_guard_order(
        uint256 rawT,
        uint256 imageId,
        uint256 sold,
        uint256 rawSent,
        uint256 maxPrice,
        bool taken
    ) public {
        _reasonFollowsOrder(
            bound(rawT, 0, type(uint64).max), imageId, sold, bound(rawSent, 0, MAX_ETHER), maxPrice, taken
        );
    }

    function _reasonFollowsOrder(uint256 t, uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice, bool taken)
        private
    {
        // a character can only be taken if it exists; Alice takes it while the sale is open
        bool isTaken = taken && imageId < N;
        if (isTaken) {
            (bool first,) = _tryMintBlue(ALICE, imageId, STEP, STEP);
            assert(first);
        }
        vm.warp(t);
        _setSold(sold);

        (bool ok, bytes memory answer) = _tryMintBlue(BOB, imageId, sent, maxPrice);

        bytes4 expected = _expectedReason(t, imageId, sold, sent, maxPrice, isTaken);
        if (expected == bytes4(0)) {
            assert(ok);
            assert(nft.ownerOf(imageId) == BOB);
        } else {
            assert(!ok);
            assert(_is(answer, expected));
            assert(BOB.balance == sent);
        }
    }

    /// The reason a sale is refused, in the order the guards are documented,
    /// or nothing when it should settle.
    function _expectedReason(uint256 t, uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice, bool isTaken)
        private
        pure
        returns (bytes4)
    {
        if (t < START) return GlamToon.NotStarted.selector;
        if (imageId >= N) return GlamToon.InvalidImageId.selector;
        if (sold >= N) return GlamToon.SoldOut.selector;
        if (isTaken) return GlamToon.BlueAlreadyTaken.selector;
        if (maxPrice < _schedule(sold)) return GlamToon.PriceTooHigh.selector;
        if (sent < _schedule(sold)) return GlamToon.InsufficientPayment.selector;
        return bytes4(0);
    }

    // ════════════════════════════════════════════════
    //  Helpers
    // ════════════════════════════════════════════════

    /// A refusal left the counter, the contract's balance and the buyer's
    /// ether exactly where they were.
    function _nothingMoved(uint256 sold, uint256 sent) private view {
        assert(nft.blueMinted() == sold);
        assert(address(nft).balance == 0);
        assert(ALICE.balance == sent);
    }
}
