// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

/// @title DinoSAT Proofs — the token id packing, as arithmetic
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract PackingLemmasTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract PackingLemmasTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev Pure lemmas over tokenId = generation * 10000 + imageId. Two characters
///      sharing a token id, or a green landing on a blue id, could not be
///      repaired after deployment, so the encode side is proved without any
///      division and over a range no chain could reach.
contract PackingLemmasTest is Test {
    /// GlamToon.IMAGE_COUNT.
    uint256 constant N = 10_000;

    /// The range the division free lemmas cover. A generation is a count of
    /// green mints of one character, one transaction each.
    uint256 constant GEN_WIDE = 2 ** 200;

    /// The range the lemmas that divide cover. Division by a constant with a
    /// symbolic numerator is the solver's hard case; beyond this it is fuzzed.
    uint256 constant GEN_TIGHT = 2 ** 16;

    // ════════════════════════════════════════════════
    //  Abstract specification helpers
    // ════════════════════════════════════════════════

    /// @dev Abstract spec of GlamToon.tokenIdFor past its range check. Wrapping
    ///      arithmetic on purpose: an id that wrapped would break the lemmas
    ///      below rather than end the path, so they also prove nothing wraps.
    ///      Valid for generation < 2**200: 2**200 * 10000 + 9999 < 2**214.
    function _encode(uint256 imageId, uint256 generation) private pure returns (uint256 tokenId) {
        unchecked {
            tokenId = generation * N + imageId;
        }
    }

    /// @dev Abstract spec of GlamToon.decode: the same two expressions.
    function _decode(uint256 tokenId) private pure returns (uint256 imageId, uint256 generation) {
        imageId = tokenId % N;
        generation = tokenId / N;
    }

    // ════════════════════════════════════════════════
    //  NFT-1: distinct pairs never share a token id
    // ════════════════════════════════════════════════

    /// @notice NFT-1, lemma: a higher generation always has a higher token id,
    ///         whichever two characters are compared.
    /// @dev Technique: T11 monotonicity. The higher generation is written as
    ///      the lower one plus a gap, so no division is needed.
    /// @dev Classification: DIRECT
    function test_check_lemma_id_rises_with_generation(uint256 imageA, uint256 imageB, uint256 genB, uint256 gap)
        public
        pure
    {
        // Justification: tokenIdFor reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:340)
        vm.assume(imageA < N && imageB < N);
        // Justification: generations count green mints of one character; 2**200 transactions cannot happen
        vm.assume(genB < GEN_WIDE && gap < GEN_WIDE);
        assert(_encode(imageA, genB + 1 + gap) > _encode(imageB, genB));
    }

    /// @notice Fuzz wrapper for test_check_lemma_id_rises_with_generation
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_id_rises_with_generation(uint256 rawA, uint256 rawB, uint256 rawGen, uint256 rawGap)
        public
        pure
    {
        uint256 genB = bound(rawGen, 0, GEN_WIDE - 1);
        uint256 genA = genB + 1 + bound(rawGap, 0, GEN_WIDE - 1);
        assert(_encode(bound(rawA, 0, N - 1), genA) > _encode(bound(rawB, 0, N - 1), genB));
    }

    /// @notice NFT-1, lemma: inside one generation two ids are equal exactly
    ///         when the characters are. Holds for every generation a word can
    ///         hold, wrapped or not.
    /// @dev Technique: T2, cancellation of the shared term.
    /// @dev Classification: DIRECT
    function test_check_lemma_same_generation_keeps_characters_apart(uint256 imageA, uint256 imageB, uint256 generation)
        public
        pure
    {
        assert((_encode(imageA, generation) == _encode(imageB, generation)) == (imageA == imageB));
    }

    /// @notice NFT-1, theorem: two pairs with the same token id are the same
    ///         pair, end to end.
    /// @dev Technique: T4 lemma decomposition. Proved directly here for the
    ///      first 65,536 generations and by composition of the two lemmas
    ///      above for every generation below 2**200.
    /// @dev Classification: DECOMPOSE
    function test_check_theorem_no_collision(uint256 imageA, uint256 genA, uint256 imageB, uint256 genB) public pure {
        // Justification: tokenIdFor reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:340)
        vm.assume(imageA < N && imageB < N);
        // Justification: solver bound, tightened from 2**200; the lemmas above carry the wider range
        vm.assume(genA < GEN_TIGHT && genB < GEN_TIGHT);
        _noCollision(imageA, genA, imageB, genB);
    }

    /// @notice Fuzz wrapper for test_check_theorem_no_collision, over the wide range
    /// @dev See T17 in test-templates.md
    function test_fuzz_theorem_no_collision(uint256 rawA, uint256 rawGenA, uint256 rawB, uint256 rawGenB) public pure {
        _noCollision(
            bound(rawA, 0, N - 1),
            bound(rawGenA, 0, GEN_WIDE - 1),
            bound(rawB, 0, N - 1),
            bound(rawGenB, 0, GEN_WIDE - 1)
        );
    }

    function _noCollision(uint256 imageA, uint256 genA, uint256 imageB, uint256 genB) private pure {
        if (_encode(imageA, genA) == _encode(imageB, genB)) {
            assert(imageA == imageB);
            assert(genA == genB);
        }
    }

    // ════════════════════════════════════════════════
    //  COMPOSITION: distinct (character, generation) pairs never share a token id
    //  Case A: genA > genB  → idA > idB  (Lemma id_rises_with_generation)
    //  Case B: genA < genB  → idB > idA  (the same lemma with A and B exchanged)
    //  Case C: genA == genB → the ids are equal only if the characters are
    //                          (Lemma same_generation_keeps_characters_apart)
    //  Partition: A ∪ B ∪ C = every pair of generations. Exhaustive.
    //  Range: generations below 2**200 for A and B, every generation for C.
    //  Status: Case A [PASS], Case B [PASS], Case C [PASS]. QED.
    //  The theorem above is the same statement proved in one piece for
    //  generations below 2**16, and fuzzed below 2**200.
    // ════════════════════════════════════════════════

    // ════════════════════════════════════════════════
    //  NFT-3: the blue range is generation zero and nothing else
    // ════════════════════════════════════════════════

    /// @notice NFT-3: an id is below 10,000 exactly when its generation is
    ///         zero, so no green generation can land on a blue id.
    /// @dev Technique: T2 constant bound, no division.
    /// @dev Classification: DIRECT
    function test_check_lemma_blue_iff_generation_zero(uint256 imageId, uint256 generation) public pure {
        // Justification: tokenIdFor reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:340)
        vm.assume(imageId < N);
        // Justification: generations count green mints of one character; 2**200 transactions cannot happen
        vm.assume(generation < GEN_WIDE);
        assert((_encode(imageId, generation) < N) == (generation == 0));
    }

    /// @notice Fuzz wrapper for test_check_lemma_blue_iff_generation_zero
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_blue_iff_generation_zero(uint256 rawImage, uint256 rawGeneration) public pure {
        uint256 generation = bound(rawGeneration, 0, GEN_WIDE - 1);
        assert((_encode(bound(rawImage, 0, N - 1), generation) < N) == (generation == 0));
    }

    // ════════════════════════════════════════════════
    //  NFT-2: decode undoes encode
    // ════════════════════════════════════════════════

    /// @notice NFT-2: decoding an encoded pair gives the pair back.
    /// @dev Technique: T6 floor division identity.
    /// @dev Classification: DIRECT
    function test_check_lemma_round_trip(uint256 imageId, uint256 generation) public pure {
        // Justification: tokenIdFor reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:340)
        vm.assume(imageId < N);
        // Justification: solver bound on the division; generations above 65,535 are fuzzed
        vm.assume(generation < GEN_TIGHT);
        _roundTrip(imageId, generation);
    }

    /// @notice Fuzz wrapper for test_check_lemma_round_trip, over the wide range
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_round_trip(uint256 rawImage, uint256 rawGeneration) public pure {
        _roundTrip(bound(rawImage, 0, N - 1), bound(rawGeneration, 0, GEN_WIDE - 1));
    }

    function _roundTrip(uint256 imageId, uint256 generation) private pure {
        (uint256 gotImage, uint256 gotGeneration) = _decode(_encode(imageId, generation));
        assert(gotImage == imageId);
        assert(gotGeneration == generation);
    }

    /// @notice NFT-2: decoding any token id at all names a character inside the
    ///         collection.
    /// @dev Technique: T6, remainder is below the divisor.
    /// @dev Classification: DIRECT
    function test_check_lemma_decode_image_in_range(uint256 tokenId) public pure {
        (uint256 imageId,) = _decode(tokenId);
        assert(imageId < N);
    }

    /// @notice NFT-2: the two halves of a decoded id put together are the id.
    /// @dev Technique: T6 floor division identity.
    /// @dev Classification: DIRECT
    function test_check_lemma_decode_recomposes(uint256 tokenId) public pure {
        // Justification: solver bound on the division; 2**32 covers the first 429,496 generations
        // of every character, and the full range is fuzzed
        vm.assume(tokenId < 2 ** 32);
        _recomposes(tokenId);
    }

    /// @notice Fuzz wrapper for test_check_lemma_decode_recomposes, over every id
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_decode_recomposes(uint256 tokenId) public pure {
        _recomposes(tokenId);
    }

    function _recomposes(uint256 tokenId) private pure {
        (uint256 imageId, uint256 generation) = _decode(tokenId);
        assert(_encode(imageId, generation) == tokenId);
        assert(imageId < N);
    }
}
