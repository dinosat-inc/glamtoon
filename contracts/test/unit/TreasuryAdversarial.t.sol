// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {Treasury} from "../../src/Treasury.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin/access/Ownable2Step.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {Errors} from "openzeppelin/utils/Errors.sol";

/// Every attacker mock in this suite points at the token. Nothing points at the
/// treasury, which is the one contract that holds the money and the one contract
/// with a key. Its two push functions both hand control to an address the owner
/// chose, and neither has a reentrancy guard, so the safety has to come from the
/// order the statements are written in. These tests attack that order.
///
/// The standing claim: a hostile beneficiary or a hostile token can stop a
/// sweep, but can never take more than it was owed, can never reach the ether
/// while a token is moving, and can never make the money unrecoverable, because
/// the owner can always repoint and push again.
contract TreasuryAdversarialTest is BaseTest {
    /// Not the owner and not the beneficiary, so a successful push proves the
    /// push is permissionless rather than that the caller was privileged.
    address internal stranger = vm.addr(0x57A);

    /// Sweep through a raw call with a gas ceiling, so a beneficiary that eats
    /// every drop of gas it is handed cannot take the test process down with it.
    /// 1M is an order of magnitude more than an honest sweep needs.
    function _trySweep() internal returns (bool ok) {
        (ok,) = address(treasury).call{gas: 1_000_000}(abi.encodeCall(Treasury.sweep, ()));
    }

    /// Real sale money rather than vm.deal, for the tests where the point is
    /// that takings survive.
    function _takings(uint256 imageId) internal returns (uint256 held) {
        _buy(alice, imageId);
        nft.withdraw();
        held = address(treasury).balance;
        assertGt(held, 0, "the takings arrived");
    }

    /*//////////////////////////////////////////////////////////////
                         BENEFICIARIES THAT REFUSE
    //////////////////////////////////////////////////////////////*/

    /// A beneficiary that reverts with nothing at all is the branch that turns
    /// into FailedCall rather than a bubbled string, and a bare expectRevert
    /// would pass on either. Named exactly, because the difference between the
    /// two branches is the difference between a beneficiary that refused and a
    /// send that never happened.
    function test_aBeneficiaryThatRevertsSilentlyFailsTheSweepWithFailedCall() public {
        Mute refuser = new Mute();
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(address(refuser));

        uint256 held = _takings(11);

        vm.prank(stranger);
        vm.expectRevert(Errors.FailedCall.selector);
        treasury.sweep();

        assertEq(address(treasury).balance, held, "the ether never left");
        assertEq(address(refuser).balance, 0, "and the refuser took nothing");

        // The Swept log is emitted before the send, so the only thing keeping it
        // from promising a payment that did not happen is the sweep reverting.
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(carol);
        uint256 before = carol.balance;
        vm.prank(stranger);
        treasury.sweep();
        assertEq(carol.balance, before + held, "the same wei, delivered later");
    }

    /// An empty treasury refuses before it calls anyone, so a beneficiary that
    /// refuses ether cannot change the reason. Catches the zero check moved
    /// below the send, where the refuser's own FailedCall would surface instead.
    function test_anEmptySweepNeverCallsTheBeneficiary() public {
        Mute refuser = new Mute();
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(address(refuser));

        vm.prank(stranger);
        vm.expectRevert(Treasury.NothingToSweep.selector);
        treasury.sweep();
    }

    /// A beneficiary with no receive and no fallback at all: the sweep call
    /// reverts empty from the EVM rather than from any code, which is the same
    /// FailedCall branch reached by a different road.
    function test_aBeneficiaryThatIsAContractWithNoReceiveCannotBePaid() public {
        Helpless deaf = new Helpless();
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(address(deaf));

        uint256 held = _takings(12);

        vm.expectRevert(Errors.FailedCall.selector);
        treasury.sweep();
        assertEq(address(treasury).balance, held, "still here");

        vm.prank(treasuryOwner);
        treasury.setBeneficiary(carol);
        uint256 before = carol.balance;
        vm.prank(stranger);
        treasury.sweep();

        assertEq(carol.balance, before + held, "recovered by repointing");
        assertEq(address(deaf).balance, 0, "the deaf contract never held a wei");
    }

    /// sendValue forwards all the gas it has, so a beneficiary that loops
    /// forever burns the sweep down. The thing to prove is that it only costs
    /// the pusher their gas: the balance is untouched and the next sweep, after
    /// a repoint, still finds every wei.
    function test_aBeneficiaryThatEatsAllTheGasStopsTheSweepAndNothingElse() public {
        GasPit pit = new GasPit();
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(address(pit));

        uint256 held = _takings(13);

        vm.prank(stranger);
        assertFalse(_trySweep(), "the sweep should not have survived");
        assertEq(address(treasury).balance, held, "the ether never left");
        assertEq(address(pit).balance, 0, "the pit got nothing");

        vm.prank(treasuryOwner);
        treasury.setBeneficiary(carol);
        uint256 before = carol.balance;
        vm.prank(stranger);
        assertTrue(_trySweep(), "and the money was never actually stuck");
        assertEq(carol.balance, before + held, "recovered");
    }

    /// The summary the audit asked for: whatever the beneficiary does, a failed
    /// sweep is a no-op. Run as one table so a future change that starts sending
    /// before it checks, or that swallows the send result, fails here loudly
    /// rather than in one specialised test.
    function test_noHostileBeneficiaryCanMoveOrDestroyTheHeldEther() public {
        address[3] memory hostiles = [address(new Mute()), address(new Helpless()), address(new GasPit())];

        for (uint256 i = 0; i < hostiles.length; ++i) {
            vm.prank(treasuryOwner);
            treasury.setBeneficiary(hostiles[i]);

            vm.deal(address(treasury), 7 ether);
            vm.prank(stranger);
            assertFalse(_trySweep(), "a hostile beneficiary was paid");

            assertEq(address(treasury).balance, 7 ether, "balance moved on a failed sweep");
            assertEq(hostiles[i].balance, 0, "the hostile address gained ether");
            assertEq(treasury.beneficiary(), hostiles[i], "a failed sweep rewrote the beneficiary");
            assertEq(treasury.owner(), treasuryOwner, "a failed sweep touched the owner");
        }
    }

    /// The other half of the gas question, and the one that would bite in
    /// production: the beneficiary is meant to be a multisig, and a multisig's
    /// receive writes storage. A sweep that forwarded a 2300 gas stipend would
    /// pass every hostile test above and still fail to pay the only address
    /// this contract was built to pay.
    function test_anExpensiveButHonestBeneficiaryIsStillPaid() public {
        Multisig safe = new Multisig();
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(address(safe));

        uint256 held = _takings(18);

        vm.prank(stranger);
        treasury.sweep();

        assertEq(address(safe).balance, held, "a storage writing receive was paid");
        assertEq(safe.deliveries(), 1, "and it ran its own accounting once");
        assertEq(address(treasury).balance, 0, "emptied");
    }

    /// A refusal is not a loss of the key either: the owner can still repoint
    /// while the treasury is pointed at an address that cannot be paid. Worth
    /// its own assertion because a design that guarded sweep with a lock taken
    /// on failure would deadlock here.
    function test_theOwnerCanStillRepointWhileTheBeneficiaryIsRefusing() public {
        Mute refuser = new Mute();
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(address(refuser));
        vm.deal(address(treasury), 1 ether);

        assertFalse(_trySweep(), "refused");

        vm.prank(treasuryOwner);
        treasury.transferOwnership(bob);
        vm.prank(bob);
        treasury.acceptOwnership();
        vm.prank(bob);
        treasury.setBeneficiary(carol);

        uint256 before = carol.balance;
        vm.prank(stranger);
        treasury.sweep();
        assertEq(carol.balance, before + 1 ether, "the new owner freed it");
    }

    /*//////////////////////////////////////////////////////////////
                       A BENEFICIARY THAT RE-ENTERS
    //////////////////////////////////////////////////////////////*/

    /// Neither push function is guarded, so the beneficiary gets a live turn in
    /// the middle of a sweep and can call anything. It calls all three doors.
    /// What it must not get is a second payment, a wei more than the balance, or
    /// the right to repoint the treasury at itself for good.
    function test_aBeneficiaryReenteringEveryDoorGetsExactlyWhatItWasOwed() public {
        MockERC20 weth = new MockERC20();
        Greedy greedy = new Greedy(treasury, IERC20(address(weth)));

        vm.prank(treasuryOwner);
        treasury.setBeneficiary(address(greedy));
        weth.mint(address(treasury), 4 ether);
        uint256 held = _takings(14);

        vm.prank(stranger);
        treasury.sweep();

        assertEq(greedy.arrivals(), 1, "paid once, not once per re-entry");
        assertEq(address(greedy).balance, held, "and paid exactly the balance");
        assertEq(address(treasury).balance, 0, "emptied exactly once");

        // The balance is gone before it gets control, so its own sweep finds
        // nothing. That, not a guard, is what makes this safe.
        assertTrue(greedy.sweepAgainFailed(), "a second sweep drew ether that was already sent");

        // It can pull the token balance mid-sweep, but only to itself, because
        // it is the beneficiary. That is the whole reach of the missing guard.
        assertTrue(greedy.tokenSweepWorked(), "the token sweep behaved differently than expected");
        assertEq(weth.balanceOf(address(greedy)), 4 ether, "tokens went to the beneficiary");
        assertEq(weth.balanceOf(address(treasury)), 0, "and not a wei of it stayed");

        // Being paid is not being in charge.
        assertTrue(greedy.repointFailed(), "the beneficiary repointed the treasury");
        assertEq(treasury.owner(), treasuryOwner, "owner untouched");
    }

    /*//////////////////////////////////////////////////////////////
                             HOSTILE TOKENS
    //////////////////////////////////////////////////////////////*/

    /// The whole reason sweepToken goes through SafeERC20: a token that answers
    /// false has to be treated as a failure, not as a delivery.
    function test_aTokenThatReturnsFalseIsTreatedAsAFailedTransfer() public {
        Liar liar = new Liar();
        liar.mint(address(treasury), 5 ether);
        vm.deal(address(treasury), 3 ether);

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(liar)));
        treasury.sweepToken(IERC20(address(liar)));

        assertEq(liar.balanceOf(address(treasury)), 5 ether, "the balance is still here");
        assertEq(liar.balanceOf(beneficiary), 0, "and nothing was delivered");
        assertEq(address(treasury).balance, 3 ether, "the ether was not touched");
    }

    /// The other half of the same reason: the tokens that return nothing at all,
    /// which a plain IERC20 call would reject. Royalties really do arrive in
    /// these, so this path has to work rather than merely not lose money.
    function test_aTokenThatReturnsNothingAtAllIsStillSwept() public {
        Silent usdt = new Silent();
        usdt.mint(address(treasury), 6 ether);

        vm.expectEmit(true, true, false, true, address(treasury));
        emit Treasury.SweptToken(address(usdt), beneficiary, 6 ether);
        vm.prank(stranger);
        treasury.sweepToken(IERC20(address(usdt)));

        assertEq(usdt.balanceOf(beneficiary), 6 ether, "delivered");
        assertEq(usdt.balanceOf(address(treasury)), 0, "emptied");
    }

    /// A token that reverts has to surface its own reason, not a generic one,
    /// or nobody debugging a stuck royalty will know whether they were frozen
    /// or whether the treasury is broken.
    function test_aTokenThatRevertsBubblesItsOwnReason() public {
        Frozen frozen = new Frozen();
        frozen.mint(address(treasury), 2 ether);
        vm.deal(address(treasury), 3 ether);

        vm.expectRevert(bytes("frozen"));
        treasury.sweepToken(IERC20(address(frozen)));

        assertEq(frozen.balanceOf(address(treasury)), 2 ether, "still held");
        assertEq(address(treasury).balance, 3 ether, "the ether was not touched");
    }

    /// The same order for tokens. Some tokens refuse a transfer of zero, and an
    /// empty token sweep still says NothingToSweep rather than bubbling the
    /// token's own refusal, because it never asks the token to move anything.
    function test_anEmptyTokenSweepNeverCallsTheToken() public {
        Frozen frozen = new Frozen();

        vm.prank(stranger);
        vm.expectRevert(Treasury.NothingToSweep.selector);
        treasury.sweepToken(IERC20(address(frozen)));
    }

    /// sweepToken takes an address from the caller, and anyone may call it. An
    /// address with no code behind it must fail on the balance read rather than
    /// be treated as a zero balance or, worse, as a successful transfer. The
    /// read fails, and never with the NothingToSweep a zero balance would give.
    function test_anAddressWithNoCodeIsNotASweepableToken() public {
        vm.deal(address(treasury), 3 ether);
        address[2] memory empties = [address(0xDEAD), alice];

        for (uint256 i = 0; i < empties.length; ++i) {
            try treasury.sweepToken(IERC20(empties[i])) {
                fail();
            } catch (bytes memory err) {
                bool zeroBalance = err.length == 4 && bytes4(err) == Treasury.NothingToSweep.selector;
                assertFalse(zeroBalance, "an empty account was read as a balance");
            }
        }

        assertEq(address(treasury).balance, 3 ether, "no ether moved on either attempt");
    }

    /// A fee-on-transfer token makes the log lie: SweptToken reports the balance
    /// that left, and the beneficiary receives less. Nothing here is a loss for
    /// the treasury, but an accountant reconciling the logs will be short, and
    /// the log is not fixable after deployment. Asserted so the discrepancy is a
    /// documented property rather than a surprise during the audit.
    function test_aFeeOnTransferTokenLogsMoreThanTheBeneficiaryReceives() public {
        FeeOnTransfer fee = new FeeOnTransfer(carol);
        fee.mint(address(treasury), 100 ether);
        uint256 expectedFee = 2.5 ether; // 250 bps of 100

        vm.expectEmit(true, true, false, true, address(treasury));
        emit Treasury.SweptToken(address(fee), beneficiary, 100 ether);
        vm.prank(stranger);
        treasury.sweepToken(IERC20(address(fee)));

        assertEq(fee.balanceOf(beneficiary), 100 ether - expectedFee, "delivered less than logged");
        assertEq(fee.balanceOf(carol), expectedFee, "the fee went to the token's collector");
        assertEq(fee.balanceOf(address(treasury)), 0, "the treasury is still emptied");

        // And the shortfall is the token's, not the treasury's: a second sweep
        // has nothing to find, so no wei is sitting stranded here.
        vm.expectRevert(Treasury.NothingToSweep.selector);
        treasury.sweepToken(IERC20(address(fee)));
    }

    /// The nastiest token shape: transfer calls sweepToken again before it moves
    /// anything, so the treasury emits two deliveries for one balance. The inner
    /// leg drains the balance, the outer leg then finds nothing to move, and the
    /// whole thing unwinds. What must not happen is one balance leaving as two
    /// logged payments.
    function test_aTokenThatReEntersSweepTokenUnwindsTheWholeSweep() public {
        Recursive rec = new Recursive(treasury);
        rec.mint(address(treasury), 8 ether);
        rec.arm(true);
        vm.deal(address(treasury), 3 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(treasury), 0, 8 ether)
        );
        vm.prank(stranger);
        treasury.sweepToken(IERC20(address(rec)));

        assertEq(rec.balanceOf(address(treasury)), 8 ether, "the balance came back");
        assertEq(rec.balanceOf(beneficiary), 0, "and nothing was delivered twice");
        assertEq(address(treasury).balance, 3 ether, "the ether was never in play");

        // Disarmed, the same token sweeps normally, so the revert above is the
        // reentrancy and not the mock being broken.
        rec.arm(false);
        vm.prank(stranger);
        treasury.sweepToken(IERC20(address(rec)));
        assertEq(rec.balanceOf(beneficiary), 8 ether, "delivered once");
    }

    /// A token's transfer is the one place hostile code runs while the treasury
    /// still holds its ether. It can start an ether sweep from in there, and the
    /// sweep will go through, but the destination is read from storage the token
    /// cannot write. So the worst it achieves is paying the beneficiary early.
    function test_aTokenThatReachesForTheEtherCanOnlyPushItToTheBeneficiary() public {
        Grabby grabby = new Grabby(treasury);
        grabby.mint(address(treasury), 9 ether);
        uint256 held = _takings(15);
        uint256 before = beneficiary.balance;

        vm.prank(stranger);
        treasury.sweepToken(IERC20(address(grabby)));

        assertTrue(grabby.sweptEther(), "the token never got its turn");
        assertEq(address(grabby).balance, 0, "the token took ether");
        assertEq(beneficiary.balance, before + held, "the ether reached the beneficiary and only it");
        assertEq(grabby.balanceOf(beneficiary), 9 ether, "and the tokens followed");
        assertEq(address(treasury).balance, 0, "treasury emptied, not overdrawn");
        assertEq(stranger.balance, 0, "the pusher kept nothing");
    }

    /// The table version of the claim: no token shape takes a wei of ether for
    /// itself or sends one anywhere but the beneficiary. Deliberately includes
    /// the tokens that succeed, since the question is about ether, not about the
    /// transfer, and the one that starts an ether sweep from inside its own
    /// transfer, which is the only way a token can move the ether at all.
    function test_noHostileTokenTakesAWeiOfTheTreasurysEther() public {
        address[6] memory tokens = [
            address(new Liar()),
            address(new Frozen()),
            address(new Silent()),
            address(new FeeOnTransfer(carol)),
            address(new Recursive(treasury)),
            address(new Grabby(treasury))
        ];
        // The first two must be refused and the rest must go through, so this
        // table cannot quietly turn into six reverts and still look green.
        bool[6] memory delivers = [false, false, true, true, true, true];
        // Grabby pushes the ether out early, and only ever to the beneficiary.
        bool[6] memory pushesEther = [false, false, false, false, false, true];

        for (uint256 i = 0; i < tokens.length; ++i) {
            vm.deal(address(treasury), 5 ether);
            uint256 before = beneficiary.balance;

            // Same mint selector on every mock, hostile or not.
            (bool minted,) =
                tokens[i].call(abi.encodeWithSignature("mint(address,uint256)", address(treasury), 1 ether));
            assertTrue(minted, "the mock would not fund itself");

            (bool swept,) = address(treasury).call(abi.encodeCall(Treasury.sweepToken, (IERC20(tokens[i]))));
            assertEq(swept, delivers[i], "the token sweep took the wrong branch");

            uint256 pushed = pushesEther[i] ? 5 ether : 0;
            assertEq(address(treasury).balance, 5 ether - pushed, "a token moved the ether");
            assertEq(beneficiary.balance, before + pushed, "the ether went somewhere other than the beneficiary");
            assertEq(tokens[i].balance, 0, "a token ended up holding ether");
        }
    }

    /*//////////////////////////////////////////////////////////////
                          OWNERSHIP UNDER ATTACK
    //////////////////////////////////////////////////////////////*/

    /// transferOwnership takes address(0) on purpose in Ownable2Step: it is how
    /// a handover is called off. Worth pinning, because the obvious reading of
    /// the ZeroAddress error on setBeneficiary is that zero is refused here too,
    /// and it is not.
    function test_handingOwnershipToNobodyCancelsThePendingHandover() public {
        vm.prank(treasuryOwner);
        treasury.transferOwnership(bob);
        assertEq(treasury.pendingOwner(), bob, "pending");

        vm.expectEmit(true, true, false, true, address(treasury));
        emit Ownable2Step.OwnershipTransferStarted(treasuryOwner, address(0));
        vm.prank(treasuryOwner);
        treasury.transferOwnership(address(0));

        assertEq(treasury.pendingOwner(), address(0), "called off");
        assertEq(treasury.owner(), treasuryOwner, "and the owner never moved");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        treasury.acceptOwnership();
    }

    /// Handing ownership to the address that already holds it is legal and ends
    /// where it started. The useful part is the side effect: it clears whatever
    /// handover was in flight, so it doubles as a panic button when a key was
    /// sent to the wrong address.
    function test_handingOwnershipToTheCurrentOwnerIsAWayToCancelAMistake() public {
        vm.prank(treasuryOwner);
        treasury.transferOwnership(carol);

        vm.prank(treasuryOwner);
        treasury.transferOwnership(treasuryOwner);

        vm.expectEmit(true, true, false, true, address(treasury));
        emit Ownable.OwnershipTransferred(treasuryOwner, treasuryOwner);
        vm.prank(treasuryOwner);
        treasury.acceptOwnership();

        assertEq(treasury.owner(), treasuryOwner, "unchanged");
        assertEq(treasury.pendingOwner(), address(0), "and the pending slot is clear");

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        treasury.acceptOwnership();
    }

    /// Two steps only help if the first step is reversible. Naming a new pending
    /// owner has to lock the old one out, not queue them both.
    function test_namingASecondPendingOwnerLocksTheFirstOneOut() public {
        vm.prank(treasuryOwner);
        treasury.transferOwnership(bob);
        vm.prank(treasuryOwner);
        treasury.transferOwnership(carol);

        assertEq(treasury.pendingOwner(), carol, "only the latest is pending");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        treasury.acceptOwnership();

        vm.prank(carol);
        treasury.acceptOwnership();
        assertEq(treasury.owner(), carol, "the second one took it");
    }

    /// The step that decides who holds the money has no other guard on it, so
    /// the pendingOwner check is the whole of the access control.
    function test_onlyThePendingOwnerCanAcceptAndOnlyOnce() public {
        vm.prank(treasuryOwner);
        treasury.transferOwnership(bob);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        treasury.acceptOwnership();

        vm.prank(treasuryOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, treasuryOwner));
        treasury.acceptOwnership();

        vm.prank(bob);
        treasury.acceptOwnership();
        assertEq(treasury.owner(), bob, "handed over");

        // Accepting again would be a free re-grant if the pending slot were not
        // cleared, which matters if the old pending address is ever sold on.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        treasury.acceptOwnership();
    }

    /// renounceOwnership is overridden as pure, so it has no onlyOwner check on
    /// it any more. That is fine, but it means a stranger gets CannotRenounce
    /// rather than OwnableUnauthorizedAccount, and the test has to say so: a
    /// bare expectRevert here would pass even if the override were dropped and
    /// the inherited renounce came back for the owner.
    function test_renouncingIsRefusedForEverybodyAndChangesNothing() public {
        vm.prank(treasuryOwner);
        treasury.transferOwnership(bob);

        vm.prank(treasuryOwner);
        vm.expectRevert(Treasury.CannotRenounce.selector);
        treasury.renounceOwnership();

        vm.prank(stranger);
        vm.expectRevert(Treasury.CannotRenounce.selector);
        treasury.renounceOwnership();

        assertEq(treasury.owner(), treasuryOwner, "still owned");
        assertEq(treasury.pendingOwner(), bob, "and the handover is still in flight");

        vm.prank(bob);
        treasury.acceptOwnership();
        vm.prank(bob);
        vm.expectRevert(Treasury.CannotRenounce.selector);
        treasury.renounceOwnership();
        assertEq(treasury.owner(), bob, "a new owner cannot throw it away either");
    }

    /// The failure mode two-step ownership exists to prevent, arriving anyway: a
    /// pending owner that is a contract with no way to call acceptOwnership. The
    /// treasury is unharmed, because the transfer simply never completes.
    function test_aPendingOwnerThatCannotAcceptNeverBecomesTheOwner() public {
        Helpless stuck = new Helpless();
        vm.prank(treasuryOwner);
        treasury.transferOwnership(address(stuck));

        assertEq(treasury.owner(), treasuryOwner, "nothing happened yet");
        assertGt(address(stuck).code.length, 0, "it really is a contract");
        (bool ok,) = address(stuck).call(abi.encodeWithSignature("acceptOwnership()"));
        assertFalse(ok, "nothing in there can be made to accept");

        // The old owner still holds everything while the handover hangs.
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(carol);
        assertEq(treasury.beneficiary(), carol, "still in charge");

        // A contract that can make the call is a perfectly good owner.
        Relay relay = new Relay();
        vm.prank(treasuryOwner);
        treasury.transferOwnership(address(relay));
        relay.accept(treasury);

        assertEq(treasury.owner(), address(relay), "a contract owner works when it can call");
        assertEq(nft.owner(), address(relay), "and the label followed it");
    }

    /// The handover is one transaction that moves three things at once: the key
    /// to the money, the key to the destination, and the collection page label
    /// on a token contract that has no owner of its own. Tested together because
    /// a handover that moved only some of them would be the real danger.
    function test_acceptingOwnershipMovesTheMoneyKeyAndTheCollectionLabelTogether() public {
        vm.deal(address(treasury), 4 ether);
        assertEq(nft.owner(), treasuryOwner, "label starts with the old owner");

        vm.prank(treasuryOwner);
        treasury.transferOwnership(bob);
        assertEq(nft.owner(), treasuryOwner, "a pending handover moves nothing");

        vm.expectEmit(true, true, false, true, address(treasury));
        emit Ownable.OwnershipTransferred(treasuryOwner, bob);
        vm.prank(bob);
        treasury.acceptOwnership();

        assertEq(treasury.owner(), bob, "the key moved");
        assertEq(nft.owner(), bob, "and the label moved with it");

        vm.prank(treasuryOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, treasuryOwner));
        treasury.setBeneficiary(alice);

        vm.expectEmit(true, true, false, true, address(treasury));
        emit Treasury.BeneficiarySet(beneficiary, carol);
        vm.prank(bob);
        treasury.setBeneficiary(carol);

        uint256 before = carol.balance;
        vm.prank(stranger);
        treasury.sweep();
        assertEq(carol.balance, before + 4 ether, "the new owner decides where it goes");
    }

    /*//////////////////////////////////////////////////////////////
                        BENEFICIARIES INSIDE THE SYSTEM
    //////////////////////////////////////////////////////////////*/

    /// Nothing forbids pointing the treasury at itself, so here is what it
    /// actually does: the sweep succeeds, logs a full payment, and moves the
    /// money nowhere, because the send is to this same address. It is a
    /// footgun, not a loss, and the recorded behaviour is what an auditor needs.
    function test_pointingTheTreasuryAtItselfMakesSweepALoggedNoOp() public {
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(address(treasury));
        uint256 held = _takings(16);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit Treasury.Swept(address(treasury), held);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit Treasury.Received(address(treasury), held);
        vm.prank(stranger);
        treasury.sweep();

        assertEq(address(treasury).balance, held, "every wei is exactly where it was");

        // And it can be run again forever, which is the tell that it is doing
        // nothing rather than that it failed.
        vm.prank(stranger);
        treasury.sweep();
        assertEq(address(treasury).balance, held, "still here");

        uint256 before = carol.balance;
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(carol);
        vm.prank(stranger);
        treasury.sweep();
        assertEq(carol.balance, before + held, "and one repoint undoes the whole mistake");
    }

    /// The token half of the same mistake. An ERC20 self transfer is legal, so
    /// this also succeeds and also moves nothing.
    function test_pointingTheTreasuryAtItselfStrandsNoTokensEither() public {
        MockERC20 weth = new MockERC20();
        weth.mint(address(treasury), 5 ether);
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(address(treasury));

        vm.prank(stranger);
        treasury.sweepToken(weth);
        assertEq(weth.balanceOf(address(treasury)), 5 ether, "the tokens stayed put");

        vm.prank(treasuryOwner);
        treasury.setBeneficiary(carol);
        vm.prank(stranger);
        treasury.sweepToken(weth);
        assertEq(weth.balanceOf(carol), 5 ether, "recovered");
    }

    /// Pointing the beneficiary at the collection is the other unforbidden
    /// mistake, and ether and tokens land on opposite sides of it. The
    /// collection has no receive, so ether sweeps simply fail and nothing is
    /// lost.
    function test_pointingTheBeneficiaryAtTheCollectionJustBlocksEtherSweeps() public {
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(address(nft));
        uint256 held = _takings(17);

        vm.expectRevert(Errors.FailedCall.selector);
        treasury.sweep();

        assertEq(address(treasury).balance, held, "held");
        assertEq(address(nft).balance, 0, "the collection took nothing");

        uint256 before = carol.balance;
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(carol);
        vm.prank(stranger);
        treasury.sweep();
        assertEq(carol.balance, before + held, "recovered");
    }

    /// Tokens are the dangerous half: an ERC20 transfer to the collection
    /// succeeds, and the collection is immutable with no token rescue of any
    /// kind, so the balance is gone for good. This one mistake is not
    /// recoverable, which is the strongest argument for a confirmation step off
    /// chain before setBeneficiary is ever signed.
    function test_sweepingTokensToTheCollectionLosesThemPermanently() public {
        MockERC20 weth = new MockERC20();
        weth.mint(address(treasury), 5 ether);

        vm.prank(treasuryOwner);
        treasury.setBeneficiary(address(nft));
        vm.prank(stranger);
        treasury.sweepToken(weth);

        assertEq(weth.balanceOf(address(nft)), 5 ether, "the collection is holding them");

        // Nothing on the collection can move an ERC20, and repointing the
        // treasury afterwards does not reach back for them.
        string[4] memory rescues = [
            "sweepToken(address)", "sweep()", "rescueERC20(address,uint256)", "transferERC20(address,address,uint256)"
        ];
        for (uint256 i = 0; i < rescues.length; ++i) {
            (bool ok,) = address(nft).call(abi.encodeWithSignature(rescues[i], address(weth), uint256(5 ether)));
            assertFalse(ok, string.concat("the collection answers ", rescues[i]));
        }

        vm.prank(treasuryOwner);
        treasury.setBeneficiary(carol);
        vm.expectRevert(Treasury.NothingToSweep.selector);
        treasury.sweepToken(weth);
        assertEq(weth.balanceOf(address(nft)), 5 ether, "still stuck there");
    }
}

