// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

/// @title DinoSAT Proofs — the sold bitmap, as arithmetic
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract BitmapLemmasTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract BitmapLemmasTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev Pure lemmas over the bit GlamToon._mintBlue sets, _blueBits[imageId >> 8]
///      |= 1 << (imageId & 0xff), and the range check in blueTakenBits. The
///      website reads which blues are sold from this bitmap.
contract BitmapLemmasTest is Test {
    /// GlamToon.IMAGE_COUNT and GlamToon.BITMAP_WORDS, written the way the
    /// contract writes it.
    uint256 constant N = 10_000;
    uint256 constant WORDS = (N >> 8) + 1;

    // ════════════════════════════════════════════════
    //  Abstract specification helpers
    // ════════════════════════════════════════════════

    /// @dev The word a character's bit lives in (GlamToon.sol:254).
    function _word(uint256 imageId) private pure returns (uint256) {
        return imageId >> 8;
    }

    /// @dev The bit itself (GlamToon.sol:254).
    function _bit(uint256 imageId) private pure returns (uint256) {
        return uint256(1) << (imageId & 0xff);
    }

    // ════════════════════════════════════════════════
    //  SM-4: every character has a place in the bitmap
    // ════════════════════════════════════════════════

    /// @notice SM-4: every character's word is one of the forty the bitmap has.
    /// @dev Technique: T2 constant bound.
    /// @dev Classification: DIRECT
    function test_check_lemma_word_index_in_bitmap(uint256 imageId) public pure {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        _wordInBitmap(imageId);
    }

    /// @notice Fuzz wrapper for test_check_lemma_word_index_in_bitmap
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_word_index_in_bitmap(uint256 rawImage) public pure {
        _wordInBitmap(bound(rawImage, 0, N - 1));
    }

    function _wordInBitmap(uint256 imageId) private pure {
        assert(_word(imageId) < WORDS);
        assert(WORDS == 40);
    }

    /// @notice SM-4: forty words hold all ten thousand characters, and thirty
    ///         nine would not.
    /// @dev Technique: T2 constant bound, over constants.
    /// @dev Classification: DIRECT
    function test_check_lemma_bitmap_capacity_is_tight() public pure {
        assert(WORDS * 256 >= N);
        assert((WORDS - 1) * 256 < N);
        assert(_word(N - 1) == WORDS - 1);
        assert(_word(0) == 0);
    }

    // ════════════════════════════════════════════════
    //  CC-1: one character, one bit
    // ════════════════════════════════════════════════

    /// @notice CC-1: the mask a sale sets is exactly one bit, never none.
    /// @dev Technique: T2. A power of two has no bit in common with itself
    ///      less one.
    /// @dev Classification: DIRECT
    function test_check_lemma_bit_is_single_and_nonzero(uint256 imageId) public pure {
        uint256 bit = _bit(imageId);
        assert(bit != 0);
        assert(bit & (bit - 1) == 0);
    }

    /// @notice CC-1: two characters share a word and a bit exactly when they
    ///         are the same character, so no sale can mark another's bit.
    /// @dev Technique: T2. The word and the bit together are the whole id.
    /// @dev Classification: DIRECT
    function test_check_lemma_positions_are_injective(uint256 imageA, uint256 imageB) public pure {
        bool samePlace = _word(imageA) == _word(imageB) && _bit(imageA) == _bit(imageB);
        assert(samePlace == (imageA == imageB));
    }

    /// @notice CC-1: the shift and the mask are division and remainder by 256,
    ///         which is how a reader outside the contract finds a character.
    /// @dev Technique: T6 floor division identity, on a power of two.
    /// @dev Classification: DIRECT
    function test_check_lemma_shift_and_mask_are_div_and_mod(uint256 imageId) public pure {
        assert(_word(imageId) == imageId / 256);
        assert(imageId & 0xff == imageId % 256);
        assert(_bit(imageId) == uint256(1) << (imageId % 256));
    }

    // ════════════════════════════════════════════════
    //  AC-3: a sold bit is never cleared by another sale
    // ════════════════════════════════════════════════

    /// @notice AC-3: setting a character's bit sets that bit, leaves every
    ///         other bit of the word as it was, and clears nothing.
    /// @dev Technique: T2, over every word and every character.
    /// @dev Classification: DIRECT
    function test_check_lemma_setting_a_bit_keeps_the_rest(uint256 word, uint256 imageId) public pure {
        uint256 bit = _bit(imageId);
        uint256 afterwards = word | bit;
        assert(afterwards & bit == bit);
        assert(afterwards & ~bit == word & ~bit);
        assert(afterwards & word == word);
    }

    // ════════════════════════════════════════════════
    //  SM-4 / AS-3: the range check in blueTakenBits
    // ════════════════════════════════════════════════

    /// @notice SM-4/AS-3: the check refuses exactly the ranges that leave the
    ///         bitmap. What it lets through never underflows the subtraction
    ///         and never reads past the last word.
    /// @dev Technique: T12 gating, with the contract's own short circuit.
    /// @dev Classification: DIRECT
    function test_check_lemma_word_range_guard_is_exact(uint256 startWord, uint256 words) public pure {
        // the check as the contract writes it (GlamToon.sol:643)
        bool refused = words > WORDS || startWord > WORDS - words;
        // the same thing said plainly: the range ends past the last word
        bool leaves = words > WORDS || startWord > WORDS || startWord + words > WORDS;

        assert(refused == leaves);
        if (!refused) {
            assert(words <= WORDS);
            assert(startWord + words <= WORDS);
            assert(words == 0 || startWord + (words - 1) < WORDS);
        }
    }
}
