// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "openzeppelin/utils/ReentrancyGuardTransient.sol";

/// The paid edition at its edges. Minting.t.sol walks the happy path and
/// Pricing.t.sol checks the rule in the abstract; this file pins the places
/// where one wei, one second or one sale decides the answer, and checks that a
/// refused sale stops before it writes anything. The money is immutable once
/// this ships, so every branch that moves ether is asserted by balance rather
/// than by the contract's own accounting.
contract BlueSaleTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                             TIER BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    /// Pricing.t.sol crosses the first boundary only, and checks the quote
    /// rather than the charge. This walks four real boundaries with a buyer who
    /// overpays every time, so the number asserted is what left their wallet.
    /// Sale 2500 is still the opening tier; sale 2501 is the first to pay more.
    function test_eachTierBoundaryChargesMoreFromTheNextSaleOn() public {
        uint256[6] memory sale = [uint256(2500), 2501, 5000, 5001, 7500, 7501];
        uint256[6] memory want = [uint256(0.01 ether), 0.02 ether, 0.02 ether, 0.03 ether, 0.03 ether, 0.04 ether];

        uint256 k;
        for (uint256 id = 0; id < 7501; ++id) {
            if (k < sale.length && id + 1 == sale[k]) {
                uint256 before = bob.balance;
                vm.prank(bob);
                nft.mintBlue{value: 0.5 ether}(id, type(uint256).max);
                assertEq(before - bob.balance, want[k], "the buyer paid the tier their sale falls in");
                ++k;
            } else {
                _buy(alice, id);
            }
        }

        assertEq(k, sale.length, "every boundary sale was made by the measured buyer");
        assertEq(nft.blueMinted(), 7501, "counted");
        assertEq(nft.totalSupply(), 7501, "supply");
        // 2500 at each of the first three tiers, then one at the last
        assertEq(address(nft).balance, 150.04 ether, "what the first 7501 sales take");
        assertEq(nft.currentPrice(), 0.04 ether, "the last tier, with 2499 sales left in it");
    }

    /// The boundary is on the count of sales, not on the character bought. A
    /// sale of any id moves the price the same way.
    function test_theBoundaryFollowsTheCountNotTheCharacter() public {
        for (uint256 i = 0; i < 2499; ++i) {
            _buy(alice, 9999 - i);
        }
        assertEq(nft.currentPrice(), 0.01 ether, "2499 sold, still the opening tier");

        _buy(alice, 0);
        assertEq(nft.currentPrice(), 0.02 ether, "the two thousand five hundredth sale stepped it up");
    }

    /*//////////////////////////////////////////////////////////////
                                THE CEILING
    //////////////////////////////////////////////////////////////*/

    /// The comparison is price > maxPrice, so a ceiling equal to the price must
    /// go through. An off by one here would turn every exact quote into a
    /// revert.
    function test_aCeilingEqualToThePriceIsEnough() public {
        uint256 price = _price();

        vm.prank(alice);
        nft.mintBlue{value: price}(1, price);

        assertEq(nft.ownerOf(1), alice, "sold at exactly the quoted ceiling");
    }

    function test_aCeilingOneWeiBelowThePriceIsRefused() public {
        uint256 price = _price();

        _watch();
        vm.prank(alice);
        vm.expectRevert(GlamToon.PriceTooHigh.selector);
        nft.mintBlue{value: price}(1, price - 1);
        _assertStoppedBeforeWriting("a ceiling one wei short");
    }

    function test_aCeilingOfZeroIsRefused() public {
        uint256 price = _price();

        vm.prank(alice);
        vm.expectRevert(GlamToon.PriceTooHigh.selector);
        nft.mintBlue{value: price}(1, 0);
    }

    /// A ceiling nobody could hit is not a licence to charge more than the
    /// schedule says.
    function test_aCeilingFarAboveThePriceStillChargesOnlyThePrice() public {
        uint256 before = alice.balance;

        vm.prank(alice);
        nft.mintBlue{value: 9 ether}(1, type(uint256).max);

        assertEq(before - alice.balance, 0.01 ether, "charged the schedule, not the ceiling");
        assertEq(address(nft).balance, 0.01 ether, "and kept only that");
    }

    /// The ceiling caps what the buyer is charged, not what they are allowed to
    /// send. A wallet that pads its value to cover a tier move must still get
    /// through with the ceiling it actually meant.
    function test_theCeilingCapsTheChargeNotTheAmountSent() public {
        uint256 price = _price();
        uint256 before = alice.balance;

        vm.prank(alice);
        nft.mintBlue{value: 3 ether}(2, price);

        assertEq(before - alice.balance, price, "charged the price");
        assertEq(nft.ownerOf(2), alice, "and sent more than the ceiling without being refused");
    }

    /// The point of the ceiling. A buyer quotes 0.01, the tier moves while their
    /// transaction sits in the mempool, and the two outcomes are: refused at the
    /// old ceiling, or charged the new price if they said they would accept it.
    /// The second half is the one nothing asserted.
    function test_theBuyerPaysThePriceWhenTheirCallLandsNotWhenTheyQuoted() public {
        _sell(2499);
        uint256 quoted = _price();
        assertEq(quoted, 0.01 ether, "quoted in the opening tier");

        _buy(carol, 9998);
        assertEq(nft.currentPrice(), 0.02 ether, "the tier moved under the quote");

        vm.prank(alice);
        vm.expectRevert(GlamToon.PriceTooHigh.selector);
        nft.mintBlue{value: 1 ether}(9000, quoted);

        uint256 before = alice.balance;
        vm.prank(alice);
        nft.mintBlue{value: 1 ether}(9000, 0.02 ether);
        assertEq(before - alice.balance, 0.02 ether, "paid the price at the moment it landed");
    }

    /*//////////////////////////////////////////////////////////////
                            PAYMENT AND CHANGE
    //////////////////////////////////////////////////////////////*/

    /// Exact payment must send nothing back and leave nothing over. The two
    /// measured sales straddle a tier boundary, so a per sale rounding error
    /// would show up here as dust.
    function test_exactPaymentLeavesNoRefundAndNoDust() public {
        _sell(2499);

        uint256 first = _price();
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        nft.mintBlue{value: first}(8000, first);
        assertEq(aliceBefore - alice.balance, first, "alice paid exactly the price");

        uint256 second = _price();
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        nft.mintBlue{value: second}(8001, second);
        assertEq(bobBefore - bob.balance, second, "bob paid exactly the price");

        assertEq(first, 0.01 ether, "the last sale of the opening tier");
        assertEq(second, 0.02 ether, "the first of the next");
        // two and a half thousand at the opening price, then one at the next
        assertEq(address(nft).balance, 25.02 ether, "every wei taken is still held");
    }

    function test_overpayingByOneWeiRefundsOneWei() public {
        uint256 price = _price();
        uint256 before = alice.balance;

        vm.prank(alice);
        nft.mintBlue{value: price + 1}(3, price + 1);

        assertEq(before - alice.balance, price, "the extra wei came back");
        assertEq(address(nft).balance, price, "and was never kept");
    }

    /// The refund is msg.value minus the price, not whatever the contract
    /// happens to hold. A refund computed from the balance would hand this
    /// buyer the earlier sale's money.
    function test_aRefundNeverDipsIntoEarlierSales() public {
        _buy(alice, 1);
        assertEq(address(nft).balance, 0.01 ether, "one sale banked");

        uint256 before = bob.balance;
        vm.prank(bob);
        nft.mintBlue{value: 100 ether}(2, 1 ether);

        assertEq(before - bob.balance, 0.01 ether, "bob paid only his price");
        assertEq(address(nft).balance, 0.02 ether, "both sales still banked");
    }

    /// Buying through the gift door for yourself is still a gift as far as the
    /// change is concerned: it goes to msg.sender, who here is also the
    /// recipient, and the sum has to come out the same.
    function test_giftingToYourselfChargesTheSameAndRefundsTheSame() public {
        uint256 price = _price();
        uint256 before = alice.balance;

        vm.prank(alice);
        nft.mintBlueFor{value: price + 4 ether}(alice, 33, price + 4 ether);

        assertEq(before - alice.balance, price, "charged once, refunded the rest");
        assertEq(nft.ownerOf(33), alice, "and holds it");
        assertEq(address(nft).balance, price, "the contract kept only the price");
    }

    /// A generous ceiling says what the buyer will accept, not what they sent.
    function test_underpayingIsRefusedHoweverGenerousTheCeiling() public {
        uint256 price = _price();

        _watch();
        vm.prank(alice);
        vm.expectRevert(GlamToon.InsufficientPayment.selector);
        nft.mintBlue{value: price - 1}(1, type(uint256).max);
        _assertStoppedBeforeWriting("one wei short of the opening price");

        _watch();
        vm.prank(alice);
        vm.expectRevert(GlamToon.InsufficientPayment.selector);
        nft.mintBlue{value: 0}(1, type(uint256).max);
        _assertStoppedBeforeWriting("nothing sent at all");
    }

    /// Same wei, later tier. A buyer who sends exactly the opening price after
    /// the tier moved is now underpaying, and must not get in.
    function test_yesterdaysExactPriceIsTodaysUnderpayment() public {
        _sell(2500);
        assertEq(nft.currentPrice(), 0.02 ether, "tier two");

        vm.prank(bob);
        vm.expectRevert(GlamToon.InsufficientPayment.selector);
        nft.mintBlue{value: 0.01 ether}(9000, type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(GlamToon.InsufficientPayment.selector);
        nft.mintBlue{value: 0.02 ether - 1}(9000, type(uint256).max);

        assertEq(nft.blueMinted(), 2500, "neither attempt counted");
    }

    /// Any character, any overpayment: the charge is the schedule and the rest
    /// comes straight back.
    function testFuzz_theBuyerIsChargedThePriceAndGetsTheRestBack(uint256 seed) public {
        uint256 imageId = bound(seed, 0, BLUE_SUPPLY - 1);
        uint256 extra = bound(uint256(keccak256(abi.encode(seed))), 0, 500 ether);
        uint256 price = _price();
        uint256 before = alice.balance;

        vm.prank(alice);
        nft.mintBlue{value: price + extra}(imageId, price + extra);

        assertEq(before - alice.balance, price, "charged the price and nothing more");
        assertEq(address(nft).balance, price, "the contract kept only the price");
        assertEq(nft.ownerOf(imageId), alice, "and the token arrived");
    }

    /*//////////////////////////////////////////////////////////////
                             WHICH CHARACTER
    //////////////////////////////////////////////////////////////*/

    /// Both ends of the range, and the bitmap word each one lands in. 9999 is
    /// bit 15 of word 39, the only word that is not full at sell out.
    function test_theFirstAndLastCharactersAreBothForSale() public {
        _buy(alice, 0);
        _buy(bob, 9999);

        assertEq(nft.ownerOf(0), alice, "character zero");
        assertEq(nft.ownerOf(9999), bob, "character 9999");
        assertTrue(nft.blueTaken(0), "flagged");
        assertTrue(nft.blueTaken(9999), "flagged");

        uint256[] memory all = nft.blueTakenBits(0, 40);
        assertEq(all[0], 1, "bit zero of word zero");
        assertEq(all[39], uint256(1) << 15, "bit fifteen of word thirty nine");
        for (uint256 w = 1; w < 39; ++w) {
            assertEq(all[w], 0, "no other word was touched");
        }
    }

    function test_pastTheLastCharacterIsRefusedThroughEitherDoor() public {
        uint256 price = _price();

        vm.startPrank(alice);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.mintBlue{value: price}(10_000, price);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.mintBlue{value: price}(type(uint256).max, price);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.mintBlueFor{value: price}(bob, 10_000, price);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.mintBlueFor{value: price}(bob, type(uint256).max, price);
        vm.stopPrank();

        assertEq(nft.blueMinted(), 0, "nothing counted");
        assertEq(address(nft).balance, 0, "and nothing kept");
    }

    /// A character is sold once whichever door sold it and whichever door tries
    /// next. Buying and gifting share one counter and one ownership check.
    function test_aCharacterSoldByEitherDoorIsRefusedByBoth() public {
        _buy(alice, 100);
        uint256 price = _price();

        vm.prank(bob);
        vm.expectRevert(GlamToon.BlueAlreadyTaken.selector);
        nft.mintBlue{value: price}(100, price);

        vm.prank(bob);
        vm.expectRevert(GlamToon.BlueAlreadyTaken.selector);
        nft.mintBlueFor{value: price}(carol, 100, price);

        price = _price();
        vm.prank(carol);
        nft.mintBlueFor{value: price}(bob, 200, price);

        price = _price();
        vm.prank(alice);
        vm.expectRevert(GlamToon.BlueAlreadyTaken.selector);
        nft.mintBlue{value: price}(200, price);

        vm.prank(alice);
        vm.expectRevert(GlamToon.BlueAlreadyTaken.selector);
        nft.mintBlueFor{value: price}(alice, 200, price);

        assertEq(nft.blueMinted(), 2, "two sales, four refusals");
        assertEq(address(nft).balance, 0.02 ether, "and the refusals kept no money");
    }

    /// The sold check reads ownership, and there is no burn, so selling the
    /// token on cannot put the character back on the market.
    function test_sellingTheTokenOnDoesNotPutTheCharacterBackOnSale() public {
        _buy(alice, 42);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 42);
        assertEq(nft.ownerOf(42), bob, "moved");

        assertTrue(nft.blueTaken(42), "still sold");
        assertEq(nft.blueTakenBits(0, 1)[0] >> 42 & 1, 1, "bitmap still set");

        uint256 price = _price();
        vm.prank(carol);
        vm.expectRevert(GlamToon.BlueAlreadyTaken.selector);
        nft.mintBlue{value: price}(42, price);
    }

    /*//////////////////////////////////////////////////////////////
                           WHEN THE SALE OPENS
    //////////////////////////////////////////////////////////////*/

    /// The check is block.timestamp < SALE_START, so the opening second itself
    /// must sell. A test that only warps backwards would pass with the
    /// comparison the wrong way round.
    function test_theSaleIsOpenAtExactlySaleStart() public {
        vm.warp(SALE_START);
        assertEq(block.timestamp, SALE_START, "on the second");

        uint256 price = _price();
        vm.prank(alice);
        nft.mintBlue{value: price}(1, price);
        assertEq(nft.ownerOf(1), alice, "sold in the opening second");

        vm.prank(bob);
        nft.mintGreen(1);
        assertEq(nft.greenCount(1), 1, "green opens on the same second");
    }

    function test_oneSecondEarlyNothingSellsAndNothingChanges() public {
        vm.warp(SALE_START - 1);

        _watch();
        vm.prank(alice);
        vm.expectRevert(GlamToon.NotStarted.selector);
        nft.mintBlue{value: 1 ether}(1, 1 ether);
        _assertStoppedBeforeWriting("a second before the sale");

        _watch();
        vm.prank(alice);
        vm.expectRevert(GlamToon.NotStarted.selector);
        nft.mintBlueFor{value: 1 ether}(bob, 1, 1 ether);
        _assertStoppedBeforeWriting("a gift a second before the sale");
    }

    function testFuzz_theDoorIsShutAtEverySecondBeforeTheStart(uint256 t) public {
        vm.warp(bound(t, 1, SALE_START - 1));

        vm.prank(alice);
        vm.expectRevert(GlamToon.NotStarted.selector);
        nft.mintBlue{value: 1 ether}(1, 1 ether);
    }

    function testFuzz_theDoorStaysOpenForever(uint256 t) public {
        vm.warp(bound(t, SALE_START, type(uint64).max));
        uint256 price = _price();

        vm.prank(alice);
        nft.mintBlue{value: price}(1, price);

        assertEq(nft.ownerOf(1), alice, "no end date");
    }

    /*//////////////////////////////////////////////////////////////
                           THE END OF THE SALE
    //////////////////////////////////////////////////////////////*/

    /// The permanent terminal state, checked on the books rather than on one
    /// revert: the bitmap is full, the money is all there, both doors are shut
    /// and the free edition is untouched by any of it. A character past the end
    /// is still named as invalid rather than as sold out, because the door
    /// checks the id before the count.
    function test_whenTheLastBlueIsSoldTheSaleIsShutForGood() public {
        for (uint256 id = 0; id < BLUE_SUPPLY - 1; ++id) {
            _buy(alice, id);
        }
        assertEq(nft.blueMinted(), 9999, "one left");
        assertEq(nft.currentPrice(), 0.04 ether, "at the last tier");

        _buy(bob, 9999);
        assertEq(nft.blueMinted(), BLUE_SUPPLY, "sold out");
        assertEq(address(nft).balance, 250 ether, "every sale banked");

        uint256[] memory all = nft.blueTakenBits(0, 40);
        for (uint256 w = 0; w < 39; ++w) {
            assertEq(all[w], type(uint256).max, "word full");
        }
        assertEq(all[39], 0xFFFF, "the last word holds exactly the sixteen tail characters");

        vm.expectRevert(GlamToon.SoldOut.selector);
        nft.currentPrice();

        vm.prank(carol);
        vm.expectRevert(GlamToon.SoldOut.selector);
        nft.mintBlue{value: 1 ether}(4242, type(uint256).max);

        vm.prank(carol);
        vm.expectRevert(GlamToon.SoldOut.selector);
        nft.mintBlueFor{value: 1 ether}(alice, 4242, type(uint256).max);

        vm.prank(carol);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.mintBlue{value: 1 ether}(10_000, type(uint256).max);

        vm.prank(carol);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.mintBlueFor{value: 1 ether}(alice, type(uint256).max, type(uint256).max);

        assertEq(nft.blueMinted(), BLUE_SUPPLY, "still ten thousand");
        assertEq(address(nft).balance, 250 ether, "and the refusals moved nothing");

        vm.prank(carol);
        nft.mintGreen(4242);
        assertEq(nft.greenCount(4242), 1, "the free edition is not closed by the sale ending");
    }

    /*//////////////////////////////////////////////////////////////
                        THE ORDER OF THE REFUSALS
    //////////////////////////////////////////////////////////////*/

    /// Which error a buyer gets when several things are wrong at once. It is a
    /// real promise: a wallet shows this to a human, and a reader who sees
    /// InsufficientPayment for a character that is gone will send more money to
    /// the same dead end.
    function test_theRefusalsComeInTheOrderTheDoorChecksThem() public {
        _buy(alice, 5);

        vm.warp(SALE_START - 1);
        vm.prank(bob);
        vm.expectRevert(GlamToon.NotStarted.selector);
        nft.mintBlue{value: 0}(10_000, 0);

        vm.warp(SALE_START);
        vm.prank(bob);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.mintBlue{value: 0}(10_000, 0);

        vm.prank(bob);
        vm.expectRevert(GlamToon.BlueAlreadyTaken.selector);
        nft.mintBlue{value: 0}(5, 0);

        vm.prank(bob);
        vm.expectRevert(GlamToon.PriceTooHigh.selector);
        nft.mintBlue{value: 0}(6, 0);
    }

    /// The ceiling and the payment are checked before the recipient is asked
    /// to take the token. A buyer who sent too little is told so whatever the
    /// recipient's hook would have said, and the recipient's code never runs
    /// for a sale that was never valid. Paid in full, each recipient turns the
    /// token away itself, which is what shows it was not asked above.
    function test_anUnderpaidGiftIsRefusedForThePaymentBeforeTheRecipientIsAsked() public {
        address[2] memory recipients = [address(new Hookless()), address(new TurnsAway())];
        bytes[2] memory ownReason = [
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, recipients[0]),
            abi.encodeWithSignature("Error(string)", "not today")
        ];
        uint256 price = _price();

        for (uint256 i = 0; i < recipients.length; ++i) {
            _watch();
            vm.prank(alice);
            vm.expectRevert(GlamToon.InsufficientPayment.selector);
            nft.mintBlueFor{value: price - 1}(recipients[i], 6, price);
            _assertStoppedBeforeWriting("an underpaid gift");

            _watch();
            vm.prank(alice);
            vm.expectRevert(GlamToon.PriceTooHigh.selector);
            nft.mintBlueFor{value: price}(recipients[i], 6, price - 1);
            _assertStoppedBeforeWriting("a gift with the ceiling too low");

            vm.prank(alice);
            vm.expectRevert(ownReason[i]);
            nft.mintBlueFor{value: price}(recipients[i], 6, price);
        }
    }

    /*//////////////////////////////////////////////////////////////
                   WHAT A REFUSED SALE LEAVES BEHIND
    //////////////////////////////////////////////////////////////*/

    /// Every way a sale can be refused, run against a live contract that already
    /// holds one sale's money. Each refusal has to come before the first write
    /// and before any call out. The revert would roll such a write back, so the
    /// books read afterwards could not show it; the recorded accesses can. The
    /// character the refusals aimed at then sells cleanly.
    function test_noRefusedSaleMovesTheBooks() public {
        _buy(alice, 5);
        uint256 price = _price();

        _watch();
        vm.prank(bob);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.mintBlue{value: price}(10_000, price);
        _assertStoppedBeforeWriting("out of range");

        _watch();
        vm.prank(bob);
        vm.expectRevert(GlamToon.BlueAlreadyTaken.selector);
        nft.mintBlue{value: price}(5, price);
        _assertStoppedBeforeWriting("already sold");

        _watch();
        vm.prank(bob);
        vm.expectRevert(GlamToon.PriceTooHigh.selector);
        nft.mintBlue{value: price}(6, price - 1);
        _assertStoppedBeforeWriting("ceiling too low");

        _watch();
        vm.prank(bob);
        vm.expectRevert(GlamToon.InsufficientPayment.selector);
        nft.mintBlue{value: price - 1}(6, price);
        _assertStoppedBeforeWriting("underpaid");

        _watch();
        vm.prank(bob);
        vm.expectRevert(GlamToon.PriceTooHigh.selector);
        nft.mintBlueFor{value: price}(carol, 6, price - 1);
        _assertStoppedBeforeWriting("a gift with the ceiling too low");

        uint256 before = bob.balance;
        _buy(bob, 6);
        assertEq(nft.ownerOf(6), bob, "character six sells cleanly afterwards");
        assertEq(before - bob.balance, price, "at the price the refusals were quoted");
        assertEq(nft.blueMinted(), 2, "as the second sale on the books");
    }

    /*//////////////////////////////////////////////////////////////
                            THE PRICE SCHEDULE
    //////////////////////////////////////////////////////////////*/

    /// The schedule stated as four flat bands rather than as the contract's own
    /// division, so a changed tier size or a changed step is a failure here and
    /// not a matching edit on both sides.
    function testFuzz_thePriceScheduleIsFourFlatBands(uint256 sold) public view {
        sold = bound(sold, 0, BLUE_SUPPLY - 1);

        uint256 band = sold < 2500 ? 1 : sold < 5000 ? 2 : sold < 7500 ? 3 : 4;
        assertEq(nft.priceAt(sold), band * 0.01 ether, "band");
        assertEq(nft.priceAt(sold), PRICE_STEP * (1 + sold / TIER_SIZE), "and the stated rule");
    }

    /// No fifth band, at any number a caller can reach. An interface that
    /// quotes a price past the end is quoting a sale that cannot happen.
    function testFuzz_pastTheLastSaleThereIsNoPrice(uint256 sold) public {
        sold = bound(sold, BLUE_SUPPLY, type(uint256).max);

        vm.expectRevert(GlamToon.SoldOut.selector);
        nft.priceAt(sold);
    }

    function test_pastTheLastSaleThereIsNoPriceAtTheEdges() public {
        vm.expectRevert(GlamToon.SoldOut.selector);
        nft.priceAt(BLUE_SUPPLY);

        vm.expectRevert(GlamToon.SoldOut.selector);
        nft.priceAt(type(uint256).max);
    }

    /// The quote and the charge are the same function. Whatever has sold, what
    /// currentPrice says is what the next buyer's wallet loses, through either
    /// door and whatever they send on top. The two could only drift apart at a
    /// tier boundary, so this walks the whole sale once and measures every one.
    function test_currentPriceIsWhatTheNextBuyerPaysAtEverySale() public {
        // Metering off: with each call its own transaction, as in a gas report,
        // this walk comes close to the per test gas limit. Nothing here asserts
        // on gas.
        vm.pauseGasMetering();

        for (uint256 sold = 0; sold < BLUE_SUPPLY; ++sold) {
            uint256 quoted = nft.currentPrice();
            assertEq(quoted, _expectedPrice(sold), "quote agrees with the schedule");

            uint256 extra = (sold % 5) * 0.003 ether;
            uint256 before = bob.balance;
            vm.prank(bob);
            if (sold % 2 == 0) {
                nft.mintBlue{value: quoted + extra}(sold, type(uint256).max);
            } else {
                nft.mintBlueFor{value: quoted + extra}(carol, sold, type(uint256).max);
            }
            assertEq(before - bob.balance, quoted, "the quote is the charge");
        }

        assertEq(nft.blueMinted(), BLUE_SUPPLY, "every sale was measured");
    }

    /*//////////////////////////////////////////////////////////////
                         THE STATE DURING A SALE
    //////////////////////////////////////////////////////////////*/

    /// Every write lands before the recipient's hook, which is the first handoff
    /// to code the contract does not control. A recipient that looks around
    /// mid mint must see the sale already counted, not a stale count it could
    /// act on. The gift door is used because there the hook runs in code that
    /// never asked to be called.
    function test_aRecipientSeesTheSaleAlreadyCountedFromInsideItsHook() public {
        Nosy nosy = new Nosy(nft);
        uint256 price = _price();

        vm.prank(alice);
        nft.mintBlueFor{value: price + 1 ether}(address(nosy), 77, price + 1 ether);

        assertEq(nosy.seenMinted(), 1, "the sale was counted before the hook ran");
        assertTrue(nosy.seenTaken(), "and the character was already flagged");
        assertEq(nosy.seenOwner(), address(nosy), "and the token was already theirs");
        assertEq(nosy.seenSupply(), 1, "supply already includes it");
        assertEq(nosy.seenHeld(), price + 1 ether, "the refund had not been sent yet");
        assertEq(address(nft).balance, price, "and was sent after the hook returned");
    }

    /// The gift case the mocks miss: the recipient did not start the call, so a
    /// mock that only fires on its own attack would never reach this. Buying a
    /// second character from inside the hook has to fail, or one transaction
    /// could walk the whole sale on one lock.
    function test_aGiftRecipientCannotBuyAgainFromInsideItsHook() public {
        SecondHelping greedy = new SecondHelping(nft);
        vm.deal(address(greedy), 10 ether);
        uint256 price = _price();

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        nft.mintBlueFor{value: price}(address(greedy), 78, price);

        assertEq(nft.blueMinted(), 0, "neither character was sold");
        assertEq(nft.totalSupply(), 0, "nothing minted at all");
        assertEq(address(nft).balance, 0, "and no money stuck");
    }

    /// The refund is the last thing a sale does, and it hands control back to
    /// the payer. The lock has to still be held there.
    function test_aPayerCannotBuyAgainFromInsideItsRefund() public {
        RefundBuyer payer = new RefundBuyer(nft);
        vm.deal(address(payer), 10 ether);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        payer.buy(79, 1 ether);

        assertEq(nft.blueMinted(), 0, "nothing sold");
        assertEq(address(nft).balance, 0, "and nothing kept");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// Record every account and storage slot the next call touches, including
    /// the writes a revert later takes back.
    function _watch() private {
        vm.startStateDiffRecording();
    }

    /// A refused sale must stop before it writes a slot or reaches another
    /// account. Sending ether, minting and counting all need one or the other.
    function _assertStoppedBeforeWriting(string memory what) private {
        Vm.AccountAccess[] memory seen = vm.stopAndReturnStateDiff();
        for (uint256 i = 0; i < seen.length; ++i) {
            assertNotEq(seen[i].accessor, address(nft), string.concat("the collection called out: ", what));
            Vm.StorageAccess[] memory slots = seen[i].storageAccesses;
            for (uint256 j = 0; j < slots.length; ++j) {
                assertFalse(slots[j].isWrite, string.concat("a slot was written before the refusal: ", what));
            }
        }
    }
}

