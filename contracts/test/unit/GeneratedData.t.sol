// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";
import {TraitData0} from "../../src/gen/TraitData0.sol";
import {TraitData1} from "../../src/gen/TraitData1.sol";
import {TraitNames} from "../../src/gen/TraitNames.sol";
import {TraitSchema} from "../../src/gen/TraitSchema.sol";

/// The generated contracts called on their own terms rather than through
/// GlamToon. GlamToon checks the image id first and routes by division, so its
/// callers can never make a chunk refuse anything: the bounds checks inside the
/// generated code are the last defence against a bad regeneration, and until
/// something calls them directly they are dead code that nothing would miss.
/// These tests call them directly, then pin the bytes sitting behind them.
contract GeneratedDataTest is BaseTest {
    uint256 internal constant PER_CHUNK = 5000;
    uint256 internal constant LAST_ID = 9999;
    uint256 internal constant SLOTS = 68;
    uint256 internal constant SLOT_BYTES = 32;

    /*//////////////////////////////////////////////////////////////
                              CHUNK BOUNDS
    //////////////////////////////////////////////////////////////*/

    /// Chunk zero owns 0 to 4999. The first character past its range is the one
    /// a regenerated table with the wrong split would hand it, so that boundary
    /// has to be exact rather than roughly right.
    function test_chunkZeroAnswersItsLastCharacterAndRefusesTheNextOne() public {
        uint40 last = chunk0.record(PER_CHUNK - 1);
        assertEq(uint256(last), uint256(nft.recordOf(PER_CHUNK - 1)), "4999 belongs to chunk zero");

        vm.expectRevert(TraitData0.OutOfChunk.selector);
        chunk0.record(PER_CHUNK);

        vm.expectRevert(TraitData0.OutOfChunk.selector);
        chunk0.record(PER_CHUNK + 1);
    }

    /// The mirror of the seam from the other side. Chunk one's guard is the only
    /// one in the system with a reachable lower bound, and a chunk that answered
    /// below its own range would read 4999 out of the wrong end of its bytes and
    /// name some other character's traits.
    function test_chunkOneRefusesEveryCharacterBelowItsFirst() public {
        uint40 first = chunk1.record(PER_CHUNK);
        assertEq(uint256(first), uint256(nft.recordOf(PER_CHUNK)), "5000 belongs to chunk one");

        vm.expectRevert(TraitData1.OutOfChunk.selector);
        chunk1.record(PER_CHUNK - 1);

        vm.expectRevert(TraitData1.OutOfChunk.selector);
        chunk1.record(0);

        vm.expectRevert(TraitData1.OutOfChunk.selector);
        chunk1.record(1);

        vm.expectRevert(TraitData1.OutOfChunk.selector);
        chunk1.record(PER_CHUNK - 2);
    }

    /// Neither chunk carries a character the collection does not have. Ten
    /// thousand is the first such id and the maximum word is the last, and both
    /// have to bounce off the same guard rather than index past the blob.
    function test_neitherChunkAnswersPastTheEndOfTheCollection() public {
        uint40 last = chunk1.record(LAST_ID);
        assertEq(uint256(last), uint256(nft.recordOf(LAST_ID)), "9999 belongs to chunk one");

        vm.expectRevert(TraitData1.OutOfChunk.selector);
        chunk1.record(TraitSchema.IMAGE_COUNT);

        vm.expectRevert(TraitData1.OutOfChunk.selector);
        chunk1.record(type(uint256).max);

        vm.expectRevert(TraitData0.OutOfChunk.selector);
        chunk0.record(TraitSchema.IMAGE_COUNT);

        vm.expectRevert(TraitData0.OutOfChunk.selector);
        chunk0.record(type(uint256).max);
    }

    /// Chunk zero starts at character zero, so its lower bound can never fire.
    /// Pin that the first character still reads, because a chunk that began at
    /// one would shift every record in the collection by a character.
    function test_chunkZeroAnswersForCharacterZero() public view {
        assertEq(uint256(chunk0.FIRST_IMAGE_ID()), 0, "chunk zero starts at the first character");
        assertEq(uint256(chunk0.record(0)), uint256(nft.recordOf(0)), "character zero");
    }

    /*//////////////////////////////////////////////////////////////
                              NAME BOUNDS
    //////////////////////////////////////////////////////////////*/

    /// The name table is padded so every index a record can hold names
    /// something, which means nothing in normal use ever asks for a slot past
    /// the end. The guard behind that is still the difference between a revert
    /// and a read off the end of a memory copy.
    function test_namesAtRefusesTheFirstSlotPastTheTable() public {
        uint256 count = names.SLOT_COUNT();
        assertEq(count, SLOTS, "the table is sixty eight slots");

        uint256[] memory lastSlot = _slots(count - 1);
        assertEq(names.namesAt(lastSlot)[0], "-", "the last slot is padding and reads as a dash");

        uint256[] memory past = _slots(count);
        vm.expectRevert(TraitNames.OutOfRange.selector);
        names.namesAt(past);

        uint256[] memory wayPast = _slots(count + 1);
        vm.expectRevert(TraitNames.OutOfRange.selector);
        names.namesAt(wayPast);

        uint256[] memory huge = _slots(type(uint256).max);
        vm.expectRevert(TraitNames.OutOfRange.selector);
        names.namesAt(huge);
    }

    /// A guard that only looks at the first element passes every test that puts
    /// the bad slot first. Bury it at the end of a long request instead: that is
    /// the shape _attributes builds, one slot per category interleaved with its
    /// value, and the bad one would be the last thing appended.
    function test_aBadSlotAtTheEndOfALongRequestStillReverts() public {
        uint256 count = names.SLOT_COUNT();

        uint256[] memory good = new uint256[](20);
        for (uint256 i = 0; i < good.length; ++i) {
            good[i] = i;
        }
        assertEq(names.namesAt(good).length, 20, "twenty valid slots answer twenty names");

        uint256[] memory tail = new uint256[](20);
        for (uint256 i = 0; i < tail.length; ++i) {
            tail[i] = i;
        }
        tail[19] = count;
        vm.expectRevert(TraitNames.OutOfRange.selector);
        names.namesAt(tail);

        uint256[] memory middle = new uint256[](20);
        for (uint256 i = 0; i < middle.length; ++i) {
            middle[i] = i;
        }
        middle[9] = type(uint256).max;
        vm.expectRevert(TraitNames.OutOfRange.selector);
        names.namesAt(middle);
    }

    /// Asking for nothing is not an error, and must not become one by way of a
    /// loop that reads slots[0] before it checks the length.
    function test_askingForNoNamesAnswersWithNone() public view {
        uint256[] memory none = new uint256[](0);
        assertEq(names.namesAt(none).length, 0, "no slots, no names");
    }

    /// _read stops at a zero byte or at the end of the slot, whichever comes
    /// first, and the second half has never been reachable: the longest name in
    /// the table is eleven bytes against a slot of thirty two. A mutation that
    /// narrows the bound to SLOT - 1 therefore changes nothing today. Pin the
    /// reason, so a regenerated table that fills a slot to the brim fails here
    /// and whoever did it has to prove the boundary instead of inheriting it.
    function test_noNameReachesTheEndOfItsSlot() public view {
        bytes memory table = names.data();
        uint256 slots = names.SLOT_COUNT();
        uint256 width = table.length / slots;

        for (uint256 slot = 0; slot < slots; ++slot) {
            assertEq(uint8(table[slot * width + width - 1]), 0, "a name reaches the last byte of its slot");
        }
    }

    /*//////////////////////////////////////////////////////////////
                            THE IMAGE ID GUARD
    //////////////////////////////////////////////////////////////*/

    /// blueTaken is what a front end polls before it lets someone buy. An id
    /// past the collection has to revert rather than answer false, or a typo in
    /// a query string reads back as a character that is still for sale.
    function test_blueTakenRefusesACharacterTheCollectionDoesNotHave() public {
        assertFalse(nft.blueTaken(LAST_ID), "the last character answers before it sells");

        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.blueTaken(TraitSchema.IMAGE_COUNT);

        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.blueTaken(TraitSchema.IMAGE_COUNT + 1);

        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.blueTaken(type(uint256).max);
    }

    /// The guard is on the character, not on whether anything has sold. Selling
    /// the last character must not make the id after it start answering.
    function test_theImageIdGuardDoesNotSoftenOnceTheSaleHasRun() public {
        _buy(alice, LAST_ID);
        assertTrue(nft.blueTaken(LAST_ID), "the last character is sold");

        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.blueTaken(TraitSchema.IMAGE_COUNT);
    }

    /*//////////////////////////////////////////////////////////////
                              PINNED BYTES
    //////////////////////////////////////////////////////////////*/

    /// A chunk hands out bytes through data() and swears to them through
    /// dataHash(). The constructor only ever compares the hash, so a chunk whose
    /// two answers disagreed would pass deployment and then serve a table nobody
    /// ever pinned.
    function test_eachChunkHashesTheBytesItActuallyHandsOut() public view {
        assertEq(chunk0.dataHash(), keccak256(chunk0.data()), "chunk zero swears to bytes it does not serve");
        assertEq(chunk1.dataHash(), keccak256(chunk1.data()), "chunk one swears to bytes it does not serve");

        assertEq(chunk0.dataHash(), TraitSchema.DATA_HASH_0, "chunk zero drifted from the schema");
        assertEq(chunk1.dataHash(), TraitSchema.DATA_HASH_1, "chunk one drifted from the schema");
    }

    /// Same contract, same promise, for the name table.
    function test_theNameTableHashesTheBytesItActuallyHandsOut() public view {
        assertEq(names.namesHash(), keccak256(names.data()), "the table swears to bytes it does not serve");
        assertEq(names.namesHash(), TraitSchema.NAMES_HASH, "the name table drifted from the schema");
    }

    /// Half the collection encoded twice would hash cleanly against itself and
    /// be wrong for five thousand characters. The two halves have to be two
    /// different things.
    function test_theTwoChunksAreNotTheSameBytesTwice() public view {
        assertTrue(TraitSchema.DATA_HASH_0 != TraitSchema.DATA_HASH_1, "the schema pins one blob twice");
        assertTrue(keccak256(chunk0.data()) != keccak256(chunk1.data()), "both chunks carry the same records");
    }

    /// A truncated table still hashes to something. Length is the one property
    /// the hash cannot tell you about, so state it: stride times the characters
    /// each chunk carries, and thirty two bytes for every name slot.
    function test_theTablesAreExactlyAsLongAsTheSchemaSays() public view {
        uint256 expected = TraitSchema.IMAGES_PER_CHUNK * TraitSchema.STRIDE;
        assertEq(expected, 10_000, "five thousand two byte records");

        assertEq(chunk0.data().length, expected, "chunk zero is the wrong length");
        assertEq(chunk1.data().length, expected, "chunk one is the wrong length");
        assertEq(names.data().length, SLOTS * SLOT_BYTES, "the name table is the wrong length");
        assertEq(names.SLOT(), SLOT_BYTES, "a name slot is not thirty two bytes");
    }

    /*//////////////////////////////////////////////////////////////
                           RECORDS AND OFFSETS
    //////////////////////////////////////////////////////////////*/

    /// record() reads a character out of the blob at an offset it computes from
    /// the chunk's own first id. Check the arithmetic against the raw bytes at
    /// both ends of both chunks: an offset that forgot to subtract FIRST_IMAGE_ID
    /// reverts on every read from chunk one, and one that was off by a record
    /// would still answer, plausibly, for the wrong character.
    function test_eachChunkReadsTheRecordSittingAtTheRightOffset() public view {
        bytes memory zero = chunk0.data();
        _assertRecordSitsAt(chunk0.record(0), zero, 0, "chunk zero, first");
        _assertRecordSitsAt(chunk0.record(PER_CHUNK - 1), zero, (PER_CHUNK - 1) * 2, "chunk zero, last");

        bytes memory one = chunk1.data();
        _assertRecordSitsAt(chunk1.record(PER_CHUNK), one, 0, "chunk one, first");
        _assertRecordSitsAt(chunk1.record(LAST_ID), one, (PER_CHUNK - 1) * 2, "chunk one, last");
    }

    /// The ends can be right while the middle slides. Walk a spread of both
    /// chunks and hold every record against the bytes it claims to come from and
    /// against what GlamToon serves for the same character.
    function test_aSpreadOfRecordsAgreesWithTheBytesAndWithGlamToon() public view {
        bytes memory zero = chunk0.data();
        for (uint256 id = 0; id < PER_CHUNK; id += 250) {
            uint40 packed = chunk0.record(id);
            _assertRecordSitsAt(packed, zero, id * 2, "chunk zero");
            assertEq(uint256(packed), uint256(nft.recordOf(id)), "chunk zero disagrees with GlamToon");
        }

        bytes memory one = chunk1.data();
        for (uint256 id = PER_CHUNK; id < TraitSchema.IMAGE_COUNT; id += 250) {
            uint40 packed = chunk1.record(id);
            _assertRecordSitsAt(packed, one, (id - PER_CHUNK) * 2, "chunk one");
            assertEq(uint256(packed), uint256(nft.recordOf(id)), "chunk one disagrees with GlamToon");
        }
    }

    /*//////////////////////////////////////////////////////////////
                           SCHEMA CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    /// The chunks have to tile the collection exactly: no character in both, no
    /// character in neither. Each chunk's own constants are the ones record()
    /// uses, so they are what has to agree with the schema, not the comments.
    function test_theChunksTileTheCollectionWithNoGapAndNoOverlap() public view {
        assertEq(
            TraitSchema.IMAGES_PER_CHUNK * TraitSchema.CHUNK_COUNT, TraitSchema.IMAGE_COUNT, "the halves do not add up"
        );
        assertEq(TraitSchema.IMAGE_COUNT, 10_000, "the collection is ten thousand characters");
        assertEq(nft.IMAGE_COUNT(), TraitSchema.IMAGE_COUNT, "GlamToon counts a different collection");

        assertEq(chunk0.FIRST_IMAGE_ID(), 0, "chunk zero does not start at the beginning");
        assertEq(chunk0.IMAGE_COUNT(), TraitSchema.IMAGES_PER_CHUNK, "chunk zero carries the wrong count");
        assertEq(
            chunk1.FIRST_IMAGE_ID(),
            chunk0.FIRST_IMAGE_ID() + chunk0.IMAGE_COUNT(),
            "chunk one does not start where chunk zero ends"
        );
        assertEq(
            chunk1.FIRST_IMAGE_ID() + chunk1.IMAGE_COUNT(),
            TraitSchema.IMAGE_COUNT,
            "chunk one does not end at the last character"
        );

        assertEq(chunk0.STRIDE(), TraitSchema.STRIDE, "chunk zero strides differently from the schema");
        assertEq(chunk1.STRIDE(), TraitSchema.STRIDE, "chunk one strides differently from the schema");
    }

    /// The deploy script refuses any real chain unless every row came from real
    /// art. That check is only worth something while REAL_ROWS means what it
    /// says, so hold the generated constant to the whole collection.
    function test_everyRowInTheTableCameFromRealArt() public pure {
        assertEq(TraitSchema.REAL_ROWS, TraitSchema.IMAGE_COUNT, "some rows are filler");
        assertEq(TraitSchema.REAL_ROWS, 10_000, "ten thousand real rows");
    }

    /// Every category is a contiguous run of bits, the runs are laid out most
    /// significant first, and together they fill the record with nothing left
    /// over. A gap throws away a bit the encoder wrote; an overlap ties two
    /// categories together so they change as one.
    function test_theCategoryFieldsAreContiguousAndFillTheRecord() public pure {
        uint8[4] memory shift = TraitSchema.shifts();
        uint40[4] memory mask = TraitSchema.masks();
        uint256 width = TraitSchema.STRIDE * 8;

        uint256 covered;
        for (uint256 c = 0; c < TraitSchema.CATEGORY_COUNT; ++c) {
            uint256 m = uint256(mask[c]);
            assertGt(m, 0, "a category has no bits at all");
            assertEq(m & (m + 1), 0, "a category's mask is not a contiguous run of low bits");

            uint256 bits = _bitWidth(m);
            assertLe(uint256(shift[c]) + bits, width, "a category hangs off the end of the record");

            if (c > 0) {
                assertGt(
                    uint256(shift[c - 1]), uint256(shift[c]), "the categories are not ordered most significant first"
                );
            }

            uint256 field = m << shift[c];
            assertEq(covered & field, 0, "two categories share a bit");
            covered |= field;
        }

        assertEq(covered, (uint256(1) << width) - 1, "the categories leave a bit of the record unused");
    }

    /// The value tables sit one after another behind the category names, and the
    /// last index the last category can hold has to land inside the table. One
    /// slot further and a real character's metadata reverts, permanently.
    function test_theValueTablesAscendAndEndInsideTheNameTable() public view {
        uint16[4] memory base = TraitSchema.valueBase();
        uint40[4] memory mask = TraitSchema.masks();
        uint256 count = names.SLOT_COUNT();

        assertGe(uint256(base[0]), TraitSchema.CATEGORY_COUNT, "a value table overwrites a category name");

        for (uint256 c = 0; c < TraitSchema.CATEGORY_COUNT; ++c) {
            if (c > 0) {
                assertGt(uint256(base[c]), uint256(base[c - 1]), "the value tables do not ascend");
                assertGe(
                    uint256(base[c]),
                    uint256(base[c - 1]) + uint256(mask[c - 1]) + 1,
                    "a value table runs into the one after it"
                );
            }
            uint256 highest = uint256(base[c]) + uint256(mask[c]);
            assertLt(highest, count, "a reachable value index falls off the end of the name table");
        }

        uint256 top = uint256(base[TraitSchema.CATEGORY_COUNT - 1]) + uint256(mask[TraitSchema.CATEGORY_COUNT - 1]);
        assertEq(top, count - 1, "the tables do not reach the last slot of the name table");
    }

    /*//////////////////////////////////////////////////////////////
                             JSON SAFE NAMES
    //////////////////////////////////////////////////////////////*/

    /// _attributes drops names straight into JSON between quotes with no
    /// escaping anywhere. That is only safe because of the table, so assert the
    /// table: nothing empty, no quote, no backslash, no control byte, nothing
    /// outside plain printable ASCII. One bad byte in a regenerated table breaks
    /// tokenURI for every character that carries it, forever.
    function test_noNameCarriesAByteThatWouldBreakTheJson() public view {
        string[] memory all = _everyName();

        for (uint256 i = 0; i < all.length; ++i) {
            bytes memory name = bytes(all[i]);
            assertGt(name.length, 0, "a name slot is empty");

            for (uint256 j = 0; j < name.length; ++j) {
                uint8 b = uint8(name[j]);
                assertTrue(b != 0x22, "a name carries a double quote");
                assertTrue(b != 0x5c, "a name carries a backslash");
                assertGe(b, 0x20, "a name carries a control byte");
                assertLt(b, 0x7f, "a name carries a byte outside printable ASCII");
            }
        }
    }

    /// The property stated the way the metadata uses it. Wrap each name the way
    /// _attributes does and count the quotes: two, the ones we put there. A name
    /// that could close the string early would show up here as three.
    function test_everyNameSurvivesBeingDroppedIntoJsonUnescaped() public view {
        string[] memory all = _everyName();

        for (uint256 i = 0; i < all.length; ++i) {
            bytes memory quoted = bytes(string.concat('"', all[i], '"'));
            uint256 quotes;
            uint256 slashes;
            for (uint256 j = 0; j < quoted.length; ++j) {
                if (quoted[j] == '"') ++quotes;
                if (quoted[j] == "\\") ++slashes;
            }
            assertEq(quotes, 2, "a name opens or closes a JSON string of its own");
            assertEq(slashes, 0, "a name starts an escape sequence");
        }
    }

    /// _read stops at the first zero byte and hands back everything before it.
    /// If a slot carried anything after its terminator, the table would be
    /// pinned over bytes no reader ever sees, and a later reader that trimmed
    /// differently would get a different name from the same pinned hash.
    function test_everyNameSlotIsTheTrimmedTextAndThenNothing() public view {
        bytes memory table = names.data();
        string[] memory all = _everyName();

        for (uint256 slot = 0; slot < SLOTS; ++slot) {
            bytes memory name = bytes(all[slot]);
            uint256 start = slot * SLOT_BYTES;

            for (uint256 i = 0; i < name.length; ++i) {
                assertEq(name[i], table[start + i], "a name does not match its slot");
            }
            for (uint256 i = name.length; i < SLOT_BYTES; ++i) {
                assertEq(uint8(table[start + i]), 0, "a name slot carries bytes past its terminator");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// A one element request, so a bad slot can be hoisted out of an
    /// expectRevert window rather than built inside it.
    function _slots(uint256 slot) private pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = slot;
    }

    /// Every name in the table, in slot order.
    function _everyName() private view returns (string[] memory) {
        uint256[] memory slots = new uint256[](SLOTS);
        for (uint256 i = 0; i < SLOTS; ++i) {
            slots[i] = i;
        }
        return names.namesAt(slots);
    }

    /// A two byte record read big endian out of `blob` at `offset`, stated as
    /// two separate bytes rather than rebuilt the way the contract does.
    function _assertRecordSitsAt(uint40 packed, bytes memory blob, uint256 offset, string memory what) private pure {
        assertEq(uint256(packed) >> 16, 0, string.concat(what, ": record does not fit its stride"));
        assertEq(uint256(packed) >> 8, uint256(uint8(blob[offset])), string.concat(what, ": high byte"));
        assertEq(uint256(packed) & 0xff, uint256(uint8(blob[offset + 1])), string.concat(what, ": low byte"));
    }

    /// How many bits a contiguous low run of ones occupies.
    function _bitWidth(uint256 mask) private pure returns (uint256 bits) {
        while (mask != 0) {
            mask >>= 1;
            ++bits;
        }
    }
}
