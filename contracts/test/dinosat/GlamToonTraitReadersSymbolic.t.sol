// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {TraitSchema} from "../../src/gen/TraitSchema.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, the bulk trait readers
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonTraitReadersSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000 --loop 5
/// @notice Forge:  forge test --match-contract GlamToonTraitReadersSymbolicTest --match-test "test_check_" --no-match-path "test/none/*" --fuzz-runs 100000
/// @dev The website loads the whole trait table and the name table through
///      these in a handful of calls. Each one is a pass through to a data
///      contract pinned at construction, and these prove it passes through
///      the right one, whole and in order.
///
///      None of them takes an input that can be left symbolic: a chunk index
///      and a category are enumerated over every value they have, and the
///      rest take no argument. So there is nothing to fuzz and no wrappers.
contract GlamToonTraitReadersSymbolicTest is DinoSatBase {
    // ════════════════════════════════════════════════
    //  Composition: chunk indices {0, 1} are every chunk there is.
    //  GlamToonViewGuardsSymbolicTest proves every other index is refused.
    // ════════════════════════════════════════════════

    /// @notice NFT-6, chunk 0: traitChunk answers the first data contract's
    ///         records, whole.
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_trait_chunk_is_the_data_contract_0() public view {
        bytes memory raw = nft.traitChunk(0);
        assert(raw.length == TraitSchema.IMAGES_PER_CHUNK * TraitSchema.STRIDE);
        assert(keccak256(raw) == TraitSchema.DATA_HASH_0);
        assert(keccak256(raw) == keccak256(chunk0.data()));
    }

    /// @notice NFT-6, chunk 1: traitChunk answers the second data contract's
    ///         records, whole.
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_trait_chunk_is_the_data_contract_1() public view {
        bytes memory raw = nft.traitChunk(1);
        assert(raw.length == TraitSchema.IMAGES_PER_CHUNK * TraitSchema.STRIDE);
        assert(keccak256(raw) == TraitSchema.DATA_HASH_1);
        assert(keccak256(raw) == keccak256(chunk1.data()));
    }

    /// @notice NFT-6: allTraits is the first chunk followed by the second, two
    ///         bytes for each of the ten thousand characters.
    /// @dev Technique: T2 constant bound, over constants.
    /// @dev Classification: DIRECT
    function test_check_all_traits_is_both_chunks_in_order() public view {
        bytes memory all = nft.allTraits();
        assert(all.length == TraitSchema.IMAGE_COUNT * TraitSchema.STRIDE);
        assert(keccak256(all) == keccak256(bytes.concat(chunk0.data(), chunk1.data())));
    }

    /// @notice NFT-6: traitNames is the name table the constructor pinned.
    /// @dev Technique: T2 constant bound, over constants.
    /// @dev Classification: DIRECT
    function test_check_trait_names_is_the_name_table() public view {
        bytes memory table = nft.traitNames();
        assert(keccak256(table) == TraitSchema.NAMES_HASH);
        assert(keccak256(table) == keccak256(names.data()));
    }

    /// @notice NFT-6: categoryNames is the first four slots of the name table,
    ///         in record order, and none of them is empty.
    /// @dev Technique: T2 constant bound, over constants.
    /// @dev Classification: DIRECT
    function test_check_category_names_are_the_first_slots() public view {
        string[] memory got = nft.categoryNames();
        assert(got.length == TraitSchema.CATEGORY_COUNT);

        for (uint256 c = 0; c < TraitSchema.CATEGORY_COUNT; ++c) {
            assert(bytes(got[c]).length > 0);
            assert(keccak256(bytes(got[c])) == keccak256(bytes(_slot(c))));
        }
    }

    // ════════════════════════════════════════════════
    //  Composition: categories {0, 1, 2, 3} are every category there is.
    //  GlamToonViewGuardsSymbolicTest proves every other category is refused.
    // ════════════════════════════════════════════════

    /// @notice NFT-6, category 0: valueNames answers the sixteen slots of the
    ///         category's value table, in order.
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_value_names_are_the_category_table_0() public view {
        _valueNamesAreTheTable(0);
    }

    /// @notice NFT-6, category 1: the same.
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_value_names_are_the_category_table_1() public view {
        _valueNamesAreTheTable(1);
    }

    /// @notice NFT-6, category 2: the same.
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_value_names_are_the_category_table_2() public view {
        _valueNamesAreTheTable(2);
    }

    /// @notice NFT-6, category 3: the same.
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_value_names_are_the_category_table_3() public view {
        _valueNamesAreTheTable(3);
    }

    // ════════════════════════════════════════════════
    //  Helpers
    // ════════════════════════════════════════════════

    function _valueNamesAreTheTable(uint256 category) private view {
        uint16[4] memory base = TraitSchema.valueBase();
        uint40[4] memory mask = TraitSchema.masks();

        string[] memory got = nft.valueNames(category);
        assert(got.length == uint256(mask[category]) + 1);

        for (uint256 v = 0; v < got.length; ++v) {
            assert(keccak256(bytes(got[v])) == keccak256(bytes(_slot(uint256(base[category]) + v))));
        }
    }

    /// One name, read straight from the name table.
    function _slot(uint256 slot) private view returns (string memory) {
        uint256[] memory one = new uint256[](1);
        one[0] = slot;
        return names.namesAt(one)[0];
    }
}