/// No receiver hook at all.
contract Hookless {}

/// Turns every token away from inside its hook.
contract TurnsAway {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("not today");
    }
}

/// Reads the collection's books from inside onERC721Received, while the sale
/// that is handing it the token is still running.
contract Nosy {
    GlamToon immutable NFT;

    uint256 public seenMinted;
    uint256 public seenSupply;
    uint256 public seenHeld;
    address public seenOwner;
    bool public seenTaken;

    constructor(GlamToon n) {
        NFT = n;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        seenMinted = NFT.blueMinted();
        seenSupply = NFT.totalSupply();
        seenHeld = address(NFT).balance;
        seenOwner = NFT.ownerOf(tokenId);
        seenTaken = NFT.blueTaken(tokenId);
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/// Takes a gift and tries to buy another character before letting go of it.
contract SecondHelping {
    GlamToon immutable NFT;

    constructor(GlamToon n) {
        NFT = n;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        NFT.mintBlue{value: 1 ether}(9000, 1 ether);
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/// Buys with change owing, then tries to buy again from inside the refund.
contract RefundBuyer {
    GlamToon immutable NFT;
    bool armed;

    constructor(GlamToon n) {
        NFT = n;
    }

    function buy(uint256 imageId, uint256 send) external {
        armed = true;
        NFT.mintBlue{value: send}(imageId, send);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            NFT.mintBlue{value: 1 ether}(9000, 1 ether);
        }
    }
}
