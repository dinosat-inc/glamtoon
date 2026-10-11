// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {TierHandler} from "./handlers/TierHandler.sol";

/// The lifecycle campaign again, started from a sale already most of the way to
/// one of its edges. The other campaigns open on an empty sale and end a run a
/// hundred or so sales in, so without these nothing stateful ever saw the price
/// step up, the last blue go, or the treasury change hands with money moving.
///
/// Each variant sells through the handler before the first call, so the books
/// know every token from the start, and every run has to get past the variant's
/// edge or it proved nothing about it. The treasury's owner acts here as well,
/// which the lifecycle campaign keeps out on purpose, and the sweeps are held
/// to whoever was beneficiary at the time.
///
/// The pre sale is paid for once per variant and every invariant is a campaign
/// of its own, so the checks are gathered into three invariants that each
/// assert a great deal rather than spread across many that each assert a little.
/// Each variant trades runs for depth the way the lifecycle campaign does. The
/// handler offers twenty six doors, and at this depth each one is picked about
/// fifteen times a run, so the coverage claims below are not left to luck.
abstract contract TierCampaign is BaseTest {
    TierHandler internal handler;

    /// Blues sold before the first call of every run.
    function _startAt() internal pure virtual returns (uint256);

    /// The sale count every run has to pass.
    function _edge() internal pure virtual returns (uint256);

    function setUp() public override {
        super.setUp();

        // Metering off: the pre sale near the end of the collection costs more
        // than the per test gas limit. Nothing here asserts on gas.
        vm.pauseGasMetering();
        handler = new TierHandler(nft, treasury, _startAt());
        vm.resumeGasMetering();

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                                THE SALE
    //////////////////////////////////////////////////////////////*/

    /// What the sale kept is the tier price of every sale it made, each priced
    /// by the handler's own count at the moment it was made, on both sides of
    /// the edge and in batches that straddle it. The live price is the rule's
    /// for the count, and once the count is ten thousand there is no price and
    /// neither door sells. Every door that had to shut did, for the reason it
    /// had to, and every sale and mint that had to go through did.
    function invariant_everySaleIsChargedTheTierItFallsIn() public view {
        uint256 sold = nft.blueMinted();
        assertLe(sold, BLUE_SUPPLY, "more blues than there are characters");
        assertEq(sold, handler.bluesSold(), "the contract and the handler disagree on sales");
        assertEq(
            handler.etherIn() - handler.etherRefunded(), handler.expectedRevenue(), "the sale kept the wrong amount"
        );

        if (sold < BLUE_SUPPLY) {
            assertEq(nft.currentPrice(), _expectedPrice(sold), "the live price is off the ladder");
        } else {
            (bool ok, bytes memory reason) = address(nft).staticcall(abi.encodeCall(nft.currentPrice, ()));
            assertFalse(ok, "a sold out sale still quotes a price");
            assertEq(reason, abi.encodeWithSelector(GlamToon.SoldOut.selector), "the sold out sale says something else");
        }

        assertFalse(handler.soldPastTheEnd(), "a blue sold after the last one");
        assertFalse(handler.soldATakenBlue(), "a character's blue was sold twice");
        assertFalse(handler.ignoredThePriceCeiling(), "a sale went through above the buyer's ceiling");
        assertFalse(handler.acceptedShortPayment(), "a sale went through underpaid");
        assertFalse(handler.mintedOffTheEndOfTheCollection(), "a character past 9999 was minted");
        assertFalse(handler.gaveTheSameAddressASecondGreen(), "an address took two greens of one character");
        assertFalse(handler.mintedBeforeTheSaleOpened(), "a mint went through before the sale opened");
        assertFalse(handler.refusedForTheWrongReason(), "a door shut with some other error than the one that says why");

        assertFalse(handler.unexpectedRevert(), "a call that should have gone through reverted");
        assertFalse(handler.approvalLost(), "an approval lapsed while its token sat still");
        assertFalse(handler.reenterer().gotBackIn(), "a mint re-entered the collection and completed");
        assertFalse(handler.reenterer().stoppedByAnythingButTheGuard(), "something other than the guard stopped a mint");
        assertFalse(handler.reenterer().sawStaleState(), "the mint handed control over before recording the sale");
    }

    /*//////////////////////////////////////////////////////////////
                                THE BOOKS
    //////////////////////////////////////////////////////////////*/

    /// The chain and the handler's books describe one collection. The whole
    /// bitmap, all forty words, is the one the handler drew from the sales it
    /// saw. Every mint handed out the id it was for and no id twice. Every token
    /// was where a mint or a move had just put it, and every holder holds the
    /// number it was handed. The operators on chain are the ones the holders
    /// named, and nobody moved a token without leave. Every character's greens
    /// are the ones taken, slot by slot.
    function invariant_theChainAndTheBooksDescribeOneCollection() public view {
        uint256[] memory words = nft.blueTakenBits(0, nft.blueBitmapWords());
        uint256[] memory drawn = handler.soldWords();
        assertEq(words.length, drawn.length, "the bitmap is a different size");
        for (uint256 i = 0; i < words.length; ++i) {
            assertEq(words[i], drawn[i], "a word of the bitmap is not the sales that went through");
        }

        assertEq(nft.totalSupply(), nft.blueMinted() + nft.greenMinted(), "supply is not the sum of the editions");
        assertEq(nft.totalSupply(), handler.tokenCount(), "supply drifted from the mints that went through");
        assertGe(nft.totalSupply(), handler.supplyHighWater(), "supply went backwards");
        assertFalse(handler.doubleMinted(), "a token id was minted twice");
        assertFalse(handler.mintedTheWrongId(), "a mint handed out some other id than the one it was for");

        address[] memory actors = handler.actorList();
        _checkHolders(actors);
        assertFalse(handler.operatorsDrifted(), "an operator on chain is not one its holder named");
        assertTrue(handler.operatorsAgree(), "an operator on chain is not one its holder named");
        assertFalse(handler.movedWithoutPermission(), "a token moved without its holder's leave");
        _checkGreens(actors);
    }

    /*//////////////////////////////////////////////////////////////
                                THE MONEY
    //////////////////////////////////////////////////////////////*/

    /// Every wei the collection took is held, handed back or paid on. Whatever
    /// reached the treasury, from the sale or as a royalty, is still there or
    /// with the beneficiary it was swept to at the time, ether and token alike,
    /// and no beneficiary holds a wei it was not swept. The treasury answers to
    /// the owner the handovers left, with the offer the owner last made, the
    /// label follows it, and nothing about the deployment itself moved.
    function invariant_theMoneyFollowsTheTreasuryOfTheMoment() public view {
        uint256 inflow = handler.etherIn() + handler.etherForced();
        uint256 outflow = handler.etherRefunded() + handler.etherWithdrawn();
        assertLe(outflow, inflow, "more ether left than ever arrived");
        assertEq(address(nft).balance, inflow - outflow, "the balance does not add up");

        MockERC20 token = handler.royaltyToken();
        uint256 etherPaidOn;
        uint256 tokenPaidOn;
        for (uint256 i = 0; i < handler.payeeCount(); ++i) {
            address payee = handler.payees(i);
            uint256 tokens = token.balanceOf(payee);
            assertEq(payee.balance, handler.sweptTo(payee), "a beneficiary holds other than the ether swept to it");
            assertEq(tokens, handler.tokenSweptTo(payee), "a beneficiary holds other than the tokens swept to it");
            etherPaidOn += payee.balance;
            tokenPaidOn += tokens;
        }
        assertEq(
            address(treasury).balance + etherPaidOn,
            handler.etherWithdrawn() + handler.etherRoyalties(),
            "ether left the treasury chain"
        );
        assertEq(
            token.balanceOf(address(treasury)) + tokenPaidOn,
            handler.tokenPaidIn(),
            "a royalty token left the treasury chain"
        );

        assertEq(
            treasury.owner(), handler.treasuryOwnerGhost(), "the treasury is not with the owner the handovers left"
        );
        assertEq(
            treasury.pendingOwner(), handler.pendingOwnerGhost(), "the standing offer is not the one the owner made"
        );
        assertEq(treasury.beneficiary(), handler.beneficiaryGhost(), "the beneficiary is not the one the owner chose");
        assertEq(nft.owner(), handler.treasuryOwnerGhost(), "the label stopped following the treasury");

        assertEq(nft.PAYOUT(), address(treasury), "the payee moved");
        assertEq(nft.SALE_START(), SALE_START, "the sale start moved");
        assertEq(address(nft.CHUNK0()), address(chunk0), "the first trait chunk moved");
        assertEq(address(nft.CHUNK1()), address(chunk1), "the second trait chunk moved");
        assertEq(address(nft.NAMES()), address(names), "the name table moved");
        (address receiver, uint256 amount) = nft.royaltyInfo(4242, 10 ether);
        assertEq(receiver, address(treasury), "the royalty receiver moved");
        assertEq(amount, 0.2 ether, "the royalty rate moved");
    }

    /*//////////////////////////////////////////////////////////////
                                COVERAGE
    //////////////////////////////////////////////////////////////*/

    /// A run that stayed on one side of its edge proved nothing about the edge,
    /// and one that never used a door proved nothing about that door.
    function afterInvariant() public view virtual {
        assertGt(nft.blueMinted(), _edge(), "the run never got past its edge");
        assertGt(handler.greensTaken(), 0, "no green was ever taken");
        assertGt(handler.sweepCount(), 0, "the treasury was never swept");
        assertGt(handler.tokenSweepCount(), 0, "no royalty token was ever swept");
        assertGt(handler.handovers(), 0, "the treasury never changed hands");
        assertGt(handler.repoints(), 0, "the beneficiary was never moved");

        // The deployment's own beneficiary is the first payee, so anything the
        // others hold came from a sweep that followed the money somewhere new.
        uint256 followed;
        for (uint256 i = 1; i < handler.payeeCount(); ++i) {
            address payee = handler.payees(i);
            followed += handler.sweptTo(payee) + handler.tokenSweptTo(payee);
        }
        assertGt(followed, 0, "no sweep ever reached a beneficiary the owner had moved the money to");

        assertGt(handler.operatorMoves(), 0, "no operator ever moved a token");
        assertGt(handler.reenterer().attempts(), 0, "nothing only the guard could stop ever tried to get back in");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _checkHolders(address[] memory actors) private view {
        assertFalse(handler.misplaced(), "a token was not with the holder a mint or a move had just handed it to");

        uint256 held;
        for (uint256 a = 0; a < actors.length; ++a) {
            uint256 count = handler.heldBy(actors[a]);
            assertEq(nft.balanceOf(actors[a]), count, "a holder has some other number of tokens");
            held += count;
        }
        assertEq(held, nft.totalSupply(), "some tokens are with nobody the handler knows");
    }

    function _checkGreens(address[] memory actors) private view {
        assertEq(nft.greenMinted(), handler.greensTaken(), "the green total drifted from the mints");

        uint256[] memory ids = handler.charactersTouched();
        uint256 sum;
        for (uint256 a = 0; a < actors.length; ++a) {
            bool[] memory taken = nft.greenTakenBatch(ids, actors[a]);
            bool[] memory took = handler.tookGreenBatch(ids, actors[a]);
            uint256 mine;
            for (uint256 i = 0; i < ids.length; ++i) {
                assertEq(taken[i], took[i], "a green slot is not where the mint put it");
                if (taken[i]) mine += 1;
            }
            assertEq(mine, handler.greensOfActor(actors[a]), "an actor's slots on chain are not the greens it took");
            sum += mine;
        }
        assertEq(sum, nft.greenMinted(), "the per actor greens do not add up to the total");

        uint256[] memory counts = nft.greenCountBatch(ids);
        uint256[] memory believed = handler.greensOfCharacterBatch(ids);
        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(counts[i], believed[i], "a character has the wrong generation count");
        }
    }
}

/// The variants that start below a tier edge. Getting past it a sale at a time
/// is not enough: some batch has to be priced on both sides of it, or the claim
/// that a batch straddling the edge is charged each side's price was never put
/// to the test.
abstract contract TierEdgeCampaign is TierCampaign {
    function afterInvariant() public view override {
        super.afterInvariant();
        assertGt(handler.straddles(), 0, "no batch ever crossed the edge");
    }
}

/// Sixty sales short of the first edge, where the price goes from a hundredth to
/// two hundredths.
/// forge-config: default.invariant.runs = 8
/// forge-config: default.invariant.depth = 384
contract FirstTierEdgeInvariants is TierEdgeCampaign {
    function _startAt() internal pure override returns (uint256) {
        return TIER_SIZE - 60;
    }

    function _edge() internal pure override returns (uint256) {
        return TIER_SIZE;
    }
}

/// Sixty sales short of the second edge.
/// forge-config: default.invariant.runs = 8
/// forge-config: default.invariant.depth = 384
contract SecondTierEdgeInvariants is TierEdgeCampaign {
    function _startAt() internal pure override returns (uint256) {
        return 2 * TIER_SIZE - 60;
    }

    function _edge() internal pure override returns (uint256) {
        return 2 * TIER_SIZE;
    }
}

/// Sixty sales short of the third and last edge, where the price reaches the
/// four hundredths it holds to the end.
/// forge-config: default.invariant.runs = 8
/// forge-config: default.invariant.depth = 384
contract ThirdTierEdgeInvariants is TierEdgeCampaign {
    function _startAt() internal pure override returns (uint256) {
        return 3 * TIER_SIZE - 60;
    }

    function _edge() internal pure override returns (uint256) {
        return 3 * TIER_SIZE;
    }
}

/// Fifteen blues from the end. Every run sells the last of them early on and
/// spends the rest of its calls in the sold out collection, where both doors
/// have to refuse with SoldOut on every try while greens, transfers and the
/// money go on as before.
/// forge-config: default.invariant.runs = 8
/// forge-config: default.invariant.depth = 384
contract SellOutInvariants is TierCampaign {
    function _startAt() internal pure override returns (uint256) {
        return BLUE_SUPPLY - 15;
    }

    function _edge() internal pure override returns (uint256) {
        return BLUE_SUPPLY - 1;
    }

    function afterInvariant() public view override {
        super.afterInvariant();
        assertGt(handler.soldOutRefusals(), 0, "nobody was ever turned away from the sold out sale");
        assertGt(handler.greensAfterSellOut(), 0, "no green was taken once the blues were gone");
    }
}
