// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {GlamToon, ITraitData, ITraitNames} from "../../src/GlamToon.sol";
import {TraitData0} from "../../src/gen/TraitData0.sol";
import {TraitData1} from "../../src/gen/TraitData1.sol";
import {TraitNames} from "../../src/gen/TraitNames.sol";
import {WordPayee, RevertingPayee, ShortPayee, LongPayee, SilentPayee} from "./mocks/LabelPayees.sol";

/// @title DinoSAT Proofs — GlamToon, reading an owner from a payee that misbehaves
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonOwnerDecodingSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonOwnerDecodingSymbolicTest --match-test "test_check_" --no-match-path "test/none/*" --fuzz-runs 100000
/// @dev GlamToon.owner() makes a staticcall into its payee and decodes the
///      answer by hand. The payee is fixed for good at construction, so a
///      payee that reverts, answers the wrong length or answers a word that is
///      not an address must read as nobody, and must never make owner() itself
///      revert: marketplaces call it without a try.
///
///      Six tokens are built here, each with a payee that answers differently.
///      No input is narrowed by two numeric bounds, so these have no fuzz
///      wrappers: forge runs the same functions directly.
contract GlamToonOwnerDecodingSymbolicTest is Test {
    uint64 internal constant START = 1000;

    /// A payee with no code at all.
    address internal constant PLAIN_PAYEE = address(0xFEED00);

    WordPayee internal wordPayee;
    GlamToon internal withWord;
    GlamToon internal withReverting;
    GlamToon internal withShort;
    GlamToon internal withLong;
    GlamToon internal withSilent;
    GlamToon internal withPlain;

    function setUp() public {
        vm.warp(START);
        ITraitData c0 = ITraitData(address(new TraitData0()));
        ITraitData c1 = ITraitData(address(new TraitData1()));
        ITraitNames n = ITraitNames(address(new TraitNames()));

        wordPayee = new WordPayee();
        withWord = new GlamToon(c0, c1, n, address(wordPayee), START);
        withReverting = new GlamToon(c0, c1, n, address(new RevertingPayee()), START);
        withShort = new GlamToon(c0, c1, n, address(new ShortPayee()), START);
        withLong = new GlamToon(c0, c1, n, address(new LongPayee()), START);
        withSilent = new GlamToon(c0, c1, n, address(new SilentPayee()), START);
        withPlain = new GlamToon(c0, c1, n, PLAIN_PAYEE, START);
    }

    // ════════════════════════════════════════════════
    //  AS-4: one clean address, or nobody
    // ════════════════════════════════════════════════

    /// @notice AS-4: a word that is an address reads as that address, for
    ///         every one of them, and owner() does not revert.
    /// @dev Technique: T2, over every word that fits an address.
    /// @dev Classification: DIRECT
    function test_check_label_reads_a_clean_address(uint256 word) public {
        // Justification: the branch under test, a word with nothing above its low 160 bits (GlamToon.sol:307)
        vm.assume(word <= type(uint160).max);
        wordPayee.set(word);

        (bool ok, bytes memory answer) = address(withWord).staticcall(abi.encodeCall(withWord.owner, ()));

        assert(ok);
        assert(answer.length == 32);
        assert(uint256(bytes32(answer)) == word);
    }

    /// @notice AS-4: a word with anything above its low 160 bits is not an
    ///         address, and reads as nobody rather than being truncated into
    ///         one. A truncating cast would let a payee name any account.
    /// @dev Technique: T2, over every word that does not fit an address.
    /// @dev Classification: DIRECT
    function test_check_label_refuses_a_dirty_word(uint256 word) public {
        // Justification: the branch under test, a word past uint160.max (GlamToon.sol:307)
        vm.assume(word > type(uint160).max);
        wordPayee.set(word);

        (bool ok, bytes memory answer) = address(withWord).staticcall(abi.encodeCall(withWord.owner, ()));

        assert(ok);
        assert(abi.decode(answer, (address)) == address(0));
    }

    /// @notice AS-4: a payee that reverts reads as nobody.
    /// @dev Technique: T3 guard, over constants.
    /// @dev Classification: DIRECT
    function test_check_label_is_nobody_when_the_payee_reverts() public view {
        assert(_label(withReverting) == address(0));
    }

    /// @notice AS-4: a payee that answers one byte short of a word reads as nobody.
    /// @dev Technique: T3 guard, over constants.
    /// @dev Classification: DIRECT
    function test_check_label_is_nobody_when_the_answer_is_short() public view {
        assert(_label(withShort) == address(0));
    }

    /// @notice AS-4: a payee that answers two words reads as nobody, even though the
    ///         first of them is a clean address.
    /// @dev Technique: T3 guard, over constants.
    /// @dev Classification: DIRECT
    function test_check_label_is_nobody_when_the_answer_is_long() public view {
        assert(_label(withLong) == address(0));
    }

    /// @notice AS-4: a payee that answers with nothing, with or without code, reads
    ///         as nobody.
    /// @dev Technique: T3 guard, over constants.
    /// @dev Classification: DIRECT
    function test_check_label_is_nobody_when_the_answer_is_empty() public view {
        assert(_label(withSilent) == address(0));
        assert(_label(withPlain) == address(0));
    }

    // ════════════════════════════════════════════════
    //  Helpers
    // ════════════════════════════════════════════════

    /// The label, with a revert in owner() itself failing the proof.
    function _label(GlamToon token) private view returns (address) {
        (bool ok, bytes memory answer) = address(token).staticcall(abi.encodeCall(token.owner, ()));
        assert(ok);
        return abi.decode(answer, (address));
    }
}
