// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {GlamToon} from "../../src/GlamToon.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, the withdraw anyone may call
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonWithdrawSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonWithdrawSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev withdraw checks no caller and takes no argument. Its whole safety is
///      that it can only ever pay the one payee fixed at construction, and
///      that whoever calls it keeps none of what it moves.
contract GlamToonWithdrawSymbolicTest is DinoSatBase {
    // ════════════════════════════════════════════════
    //  CC-3: a withdraw reaches the treasury and nowhere else
    // ════════════════════════════════════════════════

    /// @notice CC-3: whoever calls it, a withdraw empties the contract into the
    ///         treasury, for every balance, and the caller's own balance does
    ///         not move.
    /// @dev Technique: T14 conservation, over every caller and balance.
    /// @dev Classification: DIRECT
    function test_check_withdraw_pays_only_the_treasury(address caller, uint256 amount) public {
        // Justification: the token and the treasury do not call withdraw; either would count its own balance twice
        vm.assume(caller != address(nft) && caller != address(treasury));
        // Justification: withdraw reverts with NothingToWithdraw at zero (GlamToon.sol:289); 2**128 wei is more than exists
        vm.assume(amount >= 1 && amount <= MAX_ETHER);
        _paysTreasury(caller, amount);
    }

    /// @notice Fuzz wrapper for test_check_withdraw_pays_only_the_treasury
    /// @dev See T17 in test-templates.md
    function test_fuzz_withdraw_pays_only_the_treasury(address caller, uint256 rawAmount) public {
        if (caller == address(nft) || caller == address(treasury)) return;
        _paysTreasury(caller, bound(rawAmount, 1, MAX_ETHER));
    }

    function _paysTreasury(address caller, uint256 amount) private {
        vm.deal(address(nft), amount);
        uint256 callerBefore = caller.balance;
        uint256 beneficiaryBefore = BENEFICIARY.balance;

        vm.prank(caller);
        (bool ok,) = address(nft).call(abi.encodeCall(nft.withdraw, ()));

        assert(ok);
        assert(address(nft).balance == 0);
        assert(address(treasury).balance == amount);
        assert(caller.balance == callerBefore);
        assert(BENEFICIARY.balance == beneficiaryBefore);
    }

    /// @notice CC-3: a sale followed by a withdraw moves exactly the price to
    ///         the treasury. The buyer's change is not part of it.
    /// @dev Technique: T14 conservation, across the sale and the withdraw.
    /// @dev Classification: DIRECT
    function test_check_withdraw_moves_exactly_the_takings(uint256 imageId, uint256 sold, uint256 sent) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: _mintBlue reverts with SoldOut unless blueMinted < BLUE_SUPPLY (GlamToon.sol:246)
        vm.assume(sold < N);
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(sent <= MAX_ETHER);
        // Justification: below the price the sale reverts with InsufficientPayment (GlamToon.sol:251)
        vm.assume(sent >= _schedule(sold));
        _movesTakings(imageId, sold, sent);
    }

    /// @notice Fuzz wrapper for test_check_withdraw_moves_exactly_the_takings
    /// @dev See T17 in test-templates.md
    function test_fuzz_withdraw_moves_exactly_the_takings(uint256 rawImage, uint256 rawSold, uint256 rawSent) public {
        uint256 sold = bound(rawSold, 0, N - 1);
        _movesTakings(bound(rawImage, 0, N - 1), sold, bound(rawSent, _schedule(sold), MAX_ETHER));
    }

    function _movesTakings(uint256 imageId, uint256 sold, uint256 sent) private {
        _setSold(sold);
        uint256 price = _schedule(sold);
        (bool bought,) = _tryMintBlue(ALICE, imageId, sent, price);
        assert(bought);

        vm.prank(BOB);
        (bool ok,) = address(nft).call(abi.encodeCall(nft.withdraw, ()));

        assert(ok);
        assert(address(nft).balance == 0);
        assert(address(treasury).balance == price);
        assert(ALICE.balance == sent - price);
        assert(BOB.balance == 0);
    }

    // ════════════════════════════════════════════════
    //  The refusals
    // ════════════════════════════════════════════════

    /// @notice PD-1: an empty contract refuses a withdraw with NothingToWithdraw,
    ///         whoever asks.
    /// @dev Technique: T3 guard.
    /// @dev Classification: DIRECT
    function test_check_withdraw_refuses_when_empty(address caller) public {
        vm.prank(caller);
        (bool ok, bytes memory answer) = address(nft).call(abi.encodeCall(nft.withdraw, ()));

        assert(!ok);
        assert(_is(answer, GlamToon.NothingToWithdraw.selector));
        assert(address(treasury).balance == 0);
    }

    /// @notice PD-1: withdraw takes no ether. A call that attaches some is refused
    ///         and both balances stay as they were.
    /// @dev Technique: T3 guard, on a function that is not payable.
    /// @dev Classification: DIRECT
    function test_check_withdraw_refuses_ether(address caller, uint256 value, uint256 held) public {
        // Justification: a caller that attaches ether signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(caller));
        // Justification: the case under test is ether attached, up to more than exists
        vm.assume(value >= 1 && value <= MAX_ETHER);
        // Justification: the contract's balance is ether, and 2**128 wei is more than exists
        vm.assume(held <= MAX_ETHER);
        _withdrawRefusesEther(caller, value, held);
    }

    /// @notice Fuzz wrapper for test_check_withdraw_refuses_ether
    /// @dev See T17 in test-templates.md
    function test_fuzz_withdraw_refuses_ether(address caller, uint256 rawValue, uint256 rawHeld) public {
        if (!_isAccount(caller)) return;
        _withdrawRefusesEther(caller, bound(rawValue, 1, MAX_ETHER), bound(rawHeld, 0, MAX_ETHER));
    }

    function _withdrawRefusesEther(address caller, uint256 value, uint256 held) private {
        vm.deal(address(nft), held);
        vm.deal(caller, value);

        vm.prank(caller);
        (bool ok,) = address(nft).call{value: value}(abi.encodeCall(nft.withdraw, ()));

        assert(!ok);
        assert(address(nft).balance == held);
        assert(caller.balance == value);
        assert(address(treasury).balance == 0);
    }

    // ════════════════════════════════════════════════
    //  AC-2: a withdraw moves money and nothing else
    // ════════════════════════════════════════════════

    /// @notice AC-2: a withdraw leaves every token, counter and claim as it
    ///         was. Being able to call it grants nothing over the collection.
    /// @dev Technique: T16 stateful, over every caller and balance.
    /// @dev Classification: DIRECT
    function test_check_withdraw_leaves_the_collection_alone(address caller, uint256 amount) public {
        // Justification: withdraw reverts with NothingToWithdraw at zero (GlamToon.sol:289); 2**128 wei is more than exists
        vm.assume(amount >= 1 && amount <= MAX_ETHER);
        _leavesCollection(caller, amount);
    }

    /// @notice Fuzz wrapper for test_check_withdraw_leaves_the_collection_alone
    /// @dev See T17 in test-templates.md
    function test_fuzz_withdraw_leaves_the_collection_alone(address caller, uint256 rawAmount) public {
        _leavesCollection(caller, bound(rawAmount, 1, MAX_ETHER));
    }

    function _leavesCollection(address caller, uint256 amount) private {
        (bool bought,) = _tryMintBlue(ALICE, 7, STEP, STEP);
        (bool taken,) = _tryMintGreen(BOB, 7);
        assert(bought && taken);
        vm.deal(address(nft), amount);

        vm.prank(caller);
        (bool ok,) = address(nft).call(abi.encodeCall(nft.withdraw, ()));

        assert(ok);
        assert(nft.ownerOf(7) == ALICE);
        assert(nft.ownerOf(N + 7) == BOB);
        assert(nft.blueMinted() == 1);
        assert(nft.greenMinted() == 1);
        assert(nft.greenTaken(7, BOB));
        assert(nft.blueTaken(7));
    }
}
