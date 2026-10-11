// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {TraitSchema} from "../../src/gen/TraitSchema.sol";

/// @title DinoSAT Proofs — the packed trait record, as arithmetic
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract TraitSchemaLemmasTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000 --loop 5
/// @notice Forge:  forge test --match-contract TraitSchemaLemmasTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev Pure lemmas over the layout in TraitSchema, the library itself rather
///      than a copy of it. They hold for every record the two bytes can spell,
///      so they do not depend on the trait data that happens to ship: no
///      record, real or not, can index outside a chunk, overflow a trait value
///      or name a slot the name table does not have.
contract TraitSchemaLemmasTest is Test {
    /// TraitNames.SLOT_COUNT, pinned to the contract in TraitDataSymbolicTest.
    uint256 constant SLOT_COUNT = 68;

    /// Bytes of records in one chunk.
    uint256 constant CHUNK_BYTES = TraitSchema.IMAGES_PER_CHUNK * TraitSchema.STRIDE;

    // ════════════════════════════════════════════════
    //  SM-4: every character is in exactly one chunk
    // ════════════════════════════════════════════════

    /// @notice SM-4: the chunk a character is read from is 0 or 1, and it is 0
    ///         exactly for the first five thousand.
    /// @dev Technique: T2 constant bound.
    /// @dev Classification: DIRECT
    function test_check_lemma_chunk_index_is_zero_or_one(uint256 imageId) public pure {
        // Justification: _record reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:762)
        vm.assume(imageId < TraitSchema.IMAGE_COUNT);
        _chunkIndex(imageId);
    }

    /// @notice Fuzz wrapper for test_check_lemma_chunk_index_is_zero_or_one
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_chunk_index_is_zero_or_one(uint256 rawImage) public pure {
        _chunkIndex(bound(rawImage, 0, TraitSchema.IMAGE_COUNT - 1));
    }

    function _chunkIndex(uint256 imageId) private pure {
        uint256 index = imageId / TraitSchema.IMAGES_PER_CHUNK;
        assert(index < TraitSchema.CHUNK_COUNT);
        assert((index == 0) == (imageId < TraitSchema.IMAGES_PER_CHUNK));
    }

    // ════════════════════════════════════════════════
    //  AS-3: a record is read from inside its chunk
    //  Composition: {chunk 0, chunk 1} covers every chunk there is.
    // ════════════════════════════════════════════════

    /// @notice AS-3, chunk 0: for every character the chunk accepts, both bytes
    ///         of its record lie inside the chunk and the subtraction that
    ///         finds them cannot underflow.
    /// @dev Technique: T9 concrete enumeration, one test per chunk.
    /// @dev Classification: ENUMERATE
    function test_check_lemma_record_offset_in_bounds_chunk0(uint256 imageId) public pure {
        // Justification: TraitData0.record reverts with OutOfChunk outside 0 to 4999 (TraitData0.sol:52)
        vm.assume(imageId < TraitSchema.IMAGES_PER_CHUNK);
        _offsetInBounds(imageId, 0);
    }

    /// @notice Fuzz wrapper for test_check_lemma_record_offset_in_bounds_chunk0
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_record_offset_in_bounds_chunk0(uint256 rawImage) public pure {
        _offsetInBounds(bound(rawImage, 0, TraitSchema.IMAGES_PER_CHUNK - 1), 0);
    }

    /// @notice AS-3, chunk 1: the same for characters 5000 to 9999.
    /// @dev Technique: T9 concrete enumeration, one test per chunk.
    /// @dev Classification: ENUMERATE
    function test_check_lemma_record_offset_in_bounds_chunk1(uint256 imageId) public pure {
        // Justification: TraitData1.record reverts with OutOfChunk outside 5000 to 9999 (TraitData1.sol:52)
        vm.assume(imageId >= TraitSchema.IMAGES_PER_CHUNK && imageId < TraitSchema.IMAGE_COUNT);
        _offsetInBounds(imageId, TraitSchema.IMAGES_PER_CHUNK);
    }

    /// @notice Fuzz wrapper for test_check_lemma_record_offset_in_bounds_chunk1
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_record_offset_in_bounds_chunk1(uint256 rawImage) public pure {
        _offsetInBounds(
            bound(rawImage, TraitSchema.IMAGES_PER_CHUNK, TraitSchema.IMAGE_COUNT - 1), TraitSchema.IMAGES_PER_CHUNK
        );
    }

    function _offsetInBounds(uint256 imageId, uint256 first) private pure {
        assert(imageId >= first);
        uint256 offset;
        unchecked {
            offset = (imageId - first) * TraitSchema.STRIDE;
        }
        // the last byte record() reads is offset + STRIDE - 1
        assert(offset + TraitSchema.STRIDE <= CHUNK_BYTES);
    }

    // ════════════════════════════════════════════════
    //  AS-4: a trait value fits the type it is cast to
    // ════════════════════════════════════════════════

    /// @notice AS-4: whatever a record holds, each of its four values is at
    ///         most fifteen, so the cast to uint8 in traitsOf cannot truncate.
    /// @dev Technique: T2 constant bound, over every record a uint40 can hold.
    /// @dev Classification: DIRECT
    function test_check_lemma_trait_values_fit_their_type(uint40 packed) public pure {
        uint8[4] memory shift = TraitSchema.shifts();
        uint40[4] memory mask = TraitSchema.masks();
        for (uint256 c = 0; c < TraitSchema.CATEGORY_COUNT; ++c) {
            uint256 value = (packed >> shift[c]) & mask[c];
            assert(value <= 15);
            assert(value <= type(uint8).max);
        }
    }

    /// @notice SM-4: whatever a record holds, every name slot _attributes asks
    ///         for exists, so no record can make the metadata revert.
    /// @dev Technique: T2 constant bound, over every record a uint40 can hold.
    /// @dev Classification: DIRECT
    function test_check_lemma_name_slots_stay_in_table(uint40 packed) public pure {
        uint8[4] memory shift = TraitSchema.shifts();
        uint40[4] memory mask = TraitSchema.masks();
        uint16[4] memory base = TraitSchema.valueBase();
        for (uint256 c = 0; c < TraitSchema.CATEGORY_COUNT; ++c) {
            uint256 value = (packed >> shift[c]) & mask[c];
            // the category's own name, then the value's
            assert(c < SLOT_COUNT);
            assert(uint256(base[c]) + value < SLOT_COUNT);
        }
    }

    // ════════════════════════════════════════════════
    //  NFT-6: the four fields are the whole record
    // ════════════════════════════════════════════════

    /// @notice NFT-6: the four values put back at their shifts are the record,
    ///         so no bit is read twice and none is ignored.
    /// @dev Technique: T2, over every two byte record.
    /// @dev Classification: DIRECT
    function test_check_lemma_fields_rebuild_the_record(uint256 packed) public pure {
        // Justification: a record is STRIDE = 2 bytes, read by TraitData.record (TraitData0.sol:58)
        vm.assume(packed < 2 ** 16);
        _fieldsRebuild(packed);
    }

    /// @notice Fuzz wrapper for test_check_lemma_fields_rebuild_the_record
    /// @dev See T17 in test-templates.md
    function test_fuzz_lemma_fields_rebuild_the_record(uint256 rawPacked) public pure {
        _fieldsRebuild(bound(rawPacked, 0, 2 ** 16 - 1));
    }

    function _fieldsRebuild(uint256 packed) private pure {
        uint8[4] memory shift = TraitSchema.shifts();
        uint40[4] memory mask = TraitSchema.masks();
        uint256 rebuilt;
        for (uint256 c = 0; c < TraitSchema.CATEGORY_COUNT; ++c) {
            rebuilt |= ((packed >> shift[c]) & mask[c]) << shift[c];
        }
        assert(rebuilt == packed);
    }

    /// @notice NFT-6: the layout constants agree with each other. The chunks
    ///         cover the collection, the fields fill the record, and the value
    ///         tables follow the category names without a gap or an overlap.
    /// @dev Technique: T2 constant bound, over constants.
    /// @dev Classification: DIRECT
    function test_check_lemma_layout_constants_agree() public pure {
        uint8[4] memory shift = TraitSchema.shifts();
        uint40[4] memory mask = TraitSchema.masks();
        uint16[4] memory base = TraitSchema.valueBase();

        assert(TraitSchema.CHUNK_COUNT * TraitSchema.IMAGES_PER_CHUNK == TraitSchema.IMAGE_COUNT);
        assert(TraitSchema.REAL_ROWS == TraitSchema.IMAGE_COUNT);
        assert(TraitSchema.CATEGORY_COUNT == 4);

        // the first value table starts where the category names end
        assert(base[0] == TraitSchema.CATEGORY_COUNT);
        // each table is as long as its field can count, and the next follows it
        for (uint256 c = 0; c + 1 < TraitSchema.CATEGORY_COUNT; ++c) {
            assert(uint256(base[c]) + mask[c] + 1 == base[c + 1]);
            assert(uint256(shift[c + 1]) + 4 == shift[c]);
        }
        assert(uint256(base[3]) + mask[3] + 1 == SLOT_COUNT);

        // four fields of four bits fill the two bytes exactly
        assert(shift[3] == 0);
        assert(uint256(shift[0]) + 4 == TraitSchema.STRIDE * 8);
    }
}
