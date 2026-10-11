// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon, ITraitData, ITraitNames} from "../../src/GlamToon.sol";
import {Treasury} from "../../src/Treasury.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";

/// owner() is the one function on this contract whose answer comes from code
/// nobody here controls. Every marketplace reads it, it is read on the indexing
/// path rather than by a user who can retry, and the payee it asks is the one
/// address the token can never be pointed away from. So the bar is not "usually
/// right": it is that the call returns, with a clean address or nothing, for
/// every payee built here, and that nothing else about the collection changes
/// when the payee misbehaves.
///
/// owner() copies the whole reply before it looks at the length, so the promise
/// holds for answers of a fixed size, which is every answer here. A payee that
/// sized its reply to the gas it is handed could make the read itself run out.
/// The payee the deploy script wires in is always a fresh Treasury, which
/// answers with one word.
contract OwnerLabelTest is BaseTest {
    /// A payee that misbehaves, and the label the token has to end up showing
    /// for it. Named so a failure says which one broke.
    struct Payee {
        address at;
        address label;
        string what;
    }

    function _payee(address at, address label, string memory what) internal pure returns (Payee memory) {
        return Payee({at: at, label: label, what: what});
    }

    /// The whole zoo, built once so every test can sweep all of it.
    function _hostilePayees() internal returns (Payee[] memory zoo) {
        zoo = new Payee[](12);
        zoo[0] = _payee(address(new Reverter()), address(0), "reverts with a custom error");
        zoo[1] = _payee(address(new SilentReverter()), address(0), "reverts with no data");
        zoo[2] = _payee(address(new RevertingAddress()), address(0), "reverts with a whole address");
        zoo[3] = _payee(address(new Sized(0)), address(0), "answers with nothing");
        zoo[4] = _payee(address(new Sized(31)), address(0), "answers with 31 bytes");
        zoo[5] = _payee(address(new Sized(33)), address(0), "answers with 33 bytes");
        zoo[6] = _payee(address(new Huge()), address(0), "answers with a megabyte");
        zoo[7] = _payee(address(new Word(uint256(type(uint160).max) + 1)), address(0), "one bit too wide");
        zoo[8] = _payee(address(new Word(type(uint256).max)), address(0), "all dirty bits");
        zoo[9] = _payee(address(new GasEater()), address(0), "never returns");
        zoo[10] = _payee(address(new Writer()), address(0), "writes instead of answering");
        // This one does answer. It just tries to mint from whichever token asks.
        zoo[11] = _payee(address(new Reenterer()), PLANTED, "calls back into the token");
    }

    function _withPayee(address payee) internal returns (GlamToon) {
        return new GlamToon(
            ITraitData(address(chunk0)), ITraitData(address(chunk1)), ITraitNames(address(names)), payee, SALE_START
        );
    }

    /// Reads the label through a raw call, so a revert shows up as a failed call
    /// rather than as a failed test line. Asserting the 32 byte answer as well
    /// catches a label that "works" only because the caller happened to decode
    /// an empty return as zero. Gas is capped the way a node caps an eth_call,
    /// which is also what stops a payee that burns gas from eating the test.
    function _readLabel(GlamToon n) internal view returns (address) {
        (bool ok, bytes memory ret) = address(n).staticcall{gas: 10_000_000}(abi.encodeCall(GlamToon.owner, ()));
        assertTrue(ok, "owner() reverted");
        assertEq(ret.length, 32, "owner() answered with something that is not an address");
        return abi.decode(ret, (address));
    }

    /// The same read made with a plain call, for the tests where the only
    /// static frame has to be the one owner() opens itself.
    function _callLabel(GlamToon n) internal returns (address) {
        (bool ok, bytes memory ret) = address(n).call{gas: 10_000_000}(abi.encodeCall(GlamToon.owner, ()));
        assertTrue(ok, "owner() reverted");
        assertEq(ret.length, 32, "owner() answered with something that is not an address");
        return abi.decode(ret, (address));
    }

    /*//////////////////////////////////////////////////////////////
                         A PAYEE THAT ANSWERS BADLY
    //////////////////////////////////////////////////////////////*/

    /// The property the marketplace depends on, stated once over every bad payee
    /// there is: the call comes back. What it says is the next tests' business.
    function test_theLabelReadNeverRevertsWhateverThePayeeDoes() public {
        Payee[] memory zoo = _hostilePayees();
        for (uint256 i = 0; i < zoo.length; ++i) {
            GlamToon n = _withPayee(zoo[i].at);
            assertEq(_readLabel(n), zoo[i].label, zoo[i].what);
        }
    }

    /// Each of these answers carries a perfectly good address in its first word
    /// and is the wrong length. A length check written as < 32, or as > 32, would
    /// read the word anyway and hand a marketplace an owner nobody named.
    function test_anAnswerOfTheWrongLengthIsNotReadAsAnAddress() public {
        assertEq(_readLabel(_withPayee(address(new Sized(0)))), address(0), "empty");
        assertEq(_readLabel(_withPayee(address(new Sized(31)))), address(0), "one byte short");
        assertEq(_readLabel(_withPayee(address(new Sized(33)))), address(0), "one byte long");
        assertEq(_readLabel(_withPayee(address(new Sized(64)))), address(0), "two words");
        assertEq(_readLabel(_withPayee(address(new Huge()))), address(0), "a megabyte");

        // Same contract, same first word, correct length: proves the rejections
        // above are about the length and not about the payload being unreadable.
        assertEq(_readLabel(_withPayee(address(new Sized(32)))), PLANTED, "exactly one word");
    }

    /// owner() copies the whole reply into memory before it looks at the length,
    /// so a payee answering with a megabyte hands the reader the bill for that
    /// copy. For a reply of a fixed size, even this one, the bill stays well
    /// inside what a node gives an eth_call. A reply sized to the gas it is
    /// handed is not what this pins.
    function test_aGiganticAnswerStaysAffordableToRead() public {
        GlamToon n = _withPayee(address(new Huge()));
        uint256 before = gasleft();
        address label = n.owner();
        uint256 spent = before - gasleft();

        assertEq(label, address(0), "still empty");
        assertLt(spent, 10_000_000, "a payee can make the label read this expensive");
    }

    /// The top 96 bits are the part a cast would silently drop. The pair either
    /// side of the limit is the whole test: one below is an address, one above is
    /// nothing, and a >= in place of > would lose the largest address there is.
    function test_theAnswersTopBitsDecideBetweenAnAddressAndNothing() public {
        assertEq(
            _readLabel(_withPayee(address(new Word(type(uint160).max)))),
            address(type(uint160).max),
            "the largest address is still an address"
        );
        assertEq(
            _readLabel(_withPayee(address(new Word(uint256(type(uint160).max) + 1)))),
            address(0),
            "one bit above the limit is not"
        );
        // A real address with rubbish packed above it: truncating would hand the
        // marketplace an owner that looks entirely plausible.
        uint256 dirty = (uint256(0xBAD) << 160) | uint256(uint160(PLANTED));
        assertEq(_readLabel(_withPayee(address(new Word(dirty)))), address(0), "dirty high bits are not trimmed off");
    }

    /// The third one is the one that matters. A failed call whose revert data is
    /// exactly one clean word is indistinguishable from a good answer on
    /// everything except the success flag, so it is the only payee that proves
    /// the flag is being looked at at all.
    function test_aRevertingPayeeLeavesTheLabelEmpty() public {
        assertEq(_readLabel(_withPayee(address(new Reverter()))), address(0), "custom error");
        assertEq(_readLabel(_withPayee(address(new SilentReverter()))), address(0), "revert with no data");
        assertEq(_readLabel(_withPayee(address(new RevertingAddress()))), address(0), "revert with 32 clean bytes");
    }

    /// A payee that never returns burns whatever the staticcall was given. What
    /// has to survive is the frame around it: the label read is still worth
    /// making at an ordinary call gas cap, which is all a marketplace will spend.
    function test_aPayeeThatEatsAllTheGasStillAnswersUnderACallCap() public {
        _skipUnderCoverage();
        GlamToon n = _withPayee(address(new GasEater()));

        (bool ok, bytes memory ret) = address(n).staticcall{gas: 30_000}(abi.encodeCall(GlamToon.owner, ()));
        assertTrue(ok, "a 30k gas read of the label died with the payee");
        assertEq(abi.decode(ret, (address)), address(0), "empty label");

        // And the frame that made the read keeps enough gas to go on working.
        uint256 price = n.currentPrice();
        vm.prank(alice);
        n.mintBlue{value: price}(1, price);
        assertEq(n.ownerOf(1), alice, "the collection still works after the burn");
    }

    /// The other side of a gas cap. An honest payee may need real gas to
    /// answer, the way a proxy or a smart account reading its own storage does.
    /// This one reads ninety six cold slots first, over two hundred thousand gas,
    /// and the label still has to be its answer: the read hands the payee what
    /// the caller brought rather than a fixed allowance.
    function test_anHonestPayeeThatNeedsGasToAnswerIsStillRead() public {
        GlamToon n = _withPayee(address(new Costly()));

        uint256 before = gasleft();
        address label = _readLabel(n);
        uint256 spent = before - gasleft();

        assertEq(label, PLANTED, "the payee answered and was not heard");
        assertGt(spent, 200_000, "the payee is as costly as it says");
    }

    /// The read is a staticcall, so the payee is a spectator: it cannot write its
    /// own storage, and it cannot mint, move or refund anything on the way past.
    /// Both of these look like successful owner() implementations from outside.
    /// The label is read with a plain call here, so the only static frame is the
    /// one owner() opens, and each payee is then shown doing the same thing
    /// outside a read, where nothing stops it.
    function test_thePayeeCannotWriteAnythingWhileTheLabelIsRead() public {
        Writer w = new Writer();
        GlamToon a = _withPayee(address(w));
        assertEq(_callLabel(a), address(0), "a write attempt is not an answer");
        assertEq(w.touched(), 0, "the payee wrote its own storage from inside a view");

        w.owner();
        assertEq(w.touched(), 1, "outside a read the write goes through");

        Reenterer r = new Reenterer();
        GlamToon b = _withPayee(address(r));

        // This one swallows the failure and answers anyway, so the label is
        // readable; what must not have happened is the mint.
        assertEq(_callLabel(b), PLANTED, "the payee answered");
        assertEq(b.greenMinted(), 0, "the payee minted from inside a label read");
        assertEq(b.totalSupply(), 0, "supply moved");
        assertFalse(b.greenTaken(1, address(r)), "the payee spent a slot from inside a label read");

        vm.prank(address(b));
        r.owner();
        assertEq(b.ownerOf(b.tokenIdFor(1, 1)), address(r), "outside a read the same mint goes through");
    }

    /// The label is read from inside onERC721Received by indexers that pick up a
    /// mint as it lands. The mint holds the reentrancy guard at that moment, so
    /// this is the one call ordering that could wedge owner() on the real payee.
    function test_theLabelIsReadableFromInsideAMint() public {
        Nosy nosy = new Nosy(address(nft));
        uint256 price = nft.currentPrice();
        vm.prank(alice);
        nft.mintBlueFor{value: price}(address(nosy), 1, price);

        assertEq(nosy.seen(), treasuryOwner, "the label read during the mint");
        assertEq(nft.ownerOf(1), address(nosy), "and the mint still landed");
    }

    /// Cancun keeps the code of a contract that was not created in the same
    /// transaction, so a payee calling selfdestruct drains itself and goes on
    /// answering. The case where the code really is gone is the etch below, and
    /// both have to leave a readable label.
    ///
    /// The bomb is planted rather than created here, because a real payee is
    /// deployed long before anything reads the label. One created in this same
    /// transaction is the case Cancun does delete, and forge 1.8 already reports
    /// its code gone inside the test, so creating it here would test the runner.
    function test_aPayeeThatDestroysItselfDoesNotTakeTheLabelWithIt() public {
        Bomb bomb = Bomb(address(0xB0B5));
        vm.etch(address(bomb), type(Bomb).runtimeCode);
        GlamToon n = _withPayee(address(bomb));
        vm.deal(address(bomb), 5 ether);
        assertEq(_readLabel(n), PLANTED, "answers to start with");

        bomb.kill();
        assertEq(address(bomb).balance, 0, "it did take the money");
        assertEq(_readLabel(n), PLANTED, "the label is not the payee's balance");

        vm.etch(address(bomb), "");
        assertEq(_readLabel(n), address(0), "code gone, label empty, still no revert");
        _assertTheCollectionIsUntouched(n, address(bomb));
    }

    /// A hostile payee gets to decide one thing: whether the label is empty.
    /// Everything a holder or a marketplace cares about has to be byte for byte
    /// what the honest deployment produces.
    function test_aHostilePayeeChangesNothingElseAboutTheCollection() public {
        Payee[] memory zoo = _hostilePayees();
        for (uint256 i = 0; i < zoo.length; ++i) {
            _assertTheCollectionIsUntouched(_withPayee(zoo[i].at), zoo[i].at);
        }
    }

    /// Mint, transfer, metadata and royalties, checked against the honest
    /// deployment from Base rather than against restated expectations.
    function _assertTheCollectionIsUntouched(GlamToon n, address payee) internal {
        // The reference deployment needs the same token minted before its
        // metadata can be compared.
        if (!nft.blueTaken(4242)) _buy(carol, 4242);

        uint256 price = n.currentPrice();
        assertEq(price, _expectedPrice(0), "price");

        vm.prank(alice);
        n.mintBlue{value: price}(4242, price);
        assertEq(n.ownerOf(4242), alice, "mint");

        vm.prank(alice);
        n.transferFrom(alice, bob, 4242);
        assertEq(n.ownerOf(4242), bob, "transfer");

        assertEq(n.tokenURI(4242), nft.tokenURI(4242), "the payee leaked into the token metadata");
        assertEq(n.contractURI(), nft.contractURI(), "the payee leaked into the collection metadata");

        (address receiver, uint256 amount) = n.royaltyInfo(4242, 10 ether);
        assertEq(receiver, payee, "royalties go to the payee named at construction");
        assertEq(amount, 0.2 ether, "two percent");
    }

    /*//////////////////////////////////////////////////////////////
                            A 7702 PAYEE
    //////////////////////////////////////////////////////////////*/

    /// An owner key that upgrades itself to a smart account keeps its address and
    /// gains code: 23 bytes of delegation designator. The label read resolves it,
    /// so a treasury owner moving to 7702 does not blank the collection page.
    function test_theLabelFollowsA7702Delegation() public {
        address key = vm.addr(0x7702);
        Answerer account = new Answerer();
        vm.etch(key, abi.encodePacked(hex"ef0100", account));
        assertEq(key.code.length, 23, "delegation designator");

        GlamToon n = _withPayee(key);
        assertEq(_readLabel(n), PLANTED, "the delegate answered for the key");
    }

    /// The same shape pointing at an address with no code behind it. The account
    /// has code, so the usual "is there code here" guess says yes, and there is
    /// still nothing to run.
    function test_a7702DelegationToNothingLeavesTheLabelEmpty() public {
        address key = vm.addr(0x7702);
        vm.etch(key, abi.encodePacked(hex"ef0100", address(0xD00D)));

        GlamToon n = _withPayee(key);
        assertEq(_readLabel(n), address(0), "nothing to delegate to");
    }

    /// The nastiest arrangement of it: the payee delegates to the token itself,
    /// so reading the label reads the label. It has to bottom out on gas and come
    /// back empty rather than take the read down with it.
    function test_a7702DelegationBackAtTheCollectionCannotHangTheLabel() public {
        address key = vm.addr(0x7702);
        GlamToon n = _withPayee(key);
        vm.etch(key, abi.encodePacked(hex"ef0100", address(n)));

        // Measured uncapped: the recursion has to run out on its own.
        uint256 before = gasleft();
        address label = n.owner();
        uint256 spent = before - gasleft();

        assertEq(label, address(0), "the recursion ended in an empty label");
        assertLt(spent, 10_000_000, "the recursion is bounded, not merely finite");
    }

    /*//////////////////////////////////////////////////////////////
                          THE LABEL AND THE TREASURY
    //////////////////////////////////////////////////////////////*/

    /// There is no cached copy and no event to wait for: accepting the treasury
    /// changes what the token says at once, so a marketplace that re-reads after
    /// the handover sees the new owner immediately. The new owner here reads the
    /// label, accepts and reads it again inside one call, so both answers come
    /// from the transaction that did the accepting.
    function test_theLabelMovesInTheBlockTheHandoverIsAccepted() public {
        LabelWatcher watcher = new LabelWatcher(nft, treasury);

        vm.prank(treasuryOwner);
        treasury.transferOwnership(address(watcher));

        (address before, address afterwards) = watcher.accept();
        assertEq(before, treasuryOwner, "the label up to the acceptance");
        assertEq(afterwards, address(watcher), "the label straight after it, in the same transaction");
        assertEq(nft.owner(), address(watcher), "and it stays where it moved to");
    }

    /// A handover can be re-aimed while it is pending. The label must track what
    /// was accepted, never what was merely offered, or an offer to a wrong
    /// address would hand the collection page over by itself.
    function test_onlyAnAcceptedHandoverMovesTheLabel() public {
        vm.prank(treasuryOwner);
        treasury.transferOwnership(bob);
        assertEq(nft.owner(), treasuryOwner, "an offer is not a handover");

        vm.prank(treasuryOwner);
        treasury.transferOwnership(carol);
        assertEq(nft.owner(), treasuryOwner, "nor is a second offer");

        // The address that was offered first and passed over cannot take it.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        treasury.acceptOwnership();
        assertEq(nft.owner(), treasuryOwner, "and cannot move the label by trying");

        vm.prank(carol);
        treasury.acceptOwnership();
        assertEq(nft.owner(), carol, "the accepted one");
    }

    /// Renouncing is the one move that would strand the beneficiary, and it is
    /// also the only single call that could empty the collection page. Offering
    /// the treasury to nobody gets as close as anyone can: it leaves the label
    /// exactly where it was, and the offer can still be withdrawn by making
    /// another. Completing that offer needs a transaction sent from address(0),
    /// which no key signs.
    function test_theLabelCannotBeThrownAwayByTheTreasuryOwner() public {
        vm.prank(treasuryOwner);
        vm.expectRevert(Treasury.CannotRenounce.selector);
        treasury.renounceOwnership();
        assertEq(nft.owner(), treasuryOwner, "still labelled");

        vm.prank(treasuryOwner);
        treasury.transferOwnership(address(0));
        assertEq(nft.owner(), treasuryOwner, "offering it to nobody changes nothing");

        vm.prank(treasuryOwner);
        treasury.transferOwnership(bob);
        vm.prank(bob);
        treasury.acceptOwnership();
        assertEq(nft.owner(), bob, "and the treasury is still handable on");
    }

    /*//////////////////////////////////////////////////////////////
                         THE LABEL GRANTS NOTHING
    //////////////////////////////////////////////////////////////*/

    /// Read the label first: evaluating it inside a pranked call is the call that
    /// gets pranked. Each of these is the label holder doing what a privileged
    /// account would be able to do, next to a stranger doing the same thing.
    function test_theLabelHolderBuysAtTheSamePriceAsAStranger() public {
        address label = nft.owner();
        vm.deal(label, 10 ether);
        uint256 price = nft.currentPrice();

        vm.prank(label);
        vm.expectRevert(GlamToon.InsufficientPayment.selector);
        nft.mintBlue{value: price - 1}(1, price);

        vm.prank(label);
        nft.mintBlue{value: price}(1, price);
        assertEq(nft.ownerOf(1), label, "bought like anyone else");

        // And no discount: the tier moved for them the same as for everybody.
        assertEq(nft.blueMinted(), 1, "counted against the supply");
        assertEq(address(nft).balance, price, "paid in full");

        vm.prank(label);
        vm.expectRevert(GlamToon.BlueAlreadyTaken.selector);
        nft.mintBlue{value: price}(1, price);
    }

    /// One green per address per character, and the label is an address like any
    /// other. If the label were wired to anything it would most plausibly be
    /// wired to an exemption here.
    function test_theLabelHolderGetsNoExtraGreen() public {
        address label = nft.owner();

        vm.prank(label);
        nft.mintGreen(7);
        vm.prank(label);
        vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
        nft.mintGreen(7);

        assertEq(nft.greenCount(7), 1, "one generation");
    }

    /// The collection page editor on a marketplace is not a custodian here.
    function test_theLabelHolderCannotTouchSomebodyElsesToken() public {
        _buy(alice, 1);
        address label = nft.owner();

        vm.prank(label);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, label, uint256(1)));
        nft.transferFrom(alice, label, 1);

        vm.prank(label);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidApprover.selector, label));
        nft.approve(label, 1);

        // setApprovalForAll is the label approving on its own account, which
        // gives it nothing over alice's token.
        vm.prank(label);
        nft.setApprovalForAll(label, true);
        vm.prank(label);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, label, uint256(1)));
        nft.safeTransferFrom(alice, label, 1);

        assertEq(nft.ownerOf(1), alice, "nothing moved");
        assertEq(nft.getApproved(1), address(0), "nothing was approved");
    }

    /// withdraw() is open to everyone and reaches one address. Being the label
    /// does not make it reach yours.
    function test_withdrawPaysThePayeeEvenWhenTheLabelHolderCallsIt() public {
        uint256 price = _buy(alice, 1);
        address label = nft.owner();
        uint256 labelBefore = label.balance;
        uint256 treasuryBefore = address(treasury).balance;

        vm.prank(label);
        nft.withdraw();

        assertEq(label.balance, labelBefore, "the label holder took nothing");
        assertEq(address(treasury).balance, treasuryBefore + price, "the payee took it all");
        assertEq(address(nft).balance, 0, "nothing left behind");
    }

    /// Moving the label is an event on another contract. Nothing about the token
    /// may follow it: not a holding, not an approval, not the royalty receiver.
    function test_movingTheLabelMovesNothingElse() public {
        _buy(alice, 1);
        vm.prank(alice);
        nft.approve(carol, 1);

        (address receiverBefore,) = nft.royaltyInfo(1, 1 ether);

        vm.prank(treasuryOwner);
        treasury.transferOwnership(bob);
        vm.prank(bob);
        treasury.acceptOwnership();

        assertEq(nft.owner(), bob, "the label moved");
        assertEq(nft.ownerOf(1), alice, "the token did not");
        assertEq(nft.getApproved(1), carol, "the approval did not");
        assertEq(nft.PAYOUT(), address(treasury), "the payee did not");

        (address receiverAfter, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiverAfter, receiverBefore, "the royalty receiver did not");
        assertEq(receiverAfter, address(treasury), "royalties are paid to the treasury, never to its owner");
        assertEq(amount, 0.02 ether, "two percent");

        // The old label holder keeps nothing either.
        vm.prank(treasuryOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, treasuryOwner));
        treasury.setBeneficiary(carol);
    }
}

