// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon, ITraitData, ITraitNames} from "../../src/GlamToon.sol";
import {Treasury} from "../../src/Treasury.sol";
import {Errors} from "openzeppelin/utils/Errors.sol";

/// Follows the ether rather than the tokens: out of a buyer's wallet, into the
/// collection, across to the treasury and on to the beneficiary. Each hop was
/// spot checked somewhere else in the suite; nothing joined them up, and nothing
/// asserted that the wei which leaves a buyer is the wei that arrives. A break
/// in any hop is permanent here, since there is no proxy to fix it with.
contract MoneyFlowTest is BaseTest {
    event Withdrawn(uint256 amount);
    event Swept(address indexed to, uint256 amount);
    event Received(address indexed from, uint256 amount);

    address internal stranger = vm.addr(0x57A7);

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /// withdraw is the one door out of the collection and it has no caller
    /// check, so the thing to pin is that an open door still leads to exactly
    /// one place: no tip for whoever pushes it, no shortcut to the beneficiary.
    function test_withdrawPaysThePayeeAndNobodyElse() public {
        uint256 first = _buy(alice, 11);
        uint256 second = _price();
        vm.prank(bob);
        nft.mintBlueFor{value: second + 4 ether}(carol, 12, second);

        vm.deal(stranger, 1 ether);
        uint256 held = address(nft).balance;
        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        uint256 carolBefore = carol.balance;

        vm.prank(stranger);
        nft.withdraw();

        assertEq(held, first + second, "only the two prices were ever kept");
        assertEq(address(treasury).balance, held, "the payee took all of it");
        assertEq(address(nft).balance, 0, "and the collection kept none");
        assertEq(stranger.balance, 1 ether, "the caller was paid nothing for calling");
        assertEq(beneficiary.balance, 0, "withdraw is one hop, not two");
        assertEq(alice.balance, aliceBefore, "no buyer was touched");
        assertEq(bob.balance, bobBefore, "no payer was touched");
        assertEq(carol.balance, carolBefore, "no recipient was touched");
    }

    /// The amount in the log is what an indexer and a tax return will treat as
    /// income, so it has to be the amount that actually moved, not the sale
    /// total. Ether forced in is part of what moves.
    function test_theWithdrawnLogCarriesEverySentWeiIncludingEtherNobodySent() public {
        uint256 paid = _buy(alice, 21);
        vm.deal(address(nft), address(nft).balance + 7 ether);
        uint256 held = address(nft).balance;

        vm.expectEmit(false, false, false, true, address(nft));
        emit Withdrawn(held);

        vm.prank(stranger);
        nft.withdraw();

        assertEq(held, paid + 7 ether, "the sale plus the windfall");
        assertEq(address(treasury).balance, held, "the log matches what arrived");
    }

    /// A selfdestruct or a block reward can land here with no sale behind it.
    /// Sending the balance rather than a running total is what keeps it
    /// reachable, and the payee is still the only destination.
    function test_etherThatArrivedWithNoSaleBehindItStillReachesThePayee() public {
        vm.deal(address(nft), 3 ether);
        assertEq(nft.blueMinted(), 0, "nothing was sold");

        vm.expectEmit(false, false, false, true, address(nft));
        emit Withdrawn(3 ether);

        vm.prank(stranger);
        nft.withdraw();

        assertEq(address(treasury).balance, 3 ether, "recovered anyway");
    }

    /// Two calls in a row must not pay twice. The second finds nothing because
    /// the first sent the balance, which is the whole of the bookkeeping.
    function test_aSecondWithdrawFindsNothingLeftToSend() public {
        _buy(alice, 31);
        nft.withdraw();
        uint256 delivered = address(treasury).balance;

        vm.expectRevert(GlamToon.NothingToWithdraw.selector);
        nft.withdraw();

        assertEq(address(treasury).balance, delivered, "the payee was not paid twice");
    }

    /// The guard is a zero test and not a threshold. One wei is above it.
    function test_aSingleWeiIsStillWorthSending() public {
        vm.deal(address(nft), 1);

        vm.prank(stranger);
        nft.withdraw();

        assertEq(address(treasury).balance, 1, "delivered");
        assertEq(address(nft).balance, 0, "emptied");
    }

    /// The zero test comes before the payee is called. A payee that refuses
    /// ether is never asked to take nothing, so an empty withdraw says there is
    /// nothing to send rather than passing on the payee's refusal. With a wei
    /// in the collection the same payee is called, and refuses.
    function test_anEmptyWithdrawNeverCallsThePayee() public {
        DeadEnd payee = new DeadEnd();
        GlamToon fresh = _collectionPaying(address(payee));

        vm.expectCall(address(payee), 0, "", 0);
        vm.prank(stranger);
        vm.expectRevert(GlamToon.NothingToWithdraw.selector);
        fresh.withdraw();

        vm.deal(address(fresh), 1);
        vm.prank(stranger);
        vm.expectRevert(bytes("shut"));
        fresh.withdraw();
    }

    /*//////////////////////////////////////////////////////////////
                       ETHER ARRIVING BY OTHER DOORS
    //////////////////////////////////////////////////////////////*/

    /// There is no receive and no fallback, so a wallet that pastes the
    /// collection address into a plain send gets its money back rather than
    /// handing it to a contract with no owner. The free mint takes no payment
    /// either, and neither does the withdraw door.
    function test_ratherThanSwallowingEtherTheCollectionRefusesIt() public {
        vm.startPrank(alice);

        (bool plain,) = address(nft).call{value: 1 ether}("");
        assertFalse(plain, "a bare send has nowhere to land");

        (bool green,) = address(nft).call{value: 1 ether}(abi.encodeCall(GlamToon.mintGreen, (7)));
        assertFalse(green, "the free edition is not payable");

        (bool out,) = address(nft).call{value: 1 ether}(abi.encodeCall(GlamToon.withdraw, ()));
        assertFalse(out, "the exit is not payable either");

        vm.stopPrank();

        assertEq(address(nft).balance, 0, "nothing stuck");
        assertEq(nft.greenCount(7), 0, "and the failed call minted nothing");
    }

    /*//////////////////////////////////////////////////////////////
                              THE PAYEE
    //////////////////////////////////////////////////////////////*/

    /// withdraw sends with all the gas it has, not the 2300 a transfer would
    /// forward. The treasury fits inside 2300 anyway, but a payee that does real
    /// work on arrival has to be payable too, or the sale's takings are
    /// stranded for good.
    function test_thePayeeGetsAllTheGasItNeedsToTakeDelivery() public {
        ExpensivePayee payee = new ExpensivePayee();
        GlamToon fresh = _collectionPaying(address(payee));

        uint256 price = fresh.currentPrice();
        vm.prank(alice);
        fresh.mintBlue{value: price}(1, price);

        vm.prank(stranger);
        fresh.withdraw();

        assertEq(address(payee).balance, price, "a costly receive still got paid");
        assertEq(payee.deliveries(), 1, "and got to run");
    }

    /// Royalties are often paid with transfer or send, which hand the payee
    /// only the 2300 gas stipend, and the royalty receiver can never be
    /// changed. The treasury's receive writes one log and nothing else, which
    /// fits inside the stipend, so those payers can still pay it. The same
    /// payment to a payee that writes storage fails, which shows the stipend
    /// really is all the treasury was given.
    function test_theTreasuryTakesEtherSentWithTheStipend() public {
        StipendPayer payer = new StipendPayer();
        vm.deal(address(payer), 2 ether);
        uint256 before = address(treasury).balance;

        vm.expectEmit(true, false, false, true, address(treasury));
        emit Received(address(payer), 1 ether);
        assertTrue(payer.pay(payable(address(treasury)), 1 ether), "the treasury took it on the stipend");
        assertEq(address(treasury).balance, before + 1 ether, "and every wei arrived");

        ExpensivePayee costly = new ExpensivePayee();
        assertFalse(payer.pay(payable(address(costly)), 1 ether), "a payee that writes storage cannot");
        assertEq(address(costly).balance, 0, "so it was paid nothing");
    }

    /// The counterweight to withdraw being open to anyone: it is not open to
    /// anywhere. A payee that refuses ether locks the takings away permanently,
    /// which is why the deploy script pays the payee a seed before broadcasting.
    function test_aPayeeThatRefusesEtherStrandsTheTakingsForGood() public {
        DeadEnd payee = new DeadEnd();
        GlamToon fresh = _collectionPaying(address(payee));

        uint256 price = fresh.currentPrice();
        vm.prank(alice);
        fresh.mintBlue{value: price}(1, price);

        vm.prank(stranger);
        vm.expectRevert(bytes("shut"));
        fresh.withdraw();

        assertEq(address(fresh).balance, price, "the money is still in there");
        assertEq(address(payee).balance, 0, "and there is no second door");
    }

    /*//////////////////////////////////////////////////////////////
                              CONSERVATION
    //////////////////////////////////////////////////////////////*/

    /// The one test that would catch a leak anywhere in the chain. It drives a
    /// mixed run of paid mints, gifts, overpayment, free mints, transfers,
    /// withdraws and sweeps, then checks two things: what the wallets lost equals
    /// what the three sinks hold, and that figure is exactly the posted price
    /// curve summed over the sales. Both are computed from balances and from the
    /// rule, never from a figure the contract reports, so a wei kept, sent to a
    /// fourth place, or charged at the wrong tier fails it. The invariant suite
    /// keeps a similar ledger, but it totals what its own handler sent and stops
    /// at the collection's balance; this follows the money to the beneficiary.
    ///
    /// Each run first sells its way to one of five starting points, so the mixed
    /// part lands on a different tier each time. Three of them sit ten sales
    /// below a tier boundary, and those runs keep mixing until the boundary is
    /// behind them, so the last sale of a tier and the first of the next are
    /// bought, gifted and overpaid in the mix rather than bought to the wei.
    /// Five rather than all ten thousand, because the sale is walked token by
    /// token elsewhere and this test is about the money.
    function testFuzz_everyWeiIsAccountedFor(uint256 seed) public {
        // Metering off: with each call its own transaction, as in a gas report,
        // a run that starts near the end comes close to the per test gas limit.
        // Nothing here asserts on gas.
        vm.pauseGasMetering();

        uint256 walletsBefore = alice.balance + bob.balance + carol.balance;
        uint256 lastToken;
        address lastOwner;

        uint256[5] memory starts =
            [uint256(0), TIER_SIZE - 10, 2 * TIER_SIZE - 10, 3 * TIER_SIZE - 10, BLUE_SUPPLY - 30];
        uint256 start = starts[bound(seed, 0, 4)];
        bool straddles = start % TIER_SIZE == TIER_SIZE - 10;
        uint256 nextImage = start;
        _sell(start);

        for (uint256 step = 0; step < 24 || (straddles && nft.blueMinted() <= start + 10); ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address who = _actor(seed >> 8);
            uint256 op = seed % 7;

            if (op == 0 || op == 1) {
                uint256 price = nft.currentPrice();
                uint256 extra = op == 0 ? 0 : bound(seed >> 16, 1, 3 ether);
                vm.prank(who);
                nft.mintBlue{value: price + extra}(nextImage, price);
                lastToken = nextImage;
                lastOwner = who;
                ++nextImage;
            } else if (op == 2) {
                address to = _actor(seed >> 32);
                uint256 price = nft.currentPrice();
                uint256 extra = bound(seed >> 40, 0, 5 ether);
                vm.prank(who);
                nft.mintBlueFor{value: price + extra}(to, nextImage, price);
                lastToken = nextImage;
                lastOwner = to;
                ++nextImage;
            } else if (op == 3) {
                uint256 imageId = bound(seed >> 48, 0, 9999);
                if (nft.greenTaken(imageId, who)) continue;
                vm.prank(who);
                nft.mintGreen(imageId);
                lastOwner = who;
                lastToken = nft.tokenIdFor(imageId, nft.greenCount(imageId));
            } else if (op == 4) {
                address to = _actor(seed >> 56);
                if (lastOwner == address(0) || to == lastOwner) continue;
                vm.prank(lastOwner);
                nft.transferFrom(lastOwner, to, lastToken);
                lastOwner = to;
            } else if (op == 5) {
                if (address(nft).balance == 0) continue;
                vm.prank(_actor(seed >> 64));
                nft.withdraw();
            } else {
                if (address(treasury).balance == 0) continue;
                vm.prank(_actor(seed >> 72));
                treasury.sweep();
            }
        }

        if (straddles) {
            assertEq(nft.currentPrice(), _expectedPrice(start) + PRICE_STEP, "the mix crossed into the next tier");
        }

        uint256 spent = walletsBefore - (alice.balance + bob.balance + carol.balance);
        uint256 sinks = address(nft).balance + address(treasury).balance + beneficiary.balance;
        assertEq(spent, sinks, "wei left the wallets and is not in any of the three places it may be");

        uint256 curve;
        for (uint256 k = 0; k < nft.blueMinted(); ++k) {
            curve += _expectedPrice(k);
        }
        assertEq(spent, curve, "the wallets paid the posted curve, no more and no less");
        assertGt(nft.totalSupply(), 0, "the run did something");
    }

    /*//////////////////////////////////////////////////////////////
                             THE SECOND HOP
    //////////////////////////////////////////////////////////////*/

    /// The whole journey in one test, so a change that breaks a single hop
    /// cannot hide behind the hop either side of it still passing. Both pushes
    /// are made by an address with no role at all, because nobody is obliged to
    /// be around for the money to move.
    function test_aBuyersEtherWalksAllTheWayToTheBeneficiary() public {
        uint256 price = _price();
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        nft.mintBlue{value: price + 2 ether}(4242, price);

        assertEq(alice.balance, aliceBefore - price, "the buyer was charged the price and no more");
        assertEq(address(nft).balance, price, "the collection holds the sale");

        (address receiver, uint256 royalty) = nft.royaltyInfo(4242, 10 ether);
        assertEq(receiver, address(treasury), "resales are pointed at the same treasury");
        vm.deal(address(this), royalty);
        (bool ok,) = address(treasury).call{value: royalty}("");
        assertTrue(ok, "a marketplace can pay the royalty straight in");

        vm.expectEmit(false, false, false, true, address(nft));
        emit Withdrawn(price);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit Received(address(nft), price);
        vm.prank(stranger);
        nft.withdraw();

        assertEq(address(treasury).balance, price + royalty, "sale and royalty sit together");

        vm.expectEmit(true, false, false, true, address(treasury));
        emit Swept(beneficiary, price + royalty);
        vm.prank(stranger);
        treasury.sweep();

        assertEq(beneficiary.balance, price + royalty, "delivered");
        assertEq(address(treasury).balance, 0, "treasury emptied");
        assertEq(address(nft).balance, 0, "collection emptied");
        assertEq(stranger.balance, 0, "the pusher kept nothing");
    }

    /// A sweep reads the beneficiary at the moment it runs, so money already
    /// sitting in the treasury follows the repoint. That is the only reason
    /// holding the owner key is worth anything.
    function test_moneyAlreadyHeldFollowsTheRepointAndTheOldAddressGetsNothing() public {
        _buy(alice, 55);
        nft.withdraw();
        uint256 held = address(treasury).balance;

        address elsewhere = vm.addr(0xE15E);
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(elsewhere);

        vm.prank(stranger);
        treasury.sweep();

        assertEq(elsewhere.balance, held, "the new address took it");
        assertEq(beneficiary.balance, 0, "the old one was paid nothing");
    }

    /// Unlike a payee that refuses ether, a beneficiary that refuses it is
    /// recoverable, because the owner can point somewhere else and push again.
    /// This is the reason setBeneficiary exists at all.
    function test_aBeneficiaryThatCannotTakeEtherIsNotAPermanentLoss() public {
        DeadEnd refuser = new DeadEnd();
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(address(refuser));

        _buy(alice, 66);
        nft.withdraw();
        uint256 held = address(treasury).balance;

        vm.expectRevert(bytes("shut"));
        treasury.sweep();
        assertEq(address(treasury).balance, held, "stuck, but still here");

        vm.prank(treasuryOwner);
        treasury.setBeneficiary(carol);
        uint256 carolBefore = carol.balance;

        vm.prank(stranger);
        treasury.sweep();

        assertEq(carol.balance, carolBefore + held, "freed");
        assertEq(address(refuser).balance, 0, "the dead end never got a wei");
    }

    /// sweep has no reentrancy guard, and it does not need one: the balance is
    /// gone before the beneficiary gets control, so the call it makes back finds
    /// an empty contract. Asserted because a future rewrite that sends before
    /// reading, or tracks a figure in storage, would pay out twice.
    function test_aBeneficiaryReenteringTheSweepDrawsNothingExtra() public {
        SweepsAgain greedy = new SweepsAgain(treasury);
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(address(greedy));

        _buy(alice, 77);
        nft.withdraw();
        uint256 held = address(treasury).balance;

        vm.prank(stranger);
        treasury.sweep();

        assertEq(address(greedy).balance, held, "paid once");
        assertEq(greedy.arrivals(), 1, "and only once");
        assertTrue(greedy.secondSweepFailed(), "the re-entrant call found nothing");
        assertEq(address(treasury).balance, 0, "treasury emptied exactly once");
    }

    /*//////////////////////////////////////////////////////////////
                      BUYERS WHO CANNOT TAKE CHANGE
    //////////////////////////////////////////////////////////////*/

    /// Overpaying from a contract that will not take ether back has to fail
    /// whole. The refund is the last thing a sale does, so the buyer's own
    /// reason coming out of the mint shows the failure came after the sale was
    /// written and reverted all of it. The character then sells to the next
    /// buyer at the opening price.
    function test_aBuyerWhoCannotTakeChangeMintsNothingAtAll() public {
        RefusesChange buyer = new RefusesChange(nft, false);
        vm.deal(address(buyer), 5 ether);
        uint256 price = _price();

        vm.expectRevert(bytes("keep the change"));
        buyer.buy(88, price + 1, price);

        uint256 before = alice.balance;
        vm.prank(alice);
        nft.mintBlue{value: price}(88, price);
        assertEq(nft.ownerOf(88), alice, "the character was still for sale");
        assertEq(before - alice.balance, price, "at the opening price");
        assertEq(nft.blueMinted(), 1, "as the only sale on the books");
        assertEq(address(nft).balance, price, "and the collection holds that sale alone");
    }

    /// The same buyer reverting with no reason at all, which is the branch that
    /// surfaces as FailedCall rather than a bubbled string. Named so a bare
    /// expectRevert cannot pass on the wrong failure.
    function test_aSilentRefusalSurfacesAsAFailedCall() public {
        RefusesChange buyer = new RefusesChange(nft, true);
        vm.deal(address(buyer), 5 ether);
        uint256 price = _price();

        vm.expectRevert(Errors.FailedCall.selector);
        buyer.buy(89, price + 1 wei, price);

        assertEq(nft.blueMinted(), 0, "nothing minted");
    }

    /// Paying to the wei asks nothing of the buyer's receive, so the same
    /// contract buys cleanly and its money goes the whole way.
    function test_thatSameBuyerPayingExactlyIsChargedExactlyAndTheMoneyFlowsOn() public {
        RefusesChange buyer = new RefusesChange(nft, false);
        vm.deal(address(buyer), 5 ether);
        uint256 price = _price();

        buyer.buy(90, price, price);

        assertEq(nft.ownerOf(90), address(buyer), "bought");
        assertEq(address(buyer).balance, 5 ether - price, "charged the price only");

        vm.prank(stranger);
        nft.withdraw();
        vm.prank(stranger);
        treasury.sweep();

        assertEq(beneficiary.balance, price, "and it reached the end");
    }

    /// The refund follows msg.sender, so a contract paying on someone's behalf
    /// gets its own change back. Were it tx.origin, the change would land in the
    /// wallet that signed the transaction instead of in the contract's books.
    function test_changeGoesToTheCallerNotToWhoeverSignedTheTransaction() public {
        Middleman agent = new Middleman(nft);
        vm.deal(address(agent), 5 ether);
        uint256 price = _price();
        uint256 aliceBefore = alice.balance;

        vm.prank(alice, alice);
        agent.buyFor(bob, 91, price + 2 ether, price);

        assertEq(nft.ownerOf(91), bob, "the recipient has the token");
        assertEq(address(agent).balance, 5 ether - price, "the caller took its change back");
        assertEq(alice.balance, aliceBefore, "the signer paid nothing and received nothing");
        assertEq(address(nft).balance, price, "the collection kept the price");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// A second collection wired to a different payee, so the payee's behaviour
    /// can be tested without touching the one every other test shares.
    function _collectionPaying(address payee) internal returns (GlamToon) {
        return new GlamToon(
            ITraitData(address(chunk0)), ITraitData(address(chunk1)), ITraitNames(address(names)), payee, SALE_START
        );
    }

    function _actor(uint256 draw) internal view returns (address) {
        uint256 pick = draw % 3;
        if (pick == 0) return alice;
        if (pick == 1) return bob;
        return carol;
    }
}

/// Takes the token but refuses ether, either with a reason or silently.
contract RefusesChange {
    GlamToon immutable nft;
    bool immutable silent;

    constructor(GlamToon n, bool quiet) {
        nft = n;
        silent = quiet;
    }

    function buy(uint256 imageId, uint256 send, uint256 maxPrice) external {
        nft.mintBlue{value: send}(imageId, maxPrice);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (silent) revert();
        revert("keep the change");
    }
}

/// Buys for other people out of its own float, the way a shop or a bot would.
contract Middleman {
    GlamToon immutable nft;

    constructor(GlamToon n) {
        nft = n;
    }

    function buyFor(address to, uint256 imageId, uint256 send, uint256 maxPrice) external {
        nft.mintBlueFor{value: send}(to, imageId, maxPrice);
    }

    receive() external payable {}
}

/// Refuses ether whoever sends it.
contract DeadEnd {
    receive() external payable {
        revert("shut");
    }
}

/// A payee whose receive costs far more than the 2300 gas a transfer forwards.
contract ExpensivePayee {
    uint256[8] private scratch;
    uint256 public deliveries;

    receive() external payable {
        for (uint256 i = 0; i < 8; ++i) {
            scratch[i] = block.timestamp + i + 1;
        }
        deliveries += 1;
    }
}

/// Pays the way transfer and send do: the value and no gas of its own, so the
/// payee runs on the 2300 gas stipend alone.
contract StipendPayer {
    function pay(address payable to, uint256 amount) external returns (bool ok) {
        (ok,) = to.call{value: amount, gas: 0}("");
    }
}

/// Sweeps again the moment a sweep pays it, and remembers whether that worked.
contract SweepsAgain {
    Treasury immutable treasury;
    uint256 public arrivals;
    bool public secondSweepFailed;

    constructor(Treasury t) {
        treasury = t;
    }

    receive() external payable {
        arrivals += 1;
        try treasury.sweep() {}
        catch {
            secondSweepFailed = true;
        }
    }
}
