// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";
import {MintReenterer, RefundReenterer, RejectsETH, NotAReceiver} from "../mocks/Attackers.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "openzeppelin/utils/ReentrancyGuardTransient.sol";

contract MintingTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                              GENESIS SALE
    //////////////////////////////////////////////////////////////*/

    function test_genesisTokenIdIsTheImageId() public {
        _buy(alice, 7412);
        assertEq(nft.ownerOf(7412), alice, "blue 7412 is token 7412");
        assertEq(nft.imageIdOf(7412), 7412, "image");
        assertEq(nft.generationOf(7412), 0, "generation zero");
        assertTrue(nft.isBlue(7412), "genesis");
    }

    function test_buyingRecordsTheSaleAndTheBitmap() public {
        assertFalse(nft.blueTaken(7412), "not yet sold");
        _buy(alice, 7412);
        assertTrue(nft.blueTaken(7412), "now sold");
        assertEq(nft.blueMinted(), 1, "counted");
        assertEq(nft.totalSupply(), 1, "supply");

        uint256[] memory words = nft.blueTakenBits(7412 >> 8, 1);
        assertEq(words[0] >> (7412 & 0xff) & 1, 1, "bit set in the bitmap");
    }

    function test_beforeTheSaleOpensNothingMints() public {
        vm.warp(SALE_START - 1);
        vm.prank(alice);
        vm.expectRevert(GlamToon.NotStarted.selector);
        nft.mintBlue{value: 1 ether}(1, 1 ether);

        vm.prank(alice);
        vm.expectRevert(GlamToon.NotStarted.selector);
        nft.mintGreen(1);
    }

    function test_imageIdOutOfRangeReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.mintBlue{value: 1 ether}(10_000, 1 ether);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.mintBlue{value: 1 ether}(type(uint256).max, 1 ether);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.mintGreen(10_000);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.mintGreen(type(uint256).max);
        vm.stopPrank();
    }

    function test_sameCharacterCannotBeSoldTwice() public {
        _buy(alice, 42);
        vm.prank(bob);
        vm.expectRevert(GlamToon.BlueAlreadyTaken.selector);
        nft.mintBlue{value: 1 ether}(42, 1 ether);
    }

    function test_underpayingReverts() public {
        vm.prank(alice);
        vm.expectRevert(GlamToon.InsufficientPayment.selector);
        nft.mintBlue{value: 0.01 ether - 1}(1, 1 ether);
    }

    function test_ceilingBelowThePriceReverts() public {
        vm.prank(alice);
        vm.expectRevert(GlamToon.PriceTooHigh.selector);
        nft.mintBlue{value: 1 ether}(1, 0.009 ether);
    }

    /// The reason the ceiling exists. A buyer sends a buffer expecting to pay the
    /// tier they saw; the tier moves under them; without a ceiling they would be
    /// charged the higher price out of the buffer and told nothing.
    function test_ceilingStopsASilentOvercharge() public {
        _sell(2500);
        assertEq(nft.currentPrice(), 0.02 ether, "tier moved");

        vm.prank(bob);
        vm.expectRevert(GlamToon.PriceTooHigh.selector);
        nft.mintBlue{value: 0.5 ether}(5000, 0.01 ether);

        assertEq(nft.blueMinted(), 2500, "nothing minted");
    }

    function test_overpaymentIsRefundedToThePayer() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        nft.mintBlue{value: 5 ether}(1, 1 ether);
        assertEq(alice.balance, before - 0.01 ether, "charged only the price");
        assertEq(address(nft).balance, 0.01 ether, "contract kept only the price");
    }

    function test_exactPaymentSendsNoRefund() public {
        vm.prank(alice);
        nft.mintBlue{value: 0.01 ether}(1, 0.01 ether);
        assertEq(address(nft).balance, 0.01 ether, "kept");
    }

    function test_aBuyerWhoCannotTakeARefundRevertsCleanly() public {
        RejectsETH r = new RejectsETH(nft);
        vm.deal(address(r), 1 ether);
        vm.expectRevert(bytes("no thanks"));
        r.mint(1, 1 ether, 1 ether);
        assertEq(nft.blueMinted(), 0, "nothing minted");
    }

    function test_aBuyerWhoCannotTakeARefundCanStillPayExactly() public {
        RejectsETH r = new RejectsETH(nft);
        vm.deal(address(r), 1 ether);
        r.mint(1, 0.01 ether, 0.01 ether);
        assertEq(nft.ownerOf(1), address(r), "no refund, no problem");
    }

    /*//////////////////////////////////////////////////////////////
                              GREEN EDITION
    //////////////////////////////////////////////////////////////*/

    function test_greenGenerationsRunInSequence() public {
        assertEq(nft.greenCount(7412), 0, "none yet");

        uint256 first = _green(alice, 7412);
        assertEq(first, 17_412, "gen 1 token id");
        assertEq(nft.greenCount(7412), 1, "counted");

        uint256 second = _green(bob, 7412);
        assertEq(second, 27_412, "gen 2 token id");

        // a third wallet, because no address may take two of one character
        uint256 third = _green(carol, 7412);
        assertEq(third, 37_412, "gen 3 token id");
        assertEq(nft.greenCount(7412), 3, "three generations");

        assertEq(nft.generationOf(first), 1, "decodes");
        assertEq(nft.generationOf(third), 3, "decodes");
        assertEq(nft.imageIdOf(third), 7412, "same character throughout");
        assertFalse(nft.isBlue(first), "green is not genesis");
    }

    /*//////////////////////////////////////////////////////////////
                        ONE GREEN PER CHARACTER
    //////////////////////////////////////////////////////////////*/

    function test_oneGreenPerCharacterPerWallet() public {
        _green(alice, 12);
        assertTrue(nft.greenTaken(12, alice), "recorded");

        vm.prank(alice);
        vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
        nft.mintGreen(12);
    }

    /// The exact question: alice has generation 3 of character 12. She cannot
    /// take generation 4 of it, whatever number the next generation happens to be.
    function test_aSecondGenerationOfTheSameCharacterIsRefused() public {
        _green(bob, 12);
        _green(carol, 12);
        _green(alice, 12);
        assertEq(nft.greenCount(12), 3, "alice holds generation 3");

        vm.prank(alice);
        vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
        nft.mintGreen(12);

        // and somebody who has not had one still can, so the character is not
        // frozen by one person having taken theirs
        _green(bob, 13);
        uint256 fourth = _green(vm.addr(0xD0), 12);
        assertEq(nft.generationOf(fourth), 4, "generation four went to someone else");
    }

    /// Sending it away does not free the slot. This is the whole reason the flag
    /// records the mint rather than the holding.
    function test_sendingItAwayDoesNotFreeTheSlot() public {
        uint256 token = _green(alice, 12);

        vm.prank(alice);
        nft.transferFrom(alice, bob, token);
        assertEq(nft.ownerOf(token), bob, "moved");
        assertEq(nft.balanceOf(alice), 0, "alice holds nothing");

        vm.prank(alice);
        vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
        nft.mintGreen(12);
    }

    function test_oneGreenEachOfDifferentCharacters() public {
        _green(alice, 12);
        _green(alice, 13);
        _green(alice, 9999);
        assertEq(nft.balanceOf(alice), 3, "one of each is fine");
    }

    /// The blue edition is paid and untouched by any of this.
    function test_theGuardNeverBlocksTheGenesis() public {
        _green(alice, 12);
        _buy(alice, 12);
        assertEq(nft.ownerOf(12), alice, "bought the blue after taking a green");

        _buy(bob, 13);
        _green(bob, 13);
        assertEq(nft.greenCount(13), 1, "and the other way round");

        // and a buyer may hold as many blues as they like
        _buy(alice, 20);
        _buy(alice, 21);
        // one green of 12, plus blues 12, 20 and 21
        assertEq(nft.balanceOf(alice), 4, "blues are not rationed");
    }

    function test_greenNeedsNoGenesisToExist() public {
        // Nothing requires the blue of a character to have sold first.
        uint256 id = _green(alice, 9999);
        assertEq(nft.ownerOf(id), alice, "minted");
        assertFalse(nft.blueTaken(9999), "blue still unsold");
    }

    function test_greenIsFree() public {
        uint256 before = alice.balance;
        _green(alice, 1);
        assertEq(alice.balance, before, "no ether moved");
        assertEq(address(nft).balance, 0, "contract took nothing");
    }

    function test_greenCountsTowardSupply() public {
        _buy(alice, 1);
        _green(bob, 1);
        _green(bob, 2);
        assertEq(nft.totalSupply(), 3, "one blue and two green");
        assertEq(nft.blueMinted(), 1, "blues");
        assertEq(nft.greenMinted(), 2, "greens");
    }

    function test_greenGenerationsAreIndependentPerCharacter() public {
        _green(alice, 1);
        _green(bob, 1);
        _green(alice, 2);
        assertEq(nft.greenCount(1), 2, "character one");
        assertEq(nft.greenCount(2), 1, "character two");
        assertEq(nft.greenCount(3), 0, "character three untouched");
    }

    function test_mintingToAContractWithNoHookReverts() public {
        NotAReceiver n = new NotAReceiver(nft);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(n)));
        n.mint(1);
    }

    /*//////////////////////////////////////////////////////////////
                              REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function test_reentryThroughTheReceiverHookIsBlocked() public {
        MintReenterer a = new MintReenterer(nft);
        vm.deal(address(a), 1 ether);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        a.attackBlue(1, 0.01 ether, 2);
        assertEq(nft.blueMinted(), 0, "nothing minted");
    }

    /// The green door has to hold the lock itself, not only check it, or a
    /// green hook could walk into a second mint while the first is in flight.
    function test_reentryThroughTheGreenHookIsBlocked() public {
        MintReenterer a = new MintReenterer(nft);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        a.attackGreen(1, 2);
        assertEq(nft.greenCount(1), 0, "no generation taken");
        assertEq(nft.totalSupply(), 0, "nothing minted");
    }

    function test_reentryThroughTheRefundIsBlocked() public {
        RefundReenterer a = new RefundReenterer(nft);
        vm.deal(address(a), 1 ether);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        a.attack(1, 1 ether, 1 ether);
        assertEq(nft.blueMinted(), 0, "nothing minted");
    }

    /*//////////////////////////////////////////////////////////////
                                  MONEY
    //////////////////////////////////////////////////////////////*/

    function test_withdrawGoesToTheTreasuryAndAnyoneMayCallIt() public {
        _buy(alice, 1);
        _buy(bob, 2);
        uint256 held = address(nft).balance;
        assertEq(held, 0.02 ether, "two sales");

        vm.prank(carol); // no relationship to the collection at all
        nft.withdraw();

        assertEq(address(nft).balance, 0, "swept");
        assertEq(address(treasury).balance, held, "treasury has it");
    }

    function test_withdrawWithNothingToSendReverts() public {
        vm.expectRevert(GlamToon.NothingToWithdraw.selector);
        nft.withdraw();
    }

    function test_withdrawRecoversForceFedEther() public {
        // There is no receive(), but ether can still be pushed in. Sending the
        // balance rather than a running total is what makes it recoverable.
        vm.deal(address(nft), 3 ether);
        nft.withdraw();
        assertEq(address(treasury).balance, 3 ether, "recovered");
    }

    function test_bitmapRangeIsBounded() public {
        // Forty words cover the whole collection. Asking for more, or starting
        // past the end, must not read whatever is next in storage.
        assertEq(nft.blueBitmapWords(), 40, "forty words");
        uint256[] memory all = nft.blueTakenBits(0, 40);
        assertEq(all.length, 40, "the whole bitmap in one call");

        vm.expectRevert(GlamToon.InvalidWordRange.selector);
        nft.blueTakenBits(0, 41);
        vm.expectRevert(GlamToon.InvalidWordRange.selector);
        nft.blueTakenBits(40, 1);
        vm.expectRevert(GlamToon.InvalidWordRange.selector);
        nft.blueTakenBits(type(uint256).max, 1);
    }

    function test_generationsBatchMatchesGenerations() public {
        _green(alice, 7);
        _green(bob, 7);
        _green(alice, 9);

        uint256[] memory ids = new uint256[](3);
        ids[0] = 7;
        ids[1] = 9;
        ids[2] = 11;
        uint256[] memory counts = nft.greenCountBatch(ids);

        assertEq(counts[0], 2, "two generations");
        assertEq(counts[1], 1, "one generation");
        assertEq(counts[2], 0, "untouched");
        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(counts[i], nft.greenCount(ids[i]), "batch drifted from single reads");
        }
    }

    function test_optimizedUriIsTheLighterCopyOfTheSameCharacter() public view {
        assertEq(
            nft.optimizedURI(7412, true),
            string.concat("ipfs://", nft.ipfsRoot(), "/blue/7412.webp"),
            "genesis lighter copy"
        );
        assertEq(
            nft.optimizedURI(7412, false),
            string.concat("ipfs://", nft.ipfsRoot(), "/green/7412.webp"),
            "green lighter copy"
        );
    }

    function test_optimizedUriRejectsCharactersOutOfRange() public {
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.optimizedURI(10_000, true);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.optimizedURI(type(uint256).max, true);
    }

    /// The payee is an immutable, so it sits in the deployed code rather than
    /// in a storage slot that a setter could reach. A payee kept in storage
    /// would answer PAYOUT() with the same treasury, and only the code tells the
    /// two apart.
    function test_thePayeeLivesInTheCodeNotInStorage() public view {
        assertEq(nft.PAYOUT(), address(treasury), "fixed at construction");

        bytes memory code = address(nft).code;
        bytes20 payee = bytes20(address(treasury));
        bool found;
        for (uint256 i = 0; i + 20 <= code.length && !found; ++i) {
            uint256 j;
            while (j < 20 && code[i + j] == payee[j]) {
                ++j;
            }
            found = j == 20;
        }
        assertTrue(found, "the treasury address is written into the code");
    }
}