// The address every mock plants in its answer, so a test that expects a value
// is told apart from one that expects an empty label.
address constant PLANTED = address(0xFEED);

/// Answers the way the real treasury does.
contract Answerer {
    function owner() external pure returns (address) {
        return PLANTED;
    }
}

/// Reverts with data a caller cannot decode as an address.
contract Reverter {
    error NotForYou(uint256 why);

    function owner() external pure returns (address) {
        revert NotForYou(1);
    }
}

/// Reverts with nothing at all, which is what a bare require and a failed
/// assembly revert both look like.
contract SilentReverter {
    fallback() external {
        assembly {
            revert(0, 0)
        }
    }
}

/// Fails, with revert data that is byte for byte a valid answer.
contract RevertingAddress {
    fallback() external {
        address a = PLANTED;
        assembly {
            mstore(0, a)
            revert(0, 32)
        }
    }
}

/// Answers with `n` bytes whose first word is a clean, plausible address.
contract Sized {
    uint256 immutable LEN;

    constructor(uint256 n) {
        LEN = n;
    }

    fallback() external {
        uint256 n = LEN;
        address a = PLANTED;
        assembly {
            mstore(0, a)
            mstore(32, a)
            return(0, n)
        }
    }
}

/// A megabyte of answer, with the same plausible address at the front of it.
contract Huge {
    fallback() external {
        address a = PLANTED;
        assembly {
            mstore(0, a)
            return(0, 1048576)
        }
    }
}

