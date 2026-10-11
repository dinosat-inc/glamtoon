// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {GlamToon} from "../../src/GlamToon.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, the free green edition
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonGreenSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonGreenSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev Green is the half of the collection anyone can mint for the price of
///      gas. One address takes one green of a character, ever, generations are
///      handed out in order, and no green can land on a blue id.
contract GlamToonGreenSymbolicTest is DinoSatBase {
    // ════════════════════════════════════════════════
    //  SM-5: generations are handed out in order
    // ════════════════════════════════════════════════

    /// @notice SM-5: the first account to take a character gets generation one,
    ///         whose id is the character's number plus ten thousand.
    /// @dev Technique: T16 stateful, over every account and character.
    /// @dev Classification: DIRECT
    function test_check_first_green_is_generation_one(address who, uint256 imageId) public {
        // Justification: a minter signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(who));
        // Justification: mintGreen reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:272)
        vm.assume(imageId < N);
        _firstGreen(who, imageId);
    }

    /// @notice Fuzz wrapper for test_check_first_green_is_generation_one
    /// @dev See T17 in test-templates.md
    function test_fuzz_first_green_is_generation_one(address who, uint256 rawImage) public {
        if (!_isAccount(who)) return;
        _firstGreen(who, bound(rawImage, 0, N - 1));
    }

    function _firstGreen(address who, uint256 imageId) private {
        (bool ok,) = _tryMintGreen(who, imageId);

        assert(ok);
        assert(nft.ownerOf(N + imageId) == who);
        assert(nft.tokenIdFor(imageId, 1) == N + imageId);
        assert(nft.greenCount(imageId) == 1);
        assert(nft.greenMinted() == 1);
        assert(nft.totalSupply() == 1);
        assert(nft.greenTaken(imageId, who));
    }

    /// @notice SM-5: two accounts that want the same character are not in each
    ///         other's way. They get generations one and two, in the order
    ///         they arrived.
    /// @dev Technique: T16 stateful.
    /// @dev Classification: DIRECT
    function test_check_generations_are_issued_in_order(address a, address b, uint256 imageId) public {
        // Justification: minters sign transactions, so they are accounts (see _isAccount)
        vm.assume(_isAccount(a) && _isAccount(b));
        // Justification: the same account twice is the GreenAlreadyTaken refusal, proved below
        vm.assume(a != b);
        // Justification: mintGreen reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:272)
        vm.assume(imageId < N);
        _inOrder(a, b, imageId);
    }

    /// @notice Fuzz wrapper for test_check_generations_are_issued_in_order
    /// @dev See T17 in test-templates.md
    function test_fuzz_generations_are_issued_in_order(address a, address b, uint256 rawImage) public {
        if (!_isAccount(a) || !_isAccount(b) || a == b) return;
        _inOrder(a, b, bound(rawImage, 0, N - 1));
    }

    function _inOrder(address a, address b, uint256 imageId) private {
        (bool first,) = _tryMintGreen(a, imageId);
        (bool second,) = _tryMintGreen(b, imageId);

        assert(first);
        assert(second);
        assert(nft.ownerOf(N + imageId) == a);
        assert(nft.ownerOf(2 * N + imageId) == b);
        assert(nft.greenCount(imageId) == 2);
        assert(nft.greenMinted() == 2);
    }

    // ════════════════════════════════════════════════
    //  SM-1: one green per address per character
    // ════════════════════════════════════════════════

    /// @notice SM-1: a second attempt by the same account is refused with
    ///         GreenAlreadyTaken and leaves the counters where they were, so a
    ///         refused mint cannot burn a generation.
    /// @dev Technique: T12 state gating, on the claim.
    /// @dev Classification: DIRECT
    function test_check_one_green_per_address_per_character(address who, uint256 imageId) public {
        // Justification: a minter signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(who));
        // Justification: mintGreen reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:272)
        vm.assume(imageId < N);
        _oneEach(who, imageId);
    }

    /// @notice Fuzz wrapper for test_check_one_green_per_address_per_character
    /// @dev See T17 in test-templates.md
    function test_fuzz_one_green_per_address_per_character(address who, uint256 rawImage) public {
        if (!_isAccount(who)) return;
        _oneEach(who, bound(rawImage, 0, N - 1));
    }

    function _oneEach(address who, uint256 imageId) private {
        (bool first,) = _tryMintGreen(who, imageId);
        (bool second, bytes memory answer) = _tryMintGreen(who, imageId);

        assert(first);
        assert(!second);
        assert(_is(answer, GlamToon.GreenAlreadyTaken.selector));
        assert(nft.greenCount(imageId) == 1);
        assert(nft.greenMinted() == 1);
        assert(nft.balanceOf(who) == 1);
    }

    /// @notice SM-1: the claim is per character. Taking one character does not
    ///         spend the account's green of any other.
    /// @dev Technique: T16 stateful.
    /// @dev Classification: DIRECT
    function test_check_claims_are_per_character(address who, uint256 imageA, uint256 imageB) public {
        // Justification: a minter signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(who));
        // Justification: mintGreen reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:272)
        vm.assume(imageA < N && imageB < N);
        // Justification: the same character twice is the GreenAlreadyTaken refusal, proved above
        vm.assume(imageA != imageB);
        _perCharacter(who, imageA, imageB);
    }

    /// @notice Fuzz wrapper for test_check_claims_are_per_character
    /// @dev See T17 in test-templates.md
    function test_fuzz_claims_are_per_character(address who, uint256 rawA, uint256 rawB) public {
        uint256 imageA = bound(rawA, 0, N - 1);
        uint256 imageB = bound(rawB, 0, N - 1);
        if (!_isAccount(who) || imageA == imageB) return;
        _perCharacter(who, imageA, imageB);
    }

    function _perCharacter(address who, uint256 imageA, uint256 imageB) private {
        (bool first,) = _tryMintGreen(who, imageA);
        (bool second,) = _tryMintGreen(who, imageB);

        assert(first);
        assert(second);
        assert(nft.ownerOf(N + imageA) == who);
        assert(nft.ownerOf(N + imageB) == who);
        assert(nft.greenCount(imageA) == 1);
        assert(nft.greenCount(imageB) == 1);
        assert(nft.greenMinted() == 2);
    }

    /// @notice SM-1: the claim records the mint and not the holding, so giving
    ///         the token away does not buy a second one.
    /// @dev Technique: T12 state gating, across a transfer.
    /// @dev Classification: DIRECT
    function test_check_claim_survives_giving_the_token_away(address who, address other, uint256 imageId) public {
        // Justification: a minter signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(who));
        // Justification: transferFrom refuses the zero address as a recipient
        vm.assume(other != address(0));
        // Justification: a transfer to oneself gives nothing away
        vm.assume(other != who);
        // Justification: mintGreen reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:272)
        vm.assume(imageId < N);
        _claimSurvives(who, other, imageId);
    }

    /// @notice Fuzz wrapper for test_check_claim_survives_giving_the_token_away
    /// @dev See T17 in test-templates.md
    function test_fuzz_claim_survives_giving_the_token_away(address who, address other, uint256 rawImage) public {
        if (!_isAccount(who) || other == address(0) || other == who) return;
        _claimSurvives(who, other, bound(rawImage, 0, N - 1));
    }

    function _claimSurvives(address who, address other, uint256 imageId) private {
        (bool minted,) = _tryMintGreen(who, imageId);
        assert(minted);

        vm.prank(who);
        (bool moved,) = address(nft).call(abi.encodeCall(nft.transferFrom, (who, other, N + imageId)));
        assert(moved);
        assert(nft.ownerOf(N + imageId) == other);

        (bool again, bytes memory answer) = _tryMintGreen(who, imageId);
        assert(!again);
        assert(_is(answer, GlamToon.GreenAlreadyTaken.selector));
        assert(nft.greenTaken(imageId, who));
        assert(nft.greenCount(imageId) == 1);
    }

    // ════════════════════════════════════════════════
    //  NFT-3: green never touches blue
    // ════════════════════════════════════════════════

    /// @notice NFT-3: a green mint lands outside the blue range, leaves the
    ///         character's blue unsold, takes no ether, and the blue can still
    ///         be bought afterwards.
    /// @dev Technique: T16 stateful, on the live path rather than the arithmetic.
    /// @dev Classification: DIRECT
    function test_check_green_never_lands_on_a_blue_id(address who, uint256 imageId) public {
        // Justification: a minter signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(who));
        // Justification: mintGreen reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:272)
        vm.assume(imageId < N);
        _neverBlue(who, imageId);
    }

    /// @notice Fuzz wrapper for test_check_green_never_lands_on_a_blue_id
    /// @dev See T17 in test-templates.md
    function test_fuzz_green_never_lands_on_a_blue_id(address who, uint256 rawImage) public {
        if (!_isAccount(who)) return;
        _neverBlue(who, bound(rawImage, 0, N - 1));
    }

    function _neverBlue(address who, uint256 imageId) private {
        (bool ok,) = _tryMintGreen(who, imageId);
        assert(ok);

        assert(!nft.isBlue(N + imageId));
        assert(!nft.blueTaken(imageId));
        assert(nft.blueMinted() == 0);
        assert(nft.blueTakenBits(imageId >> 8, 1)[0] == 0);
        assert(address(nft).balance == 0);

        (bool bought,) = _tryMintBlue(ALICE, imageId, STEP, STEP);
        assert(bought);
        assert(nft.ownerOf(imageId) == ALICE);
        assert(nft.ownerOf(N + imageId) == who);
        assert(nft.totalSupply() == 2);
    }

    /// @notice NFT-3: green stays open after the blue edition sells out. The
    ///         supply cap is the blue edition's alone.
    /// @dev Technique: T16 stateful, the blue counter set with vm.store.
    /// @dev Classification: DIRECT
    function test_check_green_stays_open_after_blue_sells_out(address who, uint256 imageId, uint256 sold) public {
        // Justification: a minter signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(who));
        // Justification: mintGreen reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:272)
        vm.assume(imageId < N);
        // Justification: the case under test, a blue edition at or past its supply; bounded so the
        // counter is still a count and not a wrapped word
        vm.assume(sold >= N && sold <= MAX_ETHER);
        _greenAfterSellout(who, imageId, sold);
    }

    /// @notice Fuzz wrapper for test_check_green_stays_open_after_blue_sells_out
    /// @dev See T17 in test-templates.md
    function test_fuzz_green_stays_open_after_blue_sells_out(address who, uint256 rawImage, uint256 rawSold) public {
        if (!_isAccount(who)) return;
        _greenAfterSellout(who, bound(rawImage, 0, N - 1), bound(rawSold, N, MAX_ETHER));
    }

    function _greenAfterSellout(address who, uint256 imageId, uint256 sold) private {
        _setSold(sold);

        (bool ok,) = _tryMintGreen(who, imageId);

        assert(ok);
        assert(nft.ownerOf(N + imageId) == who);
        assert(nft.blueMinted() == sold);
        assert(nft.greenMinted() == 1);
    }

    // ════════════════════════════════════════════════
    //  The refusals
    // ════════════════════════════════════════════════

    /// @notice PD-1: green costs only gas. A mint that sends ether is refused, the
    ///         sender keeps it, and none is left in the contract.
    /// @dev Technique: T3 guard, on a function that is not payable.
    /// @dev Classification: DIRECT
    function test_check_green_is_free_and_refuses_ether(address who, uint256 imageId, uint256 value) public {
        // Justification: a minter signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(who));
        // Justification: mintGreen reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:272)
        vm.assume(imageId < N);
        // Justification: the case under test is ether attached, up to more than exists
        vm.assume(value >= 1 && value <= MAX_ETHER);
        _refusesEther(who, imageId, value);
    }

    /// @notice Fuzz wrapper for test_check_green_is_free_and_refuses_ether
    /// @dev See T17 in test-templates.md
    function test_fuzz_green_is_free_and_refuses_ether(address who, uint256 rawImage, uint256 rawValue) public {
        if (!_isAccount(who)) return;
        _refusesEther(who, bound(rawImage, 0, N - 1), bound(rawValue, 1, MAX_ETHER));
    }

    function _refusesEther(address who, uint256 imageId, uint256 value) private {
        vm.deal(who, value);
        vm.prank(who);
        (bool ok,) = address(nft).call{value: value}(abi.encodeCall(nft.mintGreen, (imageId)));

        assert(!ok);
        assert(who.balance == value);
        assert(address(nft).balance == 0);
        assert(nft.greenMinted() == 0);
        assert(!nft.greenTaken(imageId, who));
    }

    /// @notice SM-1: before SALE_START no green mints, for any account or
    ///         character, and no claim is spent by trying.
    /// @dev Technique: T12 state gating, on block.timestamp.
    /// @dev Classification: DIRECT
    function test_check_green_refuses_before_the_sale_opens(uint256 t, address who, uint256 imageId) public {
        // Justification: the branch under test, block.timestamp < SALE_START (GlamToon.sol:271)
        vm.assume(t < START);
        // Justification: a minter signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(who));
        _greenBeforeOpen(t, who, imageId);
    }

    /// @notice Fuzz wrapper for test_check_green_refuses_before_the_sale_opens
    /// @dev See T17 in test-templates.md
    function test_fuzz_green_refuses_before_the_sale_opens(uint256 rawT, address who, uint256 imageId) public {
        if (!_isAccount(who)) return;
        _greenBeforeOpen(bound(rawT, 0, START - 1), who, imageId);
    }

    function _greenBeforeOpen(uint256 t, address who, uint256 imageId) private {
        vm.warp(t);

        (bool ok, bytes memory answer) = _tryMintGreen(who, imageId);

        assert(!ok);
        assert(_is(answer, GlamToon.NotStarted.selector));
        assert(nft.greenMinted() == 0);
        assert(!nft.greenTaken(imageId, who));
    }

    /// @notice SM-4: asking for a character that does not exist is refused with
    ///         InvalidImageId and changes nothing. In particular it does not
    ///         spend the account's green of a character that does exist.
    /// @dev Technique: T3 guard.
    /// @dev Classification: DIRECT
    function test_check_green_refuses_an_unknown_character(address who, uint256 imageId) public {
        // Justification: a minter signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(who));
        // Justification: the branch under test, imageId >= IMAGE_COUNT (GlamToon.sol:272)
        vm.assume(imageId >= N);
        _greenUnknown(who, imageId);
    }

    /// @notice Fuzz wrapper for test_check_green_refuses_an_unknown_character
    /// @dev See T17 in test-templates.md
    function test_fuzz_green_refuses_an_unknown_character(address who, uint256 rawImage) public {
        if (!_isAccount(who)) return;
        _greenUnknown(who, bound(rawImage, N, type(uint256).max));
    }

    function _greenUnknown(address who, uint256 imageId) private {
        (bool real,) = _tryMintGreen(who, 7412);
        assert(real);

        (bool ok, bytes memory answer) = _tryMintGreen(who, imageId);

        assert(!ok);
        assert(_is(answer, GlamToon.InvalidImageId.selector));
        assert(nft.greenMinted() == 1);
        assert(nft.greenCount(imageId) == 0);
        assert(!nft.greenTaken(imageId, who));

        // the real one it did take is intact
        assert(nft.greenCount(7412) == 1);
        assert(nft.ownerOf(N + 7412) == who);
    }
}
