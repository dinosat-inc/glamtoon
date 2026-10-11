// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

/// @title DinoSAT Proofs — the blue price schedule, as arithmetic
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract PriceLemmasTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract PriceLemmasTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev Pure lemmas over the expression GlamToon.priceAt evaluates. Nothing is
///      deployed here. GlamToonPriceSymbolicTest pins these constants to the
///      contract's and proves the deployed function agrees with the schedule.
contract PriceLemmasTest is Test {
    /// GlamToon.BLUE_SUPPLY, GlamToon.TIER_SIZE and GlamToon.PRICE_STEP.
    uint256 constant N = 10_000;
    uint256 constant TIER = 2500;
    uint256 constant STEP = 0.01 ether;

    /// More ether than has ever existed, and far below a word.
    uint256 constant MAX_ETHER = 2 ** 128 - 1;

    // ════════════════════════════════════════════════
    //  Abstract specification helpers
    // ════════════════════════════════════════════════

    /// @dev Abstract spec of GlamToon.priceAt past its sold out check: the same
    ///      expression in the same order. There is no mulDiv to inline. The
    ///      largest product is PRICE_STEP * 4 = 4e16, far below uint256.max.
    function _priceAt(uint256 sold) private pure returns (uint256) {
        return STEP * (1 + sold / TIER);
    }

    // ════════════════════════════════════════════════
    //  AS-1: the tier index stays small
    // ════════════════════════════════════════════════

    /// @notice AS-1: below the sellout the tier index is 0 to 3, so the
    ///         multiplier is at most 4 and the product cannot overflow.
    /// @dev Technique: T2 constant bound.
    /// @dev Classification: DIRECT
    function test_check_lemma_tier_index_bounded(uint256 sold) public pure {
        // Justification: priceAt reverts with SoldOut unless sold < BLUE_SUPPLY (GlamToon.sol:328)
        vm.assume(sold < N);
        _tierIndexBounded(sold);
    }

    /// @notice Fuzz wrapper for test_check_lemma_tier_index_bounded
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_tier_index_bounded(uint256 rawSold) public pure {
        _tierIndexBounded(bound(rawSold, 0, N - 1));
    }

    function _tierIndexBounded(uint256 sold) private pure {
        assert(sold / TIER <= 3);
        assert(1 + sold / TIER <= 4);
    }

    // ════════════════════════════════════════════════
    //  FB-3 / FB-4: the price of each tier
    // ════════════════════════════════════════════════

    /// @notice FB-3/FB-4, branch 0: the first 2,500 blues cost 0.01 ether.
    /// @dev Technique: T4 per-branch theorem, the branch chosen by vm.assume.
    /// @dev Classification: DECOMPOSE
    function test_check_theorem_price_tier0(uint256 sold) public pure {
        // Justification: tier 0 is sales 0 to 2499, TIER_SIZE from GlamToon.sol:98
        vm.assume(sold < TIER);
        assert(_priceAt(sold) == 0.01 ether);
    }

    /// @notice Fuzz wrapper for test_check_theorem_price_tier0
    /// @dev See T17 in test-templates.md
    function test_fuzz_theorem_price_tier0(uint256 rawSold) public pure {
        assert(_priceAt(bound(rawSold, 0, TIER - 1)) == 0.01 ether);
    }

    /// @notice FB-3/FB-4, branch 1: sales 2,500 to 4,999 cost 0.02 ether.
    /// @dev Technique: T4 per-branch theorem.
    /// @dev Classification: DECOMPOSE
    function test_check_theorem_price_tier1(uint256 sold) public pure {
        // Justification: tier 1 is sales 2500 to 4999, TIER_SIZE from GlamToon.sol:98
        vm.assume(sold >= TIER && sold < 2 * TIER);
        assert(_priceAt(sold) == 0.02 ether);
    }

    /// @notice Fuzz wrapper for test_check_theorem_price_tier1
    /// @dev See T17 in test-templates.md
    function test_fuzz_theorem_price_tier1(uint256 rawSold) public pure {
        assert(_priceAt(bound(rawSold, TIER, 2 * TIER - 1)) == 0.02 ether);
    }

    /// @notice FB-3/FB-4, branch 2: sales 5,000 to 7,499 cost 0.03 ether.
    /// @dev Technique: T4 per-branch theorem.
    /// @dev Classification: DECOMPOSE
    function test_check_theorem_price_tier2(uint256 sold) public pure {
        // Justification: tier 2 is sales 5000 to 7499, TIER_SIZE from GlamToon.sol:98
        vm.assume(sold >= 2 * TIER && sold < 3 * TIER);
        assert(_priceAt(sold) == 0.03 ether);
    }

    /// @notice Fuzz wrapper for test_check_theorem_price_tier2
    /// @dev See T17 in test-templates.md
    function test_fuzz_theorem_price_tier2(uint256 rawSold) public pure {
        assert(_priceAt(bound(rawSold, 2 * TIER, 3 * TIER - 1)) == 0.03 ether);
    }

    /// @notice FB-3/FB-4, branch 3: sales 7,500 to 9,999 cost 0.04 ether.
    /// @dev Technique: T4 per-branch theorem.
    /// @dev Classification: DECOMPOSE
    function test_check_theorem_price_tier3(uint256 sold) public pure {
        // Justification: tier 3 is sales 7500 to 9999, the last before SoldOut (GlamToon.sol:328)
        vm.assume(sold >= 3 * TIER && sold < N);
        assert(_priceAt(sold) == 0.04 ether);
    }

    /// @notice Fuzz wrapper for test_check_theorem_price_tier3
    /// @dev See T17 in test-templates.md
    function test_fuzz_theorem_price_tier3(uint256 rawSold) public pure {
        assert(_priceAt(bound(rawSold, 3 * TIER, N - 1)) == 0.04 ether);
    }

    // ════════════════════════════════════════════════
    //  COMPOSITION: the price is the published schedule at every point of the sale
    //  Branch 0: sold in [0, 2499]     → 0.01 ether
    //  Branch 1: sold in [2500, 4999]  → 0.02 ether
    //  Branch 2: sold in [5000, 7499]  → 0.03 ether
    //  Branch 3: sold in [7500, 9999]  → 0.04 ether
    //  Partition: the four ranges are disjoint and their union is [0, 9999],
    //  every value priceAt accepts. Exhaustive.
    //  Depends on: Lemma tier_index_bounded (the multiplier is 1 to 4).
    //  Status: Branch 0 [PASS], Branch 1 [PASS], Branch 2 [PASS], Branch 3 [PASS]. QED.
    // ════════════════════════════════════════════════

    // ════════════════════════════════════════════════
    //  FB-3 / FB-4: the price never leaves its range
    // ════════════════════════════════════════════════

    /// @notice FB-3/FB-4: no blue costs less than 0.01 ether or more than 0.04.
    /// @dev Technique: T2 constant bound.
    /// @dev Classification: DIRECT
    function test_check_lemma_price_within_bounds(uint256 sold) public pure {
        // Justification: priceAt reverts with SoldOut unless sold < BLUE_SUPPLY (GlamToon.sol:328)
        vm.assume(sold < N);
        _priceWithinBounds(sold);
    }

    /// @notice Fuzz wrapper for test_check_lemma_price_within_bounds
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_price_within_bounds(uint256 rawSold) public pure {
        _priceWithinBounds(bound(rawSold, 0, N - 1));
    }

    function _priceWithinBounds(uint256 sold) private pure {
        uint256 price = _priceAt(sold);
        assert(price >= STEP);
        assert(price <= 4 * STEP);
        assert(price > 0);
    }

    // ════════════════════════════════════════════════
    //  FB-5: the price never falls as the sale goes on
    // ════════════════════════════════════════════════

    /// @notice FB-5: a later sale never costs less than an earlier one.
    /// @dev Technique: T11 monotonicity, floor division is non-decreasing in
    ///      its numerator.
    /// @dev Classification: DIRECT
    function test_check_lemma_price_monotonic(uint256 earlier, uint256 later) public pure {
        // Justification: both are counts of blues sold, below BLUE_SUPPLY (GlamToon.sol:328)
        vm.assume(later < N);
        // Justification: the lemma is about a later sale, so earlier comes first
        vm.assume(earlier <= later);
        assert(_priceAt(earlier) <= _priceAt(later));
    }

    /// @notice Fuzz wrapper for test_check_lemma_price_monotonic
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_price_monotonic(uint256 rawEarlier, uint256 rawLater) public pure {
        uint256 later = bound(rawLater, 0, N - 1);
        uint256 earlier = bound(rawEarlier, 0, later);
        assert(_priceAt(earlier) <= _priceAt(later));
    }

    // ════════════════════════════════════════════════
    //  SM-5: the price moves only at a tier boundary
    // ════════════════════════════════════════════════

    /// @notice SM-5: one more sale raises the price by exactly one step when it
    ///         completes a tier of 2,500, and leaves it alone otherwise.
    /// @dev Technique: T12 state gating, on the tier index.
    /// @dev Classification: DIRECT
    function test_check_lemma_price_steps_only_at_tier_boundary(uint256 sold) public pure {
        // Justification: sold + 1 must still be below BLUE_SUPPLY for a price to exist (GlamToon.sol:328)
        vm.assume(sold < N - 1);
        _priceStepsOnlyAtBoundary(sold);
    }

    /// @notice Fuzz wrapper for test_check_lemma_price_steps_only_at_tier_boundary
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_price_steps_only_at_tier_boundary(uint256 rawSold) public pure {
        _priceStepsOnlyAtBoundary(bound(rawSold, 0, N - 2));
    }

    function _priceStepsOnlyAtBoundary(uint256 sold) private pure {
        uint256 here = _priceAt(sold);
        uint256 next = _priceAt(sold + 1);
        if ((sold + 1) % TIER == 0) {
            assert(next == here + STEP);
        } else {
            assert(next == here);
        }
    }

    // ════════════════════════════════════════════════
    //  PD-1 / AS-3: what is sent splits into the price and the change
    // ════════════════════════════════════════════════

    /// @notice PD-1/AS-3: for any payment that covers the price, the price and
    ///         the change add up to what was sent, the change never underflows,
    ///         and the buyer always pays something.
    /// @dev Technique: T14 conservation.
    /// @dev Classification: DIRECT
    function test_check_lemma_payment_splits_exactly(uint256 sold, uint256 sent) public pure {
        // Justification: priceAt reverts with SoldOut unless sold < BLUE_SUPPLY (GlamToon.sol:328)
        vm.assume(sold < N);
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(sent <= MAX_ETHER);
        // Justification: _mintBlue reverts with InsufficientPayment below the price (GlamToon.sol:251)
        vm.assume(sent >= _priceAt(sold));
        _paymentSplits(sold, sent);
    }

    /// @notice Fuzz wrapper for test_check_lemma_payment_splits_exactly
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_payment_splits_exactly(uint256 rawSold, uint256 rawSent) public pure {
        uint256 sold = bound(rawSold, 0, N - 1);
        _paymentSplits(sold, bound(rawSent, _priceAt(sold), MAX_ETHER));
    }

    function _paymentSplits(uint256 sold, uint256 sent) private pure {
        uint256 price = _priceAt(sold);
        uint256 change;
        unchecked {
            change = sent - price;
        }
        assert(change <= sent);
        assert(change < sent);
        assert(price + change == sent);
    }

    // ════════════════════════════════════════════════
    //  PD-1: the whole sale
    // ════════════════════════════════════════════════

    /// @notice PD-1: four tiers of 2,500 at the four prices come to exactly
    ///         250 ether, and the four tiers are the whole supply.
    /// @dev Technique: T14 conservation, over constants.
    /// @dev Classification: DIRECT
    function test_check_lemma_sellout_revenue_is_250_ether() public pure {
        uint256 total =
            TIER * _priceAt(0) + TIER * _priceAt(TIER) + TIER * _priceAt(2 * TIER) + TIER * _priceAt(3 * TIER);
        assert(total == 250 ether);
        assert(4 * TIER == N);
    }
}
