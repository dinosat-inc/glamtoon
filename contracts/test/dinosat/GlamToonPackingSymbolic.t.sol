// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, the token id functions the contract exposes
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonPackingSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonPackingSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev tokenIdFor, decode, imageIdOf, generationOf and isBlue on the deployed
///      contract, tied to the arithmetic PackingLemmasTest proves on its own.
///      The website, the metadata and every marketplace link read a token's
///      character and generation through these.
contract GlamToonPackingSymbolicTest is DinoSatBase {
    /// The range the proofs that go through a division cover, and the range
    /// their fuzz wrappers cover. See PackingLemmasTest for why they differ.
    uint256 internal constant GEN_TIGHT = 2 ** 16;
    uint256 internal constant GEN_WIDE = 2 ** 200;

    // ════════════════════════════════════════════════
    //  NFT-1: the deployed encoding is the formula
    // ════════════════════════════════════════════════

    /// @notice NFT-1/AS-1: tokenIdFor answers, rather than reverts, for every
    ///         character and generation in range, and what it answers is the
    ///         generation times ten thousand plus the character, unwrapped.
    /// @dev Technique: T16 stateful, against the formula in wrapping arithmetic.
    /// @dev Classification: DIRECT
    function test_check_tokenIdFor_answers_the_formula(uint256 imageId, uint256 generation) public view {
        // Justification: tokenIdFor reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:340)
        vm.assume(imageId < N);
        // Justification: solver bound on the overflow check, which divides; generations above 65,535 are fuzzed
        vm.assume(generation < GEN_TIGHT);
        _answersFormula(imageId, generation);
    }

    /// @notice Fuzz wrapper for test_check_tokenIdFor_answers_the_formula, over the wide range
    /// @dev See T17 in test-templates.md
    function test_fuzz_tokenIdFor_answers_the_formula(uint256 rawImage, uint256 rawGeneration) public view {
        _answersFormula(bound(rawImage, 0, N - 1), bound(rawGeneration, 0, GEN_WIDE - 1));
    }

    function _answersFormula(uint256 imageId, uint256 generation) private view {
        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.tokenIdFor, (imageId, generation)));
        assert(ok);

        uint256 tokenId = abi.decode(answer, (uint256));
        uint256 expected;
        unchecked {
            expected = generation * N + imageId;
        }
        assert(tokenId == expected);
        assert((tokenId < N) == (generation == 0));
    }

    /// @notice NFT-1: a blue's token id is its character's number, and decodes
    ///         back to that character at generation zero.
    /// @dev Technique: T16 stateful.
    /// @dev Classification: DIRECT
    function test_check_a_blue_id_is_the_character_number(uint256 imageId) public view {
        // Justification: tokenIdFor reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:340)
        vm.assume(imageId < N);
        _blueIdIsCharacter(imageId);
    }

    /// @notice Fuzz wrapper for test_check_a_blue_id_is_the_character_number
    /// @dev See T17 in test-templates.md
    function test_fuzz_a_blue_id_is_the_character_number(uint256 rawImage) public view {
        _blueIdIsCharacter(bound(rawImage, 0, N - 1));
    }

    function _blueIdIsCharacter(uint256 imageId) private view {
        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.tokenIdFor, (imageId, 0)));
        assert(ok);
        assert(abi.decode(answer, (uint256)) == imageId);

        (uint256 gotImage, uint256 gotGeneration) = nft.decode(imageId);
        assert(gotImage == imageId);
        assert(gotGeneration == 0);
        assert(nft.isBlue(imageId));
    }

    // ════════════════════════════════════════════════
    //  NFT-2: the deployed decoding undoes it
    // ════════════════════════════════════════════════

    /// @notice NFT-2: decode, imageIdOf and generationOf give back the pair
    ///         tokenIdFor was given.
    /// @dev Technique: T6 floor division identity, on the deployed functions.
    /// @dev Classification: DIRECT
    function test_check_decode_inverts_tokenIdFor(uint256 imageId, uint256 generation) public view {
        // Justification: tokenIdFor reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:340)
        vm.assume(imageId < N);
        // Justification: solver bound on the division; generations above 65,535 are fuzzed
        vm.assume(generation < GEN_TIGHT);
        _decodeInverts(imageId, generation);
    }

    /// @notice Fuzz wrapper for test_check_decode_inverts_tokenIdFor, over the wide range
    /// @dev See T17 in test-templates.md
    function test_fuzz_decode_inverts_tokenIdFor(uint256 rawImage, uint256 rawGeneration) public view {
        _decodeInverts(bound(rawImage, 0, N - 1), bound(rawGeneration, 0, GEN_WIDE - 1));
    }

    function _decodeInverts(uint256 imageId, uint256 generation) private view {
        uint256 tokenId;
        unchecked {
            tokenId = generation * N + imageId;
        }

        (uint256 gotImage, uint256 gotGeneration) = nft.decode(tokenId);
        assert(gotImage == imageId);
        assert(gotGeneration == generation);
        assert(nft.imageIdOf(tokenId) == imageId);
        assert(nft.generationOf(tokenId) == generation);
    }

    /// @notice NFT-2: decoding any token id at all names a character inside
    ///         the collection, and the two single readers agree with decode.
    /// @dev Technique: T6, remainder is below the divisor.
    /// @dev Classification: DIRECT
    function test_check_decode_always_names_a_real_character(uint256 tokenId) public view {
        (uint256 imageId, uint256 generation) = nft.decode(tokenId);

        assert(imageId < N);
        assert(nft.imageIdOf(tokenId) == imageId);
        assert(nft.generationOf(tokenId) == generation);
    }

    // ════════════════════════════════════════════════
    //  NFT-3: the blue range
    // ════════════════════════════════════════════════

    /// @notice NFT-3: isBlue is true for the first ten thousand ids and for no
    ///         other.
    /// @dev Technique: T2 constant bound, over every id.
    /// @dev Classification: DIRECT
    function test_check_isBlue_is_the_first_ten_thousand_ids(uint256 tokenId) public view {
        assert(nft.isBlue(tokenId) == (tokenId < N));
    }

    // ════════════════════════════════════════════════
    //  AS-1: the product inside tokenIdFor
    //  The compiler's overflow check divides by the symbolic generation. That
    //  looked out of the solver's reach at full width, so a fuzz wrapper is
    //  kept beside it; the solver proved it all the same.
    // ════════════════════════════════════════════════

    /// @notice AS-1: a generation so large that its id would not fit a word is
    ///         refused. The id never wraps around onto another token's.
    /// @dev Technique: T2 constant bound.
    /// @dev Classification: DIRECT
    function test_check_tokenIdFor_refuses_a_generation_that_would_overflow(uint256 imageId, uint256 generation)
        public
        view
    {
        // Justification: tokenIdFor reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:340)
        vm.assume(imageId < N);
        // Justification: the branch under test, generation * 10000 + imageId past uint256.max
        vm.assume(generation > (type(uint256).max - imageId) / N);
        _refusesOverflow(imageId, generation);
    }

    /// @notice Fuzz wrapper for test_check_tokenIdFor_refuses_a_generation_that_would_overflow
    /// @dev See T17 in test-templates.md
    function test_fuzz_tokenIdFor_refuses_a_generation_that_would_overflow(uint256 rawImage, uint256 rawGeneration)
        public
        view
    {
        uint256 imageId = bound(rawImage, 0, N - 1);
        _refusesOverflow(imageId, bound(rawGeneration, (type(uint256).max - imageId) / N + 1, type(uint256).max));
    }

    function _refusesOverflow(uint256 imageId, uint256 generation) private view {
        (bool ok,) = address(nft).staticcall(abi.encodeCall(nft.tokenIdFor, (imageId, generation)));
        assert(!ok);
    }
}
