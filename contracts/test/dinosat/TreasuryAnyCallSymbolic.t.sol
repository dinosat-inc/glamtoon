// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — Treasury, everything a stranger can try
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract TreasuryAnyCallSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract TreasuryAnyCallSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev Sweeping is open to everyone and repointing is closed to everyone but
///      the owner, so what has to hold is that the open door and the closed
///      one stay separate. One proof per function of the treasury, each with
///      symbolic arguments, from any account that is not the owner, with any
///      value attached: afterwards the owner, the pending owner and the
///      beneficiary are who they were, the collection label has not moved,
///      and the treasury's ether is either still there or with the
///      beneficiary. The caller ends with no more than it had.
contract TreasuryAnyCallSymbolicTest is DinoSatBase {
    /// What the treasury holds before each call, so a stranger's sweep
    /// really lands.
    uint256 internal constant HELD = 1 ether;

    // ════════════════════════════════════════════════
    //  COMPOSITION: no stranger moves the key, the destination or the money
    //  The domain is every function of the treasury, one test each:
    //    setBeneficiary, transferOwnership, acceptOwnership,
    //    renounceOwnership, sweep, sweepToken,
    //    plain ether with no calldata, and any four byte selector alone.
    //  The three views cannot write: the compiler refuses a store in them.
    //  test/unit pins the compiled ABI to a written list, so a function added
    //  later fails there rather than escaping this list.
    //  Status: 8/8 domain values [PASS].
    // ════════════════════════════════════════════════

    /// @notice AC-1/PD-1 for setBeneficiary.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_stranger_changes_nothing_setBeneficiary(address caller, uint256 value, address to) public {
        _assumeStranger(caller, value);
        _strangerChangesNothing(caller, value, abi.encodeCall(treasury.setBeneficiary, (to)));
    }

    /// @notice Fuzz wrapper for test_check_stranger_changes_nothing_setBeneficiary
    /// @dev See T17 in test-templates.md
    function test_fuzz_stranger_changes_nothing_setBeneficiary(address caller, uint256 rawValue, address to) public {
        if (!_isStranger(caller)) return;
        _strangerChangesNothing(caller, bound(rawValue, 0, MAX_ETHER), abi.encodeCall(treasury.setBeneficiary, (to)));
    }

    /// @notice AC-1/PD-1 for transferOwnership.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_stranger_changes_nothing_transferOwnership(address caller, uint256 value, address next) public {
        _assumeStranger(caller, value);
        _strangerChangesNothing(caller, value, abi.encodeCall(treasury.transferOwnership, (next)));
    }

    /// @notice Fuzz wrapper for test_check_stranger_changes_nothing_transferOwnership
    /// @dev See T17 in test-templates.md
    function test_fuzz_stranger_changes_nothing_transferOwnership(address caller, uint256 rawValue, address next)
        public
    {
        if (!_isStranger(caller)) return;
        _strangerChangesNothing(
            caller, bound(rawValue, 0, MAX_ETHER), abi.encodeCall(treasury.transferOwnership, (next))
        );
    }

    /// @notice AC-1/PD-1 for acceptOwnership, with no offer made.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_stranger_changes_nothing_acceptOwnership(address caller, uint256 value) public {
        _assumeStranger(caller, value);
        _strangerChangesNothing(caller, value, abi.encodeCall(treasury.acceptOwnership, ()));
    }

    /// @notice Fuzz wrapper for test_check_stranger_changes_nothing_acceptOwnership
    /// @dev See T17 in test-templates.md
    function test_fuzz_stranger_changes_nothing_acceptOwnership(address caller, uint256 rawValue) public {
        if (!_isStranger(caller)) return;
        _strangerChangesNothing(caller, bound(rawValue, 0, MAX_ETHER), abi.encodeCall(treasury.acceptOwnership, ()));
    }

    /// @notice AC-1/PD-1 for renounceOwnership.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_stranger_changes_nothing_renounceOwnership(address caller, uint256 value) public {
        _assumeStranger(caller, value);
        _strangerChangesNothing(caller, value, abi.encodeCall(treasury.renounceOwnership, ()));
    }

    /// @notice Fuzz wrapper for test_check_stranger_changes_nothing_renounceOwnership
    /// @dev See T17 in test-templates.md
    function test_fuzz_stranger_changes_nothing_renounceOwnership(address caller, uint256 rawValue) public {
        if (!_isStranger(caller)) return;
        _strangerChangesNothing(caller, bound(rawValue, 0, MAX_ETHER), abi.encodeCall(treasury.renounceOwnership, ()));
    }

    /// @notice AC-1/PD-1 for sweep, the one call here that lands.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_stranger_changes_nothing_sweep(address caller, uint256 value) public {
        _assumeStranger(caller, value);
        _strangerChangesNothing(caller, value, abi.encodeCall(treasury.sweep, ()));
    }

    /// @notice Fuzz wrapper for test_check_stranger_changes_nothing_sweep
    /// @dev See T17 in test-templates.md
    function test_fuzz_stranger_changes_nothing_sweep(address caller, uint256 rawValue) public {
        if (!_isStranger(caller)) return;
        _strangerChangesNothing(caller, bound(rawValue, 0, MAX_ETHER), abi.encodeCall(treasury.sweep, ()));
    }

    /// @notice AC-1/PD-1 for sweepToken, pointed at any plain address or at
    ///         one of the system's own contracts.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_stranger_changes_nothing_sweepToken(address caller, uint256 value, address token) public {
        _assumeStranger(caller, value);
        // Justification: a token is somebody else's code; the ones proved here are an address with
        // none and the token contract itself. TreasuryTokenSweepSymbolicTest covers real tokens.
        vm.assume(token == address(nft) || _isAccount(token));
        _strangerChangesNothing(caller, value, abi.encodeCall(treasury.sweepToken, (IERC20(token))));
    }

    /// @notice Fuzz wrapper for test_check_stranger_changes_nothing_sweepToken
    /// @dev See T17 in test-templates.md
    function test_fuzz_stranger_changes_nothing_sweepToken(address caller, uint256 rawValue, address token) public {
        if (!_isStranger(caller)) return;
        if (token != address(nft) && !_isAccount(token)) return;
        _strangerChangesNothing(
            caller, bound(rawValue, 0, MAX_ETHER), abi.encodeCall(treasury.sweepToken, (IERC20(token)))
        );
    }

    /// @notice AC-1/PD-1 for ether sent with no calldata, which the treasury
    ///         accepts and keeps.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_stranger_changes_nothing_plainEther(address caller, uint256 value) public {
        _assumeStranger(caller, value);
        _strangerChangesNothing(caller, value, "");
    }

    /// @notice Fuzz wrapper for test_check_stranger_changes_nothing_plainEther
    /// @dev See T17 in test-templates.md
    function test_fuzz_stranger_changes_nothing_plainEther(address caller, uint256 rawValue) public {
        if (!_isStranger(caller)) return;
        _strangerChangesNothing(caller, bound(rawValue, 0, MAX_ETHER), "");
    }

    /// @notice AC-1/PD-1 for any four byte selector sent alone: every function
    ///         that takes no argument, and every selector the treasury does
    ///         not have.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_stranger_changes_nothing_anySelector(address caller, uint256 value, bytes4 selector) public {
        _assumeStranger(caller, value);
        _strangerChangesNothing(caller, value, abi.encodePacked(selector));
    }

    /// @notice Fuzz wrapper for test_check_stranger_changes_nothing_anySelector
    /// @dev See T17 in test-templates.md
    function test_fuzz_stranger_changes_nothing_anySelector(address caller, uint256 rawValue, bytes4 selector) public {
        if (!_isStranger(caller)) return;
        _strangerChangesNothing(caller, bound(rawValue, 0, MAX_ETHER), abi.encodePacked(selector));
    }

    // ════════════════════════════════════════════════
    //  Helpers
    // ════════════════════════════════════════════════

    /// Anybody who is not the owner, and not the beneficiary, whose balance
    /// is where a sweep is meant to go.
    function _isStranger(address caller) private view returns (bool) {
        return _isAccount(caller) && caller != TREASURY_OWNER && caller != BENEFICIARY;
    }

    /// The domain every proof here shares.
    function _assumeStranger(address caller, uint256 value) private view {
        // Justification: a caller signs a transaction, so it is an account (see _isAccount);
        // the owner is the one account allowed to change anything (Treasury.sol:78)
        vm.assume(_isStranger(caller));
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(value <= MAX_ETHER);
    }

    /// Fund the treasury and the caller, make the call whatever its outcome,
    /// and check who holds the key and the money afterwards.
    function _strangerChangesNothing(address caller, uint256 value, bytes memory data) private {
        vm.deal(address(treasury), HELD);
        vm.deal(BENEFICIARY, 0);
        vm.deal(caller, value);

        vm.prank(caller);
        (bool ok,) = address(treasury).call{value: value}(data);
        ok;

        assert(treasury.owner() == TREASURY_OWNER);
        assert(treasury.pendingOwner() == address(0));
        assert(treasury.beneficiary() == BENEFICIARY);
        assert(nft.owner() == TREASURY_OWNER);

        assert(caller.balance <= value);
        assert(address(treasury).balance + BENEFICIARY.balance + caller.balance == HELD + value);
    }
}