/*//////////////////////////////////////////////////////////////
                        HOSTILE BENEFICIARIES
//////////////////////////////////////////////////////////////*/

/// Refuses ether with no reason at all, which is the FailedCall branch rather
/// than the bubbled one.
contract Mute {
    receive() external payable {
        revert();
    }
}

/// Has code and no way to receive ether or to make a call. Doubles as a pending
/// owner that can never accept.
contract Helpless {
    uint256 public parked;
}

/// Burns every drop of gas sendValue forwards. The writes are to storage so no
/// optimizer can fold the loop away.
contract GasPit {
    uint256[16] private scratch;

    receive() external payable {
        uint256 i;
        while (true) {
            scratch[i & 15] = i + 1;
            unchecked {
                ++i;
            }
        }
    }
}

/// Shaped like the multisig the beneficiary is meant to be: its receive writes
/// storage, so it costs far more than a 2300 gas stipend to pay.
contract Multisig {
    uint256[8] private ledger;
    uint256 public deliveries;

    receive() external payable {
        for (uint256 i = 0; i < 8; ++i) {
            ledger[i] = block.timestamp + i + 1;
        }
        deliveries += 1;
    }
}

/// Takes its payment and immediately tries every door back into the treasury:
/// sweep again, take the tokens too, and repoint the treasury at itself.
contract Greedy {
    Treasury immutable treasury;
    IERC20 immutable token;

    uint256 public arrivals;
    bool public sweepAgainFailed;
    bool public tokenSweepWorked;
    bool public repointFailed;

    constructor(Treasury t, IERC20 tok) {
        treasury = t;
        token = tok;
    }

    receive() external payable {
        arrivals += 1;
        if (arrivals > 1) return;

        try treasury.sweep() {}
        catch {
            sweepAgainFailed = true;
        }
        try treasury.sweepToken(token) {
            tokenSweepWorked = true;
        } catch {}
        try treasury.setBeneficiary(address(this)) {}
        catch {
            repointFailed = true;
        }
    }
}

