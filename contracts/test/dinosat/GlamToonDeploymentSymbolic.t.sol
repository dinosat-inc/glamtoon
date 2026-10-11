// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {GlamToon, ITraitData, ITraitNames} from "../../src/GlamToon.sol";
import {TraitSchema} from "../../src/gen/TraitSchema.sol";
import {ChunkStub, NamesStub} from "./mocks/TraitStubs.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, what the constructor refuses and what it pins
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonDeploymentSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonDeploymentSymbolicTest --match-test "test_check_" --no-match-path "test/none/*" --fuzz-runs 100000
/// @dev The token has no setter, so whatever its constructor accepts is
///      permanent. These prove it accepts a payee, a start time and trait data
///      only when each is what it should be, and that what it was given is
///      what it reports afterwards.
///
///      No input is narrowed by two numeric bounds, so these have no fuzz
///      wrappers: forge runs the same functions directly.
contract GlamToonDeploymentSymbolicTest is DinoSatBase {
    // ════════════════════════════════════════════════
    //  The payee
    // ════════════════════════════════════════════════

    /// @notice AC-3: a token cannot be built with nobody as its payee, whatever the
    ///         start time. Its takings and royalties would be unreachable.
    /// @dev Technique: T3 guard, the constructor run inside a try.
    /// @dev Classification: DIRECT
    function test_check_constructor_refuses_a_zero_payee(uint64 start) public {
        (bool built, bytes memory reason) = _build(_real0(), _real1(), _realNames(), address(0), start, 0);

        assert(!built);
        assert(_is(reason, GlamToon.InvalidPayout.selector));
    }

    /// @notice PD-1/CC-3: what is sent with the deployment goes straight to the payee and
    ///         none of it stays in the token, for every amount.
    /// @dev Technique: T14 conservation, across the constructor.
    /// @dev Classification: DIRECT
    function test_check_constructor_forwards_its_seed_to_the_payee(uint256 seed) public {
        // Justification: the seed is ether, and 2**128 wei is more than exists
        vm.assume(seed <= MAX_ETHER);
        vm.deal(address(this), seed);

        try new GlamToon{value: seed}(_real0(), _real1(), _realNames(), address(treasury), START) returns (
            GlamToon made
        ) {
            assert(address(made).balance == 0);
            assert(address(treasury).balance == seed);
            assert(address(this).balance == 0);
        } catch {
            assert(false);
        }
    }

    // ════════════════════════════════════════════════
    //  SM-1: the start time
    // ════════════════════════════════════════════════

    /// @notice SM-1: a token is built exactly when its start is at most ninety
    ///         days after the deployment, for every start and every clock. A
    ///         mistyped timestamp cannot lock the sale shut for years.
    /// @dev Technique: T12 state gating, both sides of the check asserted.
    /// @dev Classification: DIRECT
    function test_check_constructor_start_window(uint64 start, uint64 clock) public {
        vm.warp(clock);

        (bool built, bytes memory reason) = _build(_real0(), _real1(), _realNames(), address(treasury), start, 0);

        bool inWindow = uint256(start) <= uint256(clock) + 90 days;
        assert(built == inWindow);
        if (!built) assert(_is(reason, GlamToon.SaleStartTooFar.selector));
    }

    // ════════════════════════════════════════════════
    //  NFT-6: the trait data
    // ════════════════════════════════════════════════

    /// @notice NFT-6: a first chunk that reports any hash but the expected one
    ///         is refused with BadTraitData.
    /// @dev Technique: T3 guard, over every hash but one.
    /// @dev Classification: DIRECT
    function test_check_constructor_refuses_a_wrong_chunk0_hash(bytes32 hash) public {
        // Justification: the branch under test, a hash other than DATA_HASH_0 (GlamToon.sol:191)
        vm.assume(hash != TraitSchema.DATA_HASH_0);
        ITraitData stub = ITraitData(address(new ChunkStub(hash, true)));

        (bool built, bytes memory reason) = _build(stub, _real1(), _realNames(), address(treasury), START, 0);

        assert(!built);
        assert(_is(reason, GlamToon.BadTraitData.selector));
    }

    /// @notice NFT-6: the same for the second chunk.
    /// @dev Technique: T3 guard, over every hash but one.
    /// @dev Classification: DIRECT
    function test_check_constructor_refuses_a_wrong_chunk1_hash(bytes32 hash) public {
        // Justification: the branch under test, a hash other than DATA_HASH_1 (GlamToon.sol:192)
        vm.assume(hash != TraitSchema.DATA_HASH_1);
        ITraitData stub = ITraitData(address(new ChunkStub(hash, true)));

        (bool built, bytes memory reason) = _build(_real0(), stub, _realNames(), address(treasury), START, 0);

        assert(!built);
        assert(_is(reason, GlamToon.BadTraitData.selector));
    }

    /// @notice NFT-6: a name table that reports any hash but the expected one
    ///         is refused with BadTraitNames.
    /// @dev Technique: T3 guard, over every hash but one.
    /// @dev Classification: DIRECT
    function test_check_constructor_refuses_a_wrong_names_hash(bytes32 hash) public {
        // Justification: the branch under test, a hash other than NAMES_HASH (GlamToon.sol:193)
        vm.assume(hash != TraitSchema.NAMES_HASH);
        ITraitNames stub = ITraitNames(address(new NamesStub(hash)));

        (bool built, bytes memory reason) = _build(_real0(), _real1(), stub, address(treasury), START, 0);

        assert(!built);
        assert(_is(reason, GlamToon.BadTraitNames.selector));
    }

    /// @notice NFT-6: the two real chunks in the wrong order are refused, so
    ///         the first five thousand characters cannot be given the traits
    ///         of the last.
    /// @dev Technique: T3 guard, over constants.
    /// @dev Classification: DIRECT
    function test_check_constructor_refuses_swapped_chunks() public {
        (bool built, bytes memory reason) = _build(_real1(), _real0(), _realNames(), address(treasury), START, 0);

        assert(!built);
        assert(_is(reason, GlamToon.BadTraitData.selector));
    }

    /// @notice NFT-6: a chunk that reports the right hash but cannot answer
    ///         for a record is refused. The constructor reads the first and
    ///         last record of each chunk before it pins them.
    /// @dev Technique: T3 guard, over constants.
    /// @dev Classification: DIRECT
    function test_check_constructor_refuses_a_chunk_it_cannot_read() public {
        ITraitData mute0 = ITraitData(address(new ChunkStub(TraitSchema.DATA_HASH_0, false)));
        ITraitData mute1 = ITraitData(address(new ChunkStub(TraitSchema.DATA_HASH_1, false)));

        (bool first,) = _build(mute0, _real1(), _realNames(), address(treasury), START, 0);
        (bool second,) = _build(_real0(), mute1, _realNames(), address(treasury), START, 0);

        assert(!first);
        assert(!second);
    }

    // ════════════════════════════════════════════════
    //  What a built token reports
    // ════════════════════════════════════════════════

    /// @notice AC-3: a token reports exactly what it was built with: the payee, the
    ///         start, the three data contracts, a two percent royalty to the
    ///         payee, and an empty sale.
    /// @dev Technique: T16 stateful, over every start inside the window.
    /// @dev Classification: DIRECT
    function test_check_constructor_pins_what_it_was_given(uint64 start) public {
        // Justification: outside the window the constructor reverts with SaleStartTooFar (GlamToon.sol:188)
        vm.assume(uint256(start) <= uint256(START) + 90 days);

        try new GlamToon(_real0(), _real1(), _realNames(), address(treasury), start) returns (GlamToon made) {
            _reportsWhatItWasGiven(made, start);
        } catch {
            assert(false);
        }
    }

    function _reportsWhatItWasGiven(GlamToon made, uint64 start) private view {
        assert(made.PAYOUT() == address(treasury));
        assert(made.SALE_START() == start);
        assert(address(made.CHUNK0()) == address(chunk0));
        assert(address(made.CHUNK1()) == address(chunk1));
        assert(address(made.NAMES()) == address(names));
        assert(made.blueMinted() == 0);
        assert(made.greenMinted() == 0);
        assert(made.owner() == TREASURY_OWNER);

        (address receiver, uint256 amount) = made.royaltyInfo(0, 10_000);
        assert(receiver == address(treasury));
        assert(amount == 200);

        assert(keccak256(bytes(made.name())) == keccak256("Glamtoon"));
        assert(keccak256(bytes(made.symbol())) == keccak256("GLAMTOON"));
    }

    // ════════════════════════════════════════════════
    //  Helpers
    // ════════════════════════════════════════════════

    function _real0() private view returns (ITraitData) {
        return ITraitData(address(chunk0));
    }

    function _real1() private view returns (ITraitData) {
        return ITraitData(address(chunk1));
    }

    function _realNames() private view returns (ITraitNames) {
        return ITraitNames(address(names));
    }

    /// Build a token, with the outcome a value rather than the end of the path.
    function _build(ITraitData c0, ITraitData c1, ITraitNames n, address payee, uint64 start, uint256 seed)
        private
        returns (bool built, bytes memory reason)
    {
        try new GlamToon{value: seed}(c0, c1, n, payee, start) {
            built = true;
        } catch (bytes memory why) {
            reason = why;
        }
    }
}
