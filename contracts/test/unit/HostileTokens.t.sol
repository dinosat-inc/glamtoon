// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {stdError} from "forge-std/StdError.sol";
import {BaseTest} from "../Base.t.sol";
import {Treasury} from "../../src/Treasury.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

/// TreasuryAdversarial covers the tokens an auditor expects: false returns,
/// silent returns, reverts, fee on transfer, a reentrant transfer that unwinds.
/// Every one of those can be written with OpenZeppelin's ERC20 underneath.
///
/// This suite is the other half. These mocks own their whole ledger, so they can
/// do things a real ERC20 base class forbids: conjure supply mid transfer to pay
/// a double spend that would otherwise unwind, quote a balance they will not
/// honour, hand over more than they quoted, answer a transfer with two hundred
/// kilobytes of garbage, write storage from balanceOf, and move the balance
/// between the read and the send.
///
/// Three claims are asserted for every one of them:
///   no token takes a wei of the treasury's ether or sends one anywhere but
///   the beneficiary,
///   the beneficiary is the only address a sweep can deliver to,
///   and any loss belongs to the token, never to the treasury.
///
/// Where the outcome is ugly but inherent to a contract with no guard and no
/// admin, the test pins the real behaviour and the comment says so. Nothing here
/// can be fixed after deployment, so being written down is the whole remedy.
contract HostileTokensTest is BaseTest {
    /// Not the owner and not the beneficiary: every sweep below is pushed by a
    /// passer by, which is how it will actually be called.
    address internal stranger = vm.addr(0x57B);

    /// Ether parked in the treasury for the duration of a token test. Every
    /// token test ends by asserting this is still exactly where it was.
    uint256 internal constant PARKED = 3 ether;

    function _park() internal returns (uint256) {
        vm.deal(address(treasury), PARKED);
        return PARKED;
    }

    /// How many times a given event was emitted by the treasury, so a test can
    /// say "one balance, two logged deliveries" rather than hand wave at it.
    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(treasury) && logs[i].topics[0] == topic) ++n;
        }
    }

    /// The `to` an emitted Swept or SweptToken named, so a test can prove every
    /// single delivery in a run pointed at the beneficiary and nowhere else.
    function _everyDestinationWas(Vm.Log[] memory logs, bytes32 topic, uint256 addressTopic, address expected)
        internal
        view
        returns (bool)
    {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(treasury) || logs[i].topics[0] != topic) continue;
            if (address(uint160(uint256(logs[i].topics[addressTopic]))) != expected) return false;
        }
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                    A REENTRANCY THAT ACTUALLY COMPLETES
    //////////////////////////////////////////////////////////////*/

    /// The reentrant token in TreasuryAdversarial unwinds, because OpenZeppelin's
    /// _transfer runs out of balance on the way back out and reverts the lot. That
    /// is the token saving the treasury, not the treasury saving itself. This one
    /// keeps its own ledger and covers the shortfall by minting, so the outer
    /// transfer succeeds and the reentrancy runs to completion.
    ///
    /// The result is the honest one for an unguarded sweepToken: one balance, two
    /// SweptToken logs, twice the tokens delivered. It is pinned rather than fixed
    /// because nothing here is the treasury's to lose. The extra tokens came out
    /// of the token's own supply, both deliveries went to the beneficiary, and the
    /// ether never moved. A guard would only turn a token's self harm into a
    /// revert.
    function test_aTokenThatCoversTheShortfallCompletesTheDoubleSpendAndLogsItTwice() public {
        Doubler doubler = new Doubler(treasury);
        doubler.mint(address(treasury), 8 ether);
        uint256 parked = _park();

        vm.recordLogs();
        vm.prank(stranger);
        treasury.sweepToken(IERC20(address(doubler)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // One balance went out twice, and the treasury logged both legs.
        assertEq(_count(logs, Treasury.SweptToken.selector), 2, "the reentrancy did not complete");
        assertEq(doubler.balanceOf(beneficiary), 16 ether, "the beneficiary was not paid twice");
        assertEq(doubler.balanceOf(address(treasury)), 0, "the treasury still holds some");

        // The second eight ether was printed by the token, so the hole is in its
        // supply and not in anybody's balance.
        assertEq(doubler.minted(), 8 ether, "the shortfall came from somewhere else");

        // Both legs named the beneficiary. The destination is read from storage
        // the token cannot write, which is the reason a completed reentrancy is
        // still not a theft.
        assertTrue(_everyDestinationWas(logs, Treasury.SweptToken.selector, 2, beneficiary), "a leg went elsewhere");
        assertEq(doubler.balanceOf(address(doubler)), 0, "the token kept some for itself");
        assertEq(doubler.balanceOf(stranger), 0, "the pusher was paid");

        assertEq(address(treasury).balance, parked, "a token moved the ether");
        assertEq(address(doubler).balance, 0, "a token ended up holding ether");
    }

    /*//////////////////////////////////////////////////////////////
                        TOKENS THAT MISQUOTE THEMSELVES
    //////////////////////////////////////////////////////////////*/

    /// sweepToken trusts balanceOf for the amount and nothing else, so a token
    /// that quotes more than it will pay makes the transfer leg fail every time.
    /// The pinned consequence is the unpleasant one: the real balance is stuck
    /// here for good, because there is no sweepToken(token, amount) overload and
    /// no admin who could add one. Recovery would need the token itself to stop
    /// lying.
    function test_aTokenThatQuotesMoreThanItWillPayCanNeverBeSwept() public {
        Overstated liar = new Overstated();
        liar.mint(address(treasury), 10 ether);
        uint256 parked = _park();

        // Hoisted, because expectRevert watches the next call and this quote is
        // a call of its own.
        uint256 quoted = liar.balanceOf(address(treasury));
        assertEq(quoted, 30 ether, "the mock is not overstating");

        vm.prank(stranger);
        vm.expectRevert(bytes("overstated"));
        treasury.sweepToken(IERC20(address(liar)));

        assertEq(liar.held(address(treasury)), 10 ether, "the real balance is still here");
        assertEq(liar.held(beneficiary), 0, "and nothing reached the beneficiary");

        // Every later attempt reads the same inflated quote, so this is not a
        // retry problem. It is permanent while the token behaves this way.
        vm.expectRevert(bytes("overstated"));
        treasury.sweepToken(IERC20(address(liar)));

        // The one escape is the token telling the truth, which is outside anyone's
        // control here but worth showing is the only door.
        liar.tellTheTruth();
        vm.prank(stranger);
        treasury.sweepToken(IERC20(address(liar)));
        assertEq(liar.held(beneficiary), 10 ether, "recovered only by the token relenting");

        assertEq(address(treasury).balance, parked, "the ether was never in play");
    }

    /// The mirror image: a token that hands over more than it quoted. The
    /// treasury is emptied, the beneficiary receives everything, and the
    /// SweptToken log understates the delivery by half.
    ///
    /// Pinned because the log is the only record this contract will ever produce.
    /// Anybody reconciling royalties from logs will be short, in the opposite
    /// direction from the fee on transfer case, and neither is fixable later.
    function test_aTokenThatPaysMoreThanItQuotesEmptiesItselfAndUnderstatesTheLog() public {
        Generous gen = new Generous();
        gen.mint(address(treasury), 100 ether);
        uint256 parked = _park();

        // The log carries the quote, not the delivery.
        vm.expectEmit(true, true, false, true, address(treasury));
        emit Treasury.SweptToken(address(gen), beneficiary, 50 ether);
        vm.prank(stranger);
        treasury.sweepToken(IERC20(address(gen)));

        assertEq(gen.held(beneficiary), 100 ether, "the beneficiary got the quoted half only");
        assertEq(gen.held(address(treasury)), 0, "the treasury kept the difference");

        // Nothing is stranded: a second sweep has nothing left to find, which is
        // what separates this from the overstating token above.
        vm.expectRevert(Treasury.NothingToSweep.selector);
        treasury.sweepToken(IERC20(address(gen)));

        assertEq(address(treasury).balance, parked, "the ether was never in play");
    }

    /*//////////////////////////////////////////////////////////////
                         RETURN DATA AS A WEAPON
    //////////////////////////////////////////////////////////////*/

    /// A token whose transfer answers with two hundred kilobytes. A caller that
    /// collects the answer before reading it copies all of it into memory, and
    /// the quadratic memory price is the whole attack: it turns a cheap sweep
    /// into one that can be pushed past a block gas limit.
    ///
    /// SafeERC20 v5 reads one word straight out of the call's own output window
    /// and never touches returndatacopy, so the bomb does not go off. Measured
    /// against a spender that collects the answer as bytes, which is how
    /// SafeERC20 itself used to work, calling the identical token in the same
    /// transaction, so the comparison is not a guess about gas schedules.
    /// Rewriting sweepToken's transfer leg as a low level call that keeps the
    /// return data flips this test.
    function test_aTokenThatAnswersWithTwoHundredKilobytesIsSweptWithoutCopyingIt() public {
        Bomb bomb = new Bomb(6_250, true);
        bomb.mint(address(treasury), 5 ether);
        NaiveSpender naive = new NaiveSpender();
        bomb.mint(address(naive), 5 ether);
        uint256 parked = _park();

        vm.prank(stranger);
        uint256 before = gasleft();
        treasury.sweepToken(IERC20(address(bomb)));
        uint256 safeGas = before - gasleft();

        before = gasleft();
        naive.pay(address(bomb), carol, 5 ether);
        uint256 naiveGas = before - gasleft();

        assertEq(bomb.balanceOf(beneficiary), 5 ether, "the sweep did not deliver");
        assertEq(bomb.balanceOf(address(treasury)), 0, "emptied");

        // Both calls paid the token's own memory expansion. Only the naive one
        // paid for it a second time, on the way back.
        assertLt(safeGas, naiveGas, "the safe sweep cost more than a naive transfer");
        assertGt(naiveGas - safeGas, 50_000, "the return bomb was not actually defused");

        assertEq(address(treasury).balance, parked, "the ether was never in play");
    }

    /// The same bomb with a zero in the first word. Size is not what SafeERC20
    /// looks at, so this lands in the ordinary false return branch and is refused,
    /// which is the answer a huge return must never be allowed to smuggle past.
    function test_aHugeReturnValueThatDecodesToFalseIsStillAFailedTransfer() public {
        Bomb dud = new Bomb(6_250, false);
        dud.mint(address(treasury), 5 ether);
        uint256 parked = _park();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(dud)));
        treasury.sweepToken(IERC20(address(dud)));

        assertEq(dud.balanceOf(address(treasury)), 5 ether, "the balance is still here");
        assertEq(dud.balanceOf(beneficiary), 0, "nothing was delivered");
        assertEq(address(treasury).balance, parked, "the ether was never in play");
    }

    /*//////////////////////////////////////////////////////////////
                    BALANCES THAT MOVE UNDER THE READ
    //////////////////////////////////////////////////////////////*/

    /// sweepToken reads the balance through IERC20, where balanceOf is declared
    /// view, so the compiler emits a STATICCALL. A token that writes storage from
    /// balanceOf, which rebasing and accounting tokens do, cannot even be quoted:
    /// the read itself reverts and the sweep dies before the send.
    ///
    /// The mock's balanceOf is non view either way, and disarming only stops the
    /// write, so the second half proves the staticcall is what refuses it rather
    /// than the mutability keyword.
    function test_aTokenThatWritesStorageFromBalanceOfCannotEvenBeQuoted() public {
        Stateful acc = new Stateful();
        acc.mint(address(treasury), 4 ether);
        acc.arm(true);
        uint256 parked = _park();

        vm.prank(stranger);
        (bool ok, bytes memory why) =
            address(treasury).call(abi.encodeCall(Treasury.sweepToken, (IERC20(address(acc)))));
        assertFalse(ok, "the sweep went through");
        assertEq(why.length, 0, "it failed for some reason other than a refused staticcall");

        // The same read, typed two ways. Through IERC20 it is a staticcall and
        // dies on the write; through the mock's own type it is an ordinary call
        // and answers. That difference is the whole of the failure above.
        (bool asView,) = address(acc).staticcall(abi.encodeCall(IERC20.balanceOf, (address(treasury))));
        assertFalse(asView, "the write survived a staticcall");
        assertEq(acc.balanceOf(address(treasury)), 4 ether, "the mock cannot answer at all");
        assertEq(acc.reads(), 1, "the write never happened even when it was allowed to");

        assertEq(acc.held(address(treasury)), 4 ether, "the balance is still here");
        assertEq(acc.held(beneficiary), 0, "nothing was delivered");

        acc.arm(false);
        vm.prank(stranger);
        treasury.sweepToken(IERC20(address(acc)));
        assertEq(acc.held(beneficiary), 4 ether, "the same token sweeps once it stops writing");

        assertEq(address(treasury).balance, parked, "the ether was never in play");
    }

    /// The gap sweepToken cannot close: the amount is read, the event is emitted,
    /// and only then does the token get control and shrink the balance underneath
    /// the number already decided. The stale amount is now more than is there.
    ///
    /// The outcome is the safe one, an arithmetic panic that takes the whole sweep
    /// with it, so no phantom balance is delivered out of another holder's
    /// pocket. The cost is that such a token can never be swept at all, which is
    /// pinned here as a property rather than a bug.
    function test_aTokenThatShrinksTheBalanceInsideItsOwnTransferCanNeverBeSwept() public {
        Rebasing reb = new Rebasing();
        reb.mint(address(treasury), 4 ether);
        reb.mint(bob, 100 ether);
        reb.arm(true);
        uint256 parked = _park();

        vm.prank(stranger);
        vm.expectRevert(stdError.arithmeticError);
        treasury.sweepToken(IERC20(address(reb)));

        assertEq(reb.balanceOf(address(treasury)), 4 ether, "the rebase was rolled back with the sweep");
        assertEq(reb.balanceOf(beneficiary), 0, "nothing was delivered");
        assertEq(reb.balanceOf(bob), 100 ether, "the shortfall was paid out of another holder");

        // Retrying changes nothing, because the shrink happens inside the same
        // call every time.
        vm.expectRevert(stdError.arithmeticError);
        treasury.sweepToken(IERC20(address(reb)));

        reb.arm(false);
        vm.prank(stranger);
        treasury.sweepToken(IERC20(address(reb)));
        assertEq(reb.balanceOf(beneficiary), 4 ether, "sweeps normally once it holds still");

        assertEq(address(treasury).balance, parked, "the ether was never in play");
    }

    /*//////////////////////////////////////////////////////////////
                          THE CLAIM, AS ONE TABLE
    //////////////////////////////////////////////////////////////*/

    /// The single sentence worth quoting: no token, however it behaves, takes a
    /// wei of the treasury's ether for itself or sends one anywhere but the
    /// beneficiary. The expected outcomes differ per token on purpose, so this
    /// table cannot quietly collapse into eight reverts and still look green.
    ///
    /// The two Looper rows are the tokens that reach for the ether, calling
    /// sweep from inside their own transfer. Once pays the beneficiary early.
    /// Twice finds nothing left the second time, and NothingToSweep takes the
    /// whole token sweep down with it, the first ether sweep included.
    function test_noneOfTheseTokensTakesAWeiOfTheTreasurysEther() public {
        address[8] memory tokens = [
            address(new Doubler(treasury)),
            address(new Overstated()),
            address(new Generous()),
            address(new Bomb(1_000, true)),
            address(new Stateful()),
            address(new Rebasing()),
            address(new Looper(treasury, 1)),
            address(new Looper(treasury, 2))
        ];
        bool[8] memory sweeps = [true, false, true, true, false, false, true, false];
        bool[8] memory pushesEther = [false, false, false, false, false, false, true, false];

        // Stateful and Rebasing are inert until armed, which is what makes them
        // the interesting two rows here.
        Stateful(tokens[4]).arm(true);
        Rebasing(tokens[5]).arm(true);

        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 parked = _park();
            uint256 before = beneficiary.balance;

            (bool minted,) =
                tokens[i].call(abi.encodeWithSignature("mint(address,uint256)", address(treasury), 1 ether));
            assertTrue(minted, "the mock would not fund itself");

            vm.prank(stranger);
            (bool swept,) = address(treasury).call(abi.encodeCall(Treasury.sweepToken, (IERC20(tokens[i]))));
            assertEq(swept, sweeps[i], "the token sweep took the wrong branch");

            uint256 pushed = pushesEther[i] ? parked : 0;
            assertEq(address(treasury).balance, parked - pushed, "a token moved the ether");
            assertEq(beneficiary.balance, before + pushed, "the ether went somewhere other than the beneficiary");
            assertEq(tokens[i].balance, 0, "a token ended up holding ether");
            assertEq(stranger.balance, 0, "the pusher was paid");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ETHER, THE SAME DISCIPLINE
    //////////////////////////////////////////////////////////////*/

    /// sweep has no guard either, and the beneficiary gets control while holding
    /// the money. The reentrant beneficiary in TreasuryAdversarial fails on the
    /// second leg because the balance is already gone. This one refills the
    /// treasury out of its own pocket first, so every re-entered sweep succeeds
    /// and the recursion runs to its own chosen depth.
    ///
    /// What it buys is nothing. The logs claim four deliveries for one, which an
    /// indexer will believe, but the extra three were its own ether going out and
    /// coming back. Net, it holds what it started with plus what it was owed, and
    /// the treasury is empty exactly once.
    function test_aBeneficiaryThatRefundsAndReentersSweepInflatesTheLogsAndNothingElse() public {
        Rebounder greedy = new Rebounder(treasury);
        vm.deal(address(greedy), 5 ether);
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(address(greedy));

        _buy(alice, 21);
        nft.withdraw();
        uint256 held = address(treasury).balance;
        assertGt(held, 0, "the takings arrived");

        vm.recordLogs();
        vm.prank(stranger);
        treasury.sweep();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(greedy.laps(), 3, "the reentrancy did not run");
        assertEq(_count(logs, Treasury.Swept.selector), 4, "one sweep per lap, plus the first");

        // Every lap paid the same address, because the destination is storage the
        // beneficiary is not allowed to write.
        assertTrue(_everyDestinationWas(logs, Treasury.Swept.selector, 1, address(greedy)), "a lap paid elsewhere");

        // The books, which the logs do not match: four deliveries logged, one
        // balance actually moved.
        assertEq(address(greedy).balance, 5 ether + held, "it came out ahead or behind");
        assertEq(address(treasury).balance, 0, "the treasury is not empty");
        assertEq(stranger.balance, 0, "the pusher was paid");

        // And the treasury logged the refunds it received on the way, so the
        // round trip is at least visible to anyone reading both events.
        assertEq(_count(logs, Treasury.Received.selector), 3, "the refunds were not recorded");
    }

    /// Pointing the treasury at itself is already known to make sweep a logged no
    /// op. The part worth pinning is that it removes the backstop: a self sweep
    /// can never fail for lack of balance, so hostile code with the floor can loop
    /// it as long as it likes and mint an unbounded run of Swept events, each one
    /// claiming the full balance was paid out. The ether does not move a wei, and
    /// no address but the treasury is ever named.
    function test_withTheTreasuryAsItsOwnBeneficiarySweepCanBeLoggedOverAndOver() public {
        Looper looper = new Looper(treasury, 5);
        looper.mint(address(treasury), 2 ether);
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(address(treasury));
        uint256 parked = _park();

        vm.recordLogs();
        vm.prank(stranger);
        treasury.sweepToken(IERC20(address(looper)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(looper.laps(), 5, "the loop did not run");
        assertEq(_count(logs, Treasury.Swept.selector), 5, "five payments were logged and one was not");
        assertTrue(
            _everyDestinationWas(logs, Treasury.Swept.selector, 1, address(treasury)), "a lap named another address"
        );

        assertEq(address(treasury).balance, parked, "a wei actually moved");
        assertEq(address(looper).balance, 0, "the token ended up holding ether");
        assertEq(looper.balanceOf(address(treasury)), 2 ether, "the tokens went somewhere");

        // One repoint undoes the whole thing, for ether and for the tokens.
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(carol);
        uint256 before = carol.balance;
        vm.prank(stranger);
        treasury.sweep();
        assertEq(carol.balance, before + parked, "recovered");
    }

    /*//////////////////////////////////////////////////////////////
                       ASSETS NOBODY PLANNED FOR
    //////////////////////////////////////////////////////////////*/

    /// The treasury knows about ether and ERC20. An ERC-721 is neither. The safe
    /// door is shut, because there is no onERC721Received here, so a careful
    /// sender cannot make this mistake. transferFrom has no such check, and after
    /// it lands the token is the treasury's forever: there is no function on this
    /// contract that can call transferFrom on anything, and no admin to add one.
    ///
    /// Written down as a test so the limitation is a decision on the record rather
    /// than a discovery made by whoever sends the first airdrop.
    function test_anErc721ThroughTheUnsafeDoorCanNeverBeGotBackOut() public {
        Collectible col = new Collectible();
        col.mint(alice, 7);

        // The safe door refuses, naming the treasury as the bad receiver.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(treasury)));
        col.safeTransferFrom(alice, address(treasury), 7);

        vm.prank(alice);
        col.transferFrom(alice, address(treasury), 7);
        assertEq(col.ownerOf(7), address(treasury), "it did not land");

        // sweepToken is the only token shaped function here, and an ERC-721
        // answers balanceOf(address) with a count of tokens, so the quote even
        // succeeds. The transfer(address,uint256) leg then hits a contract with
        // no such function and no fallback.
        uint256 quoted = col.balanceOf(address(treasury));
        assertEq(quoted, 1, "balanceOf(address) did not answer");
        (bool swept, bytes memory why) =
            address(treasury).call(abi.encodeCall(Treasury.sweepToken, (IERC20(address(col)))));
        assertFalse(swept, "an ERC-721 was swept as if it were an ERC20");
        assertEq(why.length, 0, "it failed somewhere other than the missing transfer");

        // Nothing else on the treasury reaches it either, under any name an
        // operator might hope for.
        string[4] memory hopes = [
            "sweep721(address,uint256)",
            "rescueERC721(address,uint256)",
            "transferERC721(address,address,uint256)",
            "execute(address,bytes)"
        ];
        for (uint256 i = 0; i < hopes.length; ++i) {
            (bool ok,) = address(treasury).call(abi.encodeWithSignature(hopes[i], address(col), uint256(7)));
            assertFalse(ok, string.concat("the treasury answered ", hopes[i]));
        }

        // Not even the owner, who is the only key in the system.
        vm.prank(treasuryOwner);
        (bool byOwner,) = address(treasury).call(abi.encodeWithSignature("rescueERC721(address,uint256)", col, 7));
        assertFalse(byOwner, "the owner has a rescue after all");

        assertEq(col.ownerOf(7), address(treasury), "stuck, permanently");
    }

    /// The same for an ERC-1155, and the door is the same shape: a conformant
    /// transfer asks the treasury to acknowledge the receipt and gets nothing
    /// back, so it reverts. A token that skips the acknowledgement, or a mint
    /// that writes the balance directly, puts it here anyway and it stays.
    ///
    /// sweepToken cannot even quote this one, because an ERC-1155 balance takes
    /// an id and the selector does not exist.
    function test_anErc1155ThroughTheUnsafeDoorCanNeverBeGotBackOutEither() public {
        Sticker sticker = new Sticker();
        sticker.drop(alice, 3, 10);

        vm.prank(alice);
        (bool safe,) =
            address(sticker).call(abi.encodeCall(Sticker.safeTransferFrom, (alice, address(treasury), 3, 10, "")));
        assertFalse(safe, "the treasury acknowledged an ERC-1155 receipt");
        assertEq(sticker.balanceOf(alice, 3), 10, "and the balance stayed with the sender");

        sticker.drop(address(treasury), 3, 10);
        assertEq(sticker.balanceOf(address(treasury), 3), 10, "it landed");

        (bool swept,) = address(treasury).call(abi.encodeCall(Treasury.sweepToken, (IERC20(address(sticker)))));
        assertFalse(swept, "an ERC-1155 was quoted as if it were an ERC20");

        string[3] memory hopes =
            ["sweep1155(address,uint256)", "rescueERC1155(address,uint256)", "sweepToken(address,uint256)"];
        for (uint256 i = 0; i < hopes.length; ++i) {
            (bool ok,) = address(treasury).call(abi.encodeWithSignature(hopes[i], address(sticker), uint256(3)));
            assertFalse(ok, string.concat("the treasury answered ", hopes[i]));
        }

        assertEq(sticker.balanceOf(address(treasury), 3), 10, "stuck, permanently");
    }

    /// The consolation, and the reason the two tests above are a documented
    /// limitation rather than a hole: stuck collectibles are inert. They do not
    /// jam the two functions that matter, and the money still leaves on demand.
    function test_stuckCollectiblesDoNotStopEtherOrTokensFromSweeping() public {
        Collectible col = new Collectible();
        col.mint(address(treasury), 7);
        Sticker sticker = new Sticker();
        sticker.drop(address(treasury), 3, 10);

        MockERC20 weth = new MockERC20();
        weth.mint(address(treasury), 6 ether);
        _buy(alice, 22);
        nft.withdraw();
        uint256 held = address(treasury).balance;

        uint256 before = beneficiary.balance;
        vm.prank(stranger);
        treasury.sweep();
        vm.prank(stranger);
        treasury.sweepToken(weth);

        assertEq(beneficiary.balance, before + held, "the ether still leaves");
        assertEq(weth.balanceOf(beneficiary), 6 ether, "and the tokens still leave");
        assertEq(col.ownerOf(7), address(treasury), "while the ERC-721 sits there");
        assertEq(sticker.balanceOf(address(treasury), 3), 10, "and so does the ERC-1155");
    }
}

/*//////////////////////////////////////////////////////////////
                        TOKENS WITH THEIR OWN LEDGER
//////////////////////////////////////////////////////////////*/

/// Re-enters sweepToken and then covers the double spend by printing the
/// shortfall, so the outer transfer succeeds instead of unwinding.
contract Doubler {
    Treasury private immutable TREASURY;

    mapping(address => uint256) public balanceOf;
    uint256 public minted;
    bool private entered;

    constructor(Treasury t) {
        TREASURY = t;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (!entered) {
            entered = true;
            TREASURY.sweepToken(IERC20(address(this)));
        }
        if (balanceOf[msg.sender] < amount) {
            uint256 short = amount - balanceOf[msg.sender];
            balanceOf[msg.sender] += short;
            minted += short;
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Quotes three times what it holds and refuses to pay the quote.
contract Overstated {
    mapping(address => uint256) private ledger;
    uint256 private multiplier = 3;

    function mint(address to, uint256 amount) external {
        ledger[to] += amount;
    }

    function tellTheTruth() external {
        multiplier = 1;
    }

    function held(address who) external view returns (uint256) {
        return ledger[who];
    }

    function balanceOf(address who) external view returns (uint256) {
        return ledger[who] * multiplier;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (amount > ledger[msg.sender]) revert("overstated");
        ledger[msg.sender] -= amount;
        ledger[to] += amount;
        return true;
    }
}

/// Quotes half of what it holds and pays out double whatever it is asked for.
contract Generous {
    mapping(address => uint256) private ledger;

    function mint(address to, uint256 amount) external {
        ledger[to] += amount;
    }

    function held(address who) external view returns (uint256) {
        return ledger[who];
    }

    function balanceOf(address who) external view returns (uint256) {
        return ledger[who] / 2;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 pay = amount * 2;
        if (pay > ledger[msg.sender]) pay = ledger[msg.sender];
        ledger[msg.sender] -= pay;
        ledger[to] += pay;
        return true;
    }
}

/// Moves the balance and then answers with a very large block of return data.
/// The first word decides whether a caller reads it as true or false; the rest
/// exists to make anyone who copies it pay for the memory.
contract Bomb {
    uint256 private immutable WORDS;
    bool private immutable TRUTHY;

    mapping(address => uint256) public balanceOf;

    constructor(uint256 words, bool truthy) {
        WORDS = words;
        TRUTHY = truthy;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        uint256 size = WORDS * 32;
        bool truthy = TRUTHY;
        assembly ("memory-safe") {
            mstore(0x00, truthy)
            return(0x00, size)
        }
    }
}

/// Collects a transfer's answer as bytes before looking at it, which copies
/// every byte of it into memory. This is how SafeERC20 itself was written before
/// v5, and it is the yardstick the treasury is measured against.
contract NaiveSpender {
    function pay(address token, address to, uint256 amount) external {
        (bool ok, bytes memory answer) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        require(ok, "naive call failed");
        require(answer.length == 0 || abi.decode(answer, (bool)), "naive transfer refused");
    }
}

/// Writes storage from balanceOf, the way a rebasing or interest accruing token
/// does. Arming only switches the write on; the function is non view either way.
contract Stateful {
    mapping(address => uint256) private ledger;
    bool private armed;
    uint256 public reads;

    function mint(address to, uint256 amount) external {
        ledger[to] += amount;
    }

    function arm(bool on) external {
        armed = on;
    }

    function held(address who) external view returns (uint256) {
        return ledger[who];
    }

    function balanceOf(address who) external returns (uint256) {
        if (armed) reads += 1;
        return ledger[who];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        ledger[msg.sender] -= amount;
        ledger[to] += amount;
        return true;
    }
}

/// Shrinks the sender's balance as the first act of transfer, so the amount the
/// treasury read a moment earlier is already too large.
contract Rebasing {
    mapping(address => uint256) public balanceOf;
    bool private armed;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function arm(bool on) external {
        armed = on;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (armed) balanceOf[msg.sender] /= 2;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Calls sweep from inside its own transfer, a fixed number of times, to see
/// what a self dealing treasury does when it can never run out.
contract Looper {
    Treasury private immutable TREASURY;
    uint256 private immutable TARGET;

    mapping(address => uint256) public balanceOf;
    uint256 public laps;

    constructor(Treasury t, uint256 target) {
        TREASURY = t;
        TARGET = target;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        while (laps < TARGET) {
            laps += 1;
            TREASURY.sweep();
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/*//////////////////////////////////////////////////////////////
                        A BENEFICIARY THAT REFUNDS
//////////////////////////////////////////////////////////////*/

/// Takes its payment, hands some of its own ether back to the treasury, and
/// sweeps again, so each re-entry has something real to move.
contract Rebounder {
    Treasury private immutable TREASURY;
    uint256 private constant LAPS = 3;
    uint256 private constant REFUND = 1 ether;

    uint256 public laps;

    constructor(Treasury t) {
        TREASURY = t;
    }

    receive() external payable {
        if (laps >= LAPS) return;
        laps += 1;
        (bool ok,) = payable(address(TREASURY)).call{value: REFUND}("");
        require(ok, "refund refused");
        TREASURY.sweep();
    }
}

/*//////////////////////////////////////////////////////////////
                    ASSETS THE TREASURY CANNOT HOLD
//////////////////////////////////////////////////////////////*/

/// A plain ERC-721, so the unsafe door is the real one and not a mock's shortcut.
contract Collectible is ERC721 {
    constructor() ERC721("Collectible", "COL") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// The smallest ERC-1155 that still asks a contract recipient to acknowledge the
/// receipt, plus a drop that skips the question the way a careless airdrop does.
contract Sticker {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    function drop(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {
        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;
        if (to.code.length > 0) {
            bytes4 answer = IERC1155ReceiverLike(to).onERC1155Received(msg.sender, from, id, amount, data);
            require(answer == IERC1155ReceiverLike.onERC1155Received.selector, "bad receiver");
        }
    }
}

interface IERC1155ReceiverLike {
    function onERC1155Received(address operator, address from, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (bytes4);
}
