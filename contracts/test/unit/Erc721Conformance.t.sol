// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {stdError} from "forge-std/Test.sol";
import {BaseTest} from "../Base.t.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";

/// The sale, the pricing and the metadata are covered elsewhere. The inherited
/// half of this contract is not, and it is the half a marketplace actually
/// drives: ownerOf, the two transfer doors, three kinds of approval, the
/// royalty and the four interface ids a listing is matched on. Inherited code
/// is still shipped code, and OpenZeppelin is a dependency that gets bumped.
///
/// Everything here is asserted against the standard rather than against the
/// implementation: the error each failure must carry, the id each interface is
/// published under, the arithmetic the royalty is defined by.
contract Erc721ConformanceTest is BaseTest {
    /// Redeclared so expectEmit has something to compare against. A signature
    /// that drifts from the token stops matching, which is the point.
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /// The ids ERC-721, its metadata extension, ERC-165 and ERC-2981 publish.
    /// Written out because a marketplace hardcodes these numbers; the tests
    /// below recompute them from selectors rather than trusting the line.
    bytes4 constant PUBLISHED_ERC165 = 0x01ffc9a7;
    bytes4 constant PUBLISHED_ERC721 = 0x80ac58cd;
    bytes4 constant PUBLISHED_ERC721_METADATA = 0x5b5e139f;
    bytes4 constant PUBLISHED_ERC2981 = 0x2a55205a;

    Recorder internal recorder;
    Deaf internal deaf;

    function setUp() public override {
        super.setUp();
        recorder = new Recorder();
        deaf = new Deaf();
    }

    /*//////////////////////////////////////////////////////////////
                           OWNERSHIP AND BALANCE
    //////////////////////////////////////////////////////////////*/

    /// ownerOf must revert rather than answer the zero address, in both id
    /// ranges and off the end of them. A marketplace reads a zero answer as
    /// "unowned but real" and will happily list it.
    function test_ownerOfAnIdThatWasNeverMintedReverts() public {
        uint256 unsoldBlue = 4242;
        uint256 untakenGreen = nft.tokenIdFor(4242, 1);
        uint256 beyond = type(uint256).max;

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, unsoldBlue));
        nft.ownerOf(unsoldBlue);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, untakenGreen));
        nft.ownerOf(untakenGreen);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, beyond));
        nft.ownerOf(beyond);
    }

    /// balanceOf(0) is the standard's one explicit revert on that function.
    /// Answering it would make the zero address look like a holder.
    function test_balanceOfTheZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidOwner.selector, address(0)));
        nft.balanceOf(address(0));
    }

    /// One balance covers both editions. Nothing here keeps a separate count
    /// per edition, so a wallet showing three is showing all of it.
    function test_oneBalanceCountsBothEditions() public {
        _buy(alice, 11);
        _buy(alice, 12);
        _green(alice, 11);

        assertEq(nft.balanceOf(alice), 3, "two blues and a green");
        assertEq(nft.balanceOf(bob), 0, "bob holds nothing");
    }

    /*//////////////////////////////////////////////////////////////
                                TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function test_aTransferMovesTheTokenAndBothBalances() public {
        _buy(alice, 7);
        _buy(alice, 8);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 7);

        assertEq(nft.ownerOf(7), bob, "bob holds it now");
        assertEq(nft.balanceOf(alice), 1, "alice is down one");
        assertEq(nft.balanceOf(bob), 1, "bob is up one");
    }

    /// An indexer rebuilds every holder from this log alone, so the three
    /// indexed fields and the emitter have to be exactly the standard's.
    function test_aTransferLogsTheStandardEvent() public {
        _buy(alice, 9);

        vm.expectEmit(true, true, true, true, address(nft));
        emit Transfer(alice, bob, 9);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 9);
    }

    /// The sale ledger records mints, not holdings. If a transfer ever touched
    /// it, moving a token would reopen a character's genesis or hand back a
    /// spent generation slot.
    function test_aTransferChangesNoSaleRecord() public {
        _buy(alice, 5);
        uint256 green = _green(bob, 5);

        vm.prank(alice);
        nft.transferFrom(alice, carol, 5);
        vm.prank(bob);
        nft.transferFrom(bob, carol, green);

        assertTrue(nft.blueTaken(5), "genesis still sold");
        assertEq(nft.blueMinted(), 1, "sale count untouched");
        assertEq(nft.greenCount(5), 1, "generation count untouched");
        assertTrue(nft.greenTaken(5, bob), "bob's slot is still spent");
        assertFalse(nft.greenTaken(5, carol), "and holding it gave carol nothing");
        assertEq(nft.greenMinted(), 1, "green count untouched");
        assertEq(nft.totalSupply(), 2, "supply counts mints, not holders");
    }

    /// The whole point of the access check. Anyone who is not the owner and
    /// holds no approval must be refused, naming themselves and the token.
    function test_aStrangerCannotMoveSomebodyElsesToken() public {
        _buy(alice, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, uint256(1)));
        nft.transferFrom(alice, bob, 1);

        assertEq(nft.ownerOf(1), alice, "still alice's");
    }

    /// A stale `from` is how a front end sends a transfer against a token that
    /// moved a block ago. It must fail, not move the token anyway.
    function test_aTransferWithTheWrongFromReverts() public {
        _buy(alice, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, bob, uint256(1), alice));
        nft.transferFrom(bob, carol, 1);
    }

    /// Sending a token to yourself is a no-op on balances but still runs the
    /// whole update, so it is the cheapest way to prove the debit and the
    /// credit are not double counted.
    function test_aSelfTransferKeepsTheBalanceAndClearsTheApproval() public {
        _buy(alice, 3);
        vm.prank(alice);
        nft.approve(bob, 3);

        vm.prank(alice);
        nft.transferFrom(alice, alice, 3);

        assertEq(nft.ownerOf(3), alice, "still alice's");
        assertEq(nft.balanceOf(alice), 1, "balance unchanged");
        assertEq(nft.getApproved(3), address(0), "the approval went with the move");
    }

    /// Green ids sit above the blue range and are minted through a different
    /// door, so they get their own pass at the transfer path.
    function test_aLaterGenerationTransfersLikeAGenesis() public {
        _green(alice, 60);
        uint256 second = _green(bob, 60);
        assertEq(nft.generationOf(second), 2, "a second generation");

        vm.prank(bob);
        nft.transferFrom(bob, carol, second);

        assertEq(nft.ownerOf(second), carol, "green moves the same way");
        assertEq(nft.balanceOf(bob), 0, "bob is out");
    }

    /*//////////////////////////////////////////////////////////////
                              SAFE TRANSFERS
    //////////////////////////////////////////////////////////////*/

    /// The difference between the two doors: the plain one does not ask, which
    /// is what lets an escrow or a vault with no hook hold a token.
    function test_aPlainTransferToAContractWithNoHookIsAllowed() public {
        _buy(alice, 2);

        vm.prank(alice);
        nft.transferFrom(alice, address(deaf), 2);

        assertEq(nft.ownerOf(2), address(deaf), "parked in a hookless contract");
    }

    /// And the safe door does ask, so the same contract is refused by name.
    function test_aSafeTransferToAContractWithNoHookIsRefused() public {
        _buy(alice, 2);
        address to = address(deaf);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, to));
        nft.safeTransferFrom(alice, to, 2);

        assertEq(nft.ownerOf(2), alice, "the token never left");
    }

    /// The hook is told who pushed the token, not just who owned it. A
    /// marketplace settling a sale is the operator, and a vault that credits
    /// the wrong one of those two credits the wrong account.
    function test_aSafeTransferTellsTheHookWhoMovedTheToken() public {
        _buy(alice, 4);

        vm.prank(alice);
        nft.safeTransferFrom(alice, address(recorder), 4);

        assertEq(nft.ownerOf(4), address(recorder), "accepted");
        assertEq(recorder.operator(), alice, "alice pushed it");
        assertEq(recorder.from(), alice, "and owned it");
        assertEq(recorder.tokenId(), 4, "the right token");
        assertEq(recorder.data().length, 0, "no payload on the three argument door");
        assertEq(recorder.calls(), 1, "called once");
    }

    /// The four argument door carries a payload, and an operator who is not the
    /// owner shows up as the operator.
    function test_aSafeTransferPassesItsPayloadAndNamesTheOperator() public {
        _buy(alice, 6);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);

        bytes memory payload = hex"c0ffee00decafbad";
        vm.prank(bob);
        nft.safeTransferFrom(alice, address(recorder), 6, payload);

        assertEq(recorder.operator(), bob, "the operator pushed it");
        assertEq(recorder.from(), alice, "the owner it came from");
        assertEq(recorder.data(), payload, "the payload arrived intact");
    }

    /// Zero is refused before the hook is reached, so there is no accidental
    /// burn through the safe door either.
    function test_aSafeTransferToTheZeroAddressIsRefused() public {
        _buy(alice, 2);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        nft.safeTransferFrom(alice, address(0), 2);

        assertEq(nft.ownerOf(2), alice, "still owned");
    }

    /*//////////////////////////////////////////////////////////////
                                APPROVALS
    //////////////////////////////////////////////////////////////*/

    function test_approveIsReadableAndLogged() public {
        _buy(alice, 10);

        vm.expectEmit(true, true, true, true, address(nft));
        emit Approval(alice, bob, 10);

        vm.prank(alice);
        nft.approve(bob, 10);

        assertEq(nft.getApproved(10), bob, "bob may move it");
        assertFalse(nft.isApprovedForAll(alice, bob), "a single token is not a blanket");
    }

    /// A per token approval is spent by the transfer it authorised. If it
    /// survived, the old operator could take the token back off the new owner.
    function test_anApprovalIsSpentByTheTransferItAuthorised() public {
        _buy(alice, 10);
        vm.prank(alice);
        nft.approve(bob, 10);

        vm.prank(bob);
        nft.transferFrom(alice, carol, 10);

        assertEq(nft.ownerOf(10), carol, "moved by the approved address");
        assertEq(nft.getApproved(10), address(0), "and the approval is gone");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, uint256(10)));
        nft.transferFrom(carol, bob, 10);
    }

    function test_approvingTheZeroAddressClearsAnApproval() public {
        _buy(alice, 10);
        vm.startPrank(alice);
        nft.approve(bob, 10);
        nft.approve(address(0), 10);
        vm.stopPrank();

        assertEq(nft.getApproved(10), address(0), "cleared");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, uint256(10)));
        nft.transferFrom(alice, bob, 10);
    }

    /// Approving a token you do not hold must name you as the bad approver,
    /// otherwise a phishing front end can make an approval look like it landed.
    function test_aStrangerCannotApproveSomebodyElsesToken() public {
        _buy(alice, 10);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidApprover.selector, bob));
        nft.approve(carol, 10);
    }

    function test_getApprovedRevertsForAnIdThatWasNeverMinted() public {
        uint256 unsold = 4242;
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, unsold));
        nft.getApproved(unsold);
    }

    /// An operator approves in the owner's name, so the log has to say the
    /// owner. An indexer that recorded the operator would attribute the
    /// approval to the wrong wallet.
    function test_anOperatorApprovesInTheOwnersName() public {
        _buy(alice, 10);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);

        vm.expectEmit(true, true, true, true, address(nft));
        emit Approval(alice, carol, 10);

        vm.prank(bob);
        nft.approve(carol, 10);

        assertEq(nft.getApproved(10), carol, "the operator set it");
    }

    /// A blanket approval is granted once and covers tokens bought afterwards,
    /// which is exactly why marketplaces ask for it.
    function test_aBlanketApprovalCoversTokensBoughtLater() public {
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);

        _buy(alice, 77);
        uint256 green = _green(alice, 77);

        vm.startPrank(bob);
        nft.transferFrom(alice, carol, 77);
        nft.transferFrom(alice, carol, green);
        vm.stopPrank();

        assertEq(nft.ownerOf(77), carol, "blue moved");
        assertEq(nft.ownerOf(green), carol, "green moved");
    }

    /// The per token approval is cleared by a transfer; the blanket one is a
    /// property of the owner and is not.
    function test_aBlanketApprovalOutlivesATransfer() public {
        _buy(alice, 20);
        _buy(alice, 21);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);

        vm.prank(bob);
        nft.transferFrom(alice, carol, 20);

        assertTrue(nft.isApprovedForAll(alice, bob), "still alice's operator");
        vm.prank(bob);
        nft.transferFrom(alice, carol, 21);
        assertEq(nft.ownerOf(21), carol, "and can still move the rest");
    }

    function test_aBlanketApprovalCanBeRevoked() public {
        _buy(alice, 20);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);

        vm.expectEmit(true, true, true, true, address(nft));
        emit ApprovalForAll(alice, bob, false);

        vm.prank(alice);
        nft.setApprovalForAll(bob, false);

        assertFalse(nft.isApprovedForAll(alice, bob), "revoked");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, uint256(20)));
        nft.transferFrom(alice, carol, 20);
    }

    /// Approving the zero address for everything would read as a revocation and
    /// silently leave nothing approved, so the standard makes it an error.
    function test_aBlanketApprovalToTheZeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidOperator.selector, address(0)));
        nft.setApprovalForAll(address(0), true);
    }

    /// Operator approval points one way. Reading the pair backwards must not
    /// answer true.
    function test_operatorApprovalIsDirectional() public {
        assertFalse(nft.isApprovedForAll(alice, bob), "nothing by default");

        vm.prank(alice);
        nft.setApprovalForAll(bob, true);

        assertTrue(nft.isApprovedForAll(alice, bob), "alice trusts bob");
        assertFalse(nft.isApprovedForAll(bob, alice), "bob does not trust alice");
    }

    /*//////////////////////////////////////////////////////////////
                                 ERC-2981
    //////////////////////////////////////////////////////////////*/

    /// The royalty is a default over every id, so it answers for ids that do
    /// not exist and for ids outside both ranges. A marketplace asks before a
    /// listing settles, sometimes before the token is minted.
    function test_theRoyaltyAnswersForAnyIdAtAll() public view {
        uint256 price = 3.33 ether;
        uint256 expected = price / 50;

        uint256[4] memory ids = [uint256(0), nft.tokenIdFor(4242, 1), 4242, type(uint256).max];
        for (uint256 i = 0; i < ids.length; ++i) {
            (address receiver, uint256 amount) = nft.royaltyInfo(ids[i], price);
            assertEq(receiver, address(treasury), "royalty receiver");
            assertEq(amount, expected, "two percent");
        }
    }

    /// Two percent is one fiftieth, computed here rather than copied from the
    /// contract, so a basis point figure that drifts shows up as a number.
    function test_theRoyaltyIsOneFiftiethOfTheSalePrice() public view {
        uint256[5] memory prices = [uint256(1 ether), 0.05 ether, 12_345 wei, 1_000_000 ether, 7 ether];
        for (uint256 i = 0; i < prices.length; ++i) {
            (, uint256 amount) = nft.royaltyInfo(1, prices[i]);
            assertEq(amount, prices[i] / 50, "one fiftieth");
        }
    }

    /// Integer division floors. Worth pinning because a marketplace settling in
    /// a six decimal token trades in numbers this small.
    function test_theRoyaltyRoundsDownAndCanBeZero() public view {
        (, uint256 atFortyNine) = nft.royaltyInfo(1, 49);
        (, uint256 atFifty) = nft.royaltyInfo(1, 50);
        (, uint256 atNinetyNine) = nft.royaltyInfo(1, 99);
        (, uint256 atZero) = nft.royaltyInfo(1, 0);

        assertEq(atFortyNine, 0, "under a whole wei of royalty");
        assertEq(atFifty, 1, "the first whole wei");
        assertEq(atNinetyNine, 1, "still one, rounded down from 1.98");
        assertEq(atZero, 0, "no sale, no royalty");
    }

    /// royaltyInfo multiplies before it divides, so there is a sale price above
    /// which it reverts instead of answering. It sits at max/200, far above any
    /// real denomination, but a caller that sweeps prices needs to know the
    /// edge is a revert and not a wrapped number.
    function test_theRoyaltyOverflowsOnlyAboveMaxOverTheBasisPoints() public {
        uint256 bps = nft.ROYALTY_BPS();
        uint256 highest = type(uint256).max / bps;

        (address receiver, uint256 amount) = nft.royaltyInfo(1, highest);
        assertEq(receiver, address(treasury), "still the treasury at the edge");
        assertEq(amount, highest / 50, "and still one fiftieth");

        uint256 justOver = highest + 1;
        vm.expectRevert(stdError.arithmeticError);
        nft.royaltyInfo(1, justOver);
    }

    /// No per token royalty is ever set, so the two editions of a character owe
    /// the same. A token specific override would break that.
    function test_bothEditionsOfACharacterOweTheSame() public {
        _buy(alice, 33);
        uint256 green = _green(bob, 33);

        (address blueTo, uint256 blueAmount) = nft.royaltyInfo(33, 9 ether);
        (address greenTo, uint256 greenAmount) = nft.royaltyInfo(green, 9 ether);

        assertEq(blueTo, greenTo, "same receiver");
        assertEq(blueAmount, greenAmount, "same amount");
        assertEq(blueAmount, 0.18 ether, "two percent of nine ether");
    }

    /// The receiver is the treasury contract, not the key that owns it and not
    /// where that key currently points sweeps. Those two move; this one cannot.
    function test_theReceiverIsTheTreasuryItselfNotItsOwnerOrBeneficiary() public view {
        (address receiver,) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, address(treasury), "the contract");
        assertTrue(receiver != treasuryOwner, "not the owning key");
        assertTrue(receiver != beneficiary, "not the sweep destination");
        assertTrue(receiver != nft.owner(), "not the marketplace label");
    }

    /// OpenZeppelin's royalty setters are internal. If any of them were ever
    /// exposed, the one number a holder cannot renegotiate would become a
    /// setter. Each is called with arguments it would accept, a whole hundred
    /// percent to alice, by a stranger, the label holder and the beneficiary.
    /// None may answer: the call has to come back with no data at all, which is
    /// how a selector the contract does not have fails.
    function test_nothingReachableCanMoveTheRoyalty() public {
        string[5] memory doors = [
            "setDefaultRoyalty(address,uint96)",
            "deleteDefaultRoyalty()",
            "setTokenRoyalty(uint256,address,uint96)",
            "resetTokenRoyalty(uint256)",
            "_setDefaultRoyalty(address,uint96)"
        ];
        bytes[5] memory calls = [
            abi.encodeWithSignature(doors[0], alice, uint96(10_000)),
            abi.encodeWithSignature(doors[1]),
            abi.encodeWithSignature(doors[2], uint256(1), alice, uint96(10_000)),
            abi.encodeWithSignature(doors[3], uint256(1)),
            abi.encodeWithSignature(doors[4], alice, uint96(10_000))
        ];
        address[3] memory callers = [alice, nft.owner(), beneficiary];
        assertEq(callers[1], treasuryOwner, "the label holder is among the callers");

        for (uint256 i = 0; i < calls.length; ++i) {
            for (uint256 j = 0; j < callers.length; ++j) {
                vm.prank(callers[j]);
                (bool ok, bytes memory answer) = address(nft).call(calls[i]);
                assertFalse(ok, string.concat("this contract answers ", doors[i]));
                assertEq(answer.length, 0, string.concat("this contract knows ", doors[i]));
            }
        }

        uint256[3] memory ids = [uint256(1), 2, nft.tokenIdFor(1, 1)];
        for (uint256 i = 0; i < ids.length; ++i) {
            (address receiver, uint256 amount) = nft.royaltyInfo(ids[i], 1 ether);
            assertEq(receiver, address(treasury), "receiver untouched");
            assertEq(amount, 0.02 ether, "rate untouched");
        }
    }

    /// Handing the treasury to a new key moves the marketplace label, because
    /// that follows the treasury's owner. It must not move the royalty, which
    /// is welded into the token.
    function test_aTreasuryHandoverMovesTheLabelAndNotTheRoyalty() public {
        assertEq(nft.owner(), treasuryOwner, "label starts at the deployer's key");

        vm.prank(treasuryOwner);
        treasury.transferOwnership(carol);
        vm.prank(carol);
        treasury.acceptOwnership();

        assertEq(nft.owner(), carol, "the label followed the treasury");

        vm.prank(carol);
        (bool ok,) =
            address(nft).call(abi.encodeWithSignature("setDefaultRoyalty(address,uint96)", carol, uint96(10_000)));
        assertFalse(ok, "the new owner found a setter");

        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, address(treasury), "royalties still land in the treasury");
        assertEq(amount, 0.02 ether, "still two percent");
    }

    /*//////////////////////////////////////////////////////////////
                                 ERC-165
    //////////////////////////////////////////////////////////////*/

    /// The four ids are XORs of selectors, not magic numbers. Recomputing them
    /// here means the tests still mean something if the published constants at
    /// the top of this file are wrong.
    function test_theInterfaceIdsAreTheXorOfTheirOwnSelectors() public pure {
        assertEq(_erc165Id(), PUBLISHED_ERC165, "ERC-165");
        assertEq(_erc721Id(), PUBLISHED_ERC721, "ERC-721");
        assertEq(_erc721MetadataId(), PUBLISHED_ERC721_METADATA, "ERC-721 Metadata");
        assertEq(_erc2981Id(), PUBLISHED_ERC2981, "ERC-2981");
    }

    function test_everyInterfaceItClaimsIsOneItComputes() public view {
        assertTrue(nft.supportsInterface(_erc165Id()), "ERC-165");
        assertTrue(nft.supportsInterface(_erc721Id()), "ERC-721");
        assertTrue(nft.supportsInterface(_erc721MetadataId()), "ERC-721 Metadata");
        assertTrue(nft.supportsInterface(_erc2981Id()), "ERC-2981");
    }

    /// ERC-165 names 0xffffffff explicitly: a contract that answers true to it
    /// is not a conforming ERC-165 contract at all.
    function test_theAllOnesIdIsRefused() public view {
        assertFalse(nft.supportsInterface(0xffffffff), "0xffffffff must be false");
    }

    /// A supportsInterface stuck on true would pass every test above. These are
    /// the ids that catch it, including enumerable, which this collection
    /// deliberately does not implement.
    function test_interfacesItDoesNotHaveAreRefused() public view {
        bytes4 enumerable = bytes4(keccak256("totalSupply()"))
            ^ bytes4(keccak256("tokenOfOwnerByIndex(address,uint256)")) ^ bytes4(keccak256("tokenByIndex(uint256)"));
        assertFalse(nft.supportsInterface(enumerable), "ERC-721 Enumerable is not implemented");
        assertFalse(nft.supportsInterface(0x00000000), "the zero id");
        assertFalse(nft.supportsInterface(bytes4(keccak256("Glamtoon"))), "a made up id");
    }

    /// Real ids a marketplace or wallet acts on. Claiming ERC-173 would dress the
    /// label up as an ownership standard, 4906 promises refresh events that are
    /// never emitted, and 5192 would mark every token as locked. Each is refused
    /// by name, recomputed from its selectors where the standard defines it that
    /// way.
    function test_wellKnownInterfacesItDoesNotImplementAreRefused() public view {
        assertEq(
            bytes4(keccak256("owner()")) ^ bytes4(keccak256("transferOwnership(address)")),
            bytes4(0x7f5828d0),
            "ERC-173 id"
        );
        assertEq(bytes4(keccak256("locked(uint256)")), bytes4(0xb45a3c0e), "ERC-5192 id");
        assertEq(
            bytes4(keccak256("setUser(uint256,address,uint64)")) ^ bytes4(keccak256("userOf(uint256)"))
                ^ bytes4(keccak256("userExpires(uint256)")),
            bytes4(0xad092b5c),
            "ERC-4907 id"
        );

        assertFalse(nft.supportsInterface(0x7f5828d0), "ERC-173 ownership");
        assertFalse(nft.supportsInterface(0x49064906), "ERC-4906 metadata update");
        assertFalse(nft.supportsInterface(0xb45a3c0e), "ERC-5192 soulbound");
        assertFalse(nft.supportsInterface(0x780e9d63), "ERC-721 Enumerable");
        assertFalse(nft.supportsInterface(0xad092b5c), "ERC-4907 rental");
        assertFalse(nft.supportsInterface(0x150b7a02), "ERC-721 receiver");
        assertFalse(nft.supportsInterface(0xd9b67a26), "ERC-1155");
        assertFalse(nft.supportsInterface(0x0e89341c), "ERC-1155 metadata URI");
    }

    /// Two more ids a wallet or marketplace acts on without asking. A claimed
    /// 4494 invites signed approvals sent to a permit that is not here, and a
    /// claimed 7496 has a marketplace read dynamic traits from functions that
    /// do not exist. The fuzz below cannot land on either by chance, so each is
    /// recomputed from its selectors and refused by name.
    function test_thePermitAndDynamicTraitExtensionsAreRefused() public view {
        string[] memory permit = new string[](3);
        permit[0] = "permit(address,uint256,uint256,bytes)";
        permit[1] = "nonces(uint256)";
        permit[2] = "DOMAIN_SEPARATOR()";
        assertEq(_xor(permit), bytes4(0x5604e225), "ERC-4494 id");

        string[] memory traits = new string[](4);
        traits[0] = "getTraitValue(uint256,bytes32)";
        traits[1] = "getTraitValues(uint256,bytes32[])";
        traits[2] = "getTraitMetadataURI()";
        traits[3] = "setTrait(uint256,bytes32,bytes32)";
        assertEq(_xor(traits), bytes4(0xaf332f3e), "ERC-7496 id");

        assertFalse(nft.supportsInterface(0x5604e225), "ERC-4494 permit");
        assertFalse(nft.supportsInterface(0xaf332f3e), "ERC-7496 dynamic traits");
    }

    /// Exactly four ids answer true and every other one answers false.
    function testFuzz_supportsInterfaceIsExactlyTheFour(bytes4 id) public view {
        bool claimed = id == PUBLISHED_ERC165 || id == PUBLISHED_ERC721 || id == PUBLISHED_ERC721_METADATA
            || id == PUBLISHED_ERC2981;
        assertEq(nft.supportsInterface(id), claimed, "only the four published ids are claimed");
    }

    /// Claiming an id is a promise that every selector behind it answers. This
    /// drives all fourteen of them for real, so a claim cannot outlive the
    /// function it stands for.
    function test_everySelectorBehindTheClaimedIdsActuallyAnswers() public {
        _buy(alice, 1);
        _buy(alice, 2);
        _buy(alice, 3);

        _answers(bob, abi.encodeWithSignature("balanceOf(address)", alice), "balanceOf");
        _answers(bob, abi.encodeWithSignature("ownerOf(uint256)", uint256(1)), "ownerOf");
        _answers(bob, abi.encodeWithSignature("getApproved(uint256)", uint256(1)), "getApproved");
        _answers(bob, abi.encodeWithSignature("isApprovedForAll(address,address)", alice, bob), "isApprovedForAll");
        _answers(alice, abi.encodeWithSignature("approve(address,uint256)", bob, uint256(1)), "approve");
        _answers(alice, abi.encodeWithSignature("setApprovalForAll(address,bool)", bob, true), "setApprovalForAll");
        _answers(
            alice,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, bob, uint256(1)),
            "transferFrom"
        );
        _answers(
            alice,
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, bob, uint256(2)),
            "safeTransferFrom"
        );
        _answers(
            alice,
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", alice, bob, uint256(3), hex"01"),
            "safeTransferFrom with data"
        );

        _answers(bob, abi.encodeWithSignature("name()"), "name");
        _answers(bob, abi.encodeWithSignature("symbol()"), "symbol");
        _answers(bob, abi.encodeWithSignature("tokenURI(uint256)", uint256(1)), "tokenURI");
        _answers(bob, abi.encodeWithSignature("supportsInterface(bytes4)", PUBLISHED_ERC165), "supportsInterface");
        _answers(
            bob, abi.encodeWithSignature("royaltyInfo(uint256,uint256)", uint256(1), uint256(1 ether)), "royaltyInfo"
        );

        assertEq(nft.balanceOf(bob), 3, "all three doors delivered");
    }

    /*//////////////////////////////////////////////////////////////
                            METADATA SURFACE
    //////////////////////////////////////////////////////////////*/

    /// Nothing writes these, and nothing should ever make them depend on state.
    function test_theNameAndSymbolDoNotMoveWithTheSale() public {
        _buy(alice, 1);
        _green(bob, 1);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);

        assertEq(nft.name(), "Glamtoon", "name");
        assertEq(nft.symbol(), "GLAMTOON", "symbol");
    }

    /// tokenURI is the one metadata call the standard scopes to existing
    /// tokens, and the error has to carry the id so a caller can tell an
    /// unminted token from a broken contract.
    function test_tokenUriRefusesAnIdThatWasNeverMintedAndNamesIt() public {
        uint256 unsoldBlue = 4242;
        uint256 untakenGreen = nft.tokenIdFor(4242, 1);
        uint256 beyond = type(uint256).max;

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, unsoldBlue));
        nft.tokenURI(unsoldBlue);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, untakenGreen));
        nft.tokenURI(untakenGreen);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, beyond));
        nft.tokenURI(beyond);
    }

    /// A token that has moved on is still a token. The existence check follows
    /// ownership, and the document itself does not depend on who holds it.
    function test_tokenUriAnswersForBothEditionsAndDoesNotFollowTheOwner() public {
        _buy(alice, 1);
        uint256 green = _green(alice, 1);

        string memory blueBefore = nft.tokenURI(1);
        string memory greenBefore = nft.tokenURI(green);
        assertGt(bytes(blueBefore).length, 0, "blue has metadata");
        assertGt(bytes(greenBefore).length, 0, "green has metadata");

        vm.startPrank(alice);
        nft.transferFrom(alice, bob, 1);
        nft.transferFrom(alice, bob, green);
        vm.stopPrank();

        assertEq(nft.tokenURI(1), blueBefore, "blue unchanged by the move");
        assertEq(nft.tokenURI(green), greenBefore, "green unchanged by the move");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// An interface id is the XOR of the selectors of every function the
    /// interface declares, which is what ERC-165 defines and what a marketplace
    /// reimplements at its end.
    function _xor(string[] memory sigs) internal pure returns (bytes4 id) {
        for (uint256 i = 0; i < sigs.length; ++i) {
            id ^= bytes4(keccak256(bytes(sigs[i])));
        }
    }

    function _erc165Id() internal pure returns (bytes4) {
        string[] memory sigs = new string[](1);
        sigs[0] = "supportsInterface(bytes4)";
        return _xor(sigs);
    }

    function _erc721Id() internal pure returns (bytes4) {
        string[] memory sigs = new string[](9);
        sigs[0] = "balanceOf(address)";
        sigs[1] = "ownerOf(uint256)";
        sigs[2] = "safeTransferFrom(address,address,uint256,bytes)";
        sigs[3] = "safeTransferFrom(address,address,uint256)";
        sigs[4] = "transferFrom(address,address,uint256)";
        sigs[5] = "approve(address,uint256)";
        sigs[6] = "setApprovalForAll(address,bool)";
        sigs[7] = "getApproved(uint256)";
        sigs[8] = "isApprovedForAll(address,address)";
        return _xor(sigs);
    }

    function _erc721MetadataId() internal pure returns (bytes4) {
        string[] memory sigs = new string[](3);
        sigs[0] = "name()";
        sigs[1] = "symbol()";
        sigs[2] = "tokenURI(uint256)";
        return _xor(sigs);
    }

    function _erc2981Id() internal pure returns (bytes4) {
        string[] memory sigs = new string[](1);
        sigs[0] = "royaltyInfo(uint256,uint256)";
        return _xor(sigs);
    }

    /// Calls a selector for real and insists it went through. A function that
    /// is not there fails here, whatever supportsInterface claims.
    function _answers(address caller, bytes memory data, string memory what) internal {
        vm.prank(caller);
        (bool ok,) = address(nft).call(data);
        assertTrue(ok, string.concat("no answer from ", what));
    }
}

/*//////////////////////////////////////////////////////////////
                                MOCKS
//////////////////////////////////////////////////////////////*/

/// Accepts tokens and keeps what the hook was told, so a test can assert the
/// operator and the payload rather than only that the transfer landed.
contract Recorder {
    address public operator;
    address public from;
    uint256 public tokenId;
    bytes public data;
    uint256 public calls;

    function onERC721Received(address op, address f, uint256 id, bytes calldata d) external returns (bytes4) {
        operator = op;
        from = f;
        tokenId = id;
        data = d;
        calls += 1;
        return this.onERC721Received.selector;
    }
}

/// A contract with no receiver hook, the thing the safe door exists to catch.
contract Deaf {
    uint256 public something;

    function poke() external {
        something += 1;
    }
}
