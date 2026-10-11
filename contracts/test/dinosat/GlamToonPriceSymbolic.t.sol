// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {GlamToon} from "../../src/GlamToon.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, the price the contract quotes
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonPriceSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonPriceSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev The deployed priceAt and currentPrice against the published schedule,
///      written out band by band so the proofs do not share the contract's
///      arithmetic. PriceLemmasTest proves the arithmetic on its own.
contract GlamToonPriceSymbolicTest is DinoSatBase {
    // ════════════════════════════════════════════════
    //  The constants the lemma contracts assume
    // ════════════════════════════════════════════════

    /// @notice FB-3: the constants the pure lemma contracts restate are the ones the
    ///         deployed contract reports.
    /// @dev Technique: T2 constant bound, over constants.
    /// @dev Classification: DIRECT
    function test_check_price_constants_match_the_lemmas() public view {
        assert(nft.IMAGE_COUNT() == N);
        assert(nft.BLUE_SUPPLY() == N);
        assert(nft.TIER_SIZE() == TIER);
        assert(nft.PRICE_STEP() == STEP);
        assert(nft.ROYALTY_BPS() == 200);
        assert(nft.blueBitmapWords() == WORDS);
        assert(nft.SALE_START() == START);
        assert(nft.PAYOUT() == address(treasury));
    }

    // ════════════════════════════════════════════════
    //  FB-3: the quoted price is the schedule
    // ════════════════════════════════════════════════

    /// @notice FB-3: priceAt answers the published schedule for every number of
    ///         sales short of the sellout, and never reverts there.
    /// @dev Technique: T16 stateful, against the deployed function.
    /// @dev Classification: DIRECT
    function test_check_priceAt_matches_schedule(uint256 sold) public view {
        // Justification: priceAt reverts with SoldOut unless sold < BLUE_SUPPLY (GlamToon.sol:328)
        vm.assume(sold < N);
        _priceAtMatches(sold);
    }

    /// @notice Fuzz wrapper for test_check_priceAt_matches_schedule
    /// @dev See T17 in test-templates.md
    function test_fuzz_priceAt_matches_schedule(uint256 rawSold) public view {
        _priceAtMatches(bound(rawSold, 0, N - 1));
    }

    function _priceAtMatches(uint256 sold) private view {
        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.priceAt, (sold)));
        assert(ok);
        assert(abi.decode(answer, (uint256)) == _schedule(sold));
    }

    // ════════════════════════════════════════════════
    //  TOK-3: there is no price past the sellout
    // ════════════════════════════════════════════════

    /// @notice TOK-3: from the ten thousandth sale on, priceAt refuses with
    ///         SoldOut, for every count a word can hold.
    /// @dev Technique: T3 guard, the outcome asserted rather than expected.
    /// @dev Classification: DIRECT
    function test_check_priceAt_refuses_once_sold_out(uint256 sold) public view {
        // Justification: the branch under test, sold >= BLUE_SUPPLY (GlamToon.sol:328)
        vm.assume(sold >= N);
        _priceAtRefuses(sold);
    }

    /// @notice Fuzz wrapper for test_check_priceAt_refuses_once_sold_out
    /// @dev See T17 in test-templates.md
    function test_fuzz_priceAt_refuses_once_sold_out(uint256 rawSold) public view {
        _priceAtRefuses(bound(rawSold, N, type(uint256).max));
    }

    function _priceAtRefuses(uint256 sold) private view {
        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.priceAt, (sold)));
        assert(!ok);
        assert(_is(answer, GlamToon.SoldOut.selector));
    }

    // ════════════════════════════════════════════════
    //  SM-5: the current price follows the sales counter
    // ════════════════════════════════════════════════

    /// @notice SM-5: currentPrice is the schedule at blueMinted, and refuses
    ///         with SoldOut once that reaches the supply. For every value the
    ///         counter's slot can hold.
    /// @dev Technique: T16 stateful, the counter set with vm.store and read back.
    /// @dev Classification: DIRECT
    function test_check_currentPrice_follows_the_sales_counter(uint256 sold) public {
        _setSold(sold);

        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.currentPrice, ()));

        if (sold < N) {
            assert(ok);
            assert(abi.decode(answer, (uint256)) == _schedule(sold));
        } else {
            assert(!ok);
            assert(_is(answer, GlamToon.SoldOut.selector));
        }
    }

    /// @notice SM-5: a sale moves the quoted price to the next point of the
    ///         schedule, which is the same price or one step more, never less.
    /// @dev Technique: T12 state gating, across a real sale.
    /// @dev Classification: DIRECT
    function test_check_a_sale_moves_the_price_along_the_schedule(uint256 imageId, uint256 sold) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: a price must still exist after the sale, so sold + 1 < BLUE_SUPPLY (GlamToon.sol:328)
        vm.assume(sold < N - 1);
        _saleMovesPrice(imageId, sold);
    }

    /// @notice Fuzz wrapper for test_check_a_sale_moves_the_price_along_the_schedule
    /// @dev See T17 in test-templates.md
    function test_fuzz_a_sale_moves_the_price_along_the_schedule(uint256 rawImage, uint256 rawSold) public {
        _saleMovesPrice(bound(rawImage, 0, N - 1), bound(rawSold, 0, N - 2));
    }

    function _saleMovesPrice(uint256 imageId, uint256 sold) private {
        _setSold(sold);
        uint256 before = _schedule(sold);

        (bool ok,) = _tryMintBlue(ALICE, imageId, before, before);
        assert(ok);

        (bool quoted, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.currentPrice, ()));
        assert(quoted);
        uint256 afterwards = abi.decode(answer, (uint256));
        assert(afterwards == _schedule(sold + 1));
        assert(afterwards == before || afterwards == before + STEP);
    }
}
