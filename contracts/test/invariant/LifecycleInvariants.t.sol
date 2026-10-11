// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";
import {LifecycleHandler} from "./handlers/LifecycleHandler.sol";

/// A second campaign, aimed at the things a supply-only sweep cannot see: where
/// each token actually ended up, what the sale was allowed to charge for it, and
/// whether the money that left the token contract is still somewhere the project
/// can reach. The handler keeps its own books and three of its actors are
/// contracts, so a recipient with code is part of the state space rather than an
/// afterthought, and all three act when the collection calls into them rather
/// than when they call it.
///
/// Deeper and narrower than the default the other campaign runs at. This handler
/// offers three times as many doors, so at the shared depth each one is picked
/// only a handful of times per run and a run can finish having never swept or
/// never taken a green, which would make the coverage claims below flaky rather
/// than true. Trading runs for depth keeps the wall clock the same.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 384
contract LifecycleInvariants is BaseTest {
    LifecycleHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LifecycleHandler(nft, treasury);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                                 SUPPLY
    //////////////////////////////////////////////////////////////*/

    /// One blue per character and no more, whatever order the sale is driven in.
    function invariant_blueSupplyIsCappedAndMatchesTheSales() public view {
        assertLe(nft.blueMinted(), BLUE_SUPPLY, "more blues than there are characters");
        assertEq(nft.blueMinted(), handler.bluesSold(), "the contract and the handler disagree on sales");
    }

    /// Supply is the two editions added up, matches the mints that went through,
    /// and never falls, because nothing here can burn.
    function invariant_supplyIsTheTwoEditionsAndNeverFalls() public view {
        assertEq(nft.totalSupply(), nft.blueMinted() + nft.greenMinted(), "supply is not the sum of the editions");
        assertEq(nft.totalSupply(), handler.tokenCount(), "supply drifted from the mints that went through");
        assertGe(nft.totalSupply(), handler.supplyHighWater(), "supply went backwards");
    }

    /// The same id twice would put two characters on one token. The handler reads
    /// the id every mint really handed out off the Transfer it logged, and flags
    /// one that was already live, or that is not the id the handler worked out
    /// for that character and generation.
    function invariant_noTokenIdWasEverMintedTwice() public view {
        assertFalse(handler.doubleMinted(), "a token id was minted twice");
        assertFalse(handler.mintedTheWrongId(), "a mint handed out some other id than the one it was for");
    }

    /*//////////////////////////////////////////////////////////////
                                 BITMAP
    //////////////////////////////////////////////////////////////*/

    /// The bitmap is what every front end reads to decide which characters are
    /// still for sale, and it is written by hand beside the ownership record, so
    /// it is exactly the sort of thing that drifts. The whole map has to match,
    /// word for word, the one the handler drew from the sales it saw go through,
    /// which pins it in both directions: nothing sold is missing, and nothing
    /// unsold is marked. The count and the ownership record are checked beside it.
    function invariant_theBitmapIsExactlyTheBluesThatSold() public view {
        uint256[] memory words = nft.blueTakenBits(0, nft.blueBitmapWords());
        uint256[] memory drawn = handler.soldWords();
        assertEq(words.length, drawn.length, "the bitmap is a different size");

        uint256 set;
        for (uint256 i = 0; i < words.length; ++i) {
            assertEq(words[i], drawn[i], "a word of the bitmap is not the sales that went through");
            set += _popcount(words[i]);
        }
        assertEq(set, nft.blueMinted(), "the bitmap marks a different number of blues than were sold");

        uint256 n = handler.blueCount();
        for (uint256 i = 0; i < n; ++i) {
            assertTrue(nft.blueTaken(handler.blueAt(i)), "a sold blue does not read as taken");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 GREENS
    //////////////////////////////////////////////////////////////*/

    /// The one per address rule is the only scarcity green has. Asking every
    /// actor about every character a green was taken of checks both halves: the
    /// minter's slot is spent, and nobody else's was spent for them.
    function invariant_greenSlotsMatchWhoActuallyTookThem() public view {
        uint256[] memory ids = handler.charactersTouched();
        if (ids.length == 0) return;

        address[] memory actors = handler.actorList();
        for (uint256 a = 0; a < actors.length; ++a) {
            bool[] memory taken = nft.greenTakenBatch(ids, actors[a]);
            bool[] memory took = handler.tookGreenBatch(ids, actors[a]);
            for (uint256 i = 0; i < ids.length; ++i) {
                assertEq(taken[i], took[i], "a green slot is not where the mint put it");
            }
        }

        uint256[] memory counts = nft.greenCountBatch(ids);
        uint256[] memory believed = handler.greensOfCharacterBatch(ids);
        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(counts[i], believed[i], "a character has the wrong generation count");
        }
    }

    /// The global green tally has to be the per actor tallies added up, which is
    /// what a mint crediting the wrong address would break first. Each actor's
    /// tally is counted off the contract's own slots, over every character a
    /// green was taken of, and has to be the number that actor took.
    function invariant_greensAddUpAcrossTheActors() public view {
        assertEq(nft.greenMinted(), handler.greensTaken(), "the green total drifted from the mints");

        uint256[] memory ids = handler.charactersTouched();
        address[] memory actors = handler.actorList();
        uint256 sum;
        for (uint256 a = 0; a < actors.length; ++a) {
            bool[] memory taken = nft.greenTakenBatch(ids, actors[a]);
            uint256 mine;
            for (uint256 i = 0; i < taken.length; ++i) {
                if (taken[i]) mine += 1;
            }
            assertEq(mine, handler.greensOfActor(actors[a]), "an actor's slots on chain are not the greens it took");
            sum += mine;
        }
        assertEq(sum, nft.greenMinted(), "the per actor greens do not add up to the total");
    }

    /*//////////////////////////////////////////////////////////////
                                OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    /// The handler models where each token should be, including the forwarder
    /// passing on whatever the mint hook hands it. A sale that delivered to the
    /// payer instead of the recipient, or a transfer that credited the wrong
    /// side, shows up here and nowhere in a supply count.
    ///
    /// Every token is asked after at the moment a mint or a move lands it, old
    /// ones included, and every holder's count has to be what the handler handed
    /// it, which is what catches a token that moved when nobody moved it. The
    /// newest forty are asked again here.
    function invariant_everyTokenIsWhereTheHandlerPutIt() public view {
        assertFalse(handler.misplaced(), "a token was not with the holder a mint or a move had just handed it to");

        (uint256[] memory ids, address[] memory holders) = handler.newestTokens(40);
        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(nft.ownerOf(ids[i]), holders[i], "a token is not with the holder it was sent to");
        }

        address[] memory actors = handler.actorList();
        uint256 held;
        for (uint256 a = 0; a < actors.length; ++a) {
            uint256 count = handler.heldBy(actors[a]);
            assertEq(nft.balanceOf(actors[a]), count, "a holder has some other number of tokens");
            held += count;
        }
        assertEq(held, nft.totalSupply(), "some tokens are with nobody the handler knows");
    }

    /// The other half of the same question. These are mints the handler tried
    /// knowing they must fail, against live state rather than a fresh contract,
    /// because a guard is only worth what it is worth mid sale.
    function invariant_theSaleHeldEveryDoorItShouldHaveShut() public view {
        assertFalse(handler.soldATakenBlue(), "a character's blue was sold twice");
        assertFalse(handler.ignoredThePriceCeiling(), "a sale went through above the buyer's ceiling");
        assertFalse(handler.acceptedShortPayment(), "a sale went through underpaid");
        assertFalse(handler.mintedOffTheEndOfTheCollection(), "a character past 9999 was minted");
        assertFalse(handler.gaveTheSameAddressASecondGreen(), "an address took two greens of one character");
        assertFalse(handler.mintedBeforeTheSaleOpened(), "a mint went through before the sale opened");
        assertFalse(handler.refusedForTheWrongReason(), "a door shut with some other error than the one that says why");
    }

    /// One of the actors is a contract that tries to mint again from inside the
    /// mint handing it a token, which is a door the collection opens itself
    /// rather than one anybody knocks on. It must never get back in, and it is
    /// the guard that has to turn it away.
    function invariant_nobodyMintsFromInsideAMint() public view {
        assertFalse(handler.reenterer().gotBackIn(), "a mint re-entered the collection and completed");
        assertFalse(handler.reenterer().stoppedByAnythingButTheGuard(), "something other than the guard stopped a mint");
        assertFalse(handler.reenterer().sawStaleState(), "the mint handed control over before recording the sale");
    }

    /// Every door the handler drove was one it had already established should
    /// work, bar a recipient that openly refuses. A revert anywhere else means
    /// some condition the contract now imposes was not there before.
    function invariant_callsThatShouldHaveGoneThroughDid() public view {
        assertFalse(handler.unexpectedRevert(), "a call that should have gone through reverted");
        assertFalse(handler.approvalLost(), "an approval lapsed while its token sat still");
    }

    /*//////////////////////////////////////////////////////////////
                                  MONEY
    //////////////////////////////////////////////////////////////*/

    /// Every wei is either still held, handed back as change, or paid out. There
    /// is no fourth place, and ether forced in by other means is held like the
    /// rest rather than stranded.
    function invariant_theBalanceIsWhatArrivedLessWhatLeft() public view {
        uint256 inflow = handler.etherIn() + handler.etherForced();
        uint256 outflow = handler.etherRefunded() + handler.etherWithdrawn();
        assertLe(outflow, inflow, "more ether left than ever arrived");
        assertEq(address(nft).balance, inflow - outflow, "the balance does not add up");
    }

    /// What the sale kept has to be the tier price, times the number of sales.
    /// The handler prices each mint from its own count, so this catches a sale
    /// that overcharged or undercharged rather than one that merely disagreed
    /// with its own quote.
    function invariant_theSaleKeptExactlyTheTierPrice() public view {
        assertEq(
            handler.etherIn() - handler.etherRefunded(), handler.expectedRevenue(), "the sale kept the wrong amount"
        );
    }

    /// The live price is the rung of the ladder for the sales made so far, with
    /// time running on and state piling up around it. The ladder itself is
    /// priceAt, which is pure, so nothing the campaign does can move it. Its
    /// rungs, both sides of every tier edge, the last sale and no price at all
    /// once the sale is over, are a fixed check that runs beside the live price.
    function invariant_thePriceLadderNeverMovesWithStateOrTheClock() public view {
        assertEq(nft.currentPrice(), _expectedPrice(nft.blueMinted()), "the live price is off the ladder");

        assertEq(nft.priceAt(0), _expectedPrice(0), "the opening rung moved");
        for (uint256 edge = TIER_SIZE; edge < BLUE_SUPPLY; edge += TIER_SIZE) {
            assertEq(nft.priceAt(edge - 1), _expectedPrice(edge - 1), "the last rung of a tier moved");
            assertEq(nft.priceAt(edge), _expectedPrice(edge), "the first rung of a tier moved");
        }
        assertEq(nft.priceAt(BLUE_SUPPLY - 1), _expectedPrice(BLUE_SUPPLY - 1), "the last rung moved");

        (bool ok, bytes memory reason) = address(nft).staticcall(abi.encodeCall(nft.priceAt, (BLUE_SUPPLY)));
        assertFalse(ok, "a rung exists past the end of the sale");
        assertEq(reason, abi.encodeWithSelector(GlamToon.SoldOut.selector), "the end of the sale is not SoldOut");
    }

    /// Withdrawals reach one address and sweeps reach one more. Anything that
    /// left the token contract is sitting in the treasury or with the
    /// beneficiary, so there is no third place for the money to be.
    function invariant_everyWithdrawalIsStillInTheTreasuryChain() public view {
        assertEq(
            address(treasury).balance + beneficiary.balance, handler.etherWithdrawn(), "money left the treasury chain"
        );
        assertEq(beneficiary.balance, handler.swept(), "the sweep delivered a different amount");
    }

    /*//////////////////////////////////////////////////////////////
                                 FIXTURES
    //////////////////////////////////////////////////////////////*/

    /// Nobody in the campaign owns anything, so nothing anybody did should have
    /// moved the payee, the royalty, the clock or the trait pointers. Sweeping
    /// is open to all, and it must not be able to move the beneficiary either.
    function invariant_nothingAboutTheDeploymentCanMove() public view {
        assertEq(nft.PAYOUT(), address(treasury), "the payee moved");
        assertEq(nft.SALE_START(), SALE_START, "the sale start moved");
        assertEq(address(nft.CHUNK0()), address(chunk0), "the first trait chunk moved");
        assertEq(address(nft.CHUNK1()), address(chunk1), "the second trait chunk moved");
        assertEq(address(nft.NAMES()), address(names), "the name table moved");

        (address receiver, uint256 amount) = nft.royaltyInfo(4242, 10 ether);
        assertEq(receiver, address(treasury), "the royalty receiver moved");
        assertEq(amount, 0.2 ether, "the royalty rate moved");

        assertEq(treasury.beneficiary(), beneficiary, "the beneficiary moved");
        assertEq(treasury.owner(), treasuryOwner, "the treasury owner moved");
        assertEq(treasury.pendingOwner(), address(0), "somebody was offered the treasury");
    }

    /*//////////////////////////////////////////////////////////////
                                COVERAGE
    //////////////////////////////////////////////////////////////*/

    /// A campaign that never walked a path proved nothing about it. These are
    /// claims about the run rather than about the contract, which is why they
    /// belong here and not in an invariant.
    function afterInvariant() public view {
        assertGt(handler.bluesSold(), 0, "no blue was ever sold");
        assertGt(handler.giftCount(), 0, "nobody ever bought one for somebody else");
        assertGt(handler.greensTaken(), 0, "no green was ever taken");
        assertGt(handler.withdrawCount(), 0, "the takings were never withdrawn");
        assertGt(handler.sweepCount(), 0, "the treasury was never swept");
        assertGt(handler.transfersToContracts(), 0, "no token ever reached an actor with code");
        assertGt(handler.forwarder().forwarded(), 0, "the forwarding receiver was never called into");
        assertGt(handler.reenterer().attempts(), 0, "nothing only the guard could stop ever tried to get back in");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// Set bits in a word. Forty of these beat ten thousand ownership reads,
    /// which is what makes checking the whole bitmap after every call affordable.
    function _popcount(uint256 x) private pure returns (uint256 count) {
        unchecked {
            x = x - ((x >> 1) & 0x5555555555555555555555555555555555555555555555555555555555555555);
            x = (x & 0x3333333333333333333333333333333333333333333333333333333333333333)
                + ((x >> 2) & 0x3333333333333333333333333333333333333333333333333333333333333333);
            x = (x + (x >> 4)) & 0x0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f;
            for (uint256 i = 0; i < 32; ++i) {
                count += (x >> (i << 3)) & 0xff;
            }
        }
    }
}