/// Can be told to accept an ownership handover, unlike Helpless.
contract Relay {
    function accept(Treasury t) external {
        t.acceptOwnership();
    }
}

/*//////////////////////////////////////////////////////////////
                             HOSTILE TOKENS
//////////////////////////////////////////////////////////////*/

/// The minimum a sweep reads from a token, so each mock below can be hostile in
/// exactly one way without inheriting behaviour it did not ask for.
abstract contract BareToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

/// Answers false and moves nothing, the shape SafeERC20 exists to catch.
contract Liar is BareToken {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// Reverts with a reason, the way a token with a blocklist does.
contract Frozen is BareToken {
    function transfer(address, uint256) external pure returns (bool) {
        revert("frozen");
    }
}

/// Moves the balance and returns nothing at all, which is what the largest
/// stablecoin on mainnet does and what a plain IERC20 call would reject.
contract Silent is BareToken {
    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// Skims a cut on the way through, so the amount delivered is smaller than the
/// amount the sweep logged.
contract FeeOnTransfer is ERC20 {
    uint256 constant FEE_BPS = 250;

    address immutable collector;

    constructor(address c) ERC20("Fee", "FEE") {
        collector = c;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        uint256 fee = (value * FEE_BPS) / 10_000;
        _transfer(_msgSender(), collector, fee);
        _transfer(_msgSender(), to, value - fee);
        return true;
    }
}

/// Calls sweepToken again from inside its own transfer, before it has moved
/// anything, so the treasury is asked to deliver the same balance twice.
contract Recursive is ERC20 {
    Treasury immutable treasury;
    bool armed;
    bool entered;

    constructor(Treasury t) ERC20("Recursive", "REC") {
        treasury = t;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(bool on) external {
        armed = on;
        entered = false;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (armed && !entered) {
            entered = true;
            treasury.sweepToken(IERC20(address(this)));
        }
        return super.transfer(to, value);
    }
}

/// Reaches for the ether while it has the floor, to show how far a token gets
/// when the treasury is holding both.
contract Grabby is ERC20 {
    Treasury immutable treasury;
    bool tried;
    bool public sweptEther;

    constructor(Treasury t) ERC20("Grabby", "GRB") {
        treasury = t;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (!tried) {
            tried = true;
            try treasury.sweep() {
                sweptEther = true;
            } catch {}
        }
        return super.transfer(to, value);
    }

    receive() external payable {}
}
