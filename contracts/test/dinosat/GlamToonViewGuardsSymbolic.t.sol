// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {GlamToon} from "../../src/GlamToon.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, the range checks on everything that reads
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonViewGuardsSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonViewGuardsSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev The website and marketplaces read the collection through these views.
///      Each refuses, with its own error, exactly the inputs that fall outside
///      what it serves, so an out of range read is a clear refusal and never a
///      wrong answer about some other character.
contract GlamToonViewGuardsSymbolicTest is DinoSatBase {
    /// The character sold in setUp, and where its bit lives.
    uint256 internal constant SOLD = 300;
    uint256 internal constant SOLD_WORD = SOLD >> 8;
    uint256 internal constant SOLD_BIT = uint256(1) << (SOLD & 0xff);

    function setUp() public override {
        super.setUp();
        (bool bought,) = _tryMintBlue(ALICE, SOLD, STEP, STEP);
        assert(bought);
    }

    // ════════════════════════════════════════════════
    //  SM-4: character numbers
    // ════════════════════════════════════════════════

    /// @notice SM-4: tokenIdFor refuses a character past the collection with
    ///         InvalidImageId, for every generation.
    /// @dev Technique: T3 guard.
    /// @dev Classification: DIRECT
    function test_check_tokenIdFor_refuses_an_unknown_character(uint256 imageId, uint256 generation) public view {
        // Justification: the branch under test, imageId >= IMAGE_COUNT (GlamToon.sol:340)
        vm.assume(imageId >= N);

        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.tokenIdFor, (imageId, generation)));

        assert(!ok);
        assert(_is(answer, GlamToon.InvalidImageId.selector));
    }

    /// @notice SM-4: blueTaken refuses a character past the collection, and
    ///         inside it answers true for the one that sold and false for
    ///         every other.
    /// @dev Technique: T3 guard, with both sides of the check asserted.
    /// @dev Classification: DIRECT
    function test_check_blueTaken_answers_inside_and_refuses_outside(uint256 imageId) public view {
        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.blueTaken, (imageId)));

        if (imageId < N) {
            assert(ok);
            assert(abi.decode(answer, (bool)) == (imageId == SOLD));
        } else {
            assert(!ok);
            assert(_is(answer, GlamToon.InvalidImageId.selector));
        }
    }

    /// @notice SM-4: the trait readers refuse a character past the collection
    ///         with InvalidImageId, one at a time or in a batch.
    /// @dev Technique: T3 guard.
    /// @dev Classification: DIRECT
    function test_check_trait_readers_refuse_an_unknown_character(uint256 imageId) public view {
        // Justification: the branch under test, imageId >= IMAGE_COUNT (GlamToon.sol:762)
        vm.assume(imageId >= N);
        uint256[] memory one = new uint256[](1);
        one[0] = imageId;

        (bool record, bytes memory a) = address(nft).staticcall(abi.encodeCall(nft.recordOf, (imageId)));
        (bool traits, bytes memory b) = address(nft).staticcall(abi.encodeCall(nft.traitsOf, (imageId)));
        (bool batch, bytes memory c) = address(nft).staticcall(abi.encodeCall(nft.traitsBatch, (one)));

        assert(!record && _is(a, GlamToon.InvalidImageId.selector));
        assert(!traits && _is(b, GlamToon.InvalidImageId.selector));
        assert(!batch && _is(c, GlamToon.InvalidImageId.selector));
    }

    /// @notice SM-4: the green batch readers do not refuse. For a character
    ///         past the collection they answer false and zero, which is true:
    ///         nobody can have minted it.
    /// @dev Technique: T3 guard, with a batch of one.
    /// @dev Classification: DIRECT
    function test_check_green_batch_readers_answer_empty_outside(uint256 imageId, address who) public view {
        // Justification: the case under test, a character that cannot be minted (GlamToon.sol:272)
        vm.assume(imageId >= N);
        uint256[] memory one = new uint256[](1);
        one[0] = imageId;

        bool[] memory taken = nft.greenTakenBatch(one, who);
        uint256[] memory counts = nft.greenCountBatch(one);

        assert(taken.length == 1 && !taken[0]);
        assert(counts.length == 1 && counts[0] == 0);
    }

    // ════════════════════════════════════════════════
    //  SM-4: chunks and categories
    // ════════════════════════════════════════════════

    /// @notice SM-4: traitChunk refuses any index but 0 and 1 with InvalidChunk.
    /// @dev Technique: T3 guard.
    /// @dev Classification: DIRECT
    function test_check_traitChunk_refuses_an_unknown_chunk(uint256 index) public view {
        // Justification: the branch under test, index >= CHUNK_COUNT (GlamToon.sol:568)
        vm.assume(index >= 2);

        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.traitChunk, (index)));

        assert(!ok);
        assert(_is(answer, GlamToon.InvalidChunk.selector));
    }

    /// @notice SM-4: valueNames refuses any category but 0 to 3 with
    ///         InvalidCategory.
    /// @dev Technique: T3 guard.
    /// @dev Classification: DIRECT
    function test_check_valueNames_refuses_an_unknown_category(uint256 category) public view {
        // Justification: the branch under test, category >= CATEGORY_COUNT (GlamToon.sol:607)
        vm.assume(category >= 4);

        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.valueNames, (category)));

        assert(!ok);
        assert(_is(answer, GlamToon.InvalidCategory.selector));
    }

    // ════════════════════════════════════════════════
    //  SM-4: the sold bitmap
    // ════════════════════════════════════════════════

    /// @notice SM-4: blueTakenBits refuses every range that leaves the forty
    ///         words with InvalidWordRange.
    /// @dev Technique: T3 guard, over every start and length.
    /// @dev Classification: DIRECT
    function test_check_blueTakenBits_refuses_a_range_outside(uint256 startWord, uint256 words) public view {
        // Justification: the branch under test, the check as the contract writes it (GlamToon.sol:643)
        vm.assume(words > WORDS || startWord > WORDS - words);

        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.blueTakenBits, (startWord, words)));

        assert(!ok);
        assert(_is(answer, GlamToon.InvalidWordRange.selector));
    }

    // ════════════════════════════════════════════════
    //  Composition: lengths {0, 1, 40} of a range inside the bitmap. A
    //  symbolic length would mean a symbolic allocation, so the length is
    //  enumerated at its two ends and at one, with the start left symbolic.
    // ════════════════════════════════════════════════

    /// @notice SM-4, length 0: an empty range is answered with an empty array
    ///         from every start up to and including the end of the bitmap.
    /// @dev Technique: T9 concrete enumeration of the length.
    /// @dev Classification: ENUMERATE
    function test_check_blueTakenBits_answers_inside_0words(uint256 startWord) public view {
        // Justification: with no words asked for, the check allows a start up to BITMAP_WORDS (GlamToon.sol:643)
        vm.assume(startWord <= WORDS);
        _emptyRange(startWord);
    }

    /// @notice Fuzz wrapper for test_check_blueTakenBits_answers_inside_0words
    /// @dev See T17 in test-templates.md
    function test_fuzz_blueTakenBits_answers_inside_0words(uint256 rawStart) public view {
        _emptyRange(bound(rawStart, 0, WORDS));
    }

    function _emptyRange(uint256 startWord) private view {
        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.blueTakenBits, (startWord, 0)));
        assert(ok);
        assert(abi.decode(answer, (uint256[])).length == 0);
    }

    /// @notice SM-4, length 1: every single word inside the bitmap is
    ///         answered, and it holds the sold character's bit exactly when it
    ///         is that character's word.
    /// @dev Technique: T9 concrete enumeration of the length.
    /// @dev Classification: ENUMERATE
    function test_check_blueTakenBits_answers_inside_1word(uint256 startWord) public view {
        // Justification: one word asked for, so the check allows a start up to BITMAP_WORDS - 1 (GlamToon.sol:643)
        vm.assume(startWord < WORDS);
        _oneWord(startWord);
    }

    /// @notice Fuzz wrapper for test_check_blueTakenBits_answers_inside_1word
    /// @dev See T17 in test-templates.md
    function test_fuzz_blueTakenBits_answers_inside_1word(uint256 rawStart) public view {
        _oneWord(bound(rawStart, 0, WORDS - 1));
    }

    function _oneWord(uint256 startWord) private view {
        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.blueTakenBits, (startWord, 1)));
        assert(ok);
        uint256[] memory taken = abi.decode(answer, (uint256[]));
        assert(taken.length == 1);
        assert(taken[0] == (startWord == SOLD_WORD ? SOLD_BIT : 0));
    }

    /// @notice SM-4, length 40: the whole bitmap in one call holds the sold
    ///         character's bit and no other.
    /// @dev Technique: T9 concrete enumeration of the length.
    /// @dev Classification: ENUMERATE
    function test_check_blueTakenBits_answers_inside_40words() public view {
        uint256[] memory taken = nft.blueTakenBits(0, WORDS);

        assert(taken.length == WORDS);
        for (uint256 i = 0; i < WORDS; ++i) {
            assert(taken[i] == (i == SOLD_WORD ? SOLD_BIT : 0));
        }
    }
}
