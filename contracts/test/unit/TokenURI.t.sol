// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {Base64} from "openzeppelin/utils/Base64.sol";
import {GlamToon} from "../../src/GlamToon.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";

/// Metadata through every shape a token can take. The JSON has to parse, the
/// title and the art have to follow the generation, the traits have to stay put
/// across generations, and nothing may ever revert.
contract TokenURITest is BaseTest {
    string constant PREFIX = "data:application/json;base64,";

    function _json(uint256 tokenId) internal view returns (string memory) {
        return nft.tokenJSON(tokenId);
    }

    /// One field of one attribute. Forge's json paths take an index, not a wildcard.
    function _attr(string memory j, uint256 i, string memory field) internal view returns (string memory) {
        return vm.parseJsonString(j, string.concat(".attributes[", vm.toString(i), "].", field));
    }

    function _kinds(string memory j, uint256 n) internal view returns (string[] memory out) {
        out = new string[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = _attr(j, i, "trait_type");
        }
    }

    function _values(string memory j, uint256 n) internal view returns (string[] memory out) {
        out = new string[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = _attr(j, i, "value");
        }
    }

    /// Solidity never frees memory, so building ten thousand documents in one call
    /// frame runs the test out of it. Behind an external call each document is
    /// built in a frame of its own and only the length comes back.
    function jsonLength(uint256 tokenId) external view returns (uint256) {
        return bytes(nft.tokenJSON(tokenId)).length;
    }

    /*//////////////////////////////////////////////////////////////
                                 SHAPE
    //////////////////////////////////////////////////////////////*/

    function test_genesisJson() public view {
        string memory j = _json(0);
        assertEq(vm.parseJsonString(j, ".name"), "Glamtoon #0", "title");
        assertEq(
            vm.parseJsonString(j, ".image"),
            string.concat("ipfs://", nft.ipfsRoot(), "/blue/0.png"),
            "full resolution art"
        );
        assertEq(vm.parseJsonString(j, ".external_url"), "https://glamtoon.com/token/0", "page");
        assertEq(
            vm.parseJsonString(j, ".glamtoon.optimized"),
            string.concat("ipfs://", nft.ipfsRoot(), "/blue/0.webp"),
            "lighter copy"
        );
        assertEq(
            vm.parseJsonString(j, ".glamtoon.arweave"),
            string.concat("ar://", nft.arweaveManifest(), "/blue/0.png"),
            "arweave copy"
        );
        assertEq(
            vm.parseJsonString(j, ".glamtoon.arweave_optimized"),
            string.concat("ar://", nft.arweaveManifest(), "/blue/0.webp"),
            "arweave lighter copy"
        );
    }

    /// The four getters and the four metadata fields are the same four URLs.
    /// A caller that reaches for a getter must not land somewhere else.
    function test_theGettersMatchTheMetadata() public view {
        string memory j = _json(nft.tokenIdFor(7412, 3));
        assertEq(vm.parseJsonString(j, ".image"), nft.imageURI(7412, false), "image");
        assertEq(vm.parseJsonString(j, ".glamtoon.optimized"), nft.optimizedURI(7412, false), "optimized");
        assertEq(vm.parseJsonString(j, ".glamtoon.arweave"), nft.arweaveURI(7412, false), "arweave");
        assertEq(
            vm.parseJsonString(j, ".glamtoon.arweave_optimized"),
            nft.arweaveOptimizedURI(7412, false),
            "arweave_optimized"
        );

        string memory g = _json(0);
        assertEq(vm.parseJsonString(g, ".image"), nft.imageURI(0, true), "genesis image");
        assertEq(vm.parseJsonString(g, ".glamtoon.arweave"), nft.arweaveURI(0, true), "genesis arweave");
    }

    function test_greenJson() public view {
        uint256 tokenId = nft.tokenIdFor(7412, 3);
        string memory j = _json(tokenId);
        assertEq(vm.parseJsonString(j, ".name"), "Glamtoon #7412 Gen 3", "title carries the gen");
        assertEq(
            vm.parseJsonString(j, ".image"), string.concat("ipfs://", nft.ipfsRoot(), "/green/7412.png"), "green art"
        );
        assertEq(
            vm.parseJsonString(j, ".external_url"),
            "https://glamtoon.com/token/37412",
            "page is the token, not the character"
        );
    }

    function test_theArtIsTheSameCharacterInBothEditions() public view {
        // The whole premise: only the background differs, so the file name is the
        // character in both, and only the folder changes.
        assertEq(vm.parseJsonString(_json(1), ".image"), nft.imageURI(1, true), "genesis #1");
        assertEq(vm.parseJsonString(_json(nft.tokenIdFor(1, 9)), ".image"), nft.imageURI(1, false), "green #1");
    }

    function test_attributes() public view {
        string memory j = _json(0);
        string[] memory kinds = _kinds(j, 6);
        // A seventh would mean the array is longer than the schema says.
        assertEq(_occurrences(j, '"trait_type":'), 6, "six attributes and no more");
        assertEq(kinds[0], "Edition", "first");
        assertEq(kinds[1], "Dress Code", "second");
        assertEq(kinds[4], "Hair Colour", "second to last");
        assertEq(kinds[5], "Generation", "last");

        // The parser reads a bare 0 back as "0" and a quoted "0" back as 0, so
        // which of the two went out is only visible in the bytes.
        assertEq(_attr(j, 5, "value"), "0", "generation label");
        assertTrue(vm.contains(j, '{"trait_type":"Generation","value":"0"}]'), "generation is a string");
        assertEq(_occurrences(j, '"value":"'), 6, "every attribute value is a string");
        assertEq(vm.parseJsonUint(j, ".glamtoon.image_id"), 0, "image id lives off the attributes");
        assertTrue(vm.contains(j, '"image_id":0,"generation":0}'), "the numeric fields are bare numbers");
        // Not one attribute may carry display_type. OpenSea will not rank a
        // collection that has a numeric trait anywhere in it.
        for (uint256 i = 0; i < 6; ++i) {
            assertEq(
                vm.parseJsonKeys(j, string.concat(".attributes[", vm.toString(i), "]")).length,
                2,
                "an attribute carries more than trait_type and value"
            );
        }
    }

    /// Character zero, read straight out of the metadata the art pipeline
    /// produced. If the trait table ever shifts under the contract, this notices.
    function test_characterZeroMatchesTheArtPipeline() public view {
        string[] memory v = _values(_json(0), 6);
        assertEq(v[1], "Masculine", "Dress Code");
        assertEq(v[2], "18-25", "Age");
        assertEq(v[3], "Medium", "Hair Cut");
        assertEq(v[4], "Medium", "Hair Colour");
    }

    /// A character with no hair carries no hair colour, so the attribute is
    /// absent rather than saying None. Token 65 is one of the 395.
    function test_aCharacterWithNoHairCarriesNoHairColour() public view {
        string memory j = _json(65);
        string[] memory kinds = _kinds(j, 5);
        assertEq(kinds[0], "Edition", "first");
        assertEq(kinds[1], "Dress Code", "second");
        assertEq(kinds[2], "Age", "third");
        assertEq(kinds[3], "Hair Cut", "fourth");
        assertEq(kinds[4], "Generation", "last, with no hair colour before it");
        // a sixth would mean the None slipped through
        assertEq(_occurrences(j, '"trait_type":'), 5, "five attributes and no more");
    }

    function test_editionFollowsTheGeneration() public view {
        assertEq(_attr(_json(1), 0, "value"), "Genesis Blue", "generation 0");
        assertEq(_attr(_json(nft.tokenIdFor(1, 1)), 0, "value"), "Generation Green", "anything above");
    }

    /// Exact while it is short, grouped after that.
    function test_generationLabels() public view {
        assertEq(_gen(0), "0", "the genesis edition");
        assertEq(_gen(1), "1", "first green");
        assertEq(_gen(8), "8", "last exact value");
        assertEq(_gen(9), "9+", "the threshold itself groups");
        assertEq(_gen(143), "9+", "and everything above it");
        assertEq(_gen(type(uint32).max), "9+", "however far it runs");
    }

    /// The row count is bounded however long minting runs.
    function test_generationRowsAreBounded() public view {
        assertEq(nft.GENERATION_SHOWN(), 9, "threshold");
        string memory overflow = _gen(nft.GENERATION_SHOWN());
        uint256[5] memory far = [uint256(10), 1000, 1e12, 1e30, type(uint64).max];
        for (uint256 i = 0; i < far.length; ++i) {
            assertEq(_gen(far[i]), overflow, "a far generation made its own row");
        }
    }

    /// Every label sorts in generation order, which is what keeps the filter row
    /// readable. This would fail if the threshold ever grew past a single digit
    /// without padding being reintroduced.
    function test_labelsSortInGenerationOrder() public view {
        for (uint256 g = 0; g < nft.GENERATION_SHOWN(); ++g) {
            assertTrue(_sortsBefore(_gen(g), _gen(g + 1)), "labels out of order");
        }
    }

    /// The overflow label has to sort after every exact value or it lands in the
    /// middle of the list. "9+" does, because every exact value is a single digit
    /// below it. A threshold of ten would have labelled the row "10+", which
    /// sorts between 1 and 2.
    function test_theOverflowLabelSortsLast() public view {
        string memory overflow = _gen(nft.GENERATION_SHOWN());
        for (uint256 g = 0; g < nft.GENERATION_SHOWN(); ++g) {
            assertTrue(_sortsBefore(_gen(g), overflow), "an exact value sorts after the overflow row");
        }
        assertTrue(_sortsBefore("10+", _gen(2)), "and this is why the threshold is a single digit");
    }

    /// Text order: compare a character at a time, shorter wins on a tie.
    function _sortsBefore(string memory a, string memory b) internal pure returns (bool) {
        bytes memory x = bytes(a);
        bytes memory y = bytes(b);
        uint256 n = x.length < y.length ? x.length : y.length;
        for (uint256 i = 0; i < n; ++i) {
            if (x[i] != y[i]) return x[i] < y[i];
        }
        return x.length < y.length;
    }

    function _gen(uint256 generation) internal view returns (string memory) {
        return _attr(_json(nft.tokenIdFor(1, generation)), 5, "value");
    }

    function test_traitsAreIdenticalAcrossEveryGenerationOfACharacter() public view {
        string[] memory want = _values(_json(7412), 5);
        uint256[4] memory gens = [uint256(1), 2, 999, 1e18];
        for (uint256 i = 0; i < gens.length; ++i) {
            string[] memory got = _values(_json(nft.tokenIdFor(7412, gens[i])), 5);
            // Slots 1 to 4 are the four stored traits. Only the background
            // before them is allowed to differ.
            for (uint256 c = 1; c < 5; ++c) {
                assertEq(got[c], want[c], "a trait moved between generations");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                TOKEN URI
    //////////////////////////////////////////////////////////////*/

    function test_tokenUriIsOneBase64LayerOverTheJson() public {
        _buy(alice, 1);
        assertEq(
            nft.tokenURI(1),
            string.concat(PREFIX, Base64.encode(bytes(_json(1)))),
            "prefix plus one encoding of exactly the plain json"
        );
    }

    function test_tokenUriForAnUnmintedTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(5)));
        nft.tokenURI(5);
    }

    function test_contractUri() public view {
        string memory j = nft.collectionJSON();
        assertEq(vm.parseJsonString(j, ".name"), "Glamtoon", "collection name");
        assertEq(vm.parseJsonString(j, ".external_link"), "https://glamtoon.com", "site");
        assertEq(nft.contractURI(), string.concat(PREFIX, Base64.encode(bytes(j))), "same shape");
    }

    /*//////////////////////////////////////////////////////////////
                             NEVER REVERTS
    //////////////////////////////////////////////////////////////*/

    /// Every character, at generation zero, one test per trait chunk, so a
    /// failure names the chunk that is wrong.
    function _sweep(uint256 from, uint256 to, uint256 generation) internal view {
        for (uint256 imageId = from; imageId <= to; ++imageId) {
            assertGt(this.jsonLength(nft.tokenIdFor(imageId, generation)), 200, "metadata missing");
        }
    }

    function test_metadataForEveryCharacterInChunkZero() public view {
        _sweep(0, 4999, 0);
    }

    function test_metadataForEveryCharacterInChunkOne() public view {
        _sweep(5000, 9999, 0);
    }

    /// The green edition reads the same records through a different folder, so it
    /// is checked at both ends of the table and on both sides of the one chunk
    /// seam, where an off by one would land.
    function test_greenMetadataAtBothEndsAndAcrossTheSeam() public view {
        uint256[8] memory ids = [uint256(0), 1, 4998, 4999, 5000, 5001, 9998, 9999];
        for (uint256 i = 0; i < ids.length; ++i) {
            assertGt(this.jsonLength(nft.tokenIdFor(ids[i], 1)), 200, "green metadata missing");
            assertEq(
                vm.parseJsonString(_json(nft.tokenIdFor(ids[i], 1)), ".image"),
                nft.imageURI(ids[i], false),
                "green art url"
            );
        }
    }

    function test_absurdGenerationsStillProduceMetadata() public view {
        uint256[4] memory gens = [uint256(1), 1e6, 1e30, (type(uint256).max - BLUE_SUPPLY) / BLUE_SUPPLY];
        for (uint256 i = 0; i < gens.length; ++i) {
            string memory j = _json(nft.tokenIdFor(7412, gens[i]));
            assertEq(vm.parseJsonUint(j, ".glamtoon.image_id"), 7412, "still character 7412");
            assertEq(vm.parseJsonUint(j, ".glamtoon.generation"), gens[i], "generation");
        }
    }

    function testFuzz_anyTokenIdHasMetadata(uint256 tokenId) public view {
        assertGt(bytes(_json(tokenId)).length, 200, "metadata missing");
    }

    function test_tokenZeroIsCharacterZero() public view {
        assertEq(vm.parseJsonString(_json(0), ".name"), "Glamtoon #0", "token 0 is character 0");
    }

    /// Nothing in the metadata depends on the clock, so it can be asserted to be
    /// stable rather than merely to not revert.
    function test_metadataDoesNotChangeWithTime() public {
        string memory before = _json(1);
        vm.warp(block.timestamp + 3650 days);
        vm.roll(block.number + 1_000_000);
        assertEq(_json(1), before, "metadata drifted");
    }

    /*//////////////////////////////////////////////////////////////
                                ESCAPING
    //////////////////////////////////////////////////////////////*/

    /// No untrusted text ever reaches this JSON: the identifiers are ours, the
    /// numbers are decimal, and the names come from a table we generated. That is
    /// why there is no escaping routine. This is the test that keeps it true.
    function test_noNameWouldNeedEscaping() public view {
        bytes memory table = nft.traitNames();
        for (uint256 i = 0; i < table.length; ++i) {
            bytes1 c = table[i];
            assertTrue(c != '"', "a name contains a quote");
            assertTrue(c != "\\", "a name contains a backslash");
            assertTrue(c == 0x00 || uint8(c) >= 0x20, "a name contains a control character");
        }
    }

    function test_artIdentifiersAreWellFormed() public view {
        _assertNoJsonSpecials(bytes(nft.ipfsRoot()));
        _assertNoJsonSpecials(bytes(nft.arweaveManifest()));
        _assertNoJsonSpecials(bytes(nft.tokenBase()));
    }

    /// How many times a piece of text appears in the raw document.
    function _occurrences(string memory j, string memory piece) internal pure returns (uint256) {
        return vm.split(j, piece).length - 1;
    }

    function _assertNoJsonSpecials(bytes memory s) internal pure {
        assertGt(s.length, 0, "empty identifier");
        for (uint256 i = 0; i < s.length; ++i) {
            assertTrue(s[i] != '"' && s[i] != "\\" && uint8(s[i]) >= 0x20, "needs escaping");
        }
    }
}
