// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";

/// The metadata of the whole collection, character by character, against
/// traits.csv. TraitTable.t.sol walks all ten thousand records but stops at the
/// trait indices; MetadataJson.t.sol reads whole documents but only a few
/// hundred of them. Between them sits what a buyer and a marketplace actually
/// see: twenty thousand JSON documents, concatenated out of a packed record and
/// a name table, and pinned forever the moment this deploys. A character whose
/// record is right and whose document is wrong still ships wrong, and there is
/// no setter to put it back.
///
/// So: every blue document parsed and read back against the sheet's row, every
/// first green document checked for the green art and the generation label, and
/// the four trait distributions the sweep counts on the way through pinned to
/// exact numbers, so a regenerated table that reshuffles the collection is
/// caught even when every individual row still reads back cleanly.
contract FullCollectionSweepTest is BaseTest {
    string internal constant CSV = "test/fixtures/traits.csv";

    /// Characters per call frame. A frame never hands memory back, and ten
    /// thousand documents built in one run into the evm's memory limit before
    /// the sweep finishes, so the loops below hop out to a fresh frame every
    /// SLICE characters. The slice functions are external for that reason and
    /// no other.
    uint256 internal constant SLICE = 250;

    /// Every trait value the collection publishes, in schema order: four dress
    /// codes, three ages, three hair cuts, four hair colours. Written out here
    /// rather than read off the contract, because the contract is the thing on
    /// trial. Medium appears twice, in two different categories, which is why
    /// the tallies are counted within a category's range and not by name alone.
    string[14] internal valueName = [
        string("Feminine"),
        "Masculine",
        "Crossed",
        "Neutral",
        "18-25",
        "26-40",
        "41-70",
        "Short",
        "Medium",
        "Long",
        "None",
        "Light",
        "Medium",
        "Dark"
    ];

    /// Where each category's values start, and how many it has.
    uint256[4] internal valueBase = [uint256(0), 4, 7, 10];
    uint256[4] internal valueCount = [uint256(4), 3, 3, 4];

    /// How many characters carry each value, counted off traits.csv and frozen
    /// here. The sweep recounts them twice, once from the sheet and once from
    /// the contract's own JSON, and both have to land on these.
    uint256[14] internal pinnedCount = [
        uint256(2911), // Feminine
        3494, // Masculine
        1596, // Crossed
        1999, // Neutral
        3844, // 18-25
        3897, // 26-40
        2259, // 41-70
        2695, // Short
        4082, // Medium
        3223, // Long
        395, // None
        2012, // Light
        2526, // Medium
        5067 // Dark
    ];

    uint256[14] internal jsonCount;
    uint256[14] internal csvCount;

    /*//////////////////////////////////////////////////////////////
                              THE BLUE SWEEP
    //////////////////////////////////////////////////////////////*/

    /// Ten thousand blue documents, each one parsed as JSON and read back
    /// against the row of traits.csv that describes the same character. Catches
    /// a name that loses its number, an image URL pointed into the green
    /// directory, an attribute list that drops a category or pairs a trait type
    /// with its neighbour's value, a None hair colour published rather than
    /// omitted, and an edition label that says the wrong thing on one of the
    /// nine thousand tokens nobody will ever read by hand.
    function test_everyBlueDocumentMatchesItsRowInTheSheet() public {
        // Metering off: a walk this long costs more than the per test gas
        // limit. Nothing here asserts on gas, GasBounds.t.sol does that.
        vm.pauseGasMetering();

        string[] memory category = _openSheet();
        for (uint256 start = 0; start < BLUE_SUPPLY; start += SLICE) {
            this.sweepBlueSlice(start, SLICE, category);
        }

        assertEq(vm.readLine(CSV), "", "the sheet holds more rows than the collection");
        vm.closeFile(CSV);

        _assertTotals();
    }

    /// One slice of the blue sweep. Reads its own rows, so the sheet stays in
    /// character order across the frames.
    function sweepBlueSlice(uint256 start, uint256 count, string[] calldata category) external {
        string memory ipfs = nft.ipfsRoot();

        for (uint256 id = start; id < start + count; ++id) {
            string[] memory row = vm.split(vm.readLine(CSV), ",");
            assertEq(row.length, 5, "the sheet is not one id and four categories wide");
            assertEq(vm.parseUint(row[0]), id, "the sheet is not in character order");

            string memory num = vm.toString(id);
            string memory json = nft.tokenJSON(id);

            assertEq(vm.parseJsonString(json, ".name"), string.concat("Glamtoon #", num), _at(id, "name"));
            assertEq(
                vm.parseJsonString(json, ".image"),
                string.concat("ipfs://", ipfs, "/blue/", num, ".png"),
                _at(id, "image")
            );

            SweptAttr[] memory attr = abi.decode(vm.parseJson(json, ".attributes"), (SweptAttr[]));
            bool bald = _eq(row[4], "None");
            assertEq(attr.length, bald ? 5 : 6, _at(id, "attribute count"));

            assertEq(attr[0].trait_type, "Edition", _at(id, "first attribute"));
            assertEq(attr[0].value, "Genesis Blue", _at(id, "edition"));

            uint256 k = 1;
            for (uint256 c = 0; c < 4; ++c) {
                ++csvCount[_slot(c, row[c + 1])];
                // A bald character publishes no hair colour at all, so the
                // generation attribute follows the hair cut directly.
                if (bald && c == 3) continue;
                assertEq(attr[k].trait_type, category[c + 1], _at(id, string.concat("trait type ", vm.toString(c))));
                assertEq(attr[k].value, row[c + 1], _at(id, category[c + 1]));
                ++jsonCount[_slot(c, attr[k].value)];
                ++k;
            }
            // Counted off the document, where a hair colour left out means None.
            if (attr.length == 5) ++jsonCount[_slot(3, "None")];

            assertEq(attr[k].trait_type, "Generation", _at(id, "last attribute"));
            assertEq(attr[k].value, "0", _at(id, "generation label"));
        }
    }

    /*//////////////////////////////////////////////////////////////
                             THE GREEN SWEEP
    //////////////////////////////////////////////////////////////*/

    /// The same ten thousand characters on the free side, one generation in.
    /// Traits do not change between editions, so the sheet is not needed again.
    /// What changes is the directory all four art URLs point at and the two
    /// attributes naming the edition and the generation. Catches a blue flag
    /// stuck true for one of the four URLs, and a generation label off by one or
    /// already collapsed into the 9+ bucket at generation one.
    function test_everyFirstGreenGenerationCarriesTheGreenArtAndGenerationOne() public {
        vm.pauseGasMetering();

        for (uint256 start = 0; start < BLUE_SUPPLY; start += SLICE) {
            this.sweepGreenSlice(start, SLICE);
        }
    }

    /// One slice of the green sweep, in its own frame for the same reason.
    function sweepGreenSlice(uint256 start, uint256 count) external view {
        string memory ipfs = nft.ipfsRoot();
        string memory arweave = nft.arweaveManifest();

        for (uint256 id = start; id < start + count; ++id) {
            string memory num = vm.toString(id);
            string memory json = nft.tokenJSON(nft.tokenIdFor(id, 1));

            assertEq(
                vm.parseJsonString(json, ".image"),
                string.concat("ipfs://", ipfs, "/green/", num, ".png"),
                _at(id, "green image")
            );
            assertEq(
                vm.parseJsonString(json, ".glamtoon.optimized"),
                string.concat("ipfs://", ipfs, "/green/", num, ".webp"),
                _at(id, "green optimized")
            );
            assertEq(
                vm.parseJsonString(json, ".glamtoon.arweave"),
                string.concat("ar://", arweave, "/green/", num, ".png"),
                _at(id, "green arweave")
            );
            assertEq(
                vm.parseJsonString(json, ".glamtoon.arweave_optimized"),
                string.concat("ar://", arweave, "/green/", num, ".webp"),
                _at(id, "green arweave optimized")
            );

            SweptAttr[] memory attr = abi.decode(vm.parseJson(json, ".attributes"), (SweptAttr[]));
            assertEq(attr[0].trait_type, "Edition", _at(id, "first attribute"));
            assertEq(attr[0].value, "Generation Green", _at(id, "green edition"));
            assertEq(attr[attr.length - 1].trait_type, "Generation", _at(id, "last attribute"));
            assertEq(attr[attr.length - 1].value, "1", _at(id, "green generation label"));
        }
    }

    /*//////////////////////////////////////////////////////////////
                            COLLECTION TOTALS
    //////////////////////////////////////////////////////////////*/

    /// The pinned numbers are counted by hand, so they get their own
    /// arithmetic: each category has to account for every character exactly
    /// once. A typo in a pin that the sweep would then fail against is caught
    /// here first, where the message says which category is short.
    function test_thePinnedTotalsAccountForEveryCharacterInEveryCategory() public view {
        for (uint256 c = 0; c < 4; ++c) {
            uint256 sum;
            for (uint256 v = 0; v < valueCount[c]; ++v) {
                sum += pinnedCount[valueBase[c] + v];
            }
            assertEq(sum, BLUE_SUPPLY, string.concat("category ", vm.toString(c), " does not cover the collection"));
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// Every tally, from both sides, against the pins. Keeping the two sources
    /// apart matters: agreeing with each other but not with the pins means the
    /// table was regenerated, and matching the pins on one side only means the
    /// contract and the sheet have come apart.
    function _assertTotals() internal view {
        for (uint256 c = 0; c < 4; ++c) {
            for (uint256 v = 0; v < valueCount[c]; ++v) {
                uint256 i = valueBase[c] + v;
                assertEq(csvCount[i], pinnedCount[i], string.concat("sheet count for ", valueName[i]));
                assertEq(jsonCount[i], pinnedCount[i], string.concat("metadata count for ", valueName[i]));
            }
        }
    }

    /// Rewind the sheet and hand back its header, which is where the category
    /// names in the expectation come from.
    function _openSheet() internal returns (string[] memory header) {
        vm.closeFile(CSV);
        header = vm.split(vm.readLine(CSV), ",");
        assertEq(header.length, 5, "the sheet header is not one id and four categories wide");
        assertEq(header[0], "imageId", "first column");
    }

    /// Where a value sits in the pinned tables, searched inside its own category
    /// so Hair Cut Medium and Hair Colour Medium stay apart.
    function _slot(uint256 category, string memory value) internal view returns (uint256) {
        uint256 base = valueBase[category];
        for (uint256 v = 0; v < valueCount[category]; ++v) {
            if (_eq(valueName[base + v], value)) return base + v;
        }
        revert(string.concat("value outside the schema: ", value));
    }

    function _at(uint256 imageId, string memory what) internal pure returns (string memory) {
        return string.concat("character ", vm.toString(imageId), ": ", what);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

/// One attribute, in the order forge hands the fields back.
struct SweptAttr {
    // forge-lint: disable-next-line(mixed-case-variable)
    string trait_type;
    string value;
}
