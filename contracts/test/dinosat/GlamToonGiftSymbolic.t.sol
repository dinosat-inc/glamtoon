// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {GlamToon} from "../../src/GlamToon.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, a blue bought for somebody else
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonGiftSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonGiftSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev mintBlueFor splits the two things a sale hands out: the token goes to
///      the recipient and the change goes back to whoever paid. A gift that
///      sent the change to the recipient, or the token to the payer, is the
///      failure these rule out.
contract GlamToonGiftSymbolicTest is DinoSatBase {
    // ════════════════════════════════════════════════
    //  PD-1: the token one way, the change the other
    // ════════════════════════════════════════════════

    /// @notice PD-1: the payer is charged the price and refunded the rest, the
    ///         recipient receives the token and not a wei, for every amount,
    ///         ceiling, character and point of the sale.
    /// @dev Technique: T14 conservation, across two accounts.
    /// @dev Classification: DIRECT
    function test_check_gift_sends_token_and_change_apart(uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice)
        public
    {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: _mintBlue reverts with SoldOut unless blueMinted < BLUE_SUPPLY (GlamToon.sol:246)
        vm.assume(sold < N);
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(sent <= MAX_ETHER);
        // Justification: below the price the sale reverts with InsufficientPayment (GlamToon.sol:251)
        vm.assume(sent >= _schedule(sold));
        // Justification: below the price the ceiling reverts with PriceTooHigh (GlamToon.sol:250)
        vm.assume(maxPrice >= _schedule(sold));
        _giftSplits(imageId, sold, sent, maxPrice);
    }

    /// @notice Fuzz wrapper for test_check_gift_sends_token_and_change_apart
    /// @dev See T17 in test-templates.md
    function test_fuzz_gift_sends_token_and_change_apart(
        uint256 rawImage,
        uint256 rawSold,
        uint256 rawSent,
        uint256 rawMax
    ) public {
        uint256 sold = bound(rawSold, 0, N - 1);
        uint256 price = _schedule(sold);
        _giftSplits(
            bound(rawImage, 0, N - 1), sold, bound(rawSent, price, MAX_ETHER), bound(rawMax, price, type(uint256).max)
        );
    }

    function _giftSplits(uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice) private {
        _setSold(sold);
        uint256 price = _schedule(sold);
        uint256 recipientBefore = BOB.balance;

        (bool ok,) = _tryMintBlueFor(ALICE, BOB, imageId, sent, maxPrice);

        assert(ok);
        assert(address(nft).balance == price);
        assert(ALICE.balance == sent - price);
        assert(BOB.balance == recipientBefore);
        assert(nft.ownerOf(imageId) == BOB);
        assert(nft.balanceOf(ALICE) == 0);
        assert(nft.blueMinted() == sold + 1);
    }

    /// @notice AC-2: a gift reaches any account it is addressed to, including the
    ///         payer's own.
    /// @dev Technique: T16 stateful, over every recipient.
    /// @dev Classification: DIRECT
    function test_check_gift_reaches_any_account(address to, uint256 imageId) public {
        // Justification: recipients with code run a callback, which the reentrancy suite covers (see _isAccount)
        vm.assume(_isAccount(to));
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        _giftReaches(to, imageId);
    }

    /// @notice Fuzz wrapper for test_check_gift_reaches_any_account
    /// @dev See T17 in test-templates.md
    function test_fuzz_gift_reaches_any_account(address to, uint256 rawImage) public {
        if (!_isAccount(to)) return;
        _giftReaches(to, bound(rawImage, 0, N - 1));
    }

    function _giftReaches(address to, uint256 imageId) private {
        (bool ok,) = _tryMintBlueFor(ALICE, to, imageId, STEP, STEP);

        assert(ok);
        assert(nft.ownerOf(imageId) == to);
        assert(nft.blueTaken(imageId));
        assert(address(nft).balance == STEP);
    }

    // ════════════════════════════════════════════════
    //  TOK-4: a gift cannot burn a character
    // ════════════════════════════════════════════════

    /// @notice TOK-4: a gift addressed to nobody is refused, the payer keeps
    ///         its ether, and the character stays unsold and buyable. Sending
    ///         a blue to the zero address would take it out of the collection
    ///         for good.
    /// @dev Technique: T3 guard.
    /// @dev Classification: DIRECT
    function test_check_gift_to_nobody_is_refused(uint256 imageId, uint256 sent, uint256 maxPrice) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(sent <= MAX_ETHER);
        _giftToNobody(imageId, sent, maxPrice);
    }

    /// @notice Fuzz wrapper for test_check_gift_to_nobody_is_refused
    /// @dev See T17 in test-templates.md
    function test_fuzz_gift_to_nobody_is_refused(uint256 rawImage, uint256 rawSent, uint256 maxPrice) public {
        _giftToNobody(bound(rawImage, 0, N - 1), bound(rawSent, 0, MAX_ETHER), maxPrice);
    }

    function _giftToNobody(uint256 imageId, uint256 sent, uint256 maxPrice) private {
        (bool ok, bytes memory answer) = _tryMintBlueFor(ALICE, address(0), imageId, sent, maxPrice);

        assert(!ok);
        // with the price paid and allowed, the only thing left to refuse it is the recipient
        if (sent >= STEP && maxPrice >= STEP) {
            assert(_is(answer, IERC721Errors.ERC721InvalidReceiver.selector));
        }
        assert(nft.blueMinted() == 0);
        assert(!nft.blueTaken(imageId));
        assert(nft.blueTakenBits(imageId >> 8, 1)[0] == 0);
        assert(address(nft).balance == 0);
        assert(ALICE.balance == sent);
    }

    // ════════════════════════════════════════════════
    //  SM-1: a gift obeys the same rules as a purchase
    // ════════════════════════════════════════════════

    /// @notice SM-1: a gift cannot take a character that has sold, whoever it
    ///         is for and whatever is paid.
    /// @dev Technique: T12 state gating, on the character's owner.
    /// @dev Classification: DIRECT
    function test_check_gift_cannot_take_a_sold_character(address to, uint256 imageId, uint256 sent) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(sent <= MAX_ETHER);
        _giftCannotRetake(to, imageId, sent);
    }

    /// @notice Fuzz wrapper for test_check_gift_cannot_take_a_sold_character
    /// @dev See T17 in test-templates.md
    function test_fuzz_gift_cannot_take_a_sold_character(address to, uint256 rawImage, uint256 rawSent) public {
        _giftCannotRetake(to, bound(rawImage, 0, N - 1), bound(rawSent, 0, MAX_ETHER));
    }

    function _giftCannotRetake(address to, uint256 imageId, uint256 sent) private {
        (bool first,) = _tryMintBlue(ALICE, imageId, STEP, STEP);
        assert(first);

        (bool ok, bytes memory answer) = _tryMintBlueFor(BOB, to, imageId, sent, type(uint256).max);

        assert(!ok);
        assert(_is(answer, GlamToon.BlueAlreadyTaken.selector));
        assert(nft.ownerOf(imageId) == ALICE);
        assert(nft.blueMinted() == 1);
        assert(BOB.balance == sent);
    }

    /// @notice SM-1/TOK-3/FB-3/FB-4: a gift to an account settles exactly when every guard passes,
    ///         the same condition as a purchase.
    /// @dev Technique: T12 state gating, with every input left symbolic.
    /// @dev Classification: DIRECT
    function test_check_gift_settles_exactly_when_every_guard_passes(
        uint256 t,
        uint256 imageId,
        uint256 sold,
        uint256 sent,
        uint256 maxPrice
    ) public {
        // Justification: block.timestamp is seconds; SALE_START itself is a uint64 (GlamToon.sol:133)
        vm.assume(t <= type(uint64).max);
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(sent <= MAX_ETHER);
        _giftSettlesIff(t, imageId, sold, sent, maxPrice);
    }

    /// @notice Fuzz wrapper for test_check_gift_settles_exactly_when_every_guard_passes
    /// @dev See T17 in test-templates.md
    function test_fuzz_gift_settles_exactly_when_every_guard_passes(
        uint256 rawT,
        uint256 imageId,
        uint256 sold,
        uint256 rawSent,
        uint256 maxPrice
    ) public {
        _giftSettlesIff(bound(rawT, 0, type(uint64).max), imageId, sold, bound(rawSent, 0, MAX_ETHER), maxPrice);
    }

    function _giftSettlesIff(uint256 t, uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice) private {
        vm.warp(t);
        _setSold(sold);

        (bool ok,) = _tryMintBlueFor(ALICE, BOB, imageId, sent, maxPrice);

        bool open = t >= START;
        bool known = imageId < N;
        bool available = sold < N;
        bool affordable = available && maxPrice >= _schedule(sold) && sent >= _schedule(sold);
        assert(ok == (open && known && affordable));
    }
}
