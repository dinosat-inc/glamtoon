// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {TraitSchema} from "../../src/gen/TraitSchema.sol";

/// traits.csv is where every other trait check in the suite starts, and it is
/// the sheet the trait chunks were encoded from. The art carries metadata of its
/// own, one file per character under metadata, and the two are
/// corrected side by side. Nothing else ties them together, and a swap of two
/// rows keeps every pinned total in the suite unchanged, so this reads every
/// row of the sheet against the art's own file: the same name, the same four
/// categories in the same order, the same four values.
///
/// REAL_ROWS is the number the deploy script trusts to say every row came from
/// real art rather than filler. Once every row has matched, it has to say so.
contract TraitProvenanceTest is Test {
    string internal constant CSV = "test/fixtures/traits.csv";

    /// Relative to the contracts directory, which is foundry's root here.
    string internal constant METADATA = "../metadata/";

    /// Characters per call frame. A frame never hands memory back, so the walk
    /// hops out to a fresh one every SLICE rows. The slice function is external
    /// for that reason and no other.
    uint256 internal constant SLICE = 500;

    /// All ten thousand rows against all ten thousand files. A row that differs
    /// stops the walk, so REAL_ROWS is only read once every row has matched.
    function test_everyRowOfTheSheetIsTheArtsOwnMetadata() public {
        // Metering off, since nothing here asserts on gas and the walk is long.
        vm.pauseGasMetering();

        vm.closeFile(CSV);
        string[] memory header = vm.split(vm.readLine(CSV), ",");
        assertEq(header.length, 5, "the sheet is not one id and four categories wide");
        assertEq(header[0], "imageId", "first column");

        for (uint256 start = 0; start < TraitSchema.IMAGE_COUNT; start += SLICE) {
            this.matchSlice(start, SLICE, header);
        }

        assertEq(vm.readLine(CSV), "", "the sheet holds more rows than the collection");
        vm.closeFile(CSV);

        assertEq(TraitSchema.REAL_ROWS, TraitSchema.IMAGE_COUNT, "REAL_ROWS says a row did not come from the art");
        assertEq(_jsonFiles(), TraitSchema.IMAGE_COUNT, "the art describes a character the sheet does not have");
    }

    /// One slice of the walk. Reads its own rows, so the sheet stays in
    /// character order across the frames. Each pair is compared by hash first
    /// and only spelled out when it differs, because building forty thousand
    /// messages nobody reads is most of the time the walk would otherwise take.
    function matchSlice(uint256 start, uint256 count, string[] calldata header) external view {
        for (uint256 id = start; id < start + count; ++id) {
            string[] memory row = vm.split(vm.readLine(CSV), ",");
            assertEq(row.length, 5, "the sheet is not one id and four categories wide");
            assertEq(vm.parseUint(row[0]), id, "the sheet is not in character order");

            string memory num = vm.toString(id);
            string memory json = vm.readFile(string.concat(METADATA, num, ".json"));
            _same(vm.parseJsonString(json, ".name"), string.concat("Glamtoon #", num), num, "name");

            ArtTrait[] memory traits = abi.decode(vm.parseJson(json, ".attributes"), (ArtTrait[]));
            if (traits.length != 4) assertEq(traits.length, 4, _at(num, "the art does not carry four traits"));
            for (uint256 c = 0; c < 4; ++c) {
                _same(traits[c].trait_type, header[c + 1], num, "trait type out of order");
                _same(traits[c].value, row[c + 1], num, header[c + 1]);
            }
        }
    }

    /// Equal, or a failure that names the character and what differed.
    function _same(string memory got, string memory want, string memory num, string memory what) internal pure {
        if (keccak256(bytes(got)) == keccak256(bytes(want))) return;
        assertEq(got, want, _at(num, what));
    }

    function _at(string memory num, string memory what) internal pure returns (string memory) {
        return string.concat("character ", num, ", ", what);
    }

    /// The metadata files in the folder. Anything else the file system leaves
    /// there, such as a Finder .DS_Store, describes no character.
    function _jsonFiles() internal view returns (uint256 count) {
        VmSafe.DirEntry[] memory entries = vm.readDir(METADATA);
        for (uint256 i = 0; i < entries.length; ++i) {
            if (!entries[i].isDir && vm.contains(entries[i].path, ".json")) ++count;
        }
    }
}

/// One trait of the art's metadata, in the order forge hands the fields back.
struct ArtTrait {
    // forge-lint: disable-next-line(mixed-case-variable)
    string trait_type;
    string value;
}
