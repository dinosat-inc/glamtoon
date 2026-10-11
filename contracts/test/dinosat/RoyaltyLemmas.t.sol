// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

/// @title DinoSAT Proofs — the royalty, as arithmetic
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract RoyaltyLemmasTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract RoyaltyLemmasTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev Pure lemmas over the expression ERC2981.royaltyInfo evaluates with the
///      royalty GlamToon's constructor sets. GlamToonRoyaltySymbolicTest proves
///      the deployed function returns this expression.
contract RoyaltyLemmasTest is Test {
    /// GlamToon.ROYALTY_BPS and ERC2981._feeDenominator.
    uint256 constant BPS = 200;
    uint256 constant DENOMINATOR = 10_000;

    /// The highest sale price the lemmas range over: a billion ether, several
    /// times all the ether there is.
    uint256 constant MAX_PRICE = 1e27;

    // ════════════════════════════════════════════════
    //  Abstract specification helpers
    // ════════════════════════════════════════════════

    /// @dev Abstract spec of ERC2981.royaltyInfo's amount: the same expression
    ///      in the same order. There is no mulDiv to inline. Valid for
    ///      salePrice <= 1e27: the product is at most 2e29, far below uint256.max.
    function _royalty(uint256 salePrice) private pure returns (uint256) {
        return (salePrice * BPS) / DENOMINATOR;
    }

    // ════════════════════════════════════════════════
    //  FB-1 / FB-2: the royalty is a small part of the price
    // ════════════════════════════════════════════════

    /// @notice FB-1: the royalty is never more than the sale price.
    /// @dev Technique: T2 constant bound.
    /// @dev Classification: DIRECT
    function test_check_lemma_royalty_never_exceeds_price(uint256 salePrice) public pure {
        // Justification: a sale price in wei; 1e27 is a billion ether, more than exists
        vm.assume(salePrice <= MAX_PRICE);
        assert(_royalty(salePrice) <= salePrice);
    }

    /// @notice Fuzz wrapper for test_check_lemma_royalty_never_exceeds_price
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_royalty_never_exceeds_price(uint256 rawPrice) public pure {
        uint256 salePrice = bound(rawPrice, 0, MAX_PRICE);
        assert(_royalty(salePrice) <= salePrice);
    }

    /// @notice FB-2: the rate is two percent, below the whole.
    /// @dev Technique: T2 constant bound, over constants.
    /// @dev Classification: DIRECT
    function test_check_lemma_royalty_rate_is_below_one() public pure {
        assert(BPS < DENOMINATOR);
        assert(BPS * 50 == DENOMINATOR);
    }

    /// @notice PD-2: below fifty wei the royalty rounds down to nothing, so
    ///         rounding only ever favours the payer.
    /// @dev Technique: T6 floor division, on a domain small enough to enumerate.
    /// @dev Classification: DIRECT
    function test_check_lemma_royalty_rounds_to_zero_below_fifty_wei(uint256 salePrice) public pure {
        // Justification: fifty wei is the first price at which two percent is a whole wei
        vm.assume(salePrice < 50);
        assert(_royalty(salePrice) == 0);
    }

    /// @notice Fuzz wrapper for test_check_lemma_royalty_rounds_to_zero_below_fifty_wei
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_royalty_rounds_to_zero_below_fifty_wei(uint256 rawPrice) public pure {
        assert(_royalty(bound(rawPrice, 0, 49)) == 0);
    }

    // ════════════════════════════════════════════════
    //  AS-1: the product fits
    // ════════════════════════════════════════════════

    /// @notice AS-1: the price times the rate cannot wrap. Written in wrapping
    ///         arithmetic, so a product that wrapped would fail the bound.
    /// @dev Technique: T2 constant bound.
    /// @dev Classification: DIRECT
    function test_check_lemma_royalty_product_fits(uint256 salePrice) public pure {
        // Justification: a sale price in wei; 1e27 is a billion ether, more than exists
        vm.assume(salePrice <= MAX_PRICE);
        _productFits(salePrice);
    }

    /// @notice Fuzz wrapper for test_check_lemma_royalty_product_fits
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_royalty_product_fits(uint256 rawPrice) public pure {
        _productFits(bound(rawPrice, 0, MAX_PRICE));
    }

    function _productFits(uint256 salePrice) private pure {
        uint256 product;
        unchecked {
            product = salePrice * BPS;
        }
        assert(product >= salePrice);
        assert(product <= MAX_PRICE * BPS);
    }

    // ════════════════════════════════════════════════
    //  PD-3 / FB-5: the amount is exactly two percent, rounded down
    //  Division by ten thousand of a wide symbolic product. Measured: the
    //  solver does not settle these within its timeout, or twice it, at any
    //  useful bound, so they are fuzz verified.
    // ════════════════════════════════════════════════

    /// @notice PD-3: the royalty is the floor of two percent. Ten thousand
    ///         royalties never exceed two hundred prices, and fall short by
    ///         less than ten thousand.
    /// @dev Technique: T6 floor division identity.
    /// @dev Classification: FUZZ
    function test_check_lemma_royalty_floor_identity(uint256 salePrice) public pure {
        // Justification: a sale price in wei; 1e27 is a billion ether, more than exists
        vm.assume(salePrice <= MAX_PRICE);
        _floorIdentity(salePrice);
    }

    /// @notice Fuzz wrapper for test_check_lemma_royalty_floor_identity
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_royalty_floor_identity(uint256 rawPrice) public pure {
        _floorIdentity(bound(rawPrice, 0, MAX_PRICE));
    }

    function _floorIdentity(uint256 salePrice) private pure {
        uint256 royalty = _royalty(salePrice);
        assert(royalty * DENOMINATOR <= salePrice * BPS);
        assert(salePrice * BPS - royalty * DENOMINATOR < DENOMINATOR);
    }

    /// @notice PD-3: two percent is one fiftieth, the same amount by a smaller
    ///         divisor.
    /// @dev Technique: T6 floor division identity.
    /// @dev Classification: FUZZ
    function test_check_lemma_royalty_is_one_fiftieth(uint256 salePrice) public pure {
        // Justification: a sale price in wei; 1e27 is a billion ether, more than exists
        vm.assume(salePrice <= MAX_PRICE);
        assert(_royalty(salePrice) == salePrice / 50);
    }

    /// @notice Fuzz wrapper for test_check_lemma_royalty_is_one_fiftieth
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_royalty_is_one_fiftieth(uint256 rawPrice) public pure {
        uint256 salePrice = bound(rawPrice, 0, MAX_PRICE);
        assert(_royalty(salePrice) == salePrice / 50);
    }

    /// @notice FB-5: a higher sale price never pays a lower royalty.
    /// @dev Technique: T11 monotonicity, floor division is non-decreasing in
    ///      its numerator.
    /// @dev Classification: FUZZ
    function test_check_lemma_royalty_monotonic(uint256 lower, uint256 higher) public pure {
        // Justification: sale prices in wei; 1e27 is a billion ether, more than exists
        vm.assume(higher <= MAX_PRICE);
        // Justification: the lemma compares a lower price with a higher one
        vm.assume(lower <= higher);
        assert(_royalty(lower) <= _royalty(higher));
    }

    /// @notice Fuzz wrapper for test_check_lemma_royalty_monotonic
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_royalty_monotonic(uint256 rawLower, uint256 rawHigher) public pure {
        uint256 higher = bound(rawHigher, 0, MAX_PRICE);
        uint256 lower = bound(rawLower, 0, higher);
        assert(_royalty(lower) <= _royalty(higher));
    }
}