/// Answers with one word, exactly as given, high bits and all.
contract Word {
    uint256 immutable ANSWER;

    constructor(uint256 w) {
        ANSWER = w;
    }

    fallback() external {
        uint256 w = ANSWER;
        assembly {
            mstore(0, w)
            return(0, 32)
        }
    }
}

/// Never returns, and spends everything it is given on the way.
contract GasEater {
    fallback() external {
        uint256 i;
        while (true) {
            unchecked {
                i = uint256(keccak256(abi.encode(i)));
            }
        }
    }
}

/// Looks like a plain owner() but writes its own storage, so the answer only
/// arrives if the read was not a staticcall.
contract Writer {
    uint256 public touched;

    function owner() external returns (address) {
        touched = 1;
        return PLANTED;
    }
}

/// Calls back into whichever token asks it for the owner, through a door that
/// would mint it a green anywhere else, swallows whatever happens, and answers
/// anyway. It accepts tokens, so the only thing that can stop the mint is the
/// read being static.
contract Reenterer {
    function owner() external returns (address) {
        (bool ok,) = msg.sender.call(abi.encodeCall(GlamToon.mintGreen, (1)));
        ok;
        return PLANTED;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// Answers the right address, but only after reading ninety six storage slots
/// nothing has touched, which costs more than a payee behind a proxy pays.
contract Costly {
    mapping(uint256 => uint256) private _pad;

    function owner() external view returns (address) {
        uint256 seen;
        for (uint256 i = 0; i < 96; ++i) {
            seen |= _pad[i];
        }
        return seen == 0 ? PLANTED : address(0);
    }
}

/// A new treasury owner that reads the label either side of accepting, inside
/// one call.
contract LabelWatcher {
    GlamToon immutable NFT;
    Treasury immutable TREASURY;

    constructor(GlamToon n, Treasury t) {
        NFT = n;
        TREASURY = t;
    }

    function accept() external returns (address before, address afterwards) {
        before = NFT.owner();
        TREASURY.acceptOwnership();
        afterwards = NFT.owner();
    }
}

/// A payee that can empty itself out on demand.
contract Bomb {
    function owner() external pure returns (address) {
        return PLANTED;
    }

    function kill() external {
        selfdestruct(payable(msg.sender));
    }
}

/// An indexer-shaped receiver: reads the collection label at the moment the
/// token lands, from inside the mint that is still holding the guard.
contract Nosy {
    address public immutable TOKEN;
    address public seen;

    constructor(address t) {
        TOKEN = t;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        seen = GlamToon(TOKEN).owner();
        return this.onERC721Received.selector;
    }
}
