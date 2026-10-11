// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";
import {TraitSchema} from "../../src/gen/TraitSchema.sol";
import {TraitData0} from "../../src/gen/TraitData0.sol";
import {TraitData1} from "../../src/gen/TraitData1.sol";

/// The trait table read back against traits.csv, the human readable sheet the
/// art was labelled from. Traits.t.sol checks the chain against traits.bin, but
/// the same encoder wrote both, so a bad shift or a swapped column would agree
/// with itself there and still hand every character the wrong face. The CSV is
/// the only artefact in the repo that says what a character actually wears, and
/// the contracts are immutable, so this is the last chance to look.
contract TraitTableTest is BaseTest {
    string internal constant CSV = "test/fixtures/traits.csv";

    /// Records per chunk, and bytes per record, as the sheet has them rather
    /// than as the generated schema claims.
    uint256 internal constant PER_CHUNK = 5000;
    uint256 internal constant STRIDE = 2;

    /*//////////////////////////////////////////////////////////////
                             THE WHOLE TABLE
    //////////////////////////////////////////////////////////////*/

    /// Ten thousand characters, four names each, against the sheet. This is the
    /// test that catches a wrong blob, a wrong shift, a wrong mask, a swapped
    /// pair of categories or an off by one at the chunk seam. Everything else in
    /// this file narrows down a failure it would already have reported.
    function test_everyCharacterReadsBackAsItsRowInTheSheet() public {
        string[] memory cats = nft.categoryNames();
        string[][] memory table = _valueTable();
        bytes32[][] memory want = _hashed(table);

        vm.closeFile(CSV);
        string[] memory header = vm.split(vm.readLine(CSV), ",");
        assertEq(header.length, 5, "the sheet is not one id and four categories wide");
        assertEq(header[0], "imageId", "first column");
        for (uint256 c = 0; c < cats.length; ++c) {
            assertEq(header[c + 1], cats[c], "categoryNames is not in the sheet's column order");
        }

        for (uint256 id = 0; id < 10_000; ++id) {
            string[] memory row = vm.split(vm.readLine(CSV), ",");
            assertEq(row.length, 5, "short row");
            assertEq(vm.parseUint(row[0]), id, "the sheet is not in character order");

            uint8[4] memory values = nft.traitsOf(id);
            for (uint256 c = 0; c < 4; ++c) {
                if (want[c][values[c]] == keccak256(bytes(row[c + 1]))) continue;
                assertEq(table[c][values[c]], row[c + 1], string.concat("character ", vm.toString(id), ", ", cats[c]));
            }
        }

        assertEq(vm.readLine(CSV), "", "the sheet holds more rows than the collection");
        vm.closeFile(CSV);
    }

    /// The value tables are padded out to sixteen slots and the spare ones read
    /// "-", so Traits.t.sol's "every index names something" passes even if every
    /// character points into the padding. Walk the records instead: no character
    /// may land on a dash, and between them they must reach every real name, so
    /// a value base off by one or a table with a phantom entry is caught.
    function test_noCharacterLandsInThePadding() public view {
        string[][] memory table = _valueTable();
        uint256[4] memory used;

        for (uint256 id = 0; id < 10_000; ++id) {
            uint8[4] memory values = nft.traitsOf(id);
            for (uint256 c = 0; c < 4; ++c) {
                assertFalse(
                    _isDash(table[c][values[c]]), string.concat("character ", vm.toString(id), " names a padding slot")
                );
                used[c] |= uint256(1) << values[c];
            }
        }

        for (uint256 c = 0; c < 4; ++c) {
            uint256 real;
            for (uint256 v = 0; v < table[c].length; ++v) {
                if (!_isDash(table[c][v])) ++real;
            }
            assertEq(used[c], (uint256(1) << real) - 1, "the names in use are not exactly the real ones");
        }
    }

    /// The README's rule for a character with no hair, read off the chain: a
    /// Hair Colour of None only ever sits on a Short hair cut. Counted as well,
    /// so a table that lost or gained bald characters is caught here too.
    function test_everyCharacterWithNoHairColourHasTheShortHairCut() public view {
        string[][] memory table = _valueTable();
        bytes32 none = keccak256(bytes("None"));
        bytes32 short = keccak256(bytes("Short"));

        uint256 bald;
        for (uint256 id = 0; id < 10_000; ++id) {
            uint8[4] memory values = nft.traitsOf(id);
            if (keccak256(bytes(table[3][values[3]])) != none) continue;
            ++bald;
            if (keccak256(bytes(table[2][values[2]])) == short) continue;
            assertEq(table[2][values[2]], "Short", string.concat("character ", vm.toString(id), " has no hair colour"));
        }
        assertEq(bald, 395, "the number of characters with no hair colour moved");
    }

    /*//////////////////////////////////////////////////////////////
                                THE SEAM
    //////////////////////////////////////////////////////////////*/

    /// The four characters either side of the chunk boundary, written out. A
    /// chunk that answers for the wrong range moves these by one and nothing in
    /// the sheet sweep says which side it happened on.
    function test_theCharactersEitherSideOfTheSeamReadCorrectly() public view {
        _assertRow(4998, "Neutral,18-25,Long,Dark");
        _assertRow(4999, "Feminine,18-25,Short,None");
        _assertRow(5000, "Crossed,18-25,Medium,Dark");
        _assertRow(5001, "Feminine,41-70,Medium,Dark");
    }

    /// The two ends of the collection, for the same reason.
    function test_theFirstAndLastCharactersReadCorrectly() public view {
        _assertRow(0, "Masculine,18-25,Medium,Medium");
        _assertRow(9998, "Masculine,18-25,Short,Light");
        _assertRow(9999, "Crossed,41-70,Short,Dark");
    }

    /// GlamToon picks a chunk by integer division and the chunks refuse anything
    /// outside their own range. Read both halves of that agreement: if the
    /// routing moved, one of these reverts rather than quietly answering.
    function test_recordOfReadsFromTheChunkThatOwnsTheCharacter() public {
        assertEq(uint256(nft.recordOf(0)), uint256(chunk0.record(0)), "first of chunk zero");
        assertEq(uint256(nft.recordOf(4999)), uint256(chunk0.record(4999)), "last of chunk zero");
        assertEq(uint256(nft.recordOf(5000)), uint256(chunk1.record(5000)), "first of chunk one");
        assertEq(uint256(nft.recordOf(9999)), uint256(chunk1.record(9999)), "last of chunk one");

        vm.expectRevert(TraitData0.OutOfChunk.selector);
        chunk0.record(PER_CHUNK);
        vm.expectRevert(TraitData1.OutOfChunk.selector);
        chunk1.record(PER_CHUNK - 1);
    }

    /// recordOf hands out the raw record and traitsOf hands out its decode. A
    /// page that draws from one and filters on the other has to see the same
    /// character, and the record has to fit the two bytes it is stored in.
    function test_recordOfAndTraitsOfDescribeTheSameCharacter(uint256 seed) public view {
        uint256 id = bound(seed, 0, 9999);
        uint40 packed = nft.recordOf(id);
        uint8[4] memory values = nft.traitsOf(id);

        assertLe(uint256(packed), (uint256(1) << (STRIDE * 8)) - 1, "a record carries bits it has no room for");

        uint256 rebuilt =
            (uint256(values[0]) << 12) | (uint256(values[1]) << 8) | (uint256(values[2]) << 4) | uint256(values[3]);
        assertEq(uint256(packed), rebuilt, "the four fields do not add back up to the record");
    }

    /*//////////////////////////////////////////////////////////////
                                 CHUNKS
    //////////////////////////////////////////////////////////////*/

    /// traitChunk has to hand back the chunk it names, byte for byte. Traits.t
    /// concatenates them and hashes, which passes if both indices return the
    /// same chunk twice and the fixture happened to be that.
    function test_traitChunkReturnsEachChunkByteForByte() public view {
        assertEq(nft.traitChunk(0), chunk0.data(), "chunk zero");
        assertEq(nft.traitChunk(1), chunk1.data(), "chunk one");
        assertEq(nft.traitChunk(0).length, PER_CHUNK * STRIDE, "chunk zero length");
        assertEq(nft.traitChunk(1).length, PER_CHUNK * STRIDE, "chunk one length");
        assertTrue(keccak256(chunk0.data()) != keccak256(chunk1.data()), "the two halves are the same bytes");
    }

    /// Two is the first index there is no chunk for. Traits.t asks for four,
    /// which a bound of `index > CHUNK_COUNT` would still let through.
    function test_chunkTwoIsTheFirstIndexThatReverts() public {
        nft.traitChunk(1);

        vm.expectRevert(GlamToon.InvalidChunk.selector);
        nft.traitChunk(2);
        vm.expectRevert(GlamToon.InvalidChunk.selector);
        nft.traitChunk(type(uint256).max);
    }

    /// allTraits is the bulk read a front end caches once instead of making ten
    /// thousand calls, so it has to be the two chunks in order and nothing else.
    function test_allTraitsIsTheTwoChunksInOrder() public view {
        bytes memory all = nft.allTraits();
        assertEq(all.length, 10_000 * STRIDE, "the whole table is twenty thousand bytes");
        assertEq(all, bytes.concat(chunk0.data(), chunk1.data()), "not chunk zero then chunk one");
    }

    /// The bulk read and the per character read have to agree at the seam, which
    /// is the one offset where a chunk length off by one hides.
    function test_allTraitsAgreesWithRecordOfAtTheSeam() public view {
        bytes memory all = nft.allTraits();
        uint256[5] memory ids = [uint256(0), 4998, 4999, 5000, 9999];
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 offset = ids[i] * STRIDE;
            uint40 packed;
            for (uint256 b = 0; b < STRIDE; ++b) {
                packed = (packed << 8) | uint40(uint8(all[offset + b]));
            }
            assertEq(uint256(nft.recordOf(ids[i])), uint256(packed), "bulk read and single read disagree");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 NAMES
    //////////////////////////////////////////////////////////////*/

    /// Every value table in full. Traits.t spot checks Hair Colour, so a value
    /// base that moved under the other three would name the wrong thing on every
    /// token and no test would say so.
    function test_everyValueTableIsTheRealNamesThenPadding() public view {
        _assertValueTable(0, "Feminine,Masculine,Crossed,Neutral");
        _assertValueTable(1, "18-25,26-40,41-70");
        _assertValueTable(2, "Short,Medium,Long");
        _assertValueTable(3, "None,Light,Medium,Dark");
    }

    /// Four is the first category there is none of. Traits.t asks for ten.
    function test_categoryFourIsTheFirstIndexThatReverts() public {
        nft.valueNames(3);

        vm.expectRevert(GlamToon.InvalidCategory.selector);
        nft.valueNames(4);
        vm.expectRevert(GlamToon.InvalidCategory.selector);
        nft.valueNames(type(uint256).max);
    }

    /// Two categories sharing a name would collide in the metadata, where a
    /// marketplace keys its filters on the trait_type string.
    function test_theFourCategoryNamesAreDistinct() public view {
        string[] memory cats = nft.categoryNames();
        assertEq(cats.length, 4, "four categories");
        for (uint256 i = 0; i < cats.length; ++i) {
            assertGt(bytes(cats[i]).length, 0, "a category names nothing");
            for (uint256 j = 0; j < i; ++j) {
                assertTrue(keccak256(bytes(cats[i])) != keccak256(bytes(cats[j])), "two categories share a name");
            }
        }
    }

    /// The categories own back to back blocks of name slots. If one overlapped
    /// the next, a character's Age would be named out of the Dress Code list and
    /// the metadata would read plausibly while being wrong.
    function test_theValueBlocksTileTheNameTableWithoutOverlapping() public view {
        uint16[4] memory base = TraitSchema.valueBase();
        uint40[4] memory mask = TraitSchema.masks();

        assertEq(uint256(base[0]), 4, "the value blocks start after the four category names");
        for (uint256 c = 0; c + 1 < 4; ++c) {
            assertEq(
                uint256(base[c + 1]), uint256(base[c]) + uint256(mask[c]) + 1, "a value block runs into the next one"
            );
        }

        uint256 slots = uint256(base[3]) + uint256(mask[3]) + 1;
        assertEq(slots, 68, "sixty eight slots");
        assertEq(nft.traitNames().length, 68 * 32, "the name table does not end where the last value block does");
    }

    /// Each category's bits are contiguous and the four of them cover the record
    /// exactly. A gap would throw away a bit the encoder used; an overlap would
    /// make two categories move together.
    function test_theCategoryFieldsTileTheRecordExactly() public pure {
        uint8[4] memory shift = TraitSchema.shifts();
        uint40[4] memory mask = TraitSchema.masks();

        uint256 covered;
        for (uint256 c = 0; c < 4; ++c) {
            uint256 field = uint256(mask[c]) << shift[c];
            assertEq(covered & field, 0, "two categories share a bit");
            covered |= field;
        }
        assertEq(covered, (uint256(1) << (STRIDE * 8)) - 1, "the categories do not cover the whole record");
    }

    /*//////////////////////////////////////////////////////////////
                              BATCH READS
    //////////////////////////////////////////////////////////////*/

    /// traitsBatch answers in the order it was asked, not the order of the
    /// table. A loop that sorted its input, or that reused the previous answer,
    /// passes the ascending case already in the suite and fails this one.
    function test_traitsBatchAnswersInTheOrderAskedAndRepeatsItself() public view {
        uint256[] memory ids = new uint256[](6);
        ids[0] = 9999;
        ids[1] = 0;
        ids[2] = 5000;
        ids[3] = 4999;
        ids[4] = 9999;
        ids[5] = 0;

        uint8[4][] memory batch = nft.traitsBatch(ids);
        assertEq(batch.length, ids.length, "one answer per id");
        for (uint256 i = 0; i < ids.length; ++i) {
            uint8[4] memory one = nft.traitsOf(ids[i]);
            for (uint256 c = 0; c < 4; ++c) {
                assertEq(uint256(batch[i][c]), uint256(one[c]), "batch drifted from the single read");
            }
        }
        for (uint256 c = 0; c < 4; ++c) {
            assertEq(uint256(batch[0][c]), uint256(batch[4][c]), "a repeated id answered differently");
            assertEq(uint256(batch[1][c]), uint256(batch[5][c]), "a repeated id answered differently");
        }
    }

    function test_traitsBatchOfNothingAnswersNothing() public view {
        uint256[] memory none = new uint256[](0);
        assertEq(nft.traitsBatch(none).length, 0, "no answers");
    }

    /// One bad id has to poison the page rather than be answered as zeros, which
    /// would read as a real character wearing the first value of everything.
    function test_traitsBatchRevertsOnAnIdPastTheCollection() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 10_000;
        ids[2] = 2;

        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.traitsBatch(ids);
    }

    /// Random pages in random order, because every fixed case above is an id the
    /// rest of the suite already leans on.
    function test_traitsBatchAgreesWithTraitsOfForAnyPage(uint256 seed) public view {
        uint256 n = bound(seed, 1, 16);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            ids[i] = uint256(keccak256(abi.encode(seed, i))) % 10_000;
        }

        uint8[4][] memory batch = nft.traitsBatch(ids);
        assertEq(batch.length, n, "one answer per id");
        for (uint256 i = 0; i < n; ++i) {
            uint8[4] memory one = nft.traitsOf(ids[i]);
            for (uint256 c = 0; c < 4; ++c) {
                assertEq(uint256(batch[i][c]), uint256(one[c]), "batch drifted from the single read");
            }
        }
    }

    /// A gallery asks about a screenful of characters in whatever order they are
    /// on screen, sometimes twice and sometimes past the end of the collection.
    /// Order, repeats and the out of range answer all have to survive, and
    /// greenCountBatch has never been asked for an id it has no character for.
    function test_theGreenBatchesKeepOrderAndAnswerPastTheEnd() public {
        _green(alice, 9999);
        _green(bob, 9999);
        _green(alice, 0);

        uint256[] memory ids = new uint256[](5);
        ids[0] = 9999;
        ids[1] = 10_000;
        ids[2] = 0;
        ids[3] = 9999;
        ids[4] = type(uint256).max;

        uint256[] memory counts = nft.greenCountBatch(ids);
        assertEq(counts[0], 2, "two generations");
        assertEq(counts[1], 0, "out of range counts zero rather than reverting");
        assertEq(counts[2], 1, "one generation");
        assertEq(counts[3], 2, "a repeated id answered differently");
        assertEq(counts[4], 0, "out of range counts zero rather than reverting");

        bool[] memory taken = nft.greenTakenBatch(ids, alice);
        assertTrue(taken[0], "alice took 9999");
        assertFalse(taken[1], "out of range answers false rather than reverting");
        assertTrue(taken[2], "alice took 0");
        assertTrue(taken[3], "a repeated id answered differently");
        assertFalse(taken[4], "out of range answers false rather than reverting");

        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(counts[i], nft.greenCount(ids[i]), "count batch disagrees with the single read");
            assertEq(taken[i], nft.greenTaken(ids[i], alice), "taken batch disagrees with the single read");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// The four value tables as the chain reports them.
    function _valueTable() internal view returns (string[][] memory table) {
        table = new string[][](4);
        for (uint256 c = 0; c < 4; ++c) {
            table[c] = nft.valueNames(c);
        }
    }

    /// Hashed once so the sweep compares words rather than strings.
    function _hashed(string[][] memory table) internal pure returns (bytes32[][] memory out) {
        out = new bytes32[][](table.length);
        for (uint256 c = 0; c < table.length; ++c) {
            out[c] = new bytes32[](table[c].length);
            for (uint256 v = 0; v < table[c].length; ++v) {
                out[c][v] = keccak256(bytes(table[c][v]));
            }
        }
    }

    /// One character against a row written the way the sheet writes it.
    function _assertRow(uint256 id, string memory row) internal view {
        string[] memory want = vm.split(row, ",");
        string[][] memory table = _valueTable();
        uint8[4] memory values = nft.traitsOf(id);
        for (uint256 c = 0; c < want.length; ++c) {
            assertEq(table[c][values[c]], want[c], string.concat("character ", vm.toString(id)));
        }
    }

    /// One category's value table: the real names in order, then dashes.
    function _assertValueTable(uint256 category, string memory real) internal view {
        string[] memory want = vm.split(real, ",");
        string[] memory got = nft.valueNames(category);
        assertEq(got.length, 16, "four bits, sixteen slots");
        for (uint256 v = 0; v < got.length; ++v) {
            assertEq(got[v], v < want.length ? want[v] : "-", string.concat("category ", vm.toString(category)));
        }
    }

    function _isDash(string memory value) internal pure returns (bool) {
        return keccak256(bytes(value)) == keccak256(bytes("-"));
    }
}
