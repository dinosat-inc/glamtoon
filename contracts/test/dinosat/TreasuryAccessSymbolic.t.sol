// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {Treasury} from "../../src/Treasury.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — Treasury, the one key in the system
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract TreasuryAccessSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract TreasuryAccessSymbolicTest --match-test "test_check_" --no-match-path "test/none/*" --fuzz-runs 100000
/// @dev The treasury is the only contract with an owner, and its owner decides
///      where every wei the collection ever earns is sent. These prove that
///      only the owner can repoint it, that ownership moves in two steps and
///      only to an account that accepts it, and that it can never be given up.
///
///      No input here is a number, so there is nothing to bound and these have
///      no fuzz wrappers: forge runs the same functions directly.
contract TreasuryAccessSymbolicTest is DinoSatBase {
    // ════════════════════════════════════════════════
    //  AC-1: only the owner repoints the money
    // ════════════════════════════════════════════════

    /// @notice AC-1: nobody but the owner can move the beneficiary, to
    ///         anywhere. The refusal is OwnableUnauthorizedAccount.
    /// @dev Technique: T3 guard, over every caller and destination.
    /// @dev Classification: DIRECT
    function test_check_stranger_cannot_move_the_beneficiary(address caller, address to) public {
        // Justification: the owner is the one account allowed (Treasury.sol:78)
        vm.assume(caller != TREASURY_OWNER);

        vm.prank(caller);
        (bool ok, bytes memory answer) = address(treasury).call(abi.encodeCall(treasury.setBeneficiary, (to)));

        assert(!ok);
        assert(_is(answer, Ownable.OwnableUnauthorizedAccount.selector));
        assert(treasury.beneficiary() == BENEFICIARY);
    }

    /// @notice AC-1: the owner moves the beneficiary to any address but the
    ///         zero one, which is refused with ZeroAddress. Sweeps can never
    ///         be pointed at nobody.
    /// @dev Technique: T3 guard, both sides of the check asserted.
    /// @dev Classification: DIRECT
    function test_check_owner_moves_the_beneficiary_but_not_to_nobody(address to) public {
        vm.prank(TREASURY_OWNER);
        (bool ok, bytes memory answer) = address(treasury).call(abi.encodeCall(treasury.setBeneficiary, (to)));

        assert(ok == (to != address(0)));
        if (ok) {
            assert(treasury.beneficiary() == to);
        } else {
            assert(_is(answer, Treasury.ZeroAddress.selector));
            assert(treasury.beneficiary() == BENEFICIARY);
        }
        assert(treasury.owner() == TREASURY_OWNER);
    }

    /// @notice AC-1: nobody but the owner can offer the treasury to anyone.
    /// @dev Technique: T3 guard, over every caller and candidate.
    /// @dev Classification: DIRECT
    function test_check_stranger_cannot_offer_ownership(address caller, address next) public {
        // Justification: the owner is the one account allowed
        vm.assume(caller != TREASURY_OWNER);

        vm.prank(caller);
        (bool ok, bytes memory answer) = address(treasury).call(abi.encodeCall(treasury.transferOwnership, (next)));

        assert(!ok);
        assert(_is(answer, Ownable.OwnableUnauthorizedAccount.selector));
        assert(treasury.owner() == TREASURY_OWNER);
        assert(treasury.pendingOwner() == address(0));
    }

    // ════════════════════════════════════════════════
    //  AC-5: ownership moves in two steps
    // ════════════════════════════════════════════════

    /// @notice AC-5: an offer names a pending owner and changes nothing else.
    ///         The owner is still the owner, and the account it offered to has
    ///         no power until it accepts.
    /// @dev Technique: T16 stateful, over every candidate.
    /// @dev Classification: DIRECT
    function test_check_an_offer_does_not_hand_over(address next, address to) public {
        // Justification: an offer to the owner itself would leave the candidate with the owner's power
        vm.assume(next != TREASURY_OWNER);

        vm.prank(TREASURY_OWNER);
        (bool offered,) = address(treasury).call(abi.encodeCall(treasury.transferOwnership, (next)));
        assert(offered);
        assert(treasury.pendingOwner() == next);
        assert(treasury.owner() == TREASURY_OWNER);

        vm.prank(next);
        (bool early,) = address(treasury).call(abi.encodeCall(treasury.setBeneficiary, (to)));
        assert(!early);
        assert(treasury.beneficiary() == BENEFICIARY);
    }

    /// @notice AC-5: only the account that was offered the treasury can accept
    ///         it. Anybody else is refused and nothing moves.
    /// @dev Technique: T3 guard, over every candidate and caller.
    /// @dev Classification: DIRECT
    function test_check_only_the_offered_account_can_accept(address next, address caller) public {
        // Justification: the branch under test, a caller that is not the pending owner
        vm.assume(caller != next);

        vm.prank(TREASURY_OWNER);
        (bool offered,) = address(treasury).call(abi.encodeCall(treasury.transferOwnership, (next)));
        assert(offered);

        vm.prank(caller);
        (bool ok, bytes memory answer) = address(treasury).call(abi.encodeCall(treasury.acceptOwnership, ()));

        assert(!ok);
        assert(_is(answer, Ownable.OwnableUnauthorizedAccount.selector));
        assert(treasury.owner() == TREASURY_OWNER);
        assert(treasury.pendingOwner() == next);
    }

    /// @notice AC-4/AC-5: accepting moves the ownership, clears the offer,
    ///         takes the old owner's power away and gives it to the new one.
    /// @dev Technique: T16 stateful, across the whole handover.
    /// @dev Classification: DIRECT
    function test_check_accepting_moves_the_key_and_clears_the_offer(address next, address to) public {
        // Justification: the new owner signs the acceptance, so it is not the zero address
        vm.assume(next != address(0));
        // Justification: handing the treasury to its own owner leaves no old owner to compare with
        vm.assume(next != TREASURY_OWNER);
        // Justification: setBeneficiary refuses the zero address, proved above
        vm.assume(to != address(0));

        vm.prank(TREASURY_OWNER);
        (bool offered,) = address(treasury).call(abi.encodeCall(treasury.transferOwnership, (next)));
        vm.prank(next);
        (bool accepted,) = address(treasury).call(abi.encodeCall(treasury.acceptOwnership, ()));
        assert(offered && accepted);
        assert(treasury.owner() == next);
        assert(treasury.pendingOwner() == address(0));

        // the old key no longer works
        vm.prank(TREASURY_OWNER);
        (bool stale,) = address(treasury).call(abi.encodeCall(treasury.setBeneficiary, (to)));
        assert(!stale);
        assert(treasury.beneficiary() == BENEFICIARY);

        // and the new one does
        vm.prank(next);
        (bool fresh,) = address(treasury).call(abi.encodeCall(treasury.setBeneficiary, (to)));
        assert(fresh);
        assert(treasury.beneficiary() == to);
    }

    /// @notice AC-4: a second offer replaces the first. The account offered
    ///         first can no longer accept.
    /// @dev Technique: T16 stateful, over every pair of candidates.
    /// @dev Classification: DIRECT
    function test_check_a_new_offer_replaces_the_old_one(address first, address second) public {
        // Justification: the same candidate twice replaces nothing
        vm.assume(first != second);

        vm.prank(TREASURY_OWNER);
        (bool offeredFirst,) = address(treasury).call(abi.encodeCall(treasury.transferOwnership, (first)));
        vm.prank(TREASURY_OWNER);
        (bool offeredSecond,) = address(treasury).call(abi.encodeCall(treasury.transferOwnership, (second)));
        assert(offeredFirst && offeredSecond);
        assert(treasury.pendingOwner() == second);

        vm.prank(first);
        (bool late,) = address(treasury).call(abi.encodeCall(treasury.acceptOwnership, ()));
        assert(!late);
        assert(treasury.owner() == TREASURY_OWNER);
    }

    // ════════════════════════════════════════════════
    //  AC-3: the key cannot be thrown away
    // ════════════════════════════════════════════════

    /// @notice AC-3: renouncing is refused with CannotRenounce for every
    ///         caller, the owner included. The treasury always has an owner,
    ///         so the collection label can never point at nobody.
    /// @dev Technique: T3 guard, over every caller.
    /// @dev Classification: DIRECT
    function test_check_renouncing_is_always_refused(address caller) public {
        vm.prank(caller);
        (bool ok, bytes memory answer) = address(treasury).call(abi.encodeCall(treasury.renounceOwnership, ()));

        assert(!ok);
        assert(_is(answer, Treasury.CannotRenounce.selector));
        assert(treasury.owner() == TREASURY_OWNER);
    }

    /// @notice AC-3: a treasury is built exactly when neither its owner nor
    ///         its beneficiary is the zero address, and then reports both as
    ///         given, with no offer pending.
    /// @dev Technique: T3 guard on the constructor, both sides asserted.
    /// @dev Classification: DIRECT
    function test_check_constructor_refuses_zero_addresses(address initialOwner, address initialBeneficiary) public {
        bool built;
        try new Treasury(initialOwner, initialBeneficiary) returns (Treasury made) {
            built = true;
            assert(made.owner() == initialOwner);
            assert(made.beneficiary() == initialBeneficiary);
            assert(made.pendingOwner() == address(0));
        } catch {
            built = false;
        }

        assert(built == (initialOwner != address(0) && initialBeneficiary != address(0)));
    }
}
