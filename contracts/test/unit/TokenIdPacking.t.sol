// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {stdError} from "forge-std/StdError.sol";
import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";

/// The packing is the one piece of arithmetic every other guarantee sits on. If
/// tokenIdFor and decode ever disagree, two characters share a token or a token
/// names the wrong artwork, and neither is fixable afterwards.
contract TokenIdPackingTest is BaseTest {
    uint256 constant N = 10_000;

    function test_genesisOccupiesZeroToNineThousandNineHundredNinetyNine() public view {
        assertEq(nft.tokenIdFor(0, 0), 0, "first blue");
        assertEq(nft.tokenIdFor(N - 1, 0), N - 1, "last blue");
        assertEq(nft.tokenIdFor(0, 1), N, "first green");
    }

    /// What a character's ids look like. The image id is the last four digits and
    /// the generation is everything above them.
    function test_oneCharacterAcrossGenerations() public view {
        assertEq(nft.tokenIdFor(7, 0), 7, "image 7 gen 0");
        assertEq(nft.tokenIdFor(7, 1), 10_007, "image 7 gen 1");
        assertEq(nft.tokenIdFor(7, 2), 20_007, "image 7 gen 2");
        assertEq(nft.tokenIdFor(7, 3), 30_007, "image 7 gen 3");

        assertEq(nft.imageIdOf(30_007), 7, "30007 is character 7");
        assertEq(nft.generationOf(30_007), 3, "30007 is generation 3");
    }

    /// Zero based removes the boundary a one based scheme has to special case.
    /// Every multiple of ten thousand is character zero of the next generation.
    function test_theMultiplesOfTenThousand() public view {
        (uint256 image, uint256 generation) = nft.decode(N);
        assertEq(image, 0, "token 10000 is character 0");
        assertEq(generation, 1, "generation one");

        (image, generation) = nft.decode(2 * N);
        assertEq(image, 0, "token 20000 is character 0");
        assertEq(generation, 2, "generation two");

        (image, generation) = nft.decode(N - 1);
        assertEq(image, N - 1, "token 9999 is character 9999");
        assertEq(generation, 0, "and it is a genesis");
    }

    function test_tokenZeroIsCharacterZero() public view {
        (uint256 image, uint256 generation) = nft.decode(0);
        assertEq(image, 0, "character zero");
        assertEq(generation, 0, "genesis");
        assertTrue(nft.isBlue(0), "token 0 is blue");
    }

    function test_isBlueMatchesTheGeneration() public view {
        assertTrue(nft.isBlue(0), "0");
        assertTrue(nft.isBlue(N - 1), "9999");
        assertFalse(nft.isBlue(N), "10000");
        assertFalse(nft.isBlue(type(uint256).max), "the far end");
    }

    function testFuzz_roundTrip(uint256 imageId, uint256 generation) public view {
        imageId = bound(imageId, 0, N - 1);
        generation = bound(generation, 0, (type(uint256).max - N) / N);

        uint256 tokenId = nft.tokenIdFor(imageId, generation);
        (uint256 gotImage, uint256 gotGeneration) = nft.decode(tokenId);

        assertEq(gotImage, imageId, "image survives the round trip");
        assertEq(gotGeneration, generation, "generation survives the round trip");
        assertEq(nft.isBlue(tokenId), generation == 0, "blue iff generation zero");
    }

    function testFuzz_decodeAlwaysLandsInRange(uint256 tokenId) public view {
        (uint256 imageId, uint256 generation) = nft.decode(tokenId);
        assertLt(imageId, N, "image id below ten thousand");
        assertEq(nft.tokenIdFor(imageId, generation), tokenId, "and it re-encodes");
    }

    function testFuzz_distinctTokensForDistinctInputs(uint256 imageA, uint256 genA, uint256 imageB, uint256 genB)
        public
        view
    {
        imageA = bound(imageA, 0, N - 1);
        imageB = bound(imageB, 0, N - 1);
        genA = bound(genA, 0, 1e30);
        genB = bound(genB, 0, 1e30);
        vm.assume(imageA != imageB || genA != genB);
        assertTrue(nft.tokenIdFor(imageA, genA) != nft.tokenIdFor(imageB, genB), "no two share an id");
    }

    function test_imageIdOutOfRangeReverts() public {
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.tokenIdFor(N, 0);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.tokenIdFor(type(uint256).max, 0);
    }

    /// Left checked on purpose. A silent wrap would collide two characters.
    function test_absurdGenerationRevertsRatherThanWrapping() public {
        vm.expectRevert(stdError.arithmeticError);
        nft.tokenIdFor(1, type(uint256).max);
    }

    /// The top generation is the one whose product still fits. There the id is
    /// the last number uint256 holds, and adding one more character overflows the
    /// addition rather than the multiply. A wrap at that point would hand back
    /// an id from 0 to 63, which is a blue.
    function test_theLargestEncodableIdIsTheTopOfUint256AndOneMoreOverflows() public {
        uint256 top = type(uint256).max / N;
        uint256 last = type(uint256).max % N;
        assertEq(last, 9935, "the character the top id belongs to");

        assertEq(nft.tokenIdFor(last, top), type(uint256).max, "the largest id there is");
        (uint256 image, uint256 generation) = nft.decode(type(uint256).max);
        assertEq(image, last, "decodes to that character");
        assertEq(generation, top, "at the top generation");

        vm.expectRevert(stdError.arithmeticError);
        nft.tokenIdFor(last + 1, top);
        vm.expectRevert(stdError.arithmeticError);
        nft.tokenIdFor(N - 1, top);
        vm.expectRevert(stdError.arithmeticError);
        nft.tokenIdFor(0, top + 1);
    }

    /// The fixture a client can check its own decoder against. Each entry has to
    /// decode to what it says and encode back to the same id, the 1e30 one
    /// included.
    function test_theSharedDecodeVectorsDecodeAsWritten() public view {
        string memory json = vm.readFile("test/fixtures/decode-vectors.json");

        uint256 count;
        while (vm.keyExistsJson(json, string.concat("$[", vm.toString(count), "]"))) {
            string memory entry = string.concat("$[", vm.toString(count), "]");
            uint256 tokenId = vm.parseJsonUint(json, string.concat(entry, ".tokenId"));
            uint256 imageId = vm.parseJsonUint(json, string.concat(entry, ".imageId"));
            uint256 generation = vm.parseJsonUint(json, string.concat(entry, ".generation"));

            (uint256 gotImage, uint256 gotGeneration) = nft.decode(tokenId);
            assertEq(gotImage, imageId, string.concat("image of ", vm.toString(tokenId)));
            assertEq(gotGeneration, generation, string.concat("generation of ", vm.toString(tokenId)));
            assertEq(nft.tokenIdFor(imageId, generation), tokenId, string.concat("encoding ", vm.toString(tokenId)));
            ++count;
        }

        assertEq(count, 12, "the fixture holds twelve vectors");
    }

    function test_everyGenesisIdDecodesToItself() public view {
        for (uint256 id = 0; id < N; ++id) {
            (uint256 imageId, uint256 generation) = nft.decode(id);
            assertEq(imageId, id, "image");
            assertEq(generation, 0, "generation");
        }
    }
}
