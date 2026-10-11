// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {GlamToon} from "../../src/GlamToon.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, the owner label and what it does not grant
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonOwnerLabelSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonOwnerLabelSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev GlamToon.owner() exists so marketplaces have somebody to ask about the
///      collection page. Inside the token it is a label and not a key: it
///      reads the treasury's owner, follows a handover of it, and gives the
///      address it names no power over the sale, the money or anybody's token.
contract GlamToonOwnerLabelSymbolicTest is DinoSatBase {
    // ════════════════════════════════════════════════
    //  CC-2: the label is the treasury's owner
    // ════════════════════════════════════════════════

    /// @notice CC-2: the token reports the treasury's owner as its own.
    /// @dev Technique: T2, over constants.
    /// @dev Classification: DIRECT
    function test_check_label_is_the_treasury_owner() public view {
        assert(nft.owner() == TREASURY_OWNER);
        assert(nft.owner() == treasury.owner());
    }

    /// @notice CC-2: the label stays put while a handover is only offered, and
    ///         moves when the new owner accepts, whoever that is.
    /// @dev Technique: T16 stateful, across the two step handover.
    /// @dev Classification: DIRECT
    function test_check_label_follows_a_two_step_handover(address next) public {
        // Justification: the new owner signs the acceptance, so it is not the zero address
        vm.assume(next != address(0));
        // Justification: handing the treasury to its own owner changes nothing to observe
        vm.assume(next != TREASURY_OWNER);

        vm.prank(TREASURY_OWNER);
        (bool offered,) = address(treasury).call(abi.encodeCall(treasury.transferOwnership, (next)));
        assert(offered);
        assert(nft.owner() == TREASURY_OWNER);

        vm.prank(next);
        (bool accepted,) = address(treasury).call(abi.encodeCall(treasury.acceptOwnership, ()));
        assert(accepted);
        assert(nft.owner() == next);
        assert(nft.owner() == treasury.owner());
    }

    // ════════════════════════════════════════════════
    //  AC-2: the label grants nothing in the token
    // ════════════════════════════════════════════════

    /// @notice AC-2: the address the label names cannot steer a withdraw. When
    ///         it calls withdraw the whole balance goes to the treasury, as it
    ///         does for anybody, and none of it to the caller.
    /// @dev Technique: T14 conservation.
    /// @dev Classification: DIRECT
    function test_check_label_holder_cannot_redirect_a_withdraw(uint256 amount) public {
        // Justification: withdraw reverts with NothingToWithdraw at zero (GlamToon.sol:289); 2**128 wei is more than exists
        vm.assume(amount >= 1 && amount <= MAX_ETHER);
        _cannotRedirect(amount);
    }

    /// @notice Fuzz wrapper for test_check_label_holder_cannot_redirect_a_withdraw
    /// @dev See T17 in test-templates.md
    function test_fuzz_label_holder_cannot_redirect_a_withdraw(uint256 rawAmount) public {
        _cannotRedirect(bound(rawAmount, 1, MAX_ETHER));
    }

    function _cannotRedirect(uint256 amount) private {
        vm.deal(address(nft), amount);
        uint256 before = TREASURY_OWNER.balance;

        vm.prank(TREASURY_OWNER);
        (bool ok,) = address(nft).call(abi.encodeCall(nft.withdraw, ()));

        assert(ok);
        assert(address(treasury).balance == amount);
        assert(TREASURY_OWNER.balance == before);
        assert(address(nft).balance == 0);
    }

    /// @notice AC-2: the address the label names cannot move, or approve
    ///         itself for, a token it does not hold.
    /// @dev Technique: T3 guard, over every character and destination.
    /// @dev Classification: DIRECT
    function test_check_label_holder_cannot_move_a_holders_token(uint256 imageId, address to) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        _cannotMove(imageId, to);
    }

    /// @notice Fuzz wrapper for test_check_label_holder_cannot_move_a_holders_token
    /// @dev See T17 in test-templates.md
    function test_fuzz_label_holder_cannot_move_a_holders_token(uint256 rawImage, address to) public {
        _cannotMove(bound(rawImage, 0, N - 1), to);
    }

    function _cannotMove(uint256 imageId, address to) private {
        (bool bought,) = _tryMintBlue(ALICE, imageId, STEP, STEP);
        assert(bought);

        vm.prank(TREASURY_OWNER);
        (bool moved,) = address(nft).call(abi.encodeCall(nft.transferFrom, (ALICE, to, imageId)));
        vm.prank(TREASURY_OWNER);
        (bool approved,) = address(nft).call(abi.encodeCall(nft.approve, (TREASURY_OWNER, imageId)));

        assert(!moved);
        assert(!approved);
        assert(nft.ownerOf(imageId) == ALICE);
    }

    /// @notice AC-2: the address the label names pays the same price as
    ///         everybody else. Without the price it gets InsufficientPayment.
    /// @dev Technique: T3 guard, over every character and point of the sale.
    /// @dev Classification: DIRECT
    function test_check_label_holder_cannot_mint_below_the_price(uint256 imageId, uint256 sold, uint256 sent) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: _mintBlue reverts with SoldOut unless blueMinted < BLUE_SUPPLY (GlamToon.sol:246)
        vm.assume(sold < N);
        // Justification: the branch under test, msg.value < price (GlamToon.sol:251)
        vm.assume(sent < _schedule(sold));
        _paysLikeAnyone(imageId, sold, sent);
    }

    /// @notice Fuzz wrapper for test_check_label_holder_cannot_mint_below_the_price
    /// @dev See T17 in test-templates.md
    function test_fuzz_label_holder_cannot_mint_below_the_price(uint256 rawImage, uint256 rawSold, uint256 rawSent)
        public
    {
        uint256 sold = bound(rawSold, 0, N - 1);
        _paysLikeAnyone(bound(rawImage, 0, N - 1), sold, bound(rawSent, 0, _schedule(sold) - 1));
    }

    function _paysLikeAnyone(uint256 imageId, uint256 sold, uint256 sent) private {
        _setSold(sold);

        (bool ok, bytes memory answer) = _tryMintBlue(TREASURY_OWNER, imageId, sent, type(uint256).max);

        assert(!ok);
        assert(_is(answer, GlamToon.InsufficientPayment.selector));
        assert(nft.blueMinted() == sold);
        assert(TREASURY_OWNER.balance == sent);
    }
}
