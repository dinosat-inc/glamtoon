// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Treasury} from "../../src/Treasury.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — Treasury, the sweep anyone may call
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract TreasurySweepSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract TreasurySweepSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev sweep checks no caller. Anyone may push the treasury's ether along,
///      so its whole safety is that it reaches the beneficiary and nowhere
///      else, and that whoever pushed it keeps none.
contract TreasurySweepSymbolicTest is DinoSatBase {
    // ════════════════════════════════════════════════
    //  CC-3: a sweep reaches the beneficiary and nowhere else
    // ════════════════════════════════════════════════

    /// @notice CC-3: whoever calls it, a sweep empties the treasury into the
    ///         beneficiary, for every balance, and the caller's own balance
    ///         does not move.
    /// @dev Technique: T14 conservation, over every caller and balance.
    /// @dev Classification: DIRECT
    function test_check_sweep_pays_only_the_beneficiary(address caller, uint256 amount) public {
        // Justification: the beneficiary and the treasury would each count their own balance twice
        vm.assume(caller != BENEFICIARY && caller != address(treasury));
        // Justification: sweep reverts with NothingToSweep at zero (Treasury.sol:89); 2**128 wei is more than exists
        vm.assume(amount >= 1 && amount <= MAX_ETHER);
        _sweepPays(caller, amount);
    }

    /// @notice Fuzz wrapper for test_check_sweep_pays_only_the_beneficiary
    /// @dev See T17 in test-templates.md
    function test_fuzz_sweep_pays_only_the_beneficiary(address caller, uint256 rawAmount) public {
        if (caller == BENEFICIARY || caller == address(treasury)) return;
        _sweepPays(caller, bound(rawAmount, 1, MAX_ETHER));
    }

    function _sweepPays(address caller, uint256 amount) private {
        vm.deal(address(treasury), amount);
        vm.deal(BENEFICIARY, 0);
        uint256 callerBefore = caller.balance;

        vm.prank(caller);
        (bool ok,) = address(treasury).call(abi.encodeCall(treasury.sweep, ()));

        assert(ok);
        assert(address(treasury).balance == 0);
        assert(BENEFICIARY.balance == amount);
        assert(caller.balance == callerBefore);
        assert(treasury.beneficiary() == BENEFICIARY);
    }

    /// @notice CC-3: after the owner repoints the treasury, the next sweep
    ///         pays the new beneficiary all of it and the old one nothing.
    /// @dev Technique: T14 conservation, across a change of beneficiary.
    /// @dev Classification: DIRECT
    function test_check_sweep_follows_a_moved_beneficiary(address next, uint256 amount) public {
        // Justification: a beneficiary with code runs on receipt; a plain account is the case proved here
        vm.assume(_isAccount(next));
        // Justification: moving to the same beneficiary leaves no old one to compare with
        vm.assume(next != BENEFICIARY);
        // Justification: sweep reverts with NothingToSweep at zero (Treasury.sol:89); 2**128 wei is more than exists
        vm.assume(amount >= 1 && amount <= MAX_ETHER);
        _sweepFollows(next, amount);
    }

    /// @notice Fuzz wrapper for test_check_sweep_follows_a_moved_beneficiary
    /// @dev See T17 in test-templates.md
    function test_fuzz_sweep_follows_a_moved_beneficiary(address next, uint256 rawAmount) public {
        if (!_isAccount(next) || next == BENEFICIARY) return;
        _sweepFollows(next, bound(rawAmount, 1, MAX_ETHER));
    }

    function _sweepFollows(address next, uint256 amount) private {
        vm.prank(TREASURY_OWNER);
        (bool moved,) = address(treasury).call(abi.encodeCall(treasury.setBeneficiary, (next)));
        assert(moved);

        vm.deal(address(treasury), amount);
        vm.deal(next, 0);
        uint256 oldBefore = BENEFICIARY.balance;

        vm.prank(ALICE);
        (bool ok,) = address(treasury).call(abi.encodeCall(treasury.sweep, ()));

        assert(ok);
        assert(next.balance == amount);
        assert(BENEFICIARY.balance == oldBefore);
        assert(address(treasury).balance == 0);
    }

    // ════════════════════════════════════════════════
    //  The refusals
    // ════════════════════════════════════════════════

    /// @notice PD-1: an empty treasury refuses a sweep with NothingToSweep, whoever
    ///         asks.
    /// @dev Technique: T3 guard, over every caller.
    /// @dev Classification: DIRECT
    function test_check_sweep_refuses_when_empty(address caller) public {
        vm.prank(caller);
        (bool ok, bytes memory answer) = address(treasury).call(abi.encodeCall(treasury.sweep, ()));

        assert(!ok);
        assert(_is(answer, Treasury.NothingToSweep.selector));
    }

    /// @notice PD-1: sweep takes no ether. A call that attaches some is refused and
    ///         every balance stays as it was.
    /// @dev Technique: T3 guard, on a function that is not payable.
    /// @dev Classification: DIRECT
    function test_check_sweep_refuses_ether(address caller, uint256 value, uint256 held) public {
        // Justification: a caller that attaches ether signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(caller));
        // Justification: the case under test is ether attached, up to more than exists
        vm.assume(value >= 1 && value <= MAX_ETHER);
        // Justification: the treasury's balance is ether, and 2**128 wei is more than exists
        vm.assume(held <= MAX_ETHER);
        _sweepRefusesEther(caller, value, held);
    }

    /// @notice Fuzz wrapper for test_check_sweep_refuses_ether
    /// @dev See T17 in test-templates.md
    function test_fuzz_sweep_refuses_ether(address caller, uint256 rawValue, uint256 rawHeld) public {
        if (!_isAccount(caller)) return;
        _sweepRefusesEther(caller, bound(rawValue, 1, MAX_ETHER), bound(rawHeld, 0, MAX_ETHER));
    }

    function _sweepRefusesEther(address caller, uint256 value, uint256 held) private {
        vm.deal(address(treasury), held);
        vm.deal(caller, value);

        vm.prank(caller);
        (bool ok,) = address(treasury).call{value: value}(abi.encodeCall(treasury.sweep, ()));

        assert(!ok);
        assert(address(treasury).balance == held);
        assert(caller.balance == value);
    }

    // ════════════════════════════════════════════════
    //  PD-1: money in
    // ════════════════════════════════════════════════

    /// @notice PD-1: the treasury accepts ether from anybody, in any amount,
    ///         keeps exactly what was sent, and changes nothing else by
    ///         receiving it. A treasury that could refuse would lock the
    ///         token's withdraw.
    /// @dev Technique: T14 conservation, over every sender and amount.
    /// @dev Classification: DIRECT
    function test_check_treasury_accepts_ether_from_anyone(address sender, uint256 value, uint256 held) public {
        // Justification: a sender of plain ether signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(sender));
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(value <= MAX_ETHER);
        // Justification: the treasury's balance is ether, and 2**128 wei is more than exists
        vm.assume(held <= MAX_ETHER);
        _acceptsEther(sender, value, held);
    }

    /// @notice Fuzz wrapper for test_check_treasury_accepts_ether_from_anyone
    /// @dev See T17 in test-templates.md
    function test_fuzz_treasury_accepts_ether_from_anyone(address sender, uint256 rawValue, uint256 rawHeld) public {
        if (!_isAccount(sender)) return;
        _acceptsEther(sender, bound(rawValue, 0, MAX_ETHER), bound(rawHeld, 0, MAX_ETHER));
    }

    function _acceptsEther(address sender, uint256 value, uint256 held) private {
        vm.deal(address(treasury), held);
        vm.deal(sender, value);

        vm.prank(sender);
        (bool ok,) = address(treasury).call{value: value}("");

        assert(ok);
        assert(address(treasury).balance == held + value);
        assert(sender.balance == 0);
        assert(treasury.beneficiary() == BENEFICIARY);
        assert(treasury.owner() == TREASURY_OWNER);
    }
}
