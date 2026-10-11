// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";
import {TraitSchema} from "../../src/gen/TraitSchema.sol";

/// The trait layer, checked against the bytes the encoder wrote rather than
/// against itself. If the chain and the fixture ever disagree, one of them was
/// generated from a different schema and the collection would ship wrong.
contract TraitsTest is BaseTest {
    bytes internal fixture;
    bytes internal nameFixture;

    function setUp() public override {
        super.setUp();
        fixture = vm.readFileBinary("test/fixtures/traits.bin");
        nameFixture = vm.readFileBinary("test/fixtures/names.bin");
    }

    /*//////////////////////////////////////////////////////////////
                                 PARITY
    //////////////////////////////////////////////////////////////*/

    function test_theChainCarriesExactlyTheEncodedBytes() public view {
        bytes memory onChain = nft.allTraits();
        assertEq(onChain.length, TraitSchema.IMAGE_COUNT * TraitSchema.STRIDE, "blob length");
        assertEq(onChain.length, fixture.length, "same length as the fixture");
        assertEq(keccak256(onChain), keccak256(fixture), "trait blob differs from the fixture");
    }

    function test_theNameTableMatchesTheFixture() public view {
        bytes memory onChain = nft.traitNames();
        assertEq(onChain.length, nameFixture.length, "name table length");
        assertEq(keccak256(onChain), keccak256(nameFixture), "name table differs");
    }

    function test_chunksConcatenateInOrder() public view {
        bytes memory joined;
        for (uint256 k = 0; k < TraitSchema.CHUNK_COUNT; ++k) {
            joined = bytes.concat(joined, nft.traitChunk(k));
        }
        assertEq(keccak256(joined), keccak256(fixture), "chunks are out of order or short");
    }

    /*//////////////////////////////////////////////////////////////
                               DECODING
    //////////////////////////////////////////////////////////////*/

    /// Every record on chain must decode to the same two bytes the fixture holds
    /// at that offset. This is what catches a seam off by one, which would give a
    /// handful of characters their neighbour's traits and nothing else would show.
    function test_everyRecordMatchesItsOffsetInTheFixture() public view {
        for (uint256 imageId = 0; imageId < TraitSchema.IMAGE_COUNT; ++imageId) {
            uint256 offset = imageId * TraitSchema.STRIDE;
            uint40 want;
            for (uint256 b = 0; b < TraitSchema.STRIDE; ++b) {
                want = (want << 8) | uint40(uint8(fixture[offset + b]));
            }
            assertEq(uint256(this.record(imageId)), uint256(want), "record moved");
        }
    }

    function record(uint256 imageId) external view returns (uint40) {
        return nft.recordOf(imageId);
    }

    function test_bothSidesOfEverySeam() public view {
        uint256 per = TraitSchema.IMAGES_PER_CHUNK;
        uint256[4] memory ids = [uint256(0), per - 1, per, 2 * per - 1];
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 offset = ids[i] * TraitSchema.STRIDE;
            uint40 want;
            for (uint256 b = 0; b < TraitSchema.STRIDE; ++b) {
                want = (want << 8) | uint40(uint8(fixture[offset + b]));
            }
            assertEq(uint256(nft.recordOf(ids[i])), uint256(want), "seam");
        }
    }

    function test_decodeSplitsTheRecordIntoItsFields() public view {
        uint40 packed = nft.recordOf(7412);
        uint8[4] memory values = nft.traitsOf(7412);
        uint8[4] memory shift = TraitSchema.shifts();
        uint40[4] memory mask = TraitSchema.masks();
        for (uint256 c = 0; c < 4; ++c) {
            assertEq(uint256(values[c]), uint256((packed >> shift[c]) & mask[c]), "field decode");
        }
    }

    function test_traitsBatchMatchesTraitsOf() public view {
        uint256[] memory ids = new uint256[](4);
        ids[0] = 1;
        ids[1] = 2499;
        ids[2] = 7412;
        ids[3] = 9999;
        uint8[4][] memory batch = nft.traitsBatch(ids);
        for (uint256 i = 0; i < ids.length; ++i) {
            uint8[4] memory one = nft.traitsOf(ids[i]);
            for (uint256 c = 0; c < 4; ++c) {
                assertEq(uint256(batch[i][c]), uint256(one[c]), "batch drifted");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 NAMES
    //////////////////////////////////////////////////////////////*/

    /// The point of padding every value table out to the full range its bits can
    /// hold: there is no index a record can carry that has nothing behind it, so
    /// metadata has no out of range case to handle and cannot be bricked by one.
    function test_everyRepresentableIndexHasAName() public view {
        uint40[4] memory mask = TraitSchema.masks();
        for (uint256 c = 0; c < 4; ++c) {
            string[] memory values = nft.valueNames(c);
            assertEq(values.length, uint256(mask[c]) + 1, "table is not padded to the full range");
            for (uint256 v = 0; v < values.length; ++v) {
                assertGt(bytes(values[v]).length, 0, "an index names nothing");
            }
        }
    }

    function test_categoryNames() public view {
        string[] memory categories = nft.categoryNames();
        assertEq(categories.length, 4, "four categories");
        assertEq(categories[0], "Dress Code", "first");
        assertEq(categories[3], "Hair Colour", "last");
    }

    function test_unusedSlotsReadAsADash() public view {
        // Hair Colour carries four values in four bits, so slots four to fifteen
        // are padding and must be inert rather than absent.
        string[] memory colour = nft.valueNames(3);
        assertEq(colour.length, 16, "four bits");
        assertEq(colour[0], "None", "first real value");
        assertEq(colour[3], "Dark", "last real value");
        assertEq(colour[4], "-", "first padding slot");
        assertEq(colour[15], "-", "last padding slot");
    }

    function test_categoryOutOfRangeReverts() public {
        vm.expectRevert(GlamToon.InvalidCategory.selector);
        nft.valueNames(10);
    }

    /*//////////////////////////////////////////////////////////////
                                BOUNDS
    //////////////////////////////////////////////////////////////*/

    function test_imageIdOutOfRangeReverts() public {
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.traitsOf(10_000);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.traitsOf(type(uint256).max);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.imageURI(10_000, true);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.arweaveURI(type(uint256).max, false);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.arweaveOptimizedURI(type(uint256).max, false);
    }

    /// recordOf hands out the raw record, and it has to refuse an id past the
    /// collection with the collection's own error, not whatever a chunk says
    /// when it is asked for a character it does not carry.
    function test_recordOfRefusesAnIdPastTheCollection() public {
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.recordOf(10_000);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.recordOf(type(uint256).max);
    }

    function test_chunkIndexOutOfRangeReverts() public {
        vm.expectRevert(GlamToon.InvalidChunk.selector);
        nft.traitChunk(4);
    }

    /// Two characters may carry the same four traits. What must not repeat is the
    /// character itself, so a shared record still has to leave the two apart: its
    /// own id, its own art, its own page. Checked on the pairs that do share one
    /// and on a fixed sample either way, so it asserts something whether or not
    /// the current table happens to repeat.
    function test_charactersSharingARecordAreStillDistinct() public view {
        uint256[8] memory a = [uint256(0), 1, 2499, 2500, 5000, 7500, 9998, 9999];
        for (uint256 k = 1; k < a.length; ++k) {
            _assertSeparable(a[k - 1], a[k]);
        }

        uint256 shared;
        for (uint256 i = 1; i < 300 && shared < 2; ++i) {
            for (uint256 j = 0; j < i && shared < 2; ++j) {
                if (_record(i) != _record(j)) continue;
                ++shared;
                uint8[4] memory left = nft.traitsOf(i);
                uint8[4] memory right = nft.traitsOf(j);
                for (uint256 c = 0; c < 4; ++c) {
                    assertEq(left[c], right[c], "a shared record decodes differently");
                }
                _assertSeparable(i, j);
            }
        }
    }

    function _assertSeparable(uint256 i, uint256 j) internal view {
        assertTrue(
            keccak256(bytes(nft.tokenJSON(i))) != keccak256(bytes(nft.tokenJSON(j))),
            "two characters produced identical metadata"
        );
        assertTrue(
            keccak256(bytes(nft.imageURI(i, true))) != keccak256(bytes(nft.imageURI(j, true))),
            "two characters point at the same art"
        );
    }

    function _record(uint256 imageId) internal view returns (uint40 packed) {
        uint256 offset = imageId * TraitSchema.STRIDE;
        for (uint256 b = 0; b < TraitSchema.STRIDE; ++b) {
            packed = (packed << 8) | uint40(uint8(fixture[offset + b]));
        }
    }
}
