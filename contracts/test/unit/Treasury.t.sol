// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "../Base.t.sol";
import {Treasury} from "../../src/Treasury.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";

/// The treasury is the only contract with an owner, and the tests are mostly
/// about how little that owner can reach.
contract TreasuryTest is BaseTest {
    function test_startsWhereItWasPointed() public view {
        assertEq(treasury.owner(), treasuryOwner, "owner");
        assertEq(treasury.beneficiary(), beneficiary, "beneficiary");
    }

    /// Ownable checks the owner before the treasury's own check runs, so a zero
    /// owner is refused with OpenZeppelin's error and never reaches ZeroAddress.
    function test_zeroAddressesAreRefused() public {
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(treasuryOwner, address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Treasury(address(0), beneficiary);
    }

    function test_takesDeliveryOfEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(treasury).call{value: 1 ether}("");
        assertTrue(ok, "receive");
        assertEq(address(treasury).balance, 1 ether, "held");
    }

    /// receive answers a plain call that carries no ether as well, and logs it
    /// as a delivery of nothing rather than staying quiet.
    function test_aDeliveryOfNothingIsStillLogged() public {
        vm.expectEmit(true, false, false, true, address(treasury));
        emit Treasury.Received(alice, 0);

        vm.prank(alice);
        (bool ok,) = address(treasury).call("");

        assertTrue(ok, "a call with no value was refused");
        assertEq(address(treasury).balance, 0, "and nothing arrived");
    }

    /// There is no fallback, so ether sent along with calldata finds no function
    /// to take it. Only a plain transfer reaches receive.
    function test_etherSentWithCalldataIsRefused() public {
        uint256 before = alice.balance;

        vm.prank(alice);
        (bool ok, bytes memory err) = address(treasury).call{value: 1 ether}(hex"deadbeef");

        assertFalse(ok, "ether with calldata was taken");
        assertEq(err.length, 0, "refused with no reason, before any function ran");
        assertEq(address(treasury).balance, 0, "nothing arrived");
        assertEq(alice.balance, before, "and the sender kept it");
    }

    function test_anyoneMaySweepButOnlyToTheBeneficiary() public {
        vm.deal(address(treasury), 5 ether);
        vm.prank(carol); // a stranger
        treasury.sweep();
        assertEq(beneficiary.balance, 5 ether, "beneficiary got it");
        assertEq(address(treasury).balance, 0, "emptied");
    }

    function test_sweepingNothingReverts() public {
        vm.expectRevert(Treasury.NothingToSweep.selector);
        treasury.sweep();
    }

    function test_ownerCanRepointIt() public {
        address elsewhere = vm.addr(0xE1);
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(elsewhere);
        assertEq(treasury.beneficiary(), elsewhere, "repointed");

        vm.deal(address(treasury), 2 ether);
        treasury.sweep();
        assertEq(elsewhere.balance, 2 ether, "new destination");
    }

    /// A wallet address with no code cannot refuse, so a sweep to it always
    /// goes through, and the identity precompile takes one the same way. The
    /// treasury cannot tell a wallet from an address nobody holds a key for,
    /// which is why the owner has to get the beneficiary right: whatever lands
    /// on the precompile stays there.
    function test_aBeneficiaryWithNoCodeTakesEverySweepEvenTheIdentityPrecompile() public {
        address[2] memory sinks = [vm.addr(0xDEAD), address(4)];

        for (uint256 i = 0; i < sinks.length; ++i) {
            vm.prank(treasuryOwner);
            treasury.setBeneficiary(sinks[i]);
            vm.deal(address(treasury), 1 ether);
            uint256 before = sinks[i].balance;

            vm.prank(carol);
            treasury.sweep();

            assertEq(sinks[i].balance, before + 1 ether, "the sweep was not delivered");
            assertEq(address(treasury).balance, 0, "the treasury kept some");
        }
    }

    function test_nobodyElseCanRepointIt() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        treasury.setBeneficiary(alice);
    }

    function test_beneficiaryCannotBeZeroed() public {
        vm.prank(treasuryOwner);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.setBeneficiary(address(0));
    }

    function test_ownershipHandoverTakesTwoSteps() public {
        vm.prank(treasuryOwner);
        treasury.transferOwnership(bob);
        assertEq(treasury.owner(), treasuryOwner, "not yet");
        assertEq(treasury.pendingOwner(), bob, "pending");

        vm.prank(bob);
        treasury.acceptOwnership();
        assertEq(treasury.owner(), bob, "handed over");
    }

    /// Only the owner can start a handover. A stranger cannot nominate itself or
    /// anyone else, and with nothing pending there is nothing to accept, so the
    /// key and the collection label both stay where they are.
    function test_aStrangerCannotOfferTheTreasuryToAnybody() public {
        address stranger = vm.addr(0x57A);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        treasury.transferOwnership(stranger);
        assertEq(treasury.pendingOwner(), address(0), "a stranger opened a handover");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        treasury.transferOwnership(bob);
        assertEq(treasury.pendingOwner(), address(0), "a stranger nominated somebody else");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        treasury.acceptOwnership();

        assertEq(treasury.owner(), treasuryOwner, "the key moved");
        assertEq(nft.owner(), treasuryOwner, "the label moved");
    }

    /// A nominee holds no power until it accepts: it cannot repoint the money or
    /// pass the nomination on. Once it accepts, the old owner holds none either
    /// and cannot start or aim another handover.
    function test_aNomineeHoldsNothingUntilItAcceptsAndTheOldOwnerNothingAfter() public {
        vm.prank(treasuryOwner);
        treasury.transferOwnership(bob);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        treasury.setBeneficiary(bob);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        treasury.transferOwnership(carol);

        assertEq(treasury.beneficiary(), beneficiary, "the nominee repointed the money");
        assertEq(treasury.pendingOwner(), bob, "the nominee passed the nomination on");

        vm.prank(bob);
        treasury.acceptOwnership();

        vm.prank(treasuryOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, treasuryOwner));
        treasury.transferOwnership(treasuryOwner);

        assertEq(treasury.pendingOwner(), address(0), "the old owner opened a handover");
        assertEq(treasury.owner(), bob, "and the key stayed with the new owner");
    }

    /// Renouncing would weld the beneficiary in place forever, so it is refused.
    function test_ownershipCannotBeThrownAway() public {
        vm.prank(treasuryOwner);
        vm.expectRevert(Treasury.CannotRenounce.selector);
        treasury.renounceOwnership();

        assertEq(treasury.owner(), treasuryOwner, "still owned");

        // handing it on is still fine
        vm.prank(treasuryOwner);
        treasury.transferOwnership(bob);
        vm.prank(bob);
        treasury.acceptOwnership();
        assertEq(treasury.owner(), bob, "handed over");
    }

    function test_sweepsTokensToo() public {
        MockERC20 weth = new MockERC20();
        weth.mint(address(treasury), 3 ether);
        vm.prank(carol);
        treasury.sweepToken(weth);
        assertEq(weth.balanceOf(beneficiary), 3 ether, "royalties paid in a token");
        assertEq(weth.balanceOf(address(treasury)), 0, "emptied");
    }

    /// SweptToken is logged before the token moves, the same order sweep keeps
    /// between Swept and the payment it announces.
    function test_sweptTokenIsLoggedBeforeTheTokenMoves() public {
        MockERC20 weth = new MockERC20();
        weth.mint(address(treasury), 3 ether);

        vm.expectEmit(true, true, false, true, address(treasury));
        emit Treasury.SweptToken(address(weth), beneficiary, 3 ether);
        vm.expectEmit(true, true, false, true, address(weth));
        emit IERC20.Transfer(address(treasury), beneficiary, 3 ether);

        vm.prank(carol);
        treasury.sweepToken(weth);
    }

    function test_sweepingNoTokensReverts() public {
        MockERC20 weth = new MockERC20();
        vm.expectRevert(Treasury.NothingToSweep.selector);
        treasury.sweepToken(weth);
    }

    /// SweptToken carries whatever balanceOf quoted, and the token decides both
    /// the quote and whether its transfer moves anything. A token that quotes a
    /// balance it never pays out is logged as swept every time anyone asks while
    /// nothing moves, so the log is only as honest as the token.
    function test_aTokenThatQuotesABalanceItNeverPaysIsLoggedAsSweptEveryTime() public {
        Phantom phantom = new Phantom();
        vm.deal(address(treasury), 2 ether);

        vm.recordLogs();
        vm.prank(carol);
        treasury.sweepToken(IERC20(address(phantom)));
        vm.prank(carol);
        treasury.sweepToken(IERC20(address(phantom)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 2, "something other than the two sweeps was logged");
        for (uint256 i = 0; i < logs.length; ++i) {
            assertEq(logs[i].emitter, address(treasury), "the token logged a transfer");
            assertEq(logs[i].topics[0], Treasury.SweptToken.selector, "not a SweptToken");
            assertEq(abi.decode(logs[i].data, (uint256)), phantom.QUOTE(), "the log did not carry the quote");
        }
        assertEq(address(treasury).balance, 2 ether, "the ether was never in play");
    }

    /// The end to end shape the design turns on: sale money reaches a place the
    /// owner controls, without the token contract ever having an owner.
    function test_saleProceedsReachTheBeneficiary() public {
        _buy(alice, 1);
        _buy(bob, 2);
        nft.withdraw();
        treasury.sweep();
        assertEq(beneficiary.balance, 0.02 ether, "two sales, delivered");
    }

    /// And the limit of what that owner key is worth: it cannot touch a token.
    function test_theTreasuryOwnerCannotReachTheCollection() public {
        _buy(alice, 1);
        vm.startPrank(treasuryOwner);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, treasuryOwner, uint256(1))
        );
        nft.transferFrom(alice, treasuryOwner, 1);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), alice, "still alice's");
    }
}

/*//////////////////////////////////////////////////////////////
                              MOCKS
//////////////////////////////////////////////////////////////*/

/// Quotes the same large balance to everyone and answers every transfer with
/// true, while holding nothing and moving nothing.
contract Phantom {
    uint256 public constant QUOTE = 1e24;

    function balanceOf(address) external pure returns (uint256) {
        return QUOTE;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }
}
