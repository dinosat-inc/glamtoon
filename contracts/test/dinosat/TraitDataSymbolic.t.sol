// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {TraitData0} from "../../src/gen/TraitData0.sol";
import {TraitNames} from "../../src/gen/TraitNames.sol";
import {TraitSchema} from "../../src/gen/TraitSchema.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — the trait data contracts, and the token's reading of them
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract TraitDataSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract TraitDataSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev The two chunks and the name table are data with a thin reader on top.
///      The readers' range checks are proved for every input. Reading a record
///      at a symbolic position indexes ten thousand bytes of constant data,
///      which the symbolic engine cannot do, so the records themselves are
///      proved at the four chunk boundaries and fuzzed everywhere between.
contract TraitDataSymbolicTest is DinoSatBase {
    uint256 internal constant PER_CHUNK = TraitSchema.IMAGES_PER_CHUNK;

    // ════════════════════════════════════════════════
    //  NFT-6: the data is the data the schema names
    // ════════════════════════════════════════════════

    /// @notice NFT-6: each data contract hashes to what TraitSchema expects,
    ///         holds as many bytes as its layout says, and the name table has
    ///         the slot count the lemmas assume.
    /// @dev Technique: T2 constant bound, over constants.
    /// @dev Classification: DIRECT
    function test_check_data_matches_the_schema() public view {
        assert(chunk0.dataHash() == TraitSchema.DATA_HASH_0);
        assert(chunk1.dataHash() == TraitSchema.DATA_HASH_1);
        assert(names.namesHash() == TraitSchema.NAMES_HASH);

        assert(chunk0.data().length == PER_CHUNK * TraitSchema.STRIDE);
        assert(chunk1.data().length == PER_CHUNK * TraitSchema.STRIDE);
        assert(names.SLOT_COUNT() == 68);
        assert(names.data().length == names.SLOT_COUNT() * names.SLOT());

        assert(chunk0.FIRST_IMAGE_ID() == 0 && chunk0.IMAGE_COUNT() == PER_CHUNK);
        assert(chunk1.FIRST_IMAGE_ID() == PER_CHUNK && chunk1.IMAGE_COUNT() == PER_CHUNK);
    }

    // ════════════════════════════════════════════════
    //  SM-4: the readers' range checks
    // ════════════════════════════════════════════════

    /// @notice SM-4: the first chunk refuses every character it does not
    ///         carry with OutOfChunk, rather than reading past its data.
    /// @dev Technique: T3 guard.
    /// @dev Classification: DIRECT
    function test_check_chunk0_refuses_characters_outside(uint256 imageId) public view {
        // Justification: the branch under test, imageId past the chunk's 5000 (TraitData0.sol:52)
        vm.assume(imageId >= PER_CHUNK);

        (bool ok, bytes memory answer) = address(chunk0).staticcall(abi.encodeCall(chunk0.record, (imageId)));

        assert(!ok);
        assert(_is(answer, TraitData0.OutOfChunk.selector));
    }

    /// @notice SM-4: the second chunk refuses every character below 5000 and
    ///         from 10000 up.
    /// @dev Technique: T3 guard.
    /// @dev Classification: DIRECT
    function test_check_chunk1_refuses_characters_outside(uint256 imageId) public view {
        // Justification: the branch under test, imageId outside 5000 to 9999 (TraitData1.sol:52)
        vm.assume(imageId < PER_CHUNK || imageId >= 2 * PER_CHUNK);

        (bool ok, bytes memory answer) = address(chunk1).staticcall(abi.encodeCall(chunk1.record, (imageId)));

        assert(!ok);
        assert(_is(answer, TraitData0.OutOfChunk.selector));
    }

    /// @notice SM-4: the name table refuses a slot it does not have with
    ///         OutOfRange.
    /// @dev Technique: T3 guard, with a batch of one.
    /// @dev Classification: DIRECT
    function test_check_names_refuse_a_slot_outside(uint256 slot) public view {
        // Justification: the branch under test, slot >= SLOT_COUNT (TraitNames.sol:52)
        vm.assume(slot >= 68);
        uint256[] memory one = new uint256[](1);
        one[0] = slot;

        (bool ok, bytes memory answer) = address(names).staticcall(abi.encodeCall(names.namesAt, (one)));

        assert(!ok);
        assert(_is(answer, TraitNames.OutOfRange.selector));
    }

    // ════════════════════════════════════════════════
    //  Composition: {0, 4999, 5000, 9999} are the first and last character of
    //  each chunk, the four records the constructor reads and the only places
    //  an off by one in the routing or the offset could hide.
    // ════════════════════════════════════════════════

    /// @notice NFT-6, character 0: the token reads the first record of the
    ///         first chunk, and it is the bytes at that position.
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_token_reads_the_right_record_0() public view {
        _readsRightRecord(0);
    }

    /// @notice NFT-6, character 4999: the last record of the first chunk.
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_token_reads_the_right_record_4999() public view {
        _readsRightRecord(4999);
    }

    /// @notice NFT-6, character 5000: the first record of the second chunk.
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_token_reads_the_right_record_5000() public view {
        _readsRightRecord(5000);
    }

    /// @notice NFT-6, character 9999: the last record of the second chunk.
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_token_reads_the_right_record_9999() public view {
        _readsRightRecord(9999);
    }

    // ════════════════════════════════════════════════
    //  NFT-6: every record
    //  A symbolic index into the chunk's bytes is a symbolic memory offset,
    //  which halmos does not support, so these two are fuzz verified.
    // ════════════════════════════════════════════════

    /// @notice NFT-6: for every character, the record the token reports is the
    ///         two bytes at that character's position in the right chunk.
    /// @dev Technique: T2, against the raw data.
    /// @dev Classification: FUZZ
    function test_check_token_reads_the_right_record(uint256 imageId) public view {
        // Justification: recordOf reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:762)
        vm.assume(imageId < N);
        _readsRightRecord(imageId);
    }

    /// @notice Fuzz wrapper for test_check_token_reads_the_right_record
    /// @dev See T17 in test-templates.md
    function test_fuzz_token_reads_the_right_record(uint256 rawImage) public view {
        _readsRightRecord(bound(rawImage, 0, N - 1));
    }

    /// @notice NFT-6: for every character, the four trait values are the four
    ///         fields of its record, each at most fifteen.
    /// @dev Technique: T2, against the schema's shifts and masks.
    /// @dev Classification: FUZZ
    function test_check_traits_are_the_fields_of_the_record(uint256 imageId) public view {
        // Justification: traitsOf reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:762)
        vm.assume(imageId < N);
        _traitsAreFields(imageId);
    }

    /// @notice Fuzz wrapper for test_check_traits_are_the_fields_of_the_record
    /// @dev See T17 in test-templates.md
    function test_fuzz_traits_are_the_fields_of_the_record(uint256 rawImage) public view {
        _traitsAreFields(bound(rawImage, 0, N - 1));
    }

    // ════════════════════════════════════════════════
    //  Helpers
    // ════════════════════════════════════════════════

    function _readsRightRecord(uint256 imageId) private view {
        bool first = imageId < PER_CHUNK;
        bytes memory raw = first ? chunk0.data() : chunk1.data();
        uint256 offset = (first ? imageId : imageId - PER_CHUNK) * TraitSchema.STRIDE;
        uint256 expected = (uint256(uint8(raw[offset])) << 8) | uint256(uint8(raw[offset + 1]));

        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.recordOf, (imageId)));
        assert(ok);
        assert(abi.decode(answer, (uint256)) == expected);
        assert(expected < 2 ** 16);

        // and the chunk says the same when asked directly
        assert(first ? chunk0.record(imageId) == expected : chunk1.record(imageId) == expected);
    }

    function _traitsAreFields(uint256 imageId) private view {
        uint256 record = nft.recordOf(imageId);
        uint8[4] memory values = nft.traitsOf(imageId);
        uint8[4] memory shift = TraitSchema.shifts();
        uint40[4] memory mask = TraitSchema.masks();

        for (uint256 c = 0; c < TraitSchema.CATEGORY_COUNT; ++c) {
            assert(values[c] == (record >> shift[c]) & mask[c]);
            assert(values[c] <= 15);
        }
    }
}
