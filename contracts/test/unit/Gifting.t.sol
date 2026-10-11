// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "openzeppelin/utils/ReentrancyGuardTransient.sol";

/// Buying a blue for somebody else. The recipient and the payer are two
/// addresses for the first time, so everything that used to be one is worth
/// asserting separately: who gets the token, who gets the change, and which of
/// the two can break the sale.
contract GiftingTest is BaseTest {
    function test_theTokenGoesToTheRecipient() public {
        uint256 price = _price();

        vm.prank(alice);
        nft.mintBlueFor{value: price}(bob, 7412, price);

        assertEq(nft.ownerOf(7412), bob, "bob holds it");
        assertEq(nft.balanceOf(alice), 0, "alice holds nothing");
        assertTrue(nft.blueTaken(7412), "counted as sold");
        assertEq(nft.blueMinted(), 1, "one sale");
    }

    /// Blue has no per address rule, so a gift costs the recipient nothing they
    /// could have spent themselves.
    function test_aGiftLeavesTheRecipientFreeToBuyMore() public {
        vm.prank(alice);
        nft.mintBlueFor{value: _price()}(bob, 1, _price());

        _buy(bob, 2);
        assertEq(nft.balanceOf(bob), 2, "bob bought another for himself");
    }

    /// Green is the opposite case and has no For door at all, because the rule
    /// counts the minter and a stranger must not be able to spend their slot.
    function test_thereIsNoWayToMintAGreenForSomebodyElse() public {
        (bool found,) = address(nft).call(abi.encodeWithSignature("mintGreenFor(address,uint256)", bob, uint256(1)));
        assertFalse(found, "no mintGreenFor exists");

        _green(bob, 1);
        assertTrue(nft.greenTaken(1, bob), "bob spent his own slot");
        assertFalse(nft.greenTaken(1, alice), "and nobody else's");
    }

    function test_changeGoesBackToThePayerNotTheRecipient() public {
        uint256 price = _price();
        uint256 payerBefore = alice.balance;
        uint256 recipientBefore = bob.balance;

        vm.prank(alice);
        nft.mintBlueFor{value: price + 2 ether}(bob, 3, price + 2 ether);

        assertEq(alice.balance, payerBefore - price, "alice paid the price and got the rest back");
        assertEq(bob.balance, recipientBefore, "the recipient was sent nothing");
    }

    /// A recipient that cannot take ether is irrelevant to a gift: the refund
    /// never goes there.
    function test_aRecipientThatRefusesEtherStillReceivesTheToken() public {
        Sulks sulks = new Sulks();
        uint256 price = _price();

        vm.prank(alice);
        nft.mintBlueFor{value: price + 1 ether}(address(sulks), 4, price + 1 ether);

        assertEq(nft.ownerOf(4), address(sulks), "the token arrived");
    }

    /// The payer, on the other hand, has to be able to take its change back.
    /// Sending the exact price asks nothing of them and goes through.
    function test_aPayerThatRefusesChangeMustSendTheExactPrice() public {
        Sulks payer = new Sulks();
        uint256 price = _price();
        vm.deal(address(payer), 5 ether);

        vm.expectRevert(bytes("no thanks"));
        payer.gift(nft, bob, 5, price + 1 wei);

        payer.gift(nft, bob, 5, price);
        assertEq(nft.ownerOf(5), bob, "exact payment gifted cleanly");
    }

    /// The sale is written before the recipient is asked, so the refusal comes
    /// after those writes. The typed reason shows it came from the hook check
    /// and reverted the whole gift, which takes the writes back with it. The
    /// same character then goes to a wallet as the only sale on the books.
    function test_giftingToAContractWithNoHookRevertsAndWritesNothing() public {
        Deaf deaf = new Deaf();
        uint256 price = _price();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(deaf)));
        nft.mintBlueFor{value: price}(address(deaf), 6, price);

        vm.prank(alice);
        nft.mintBlueFor{value: price}(bob, 6, price);
        assertEq(nft.ownerOf(6), bob, "the character was still for sale");
        assertEq(nft.blueMinted(), 1, "one sale on the books");
        assertEq(nft.blueTakenBits(0, 1)[0], uint256(1) << 6, "and one bit, for the gift that landed");
    }

    function test_giftingToNobodyReverts() public {
        uint256 price = _price();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        nft.mintBlueFor{value: price}(address(0), 7, price);
    }

    /// The recipient's hook is the first handoff to untrusted code, and a gift is
    /// the case where that code did not start the call and may not want to be
    /// there. The lock the external door carries covers it either way. The
    /// green it reaches for is one nobody holds, so the lock is the only thing
    /// that can refuse it.
    function test_aRecipientCannotReEnterThroughItsHook() public {
        Greedy a = new Greedy(nft);
        uint256 price = _price();

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        nft.mintBlueFor{value: price}(address(a), 8, price);

        assertEq(nft.blueMinted(), 0, "nothing minted");
        assertEq(nft.totalSupply(), 0, "nothing at all");
    }

    function test_theSaleStillRefusesACharacterAlreadyTaken() public {
        _buy(alice, 9);
        // Read the price first. Asking for it inside the call would be the call
        // expectRevert is watching.
        uint256 price = _price();

        vm.prank(alice);
        vm.expectRevert(GlamToon.BlueAlreadyTaken.selector);
        nft.mintBlueFor{value: price}(bob, 9, price);
    }

    function test_theCeilingAppliesToAGiftToo() public {
        uint256 price = _price();
        vm.prank(alice);
        vm.expectRevert(GlamToon.PriceTooHigh.selector);
        nft.mintBlueFor{value: price}(bob, 10, price - 1);
    }

    function test_aGiftBeforeTheSaleOpensIsRefused() public {
        vm.warp(SALE_START - 1);
        vm.prank(alice);
        vm.expectRevert(GlamToon.NotStarted.selector);
        nft.mintBlueFor{value: 1 ether}(bob, 11, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                              BATCH READS
    //////////////////////////////////////////////////////////////*/

    function test_greenTakenBatchAgreesWithTheSingleRead() public {
        _green(alice, 100);
        _green(alice, 300);

        uint256[] memory ids = new uint256[](4);
        ids[0] = 300;
        ids[1] = 100;
        ids[2] = 200;
        ids[3] = 10_001;

        bool[] memory taken = nft.greenTakenBatch(ids, alice);
        assertEq(taken.length, 4, "one answer per id");
        assertTrue(taken[0], "300 taken");
        assertTrue(taken[1], "100 taken");
        assertFalse(taken[2], "200 not taken");
        assertFalse(taken[3], "out of range answers false rather than reverting");

        for (uint256 i = 0; i < 3; ++i) {
            assertEq(taken[i], nft.greenTaken(ids[i], alice), "batch disagrees with the single read");
        }
    }

    function test_greenTakenBatchIsPerAddress() public {
        _green(alice, 42);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 42;

        assertTrue(nft.greenTakenBatch(ids, alice)[0], "alice has it");
        assertFalse(nft.greenTakenBatch(ids, bob)[0], "bob does not");
    }

    function test_greenCountBatchAgreesWithTheSingleRead() public {
        _green(alice, 7);
        _green(bob, 7);
        _green(alice, 8);

        uint256[] memory ids = new uint256[](3);
        ids[0] = 7;
        ids[1] = 8;
        ids[2] = 9;

        uint256[] memory counts = nft.greenCountBatch(ids);
        assertEq(counts[0], 2, "two generations");
        assertEq(counts[1], 1, "one generation");
        assertEq(counts[2], 0, "none");

        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(counts[i], nft.greenCount(ids[i]), "batch disagrees with the single read");
        }
    }

    function test_emptyBatchesAnswerEmpty() public view {
        uint256[] memory none = new uint256[](0);
        assertEq(nft.greenTakenBatch(none, alice).length, 0, "no answers");
        assertEq(nft.greenCountBatch(none).length, 0, "no answers");
    }
}

/// Takes tokens, refuses ether.
contract Sulks {
    function gift(GlamToon nft, address to, uint256 imageId, uint256 send) external {
        nft.mintBlueFor{value: send}(to, imageId, send);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        revert("no thanks");
    }
}

/// No receiver hook at all, so ERC721 refuses to mint to it.
contract Deaf {}

/// Takes the gift and tries once to take a green of the same character while
/// the gift is still in flight. Unlike the attackers in the mocks, it does not
/// need to start the call, because a gift arrives unasked.
contract Greedy {
    GlamToon immutable nft;
    bool tried;

    constructor(GlamToon n) {
        nft = n;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (!tried) {
            tried = true;
            nft.mintGreen(tokenId);
        }
        return this.onERC721Received.selector;
    }
}
