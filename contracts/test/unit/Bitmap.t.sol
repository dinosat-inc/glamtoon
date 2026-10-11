// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";

/// The blue bitmap is what the website reads to grey out sold characters. It is
/// a view over a private mapping, so nothing else in the contract cross checks
/// it: if it lies, it lies silently and the picker sends buyers at characters
/// that are gone, or hides ones that are free. These tests pin it in both
/// directions and pin the packing, because the reader depends on the exact
/// word-and-bit layout the NatSpec promises.
contract BitmapTest is BaseTest {
    uint256 internal constant WORDS = 40;

    /*//////////////////////////////////////////////////////////////
                              EMPTY TO START
    //////////////////////////////////////////////////////////////*/

    /// The suite had no test that could fail if every bit read back as one. A
    /// bitmap stuck at all-taken greys out the entire collection on day one.
    function test_theBitmapStartsCompletelyEmpty() public view {
        uint256[] memory map = nft.blueTakenBits(0, WORDS);
        assertEq(map.length, WORDS, "forty words");
        for (uint256 w = 0; w < WORDS; ++w) {
            assertEq(map[w], 0, string.concat("word ", vm.toString(w), " is not empty"));
        }
        assertEq(_setBits(map), 0, "no bit set before a single sale");
        assertEq(nft.blueMinted(), 0, "no sale recorded either");

        uint256[] memory spread = _spread(64, 157);
        for (uint256 i = 0; i < spread.length; ++i) {
            assertFalse(nft.blueTaken(spread[i]), "character reported sold before the sale");
        }
    }

    /*//////////////////////////////////////////////////////////////
                             ONE SALE, ONE BIT
    //////////////////////////////////////////////////////////////*/

    /// Selling one character must move one bit and nothing else. An off by one
    /// in the shift, or a mask written over the whole word, would still leave
    /// the seller's own bit set and pass a test that only looked there.
    function test_sellingOneCharacterSetsExactlyItsOwnBit() public {
        _buy(alice, 4242);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 4242;
        _assertMapIs(_expectedMap(ids), "after one sale");
        assertEq(_setBits(nft.blueTakenBits(0, WORDS)), 1, "exactly one bit in the whole bitmap");
    }

    /// The property the picker leans on, character by character: a bit is zero
    /// until that exact character sells, and every other bit stays where it was.
    function test_everyBitFlipsOnlyWhenItsOwnCharacterSells() public {
        uint256[] memory ids = _spread(24, 419);
        uint256[] memory sold = new uint256[](ids.length);

        for (uint256 i = 0; i < ids.length; ++i) {
            uint256[] memory current = nft.blueTakenBits(0, WORDS);
            assertEq(_bitOf(current, ids[i]), 0, "bit set before the character sold");
            assertFalse(nft.blueTaken(ids[i]), "reported sold before the character sold");

            _buy(bob, ids[i]);

            sold[i] = ids[i];
            uint256[] memory want = _expectedMap(_head(sold, i + 1));
            _assertMapIs(want, string.concat("after selling ", vm.toString(ids[i])));
            assertTrue(nft.blueTaken(ids[i]), "not reported sold");
            assertEq(_setBits(nft.blueTakenBits(0, WORDS)), i + 1, "bit count drifted from sales");
        }
    }

    /// Four hundred sales spread over all forty words, checked against a map
    /// built outside the contract. Catches a write that is correct for one
    /// character but collides with another once the bitmap fills up. The step
    /// lands a sale in the last word too, which holds only sixteen characters,
    /// and every word is checked to have been reached.
    function test_theBitmapStaysExactOverAFullSpreadOfSales() public {
        uint256[] memory ids = _spread(400, 27);
        for (uint256 i = 0; i < ids.length; ++i) {
            _buy(alice, ids[i]);
        }

        _assertMapIs(_expectedMap(ids), "after four hundred sales");
        uint256[] memory map = nft.blueTakenBits(0, WORDS);
        for (uint256 w = 0; w < WORDS; ++w) {
            assertTrue(map[w] != 0, string.concat("the spread never reached word ", vm.toString(w)));
        }
        assertEq(_setBits(map), ids.length, "bit count does not match the sales");
        assertEq(nft.blueMinted(), ids.length, "sale count does not match either");
    }

    /*//////////////////////////////////////////////////////////////
                             WORD BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    /// The first and last bit of a word are where a shift or an index goes
    /// wrong. These nine ids are every such seam the collection has.
    function test_boundaryCharactersLandInTheRightWordAndBit() public {
        uint256[9] memory ids = [uint256(0), 1, 255, 256, 257, 511, 512, 9983, 9999];
        uint256[9] memory wantWord = [uint256(0), 0, 0, 1, 1, 1, 2, 38, 39];
        uint256[9] memory wantBit = [uint256(0), 1, 255, 0, 1, 255, 0, 255, 15];

        uint256[] memory sold = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(_bitOf(nft.blueTakenBits(0, WORDS), ids[i]), 0, "bit set before the sale");

            _buy(carol, ids[i]);

            uint256 word = nft.blueTakenBits(wantWord[i], 1)[0];
            assertEq((word >> wantBit[i]) & 1, 1, string.concat("id ", vm.toString(ids[i]), " missed its bit"));

            sold[i] = ids[i];
            _assertMapIs(_expectedMap(_head(sold, i + 1)), string.concat("after id ", vm.toString(ids[i])));
        }

        assertEq(_setBits(nft.blueTakenBits(0, WORDS)), ids.length, "nine seams, nine bits");
    }

    /// A contiguous run straddling the 255 to 256 seam, checked against hand
    /// written masks rather than against the contract's own arithmetic.
    function test_aRunAcrossAWordBoundaryFillsBothEnds() public {
        for (uint256 id = 250; id <= 265; ++id) {
            _buy(alice, id);
        }

        uint256[] memory map = nft.blueTakenBits(0, 2);
        assertEq(map[0], uint256(0x3f) << 250, "word 0 should hold ids 250 to 255 and nothing lower");
        assertEq(map[1], uint256(0x3ff), "word 1 should hold ids 256 to 265 and nothing higher");
        assertEq(_setBits(nft.blueTakenBits(0, WORDS)), 16, "sixteen sales, sixteen bits");
    }

    /// Ten thousand characters do not fill forty words. The last word carries
    /// sixteen live bits and 240 that no sale can ever reach, so a reader that
    /// walks the tail must see zeros there rather than padding.
    function test_theLastWordHoldsTheLastSixteenCharacters() public {
        assertEq(nft.blueBitmapWords(), WORDS, "forty words cover the collection");

        _buy(alice, 9984);
        _buy(alice, 9999);

        uint256 last = nft.blueTakenBits(39, 1)[0];
        assertEq(last, uint256(1) | (uint256(1) << 15), "word 39 should hold only ids 9984 and 9999");

        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.blueTaken(10_000);
        vm.prank(bob);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.mintBlue{value: 1 ether}(10_000, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                              READING RANGES
    //////////////////////////////////////////////////////////////*/

    /// A reader paging the bitmap must get the page it asked for. Dropping
    /// startWord from the lookup returns word zero over and over and is
    /// invisible to any test that only ever reads from word zero.
    function test_aPartialReadIsOffsetByStartWord() public {
        uint256[] memory ids = new uint256[](5);
        ids[0] = 3;
        ids[1] = 600;
        ids[2] = 800;
        ids[3] = 1100;
        ids[4] = 1900;
        for (uint256 i = 0; i < ids.length; ++i) {
            _buy(alice, ids[i]);
        }

        uint256[] memory full = nft.blueTakenBits(0, WORDS);
        uint256[] memory page = nft.blueTakenBits(2, 3);
        assertEq(page.length, 3, "three words asked for");
        assertEq(page[0], full[2], "page did not start at word 2");
        assertEq(page[1], full[3], "second word of the page is wrong");
        assertEq(page[2], full[4], "third word of the page is wrong");

        assertEq(page[0], uint256(1) << 88, "id 600 is word 2 bit 88");
        assertTrue(page[0] != full[0], "the page must not be a copy of word 0");

        uint256[] memory one = nft.blueTakenBits(7, 1);
        assertEq(one[0], uint256(1) << 108, "id 1900 is word 7 bit 108");
    }

    /// Reading nothing is allowed and is not a way to read something. The
    /// guard's arithmetic subtracts words from the total, so zero is the case
    /// where it could underflow or let a start past the end slip through.
    function test_readingZeroWordsReturnsAnEmptyArray() public view {
        assertEq(nft.blueTakenBits(0, 0).length, 0, "zero words from the start");
        assertEq(nft.blueTakenBits(39, 0).length, 0, "zero words from the last word");
        assertEq(nft.blueTakenBits(WORDS, 0).length, 0, "zero words from past the end");
    }

    /// The last word can be read on its own; asking for one more word than
    /// exists must revert rather than hand back a word of neighbouring storage.
    function test_theLastWordReadsAloneButNotWithAPartner() public {
        _buy(alice, 9999);

        uint256[] memory one = nft.blueTakenBits(39, 1);
        assertEq(one.length, 1, "one word");
        assertEq(one[0], uint256(1) << 15, "the last word, with id 9999 in it");

        vm.expectRevert(GlamToon.InvalidWordRange.selector);
        nft.blueTakenBits(39, 2);
    }

    /// Every other way of asking for more of the bitmap than exists.
    function test_readingPastTheEndOfTheBitmapReverts() public {
        uint256[] memory all = nft.blueTakenBits(0, WORDS);
        assertEq(all.length, WORDS, "the whole bitmap in one call");

        vm.expectRevert(GlamToon.InvalidWordRange.selector);
        nft.blueTakenBits(0, WORDS + 1);
        vm.expectRevert(GlamToon.InvalidWordRange.selector);
        nft.blueTakenBits(WORDS, 1);
        vm.expectRevert(GlamToon.InvalidWordRange.selector);
        nft.blueTakenBits(1, WORDS);
        vm.expectRevert(GlamToon.InvalidWordRange.selector);
        nft.blueTakenBits(type(uint256).max, 1);
        vm.expectRevert(GlamToon.InvalidWordRange.selector);
        nft.blueTakenBits(0, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        WHAT THE BITMAP DOES NOT TRACK
    //////////////////////////////////////////////////////////////*/

    /// The bitmap records the sale, not the holding. If it followed the token
    /// around, a resale would put the character back on the picker as free.
    function test_aTransferDoesNotChangeTheBitmap() public {
        _buy(alice, 512);
        uint256[] memory atSale = nft.blueTakenBits(0, WORDS);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 512);
        _assertMapIs(atSale, "after a plain transfer");

        vm.prank(bob);
        nft.safeTransferFrom(bob, carol, 512);
        _assertMapIs(atSale, "after a safe transfer");

        assertEq(nft.ownerOf(512), carol, "the token moved");
        assertTrue(nft.blueTaken(512), "the character is still sold");
        assertEq(nft.blueMinted(), 1, "one sale, not three");
    }

    /// Green is free and uncapped, and lives above the blue bitmap entirely. A
    /// green mint that set a bit would grey out a character nobody has bought.
    function test_greenMintsNeverTouchTheBlueBitmap() public {
        _green(alice, 5);
        _green(bob, 5);
        _green(carol, 5);
        _green(alice, 9999);

        uint256[] memory map = nft.blueTakenBits(0, WORDS);
        assertEq(_setBits(map), 0, "a green mint moved a blue bit");
        assertFalse(nft.blueTaken(5), "character 5 is still for sale");
        assertFalse(nft.blueTaken(9999), "character 9999 is still for sale");
        assertEq(nft.greenMinted(), 4, "the greens did happen");

        _buy(alice, 5);
        uint256[] memory after_ = nft.blueTakenBits(0, WORDS);
        assertEq(_setBits(after_), 1, "only the blue sale sets a bit");
        assertEq(_bitOf(after_, 5), 1, "and it is character 5's bit");
    }

    /// A gift hands control to the recipient in the middle of the mint. The
    /// contract promises every state write lands before that handover, so a
    /// receiver that looks at the bitmap on the way in must already see itself.
    function test_theRecipientSeesItsOwnBitWhileTheMintIsStillRunning() public {
        BitmapWatcher watcher = new BitmapWatcher(nft);
        uint256 price = _price();

        vm.prank(alice);
        nft.mintBlueFor{value: price}(address(watcher), 777, price);

        assertTrue(watcher.received(), "the hook never ran");
        assertEq(watcher.wordAtReceipt(), uint256(1) << (777 & 0xff), "bit not set yet when the token landed");
        assertEq(watcher.soldAtReceipt(), 1, "sale not counted yet when the token landed");
        assertEq(nft.ownerOf(777), address(watcher), "and the mint completed");
    }

    /*//////////////////////////////////////////////////////////////
                         AGREEMENT WITH OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    /// After an arbitrary mix of sales through both doors, the bitmap and
    /// ownership must tell the same story, in both directions, for characters
    /// that sold and for characters that did not.
    function test_theBitmapAgreesWithOwnershipAfterAnArbitraryMix(uint256 seed) public {
        uint256 first = bound(seed, 0, 9_999);
        uint256[] memory ids = new uint256[](8);
        address[] memory owners = new address[](8);
        uint256 n;

        for (uint256 i = 0; n < ids.length && i < 64; ++i) {
            uint256 id = i == 0 ? first : uint256(keccak256(abi.encode(seed, i))) % 10_000;
            if (nft.blueTaken(id)) continue;

            if (n % 2 == 0) {
                _buy(alice, id);
                owners[n] = alice;
            } else {
                uint256 price = nft.currentPrice();
                vm.prank(alice);
                nft.mintBlueFor{value: price}(bob, id, price);
                owners[n] = bob;
            }
            ids[n] = id;
            ++n;
        }
        assertEq(n, ids.length, "could not find eight free characters");

        uint256[] memory map = nft.blueTakenBits(0, WORDS);
        assertEq(_setBits(map), ids.length, "bit count does not match the sales");
        assertEq(nft.blueMinted(), ids.length, "sale count does not match the sales");

        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(_bitOf(map, ids[i]), 1, "sold character has no bit");
            assertTrue(nft.blueTaken(ids[i]), "sold character not reported sold");
            assertEq(nft.ownerOf(ids[i]), owners[i], "wrong owner");
        }

        uint256 untouched;
        for (uint256 j = 0; j < 96; ++j) {
            uint256 id = uint256(keccak256(abi.encode("sample", seed, j))) % 10_000;
            bool taken = nft.blueTaken(id);
            assertEq(_bitOf(map, id), taken ? 1 : 0, "bitmap disagrees with ownership");
            if (!taken) ++untouched;
        }
        assertGt(untouched, 40, "the sample never exercised an unsold character");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// Ids spread across the whole collection. Every `step` used here is coprime
    /// with 10000, so the ids never repeat within ten thousand of them.
    function _spread(uint256 count, uint256 step) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            ids[i] = (i * step) % 10_000;
        }
    }

    function _head(uint256[] memory ids, uint256 count) internal pure returns (uint256[] memory out) {
        out = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            out[i] = ids[i];
        }
    }

    /// The bitmap these sales should produce, built from the documented layout
    /// rather than from anything the contract computed.
    function _expectedMap(uint256[] memory ids) internal pure returns (uint256[] memory map) {
        map = new uint256[](WORDS);
        for (uint256 i = 0; i < ids.length; ++i) {
            map[ids[i] >> 8] |= uint256(1) << (ids[i] & 0xff);
        }
    }

    function _assertMapIs(uint256[] memory want, string memory what) internal view {
        uint256[] memory got = nft.blueTakenBits(0, WORDS);
        for (uint256 w = 0; w < WORDS; ++w) {
            assertEq(got[w], want[w], string.concat(what, ": word ", vm.toString(w), " is wrong"));
        }
    }

    function _bitOf(uint256[] memory map, uint256 imageId) internal pure returns (uint256) {
        return (map[imageId >> 8] >> (imageId & 0xff)) & 1;
    }

    function _setBits(uint256[] memory map) internal pure returns (uint256 count) {
        for (uint256 w = 0; w < map.length; ++w) {
            uint256 bits = map[w];
            while (bits != 0) {
                bits &= bits - 1;
                ++count;
            }
        }
    }
}

/// A recipient that reads the collection back from inside onERC721Received.
/// Nothing it does initiates a call, which is the point: a gift calls into it
/// unprompted, and that is the only vantage point on the write order inside a
/// mint.
contract BitmapWatcher {
    GlamToon private immutable NFT;

    uint256 public wordAtReceipt;
    uint256 public soldAtReceipt;
    bool public received;

    constructor(GlamToon nft_) {
        NFT = nft_;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        wordAtReceipt = NFT.blueTakenBits(tokenId >> 8, 1)[0];
        soldAtReceipt = NFT.blueMinted();
        received = true;
        return this.onERC721Received.selector;
    }
}
