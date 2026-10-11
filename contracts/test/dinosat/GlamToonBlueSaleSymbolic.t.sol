// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, a blue sale that goes through
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonBlueSaleSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonBlueSaleSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev What mintBlue takes, what it gives back and what it records, for every
///      character, every point of the sale and every amount. The refusals are
///      in GlamToonBlueGuardsSymbolicTest.
contract GlamToonBlueSaleSymbolicTest is DinoSatBase {
    // ════════════════════════════════════════════════
    //  PD-1: the buyer is charged the price and nothing else
    // ════════════════════════════════════════════════

    /// @notice PD-1: a buyer is charged the price of the tier the sale is in
    ///         and gets back everything above it, for every amount, every
    ///         ceiling that allows the price, every character and every point
    ///         of the sale. Nothing reaches the treasury until a withdraw.
    /// @dev Technique: T14 conservation, the sale made low level and asserted.
    /// @dev Classification: DIRECT
    function test_check_buyer_pays_exactly_the_price(uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice)
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
        _paysExactly(imageId, sold, sent, maxPrice);
    }

    /// @notice Fuzz wrapper for test_check_buyer_pays_exactly_the_price
    /// @dev See T17 in test-templates.md
    function test_fuzz_buyer_pays_exactly_the_price(uint256 rawImage, uint256 rawSold, uint256 rawSent, uint256 rawMax)
        public
    {
        uint256 sold = bound(rawSold, 0, N - 1);
        uint256 price = _schedule(sold);
        _paysExactly(
            bound(rawImage, 0, N - 1), sold, bound(rawSent, price, MAX_ETHER), bound(rawMax, price, type(uint256).max)
        );
    }

    function _paysExactly(uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice) private {
        _setSold(sold);
        uint256 price = _schedule(sold);
        uint256 held = address(nft).balance;

        (bool ok,) = _tryMintBlue(ALICE, imageId, sent, maxPrice);

        assert(ok);
        assert(address(nft).balance == held + price);
        assert(ALICE.balance == sent - price);
        assert(address(treasury).balance == 0);
    }

    /// @notice PD-1: paying the exact price leaves the buyer with nothing sent
    ///         back and nothing owed.
    /// @dev Technique: T14 conservation.
    /// @dev Classification: DIRECT
    function test_check_exact_payment_leaves_no_change(uint256 imageId, uint256 sold) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: _mintBlue reverts with SoldOut unless blueMinted < BLUE_SUPPLY (GlamToon.sol:246)
        vm.assume(sold < N);
        _exactPayment(imageId, sold);
    }

    /// @notice Fuzz wrapper for test_check_exact_payment_leaves_no_change
    /// @dev See T17 in test-templates.md
    function test_fuzz_exact_payment_leaves_no_change(uint256 rawImage, uint256 rawSold) public {
        _exactPayment(bound(rawImage, 0, N - 1), bound(rawSold, 0, N - 1));
    }

    function _exactPayment(uint256 imageId, uint256 sold) private {
        _setSold(sold);
        uint256 price = _schedule(sold);

        (bool ok,) = _tryMintBlue(ALICE, imageId, price, price);

        assert(ok);
        assert(ALICE.balance == 0);
        assert(address(nft).balance == price);
    }

    // ════════════════════════════════════════════════
    //  TOK-1 / CC-1: what a sale records
    // ════════════════════════════════════════════════

    /// @notice TOK-1/CC-1: a sale gives the buyer the token whose id is the
    ///         character's number, adds one to the supply, and marks the
    ///         character sold everywhere the contract reports it.
    /// @dev Technique: T16 stateful.
    /// @dev Classification: DIRECT
    function test_check_sale_records_owner_supply_and_bit(uint256 imageId, uint256 sold) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: _mintBlue reverts with SoldOut unless blueMinted < BLUE_SUPPLY (GlamToon.sol:246)
        vm.assume(sold < N);
        _saleRecords(imageId, sold);
    }

    /// @notice Fuzz wrapper for test_check_sale_records_owner_supply_and_bit
    /// @dev See T17 in test-templates.md
    function test_fuzz_sale_records_owner_supply_and_bit(uint256 rawImage, uint256 rawSold) public {
        _saleRecords(bound(rawImage, 0, N - 1), bound(rawSold, 0, N - 1));
    }

    function _saleRecords(uint256 imageId, uint256 sold) private {
        _setSold(sold);
        uint256 price = _schedule(sold);

        (bool ok,) = _tryMintBlue(ALICE, imageId, price, price);

        assert(ok);
        assert(nft.ownerOf(imageId) == ALICE);
        assert(nft.balanceOf(ALICE) == 1);
        assert(nft.blueMinted() == sold + 1);
        assert(nft.totalSupply() == sold + 1);
        assert(nft.blueTaken(imageId));
        assert(nft.isBlue(imageId));
        assert(nft.blueTakenBits(imageId >> 8, 1)[0] == uint256(1) << (imageId & 0xff));
    }

    /// @notice CC-1: a sale sets its own character's bit and no other. Any
    ///         other of the forty words stays empty.
    /// @dev Technique: T16 stateful.
    /// @dev Classification: DIRECT
    function test_check_sale_sets_only_its_own_bit(uint256 imageId, uint256 otherWord) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: blueTakenBits refuses a word past BITMAP_WORDS = 40 (GlamToon.sol:643)
        vm.assume(otherWord < WORDS);
        // Justification: the property is about every word but the character's own
        vm.assume(otherWord != imageId >> 8);
        _onlyOwnBit(imageId, otherWord);
    }

    /// @notice Fuzz wrapper for test_check_sale_sets_only_its_own_bit
    /// @dev See T17 in test-templates.md
    function test_fuzz_sale_sets_only_its_own_bit(uint256 rawImage, uint256 rawWord) public {
        uint256 imageId = bound(rawImage, 0, N - 1);
        uint256 otherWord = bound(rawWord, 0, WORDS - 1);
        if (otherWord == imageId >> 8) return;
        _onlyOwnBit(imageId, otherWord);
    }

    function _onlyOwnBit(uint256 imageId, uint256 otherWord) private {
        (bool ok,) = _tryMintBlue(ALICE, imageId, STEP, STEP);

        assert(ok);
        assert(nft.blueTakenBits(imageId >> 8, 1)[0] == uint256(1) << (imageId & 0xff));
        assert(nft.blueTakenBits(otherWord, 1)[0] == 0);
    }

    /// @notice CC-1: a blue sale leaves the green edition exactly as it was.
    /// @dev Technique: T16 stateful.
    /// @dev Classification: DIRECT
    function test_check_sale_leaves_green_alone(uint256 imageId) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        _leavesGreenAlone(imageId);
    }

    /// @notice Fuzz wrapper for test_check_sale_leaves_green_alone
    /// @dev See T17 in test-templates.md
    function test_fuzz_sale_leaves_green_alone(uint256 rawImage) public {
        _leavesGreenAlone(bound(rawImage, 0, N - 1));
    }

    function _leavesGreenAlone(uint256 imageId) private {
        (bool ok,) = _tryMintBlue(ALICE, imageId, STEP, STEP);

        assert(ok);
        assert(nft.greenMinted() == 0);
        assert(nft.greenCount(imageId) == 0);
        assert(!nft.greenTaken(imageId, ALICE));

        // the first green of the character does not exist yet
        (bool exists,) = address(nft).staticcall(abi.encodeCall(nft.ownerOf, (N + imageId)));
        assert(!exists);
    }

    // ════════════════════════════════════════════════
    //  AC-2: the sale is open to anybody
    // ════════════════════════════════════════════════

    /// @notice AC-2: there is no allowlist. Any account that pays the price
    ///         gets the character it asked for.
    /// @dev Technique: T16 stateful, over every caller.
    /// @dev Classification: DIRECT
    function test_check_any_account_can_buy(address buyer, uint256 imageId) public {
        // Justification: a buyer signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(buyer));
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        _anyoneBuys(buyer, imageId);
    }

    /// @notice Fuzz wrapper for test_check_any_account_can_buy
    /// @dev See T17 in test-templates.md
    function test_fuzz_any_account_can_buy(address buyer, uint256 rawImage) public {
        if (!_isAccount(buyer)) return;
        _anyoneBuys(buyer, bound(rawImage, 0, N - 1));
    }

    function _anyoneBuys(address buyer, uint256 imageId) private {
        (bool ok,) = _tryMintBlue(buyer, imageId, STEP, STEP);

        assert(ok);
        assert(nft.ownerOf(imageId) == buyer);
        assert(nft.balanceOf(buyer) == 1);
        assert(buyer.balance == 0);
    }

    // ════════════════════════════════════════════════
    //  SM-1: one character's sale does not block another's
    // ════════════════════════════════════════════════

    /// @notice SM-1: two different characters sell to two buyers, in either
    ///         order of ids, and each ends up with its own.
    /// @dev Technique: T16 stateful.
    /// @dev Classification: DIRECT
    function test_check_two_characters_sell_independently(uint256 imageA, uint256 imageB) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageA < N && imageB < N);
        // Justification: the same character twice is the BlueAlreadyTaken refusal, proved elsewhere
        vm.assume(imageA != imageB);
        _twoSell(imageA, imageB);
    }

    /// @notice Fuzz wrapper for test_check_two_characters_sell_independently
    /// @dev See T17 in test-templates.md
    function test_fuzz_two_characters_sell_independently(uint256 rawA, uint256 rawB) public {
        uint256 imageA = bound(rawA, 0, N - 1);
        uint256 imageB = bound(rawB, 0, N - 1);
        if (imageA == imageB) return;
        _twoSell(imageA, imageB);
    }

    function _twoSell(uint256 imageA, uint256 imageB) private {
        (bool first,) = _tryMintBlue(ALICE, imageA, STEP, STEP);
        (bool second,) = _tryMintBlue(BOB, imageB, STEP, STEP);

        assert(first);
        assert(second);
        assert(nft.ownerOf(imageA) == ALICE);
        assert(nft.ownerOf(imageB) == BOB);
        assert(nft.blueMinted() == 2);
        assert(address(nft).balance == 2 * STEP);
    }
}
