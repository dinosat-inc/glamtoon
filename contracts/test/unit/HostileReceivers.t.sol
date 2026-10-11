// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "openzeppelin/utils/ReentrancyGuardTransient.sol";
import {Errors} from "openzeppelin/utils/Errors.sol";

/// The second half of the receiver question. Receivers.t.sol asks whether a
/// recipient can be given a token; this file asks what a recipient can do with
/// the moment of control it is handed, and what that costs the person paying.
///
/// Three things are being pinned down. First, that a hook's answer is a decision
/// about one token and nothing is carried over from the last one. Second, that
/// the guard is drawn around the four doors and not around the reads, so a
/// recipient can look at the collection mid-mint but cannot move anything.
/// Third, the arithmetic: how much gas the hook is promised and how much a
/// hostile recipient or a hostile payer can make the payer burn. There is no
/// admin and no pause, so every one of these numbers is fixed at deploy.
contract HostileReceiversTest is BaseTest {
    bytes4 constant MAGIC = 0x150b7a02;

    /// Everything a failed mint must leave exactly where it found it.
    struct State {
        uint256 blueMinted;
        uint256 greenMinted;
        uint256 totalSupply;
        uint256 bitmapWord;
        uint256 greenCount;
        bool greenTaken;
        bool blueTaken;
        uint256 nftBalance;
    }

    function _snap(uint256 imageId, address who) internal view returns (State memory s) {
        s.blueMinted = nft.blueMinted();
        s.greenMinted = nft.greenMinted();
        s.totalSupply = nft.totalSupply();
        s.bitmapWord = nft.blueTakenBits(imageId >> 8, 1)[0];
        s.greenCount = nft.greenCount(imageId);
        s.greenTaken = nft.greenTaken(imageId, who);
        s.blueTaken = nft.blueTaken(imageId);
        s.nftBalance = address(nft).balance;
    }

    function _assertUnmoved(State memory before, uint256 imageId, address who, string memory what) internal view {
        State memory now_ = _snap(imageId, who);
        assertEq(now_.blueMinted, before.blueMinted, string.concat(what, ": blueMinted moved"));
        assertEq(now_.greenMinted, before.greenMinted, string.concat(what, ": greenMinted moved"));
        assertEq(now_.totalSupply, before.totalSupply, string.concat(what, ": totalSupply moved"));
        assertEq(now_.bitmapWord, before.bitmapWord, string.concat(what, ": a bitmap bit was set"));
        assertEq(now_.greenCount, before.greenCount, string.concat(what, ": greenCount moved"));
        assertEq(now_.greenTaken, before.greenTaken, string.concat(what, ": a green slot was spent"));
        assertEq(now_.blueTaken, before.blueTaken, string.concat(what, ": the character was marked sold"));
        assertEq(now_.nftBalance, before.nftBalance, string.concat(what, ": ether stuck in the collection"));
    }

    /// Gas charged to the payer for one gift mint, measured end to end from
    /// outside the collection so the receiver's own frame is included.
    function _giftCost(address to, uint256 imageId) internal returns (uint256 used, bool ok) {
        uint256 price = _price();
        uint256 before = gasleft();
        (ok,) = address(nft).call{value: price}(abi.encodeCall(nft.mintBlueFor, (to, imageId, price)));
        used = before - gasleft();
    }

    /*//////////////////////////////////////////////////////////////
                    A RECEIVER THAT CHANGES ITS MIND
    //////////////////////////////////////////////////////////////*/

    /// Nothing about a receiver is remembered between mints, so the fact that a
    /// contract took delivery once says nothing about the next time. A buyer
    /// about to gift a second token to a wallet that accepted the first has no
    /// guarantee at all. Catches a receiver check cached per address.
    function test_aReceiverThatTookOneTokenCanRefuseTheNext() public {
        Fickle r = new Fickle(1);
        uint256 price = _price();

        vm.prank(alice);
        nft.mintBlueFor{value: price}(address(r), 1000, price);
        assertEq(nft.ownerOf(1000), address(r), "the first one landed");
        assertEq(r.accepted(), 1, "and the hook counted it");

        State memory before = _snap(1001, address(r));
        price = _price();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(r)));
        nft.mintBlueFor{value: price}(address(r), 1001, price);

        _assertUnmoved(before, 1001, address(r), "second gift");
        assertEq(nft.balanceOf(address(r)), 1, "still holding exactly the one it wanted");
    }

    /// The reason a refusal is sticky: the hook's own counter is written in a
    /// frame the collection then reverts, so the receiver's bookkeeping rolls
    /// back with everything else. The hook logs what it counted while it ran,
    /// so each refused mint is seen reaching the hook, counting itself as the
    /// second call and saying no, and the count is back to one afterwards. A
    /// contract cannot implement "take every other token" through its hook,
    /// because the ones it refuses never happened. Catches a _safeMint
    /// downgraded to _mint, where the hook would never be asked at all and the
    /// refused gifts would land.
    function test_aRefusalRollsBackTheReceiversOwnBookkeepingToo() public {
        Fickle r = new Fickle(1);
        uint256 price = _price();

        vm.prank(alice);
        nft.mintBlueFor{value: price}(address(r), 1010, price);
        assertEq(r.seen(), 1, "one hook call survived");

        for (uint256 i = 0; i < 3; ++i) {
            price = _price();
            vm.recordLogs();
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(r)));
            nft.mintBlueFor{value: price}(address(r), 1011 + i, price);
            (uint256 counted, bool said) = _whatTheHookSaw(vm.getRecordedLogs(), address(r), 1011 + i);

            assertEq(counted, 2, "the hook did not count the refused call while it ran");
            assertFalse(said, "the hook said yes to a token it had no room for");
            assertEq(r.seen(), 1, "the refused call left no trace in the receiver either");
        }

        assertEq(nft.blueMinted(), 1, "one sale out of four attempts");
    }

    /// A refused green must hand the generation back. The counter and the per
    /// address flag are both written before the hook runs, so if the unwind were
    /// ever partial the next minter would get generation two of a character
    /// whose generation one does not exist. There is no burn to fix that.
    function test_aRefusedGreenLeavesTheGenerationForTheNextComer() public {
        Fickle r = new Fickle(0);
        State memory before = _snap(1020, address(r));

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(r)));
        r.green(nft, 1020);
        _assertUnmoved(before, 1020, address(r), "refused green");

        uint256 tokenId = _green(bob, 1020);
        assertEq(tokenId, nft.tokenIdFor(1020, 1), "bob got generation one, not two");
        assertEq(nft.ownerOf(tokenId), bob, "and it is his");
        assertEq(nft.greenCount(1020), 1, "exactly one generation exists");
        assertFalse(nft.greenTaken(1020, address(r)), "the refuser's own slot is untouched");
    }

    /// The other direction: a receiver that refuses and then relents. The
    /// character it turned down must still be there at the same price, because
    /// a refusal is not a sale. Catches a bitmap bit or a blueMinted increment
    /// left behind by a failed mint.
    function test_aReceiverThatRelentsCanStillBeGivenTheCharacterItRefused() public {
        Fickle r = new Fickle(0);
        uint256 price = _price();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(r)));
        nft.mintBlueFor{value: price}(address(r), 1030, price);

        r.relent();

        assertEq(nft.currentPrice(), price, "the price never moved");
        vm.prank(alice);
        nft.mintBlueFor{value: price}(address(r), 1030, price);
        assertEq(nft.ownerOf(1030), address(r), "the same character, second time lucky");
        assertEq(nft.blueMinted(), 1, "counted once");
    }

    /*//////////////////////////////////////////////////////////////
              READING THE COLLECTION FROM INSIDE THE HOOK
    //////////////////////////////////////////////////////////////*/

    /// The guard is on the doors, not on the reads, and this is what that buys:
    /// every view answers mid-mint with exactly what it answers afterwards. A
    /// receiving vault can index the token, price the next one, or render its
    /// metadata without waiting for the transaction to land. Catches any state
    /// write moved to after _safeMint, and catches a view given a nonReentrant
    /// modifier, which would make the whole set unreadable here.
    function test_everyViewAnswersTheSameInsideTheHookAsItDoesAfterwards() public {
        Reader r = new Reader(nft);
        uint256 price = _price();

        vm.prank(alice);
        nft.mintBlueFor{value: price}(address(r), 1100, price);

        assertEq(r.seenOwner(), address(r), "ownerOf");
        assertEq(r.seenOwner(), nft.ownerOf(1100), "ownerOf still");
        assertEq(r.seenBalance(), nft.balanceOf(address(r)), "balanceOf");
        assertEq(r.seenTotalSupply(), nft.totalSupply(), "totalSupply");
        assertEq(r.seenBlueMinted(), nft.blueMinted(), "blueMinted");
        assertEq(r.seenBitmapWord(), nft.blueTakenBits(1100 >> 8, 1)[0], "blueTakenBits");
        assertEq(r.seenBitmapWords(), nft.blueBitmapWords(), "blueBitmapWords");
        assertEq(r.seenPrice(), nft.currentPrice(), "currentPrice, already stepped for this sale");
        assertEq(r.seenGreenCount(), nft.greenCount(1100), "greenCount");
        assertEq(r.seenTrait0(), nft.traitsOf(1100)[0], "traitsBatch");
        assertTrue(r.seenIsBlue(), "isBlue");
    }

    /// tokenURI is the view a marketplace calls the instant it sees the Transfer
    /// log, and the log is emitted before the hook. So the document has to be
    /// renderable from inside the hook, not one call later. Catches metadata
    /// that depends on a write landing after _safeMint.
    function test_tokenURIIsAlreadyRenderableInsideTheHookTheMintCalled() public {
        Reader r = new Reader(nft);
        uint256 price = _price();

        vm.prank(alice);
        nft.mintBlueFor{value: price}(address(r), 1110, price);

        string memory seen = r.seenUri();
        assertGt(bytes(seen).length, 128, "a real document, not an empty string");
        assertEq(keccak256(bytes(seen)), keccak256(bytes(nft.tokenURI(1110))), "identical to the settled answer");
        assertEq(
            keccak256(bytes(_prefix(seen, 29))),
            keccak256(bytes("data:application/json;base64,")),
            "and it is a data URI"
        );
        assertEq(keccak256(bytes(r.seenJson())), keccak256(bytes(nft.tokenJSON(1110))), "tokenJSON matches too");
    }

    /// Same question on the free door, where the generation number in the name
    /// is derived from a counter written moments earlier.
    function test_theGreenDocumentIsRenderableInsideTheGreenHook() public {
        Reader r = new Reader(nft);

        r.green(nft, 1120);

        uint256 tokenId = nft.tokenIdFor(1120, 1);
        assertEq(keccak256(bytes(r.seenUri())), keccak256(bytes(nft.tokenURI(tokenId))), "green metadata matches");
        assertFalse(r.seenIsBlue(), "and it knows it is a green");
        assertEq(r.seenGreenCount(), 1, "the generation was already counted");
    }

    /*//////////////////////////////////////////////////////////////
               RE-ENTERING A DIFFERENT DOOR FROM THE HOOK
    //////////////////////////////////////////////////////////////*/

    /// The guard is per contract, not per function, so opening one door shuts
    /// all four. A recipient of a blue cannot take a free green in the same
    /// breath. Asserted with the typed error, because "it reverted" would also
    /// pass if the free door had simply broken.
    function test_theGreenDoorIsShutToAHookTheBlueDoorOpened() public {
        Intruder r = new Intruder(nft, Intruder.Door.Green);
        uint256 price = _price();
        State memory before = _snap(1200, address(r));

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        nft.mintBlueFor{value: price}(address(r), 1200, price);

        _assertUnmoved(before, 1200, address(r), "green from a blue hook");
    }

    /// And the other way round. The free door is the cheap one to reach, so a
    /// green hook reaching back for a paid mint is the shape an attacker would
    /// actually try: it costs nothing to set up. The hook reaches once, for a
    /// character nobody holds and with the money to pay for it, so the typed
    /// error can only come from the lock the free door took. Catches a mintGreen
    /// that checks the lock without holding it.
    function test_theBlueDoorIsShutToAHookTheGreenDoorOpened() public {
        Intruder r = new Intruder(nft, Intruder.Door.Blue);
        vm.deal(address(r), 10 ether);
        State memory before = _snap(1210, address(r));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        r.green(nft, 1210);

        _assertUnmoved(before, 1210, address(r), "blue from a green hook");
        assertEq(address(nft).balance, 0, "no payment got through either");
    }

    /// The gift door shares the guard with the door it was called through, so a
    /// recipient cannot mint onward to a third party from inside its hook.
    function test_theGiftDoorIsShutToAHookToo() public {
        Intruder r = new Intruder(nft, Intruder.Door.Gift);
        vm.deal(address(r), 10 ether);
        uint256 price = _price();
        State memory before = _snap(1220, address(r));

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        nft.mintBlueFor{value: price}(address(r), 1220, price);

        _assertUnmoved(before, 1220, address(r), "gift from a hook");
    }

    /// withdraw shares the guard as well, and it is the one that matters most:
    /// the collection is holding the sale's takings at exactly the moment the
    /// hook runs. Typed error, and the money checked on both sides.
    function test_withdrawIsShutToAHookAndTheTakingsStayPut() public {
        _buy(alice, 1230);
        _buy(bob, 1231);
        uint256 held = address(nft).balance;
        assertGt(held, 0, "there is something worth taking");

        Intruder r = new Intruder(nft, Intruder.Door.Withdraw);
        uint256 price = _price();
        State memory before = _snap(1232, address(r));

        vm.prank(carol);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        nft.mintBlueFor{value: price}(address(r), 1232, price);

        _assertUnmoved(before, 1232, address(r), "withdraw from a hook");
        assertEq(address(nft).balance, held, "the takings did not move");
        assertEq(address(treasury).balance, 0, "and nothing was pushed out early");

        nft.withdraw();
        assertEq(address(treasury).balance, held, "and withdraw still works once the door is closed");
    }

    /// The contrast that makes the guard legible: it is drawn around the four
    /// doors and nothing else. Plain ERC-721 transfers are untouched, so a vault
    /// can sweep the token onward the moment it arrives. Catches a guard
    /// widened onto the token core, which would silently break every forwarding
    /// wallet on the chain.
    function test_anOrdinaryTransferIsStillAllowedFromInsideTheHook() public {
        address vault = vm.addr(0x5151);
        Intruder r = new Intruder(nft, Intruder.Door.None);
        r.forwardTo(vault);
        uint256 price = _price();

        vm.prank(alice);
        nft.mintBlueFor{value: price}(address(r), 1240, price);

        assertEq(nft.ownerOf(1240), vault, "the transfer went through from inside the hook");
        assertEq(nft.blueMinted(), 1, "and the sale completed");
    }

    /*//////////////////////////////////////////////////////////////
             A HOOK THAT PASSES THE TOKEN ON AND THEN FAILS
    //////////////////////////////////////////////////////////////*/

    /// The nastiest shape in the file. The hook moves the token to a third party,
    /// emitting a real Transfer, and only then reverts. Two Transfers are emitted
    /// and a trace shows both, but a node keeps the logs of a reverted frame out
    /// of the receipt and the chain keeps none of it: the fence holds nothing and
    /// the token does not exist. Asserted from both ends, because an indexer
    /// reading traces rather than receipts would credit the fence forever.
    function test_aHookThatForwardsTheTokenAndThenRevertsLeavesNobodyHoldingIt() public {
        address fence = vm.addr(0x6161);
        Runner r = new Runner(nft, fence, true);
        uint256 price = _price();
        State memory before = _snap(1300, address(r));

        vm.recordLogs();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "changed my mind"));
        nft.mintBlueFor{value: price}(address(r), 1300, price);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 transfers;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")) ++transfers;
        }
        assertEq(transfers, 2, "the trace really did carry a mint and a forward");

        _assertUnmoved(before, 1300, address(r), "forward then revert");
        assertEq(nft.balanceOf(fence), 0, "the fence holds nothing");
        assertEq(nft.balanceOf(address(r)), 0, "and neither does the runner");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(1300)));
        nft.ownerOf(1300);

        _buy(bob, 1300);
        assertEq(nft.ownerOf(1300), bob, "the character was never consumed");
    }

    /// The same move, but the hook answers wrong instead of reverting. The
    /// acceptance test is the four bytes the hook returns, not where the token
    /// ended up, so this is still a refusal even though `to` no longer holds it.
    /// Catches a receiver check rewritten as "does `to` own it afterwards",
    /// which a forwarding vault would fail and this contract would wave through.
    function test_aHookThatForwardsTheTokenAndThenAnswersWrongIsStillRefused() public {
        address fence = vm.addr(0x6262);
        Runner r = new Runner(nft, fence, false);
        r.setAnswer(bytes4(0xdeadbeef));
        uint256 price = _price();
        State memory before = _snap(1310, address(r));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(r)));
        nft.mintBlueFor{value: price}(address(r), 1310, price);

        _assertUnmoved(before, 1310, address(r), "forward then answer wrong");
        assertEq(nft.balanceOf(fence), 0, "the fence holds nothing");
    }

    /// Third variant: the hook does everything right, the token is already with
    /// the third party, and the refund to the payer is what fails. The refund is
    /// the last thing _mintBlue does, so this is the latest point at which a
    /// mint can still come apart, and it has to take the forwarded token with it.
    function test_aForwardedTokenIsClawedBackWhenTheRefundFails() public {
        address fence = vm.addr(0x6363);
        Runner r = new Runner(nft, fence, false);
        Tightfisted payer = new Tightfisted(nft);
        vm.deal(address(payer), 10 ether);
        uint256 price = _price();
        State memory before = _snap(1320, address(r));

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "keep it"));
        payer.giftOverpaying(address(r), 1320, price);

        _assertUnmoved(before, 1320, address(r), "refund refused after forwarding");
        assertEq(nft.balanceOf(fence), 0, "the fence had to give it back");

        payer.giftExactly(address(r), 1320, price);
        assertEq(nft.ownerOf(1320), fence, "paying exactly needs no refund, and the fence keeps it");
        assertEq(nft.blueMinted(), 1, "counted once");
    }

    /*//////////////////////////////////////////////////////////////
                RETURN BOMBS, AND WHAT THEY COST THE PAYER
    //////////////////////////////////////////////////////////////*/

    /// Three bomb sizes against a measured baseline. The surcharge the payer
    /// eats is the receiver's own memory expansion and nothing else: the
    /// collection asks for four bytes back and never copies the rest. Numbers
    /// are measured on this build, not derived from the source.
    function test_aReturnBombCostsThePayerOnlyTheReceiversOwnMemory() public {
        _skipUnderCoverage();
        vm.deal(address(this), 1000 ether);
        // one mint first so blueMinted, the bitmap word and the price are all warm
        uint256 warm = _price();
        nft.mintBlueFor{value: warm}(address(new Plain()), 1400, warm);

        (uint256 base, bool okBase) = _giftCost(address(new Plain()), 1401);
        (uint256 c1k, bool ok1k) = _giftCost(address(new Bomber(MAGIC, 1024)), 1402);
        (uint256 c64k, bool ok64k) = _giftCost(address(new Bomber(MAGIC, 65_536)), 1403);
        (uint256 c256k, bool ok256k) = _giftCost(address(new Bomber(MAGIC, 262_144)), 1404);

        assertTrue(okBase && ok1k && ok64k && ok256k, "padding after a correct answer is still a yes");
        assertEq(nft.blueMinted(), 5, "all five sales landed");

        assertLt(c1k - base, 1_000, "a kilobyte is lost in the noise");
        assertGt(c64k - base, 13_000, "64kB costs the payer real gas");
        assertLt(c64k - base, 16_000, "but only the receiver's memory expansion");
        assertGt(c256k - base, 150_000, "256kB costs a lot more");
        assertLt(c256k - base, 175_000, "and still only the receiver's memory expansion");
    }

    /// The same surcharge held against the EVM's own price for memory rather
    /// than a measured figure: three gas a word plus the words squared over
    /// 512, for the bomb and nothing else. The allowance covers the two
    /// receivers' differing code. A collection that copied the answer would pay
    /// for a second expansion of the same size in its own frame and land at
    /// well over double, far outside it. Catches the collection being changed
    /// to read the hook's answer as bytes rather than bytes4.
    function test_theCollectionNeverCopiesAnAcceptingHooksAnswer() public {
        vm.deal(address(this), 1000 ether);
        uint256 warm = _price();
        nft.mintBlueFor{value: warm}(address(new Plain()), 1410, warm);

        (uint256 base,) = _giftCost(address(new Plain()), 1411);
        (uint256 c64k,) = _giftCost(address(new Bomber(MAGIC, 65_536)), 1412);
        (uint256 c256k,) = _giftCost(address(new Bomber(MAGIC, 262_144)), 1413);

        assertApproxEqAbs(c64k - base, _memoryCost(65_536), 2_000, "64kB cost other than the bomb's own memory");
        assertApproxEqAbs(c256k - base, _memoryCost(262_144), 2_000, "256kB cost other than the bomb's own memory");
        assertGt(c256k - base, 8 * (c64k - base), "and the bill grows quadratically with the bomb");
    }

    /// The other branch, and the one that does copy: a hook that reverts with a
    /// wall of data. The catch arm takes the whole revert reason into memory and
    /// bubbles it, so the payer pays twice over. It still cannot buy anything
    /// with that, which is the point. A bounded budget so the test survives it.
    function test_aRevertBombIsCopiedWholeAndStillOnlyUnwindsTheSale() public {
        Detonator r = new Detonator(65_536);
        vm.deal(address(this), 100 ether);
        uint256 price = _price();
        State memory before = _snap(1420, address(r));

        (bool ok, bytes memory ret) =
            address(nft).call{gas: 3_000_000, value: price}(abi.encodeCall(nft.mintBlueFor, (address(r), 1420, price)));

        assertFalse(ok, "no sale");
        assertEq(ret.length, 65_536, "the whole reason came back up, byte for byte");
        _assertUnmoved(before, 1420, address(r), "revert bomb");

        _buy(bob, 1420);
        assertEq(nft.ownerOf(1420), bob, "the character survived it");
    }

    /*//////////////////////////////////////////////////////////////
                      THE PAYER, NOT THE RECIPIENT
    //////////////////////////////////////////////////////////////*/

    /// Overpaying puts a second piece of untrusted code in the mint: the refund
    /// calls the payer back. It runs under the same guard as the hook, so a
    /// payer that re-enters a door during its own refund kills its own sale.
    /// Catches the guard being released before the refund, which would let a
    /// payer start fresh mints from inside a sale that has not finished.
    function test_aPayerThatReEntersADoorDuringItsRefundLosesTheWholeSale() public {
        Returner p = new Returner(nft, Returner.Mode.Mint);
        vm.deal(address(p), 100 ether);
        uint256 price = _price();
        State memory before = _snap(1500, address(p));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        p.buyOverpaying(1500, price, 1 ether);

        _assertUnmoved(before, 1500, address(p), "reentrant payer");
        assertEq(nft.currentPrice(), price, "the price never moved");
    }

    /// The same payer reaching for withdraw instead. The collection is holding
    /// the price it just took, so this is the moment a payer would most like the
    /// door to be open.
    function test_aPayerThatReEntersWithdrawDuringItsRefundLosesTheWholeSale() public {
        _buy(alice, 1510);
        uint256 held = address(nft).balance;

        Returner p = new Returner(nft, Returner.Mode.Withdraw);
        vm.deal(address(p), 100 ether);
        uint256 price = _price();
        State memory before = _snap(1511, address(p));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        p.buyOverpaying(1511, price, 1 ether);

        _assertUnmoved(before, 1511, address(p), "payer reaching for withdraw");
        assertEq(address(nft).balance, held, "the takings stayed put");
    }

    /// The gift door refunds its payer too, and that refund runs under the same
    /// lock as the self buy's. A payer that gifts, overpays and reaches for
    /// withdraw from inside its change loses the whole gift. Catches a gift
    /// whose change is sent after the lock is let go, which the self buy tests
    /// above cannot see.
    function test_aGiftPayerThatReEntersWithdrawDuringItsRefundLosesTheWholeGift() public {
        _buy(alice, 1550);
        uint256 held = address(nft).balance;

        Reacher p = new Reacher(nft, Reacher.Door.Withdraw);
        vm.deal(address(p), 100 ether);
        uint256 price = _price();
        State memory before = _snap(1551, bob);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        p.giftOverpaying(bob, 1551, price, 1 ether);

        _assertUnmoved(before, 1551, bob, "gift payer reaching for withdraw");
        assertEq(address(nft).balance, held, "the takings stayed put");
        assertEq(address(p).balance, 100 ether, "and the payer kept its ether");
    }

    /// A self buy's change reaching for the gift door. It pays in full for a
    /// character nobody holds, so the lock is the only thing refusing it.
    function test_aPayerCannotReachTheGiftDoorFromInsideItsRefund() public {
        Reacher p = new Reacher(nft, Reacher.Door.Gift);
        vm.deal(address(p), 100 ether);
        uint256 price = _price();
        State memory bought = _snap(1560, address(p));
        State memory reached = _snap(1561, address(p));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        p.buyOverpaying(1560, price, 1 ether);

        _assertUnmoved(bought, 1560, address(p), "payer reaching for the gift door");
        _assertUnmoved(reached, 1561, address(p), "the gift it reached for");
        assertEq(address(p).balance, 100 ether, "and the payer kept its ether");
    }

    /// And the free door, which costs nothing to reach and asks for a green
    /// slot the payer has never used, so again only the lock refuses it.
    function test_aPayerCannotReachTheFreeDoorFromInsideItsRefund() public {
        Reacher p = new Reacher(nft, Reacher.Door.Green);
        vm.deal(address(p), 100 ether);
        uint256 price = _price();
        State memory bought = _snap(1570, address(p));
        State memory reached = _snap(1571, address(p));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        p.buyOverpaying(1570, price, 1 ether);

        _assertUnmoved(bought, 1570, address(p), "payer reaching for the free door");
        _assertUnmoved(reached, 1571, address(p), "the green it reached for");
        assertEq(address(p).balance, 100 ether, "and the payer kept its ether");
    }

    /// A payer that only reads during its refund is fine, and sees the finished
    /// sale. The refund is the last statement in the mint, so by then even the
    /// payer's own change is accounted for: the collection holds the price and
    /// not a wei more.
    function test_aPayerThatOnlyReadsDuringItsRefundGetsItsChangeAndItsToken() public {
        Returner p = new Returner(nft, Returner.Mode.Read);
        vm.deal(address(p), 100 ether);
        uint256 price = _price();
        uint256 before = address(p).balance;

        p.buyOverpaying(1520, price, 3 ether);

        assertEq(nft.ownerOf(1520), address(p), "the token arrived");
        assertEq(address(p).balance, before - price, "and the change came back");
        assertEq(p.seenOwner(), address(p), "mid refund it already owned the token");
        assertEq(p.seenBitmapWord(), nft.blueTakenBits(1520 >> 8, 1)[0], "the bitmap already read as settled");
        assertEq(p.seenNftBalance(), price, "the collection was already down to the price alone");
        assertEq(address(nft).balance, price, "and stayed there");
    }

    /// A payer that burns every drop of gas on the refund. The 63/64 rule leaves
    /// the collection enough to notice and unwind, and because an out of gas
    /// frame returns no data the failure reads as OpenZeppelin's FailedCall
    /// rather than as anything about the token. Nothing about the sale survives.
    function test_aPayerThatBurnsAllItsGasOnTheRefundFailsTheSaleAsAFailedCall() public {
        GasEater p = new GasEater(nft);
        vm.deal(address(p), 100 ether);
        uint256 price = _price();
        State memory before = _snap(1530, address(p));

        (bool ok, bytes memory ret) =
            address(p).call{gas: 5_000_000}(abi.encodeCall(GasEater.buyOverpaying, (1530, price, 1 ether)));

        assertFalse(ok, "the sale must not go through");
        assertEq(ret, abi.encodeWithSelector(Errors.FailedCall.selector), "a silent refund failure, correctly named");
        _assertUnmoved(before, 1530, address(p), "gas eating payer");

        _buy(bob, 1530);
        assertEq(nft.ownerOf(1530), bob, "still for sale at the same price");
        assertEq(nft.blueMinted(), 1, "one sale ever");
    }

    /// A payer that answers the refund with a return bomb. The refund is sent
    /// with a low level call that asks for nothing back, so the bomb is never
    /// copied and cannot fail the sale: all it does is charge the payer for its
    /// own memory. Catches the refund being rewritten as a call that decodes a
    /// return value, which would hand every payer a denial of service switch.
    function test_aPayerThatReturnsABombOnItsRefundCannotFailItsOwnSale() public {
        vm.deal(address(this), 1000 ether);
        uint256 warm = _price();
        nft.mintBlueFor{value: warm}(address(new Plain()), 1540, warm);

        BombPayer quiet = new BombPayer(nft, 0);
        BombPayer loud = new BombPayer(nft, 262_144);
        vm.deal(address(quiet), 100 ether);
        vm.deal(address(loud), 100 ether);
        uint256 price = _price();

        uint256 g = gasleft();
        quiet.buyOverpaying(1541, price, 1 ether);
        uint256 quietCost = g - gasleft();

        g = gasleft();
        loud.buyOverpaying(1542, price, 1 ether);
        uint256 loudCost = g - gasleft();

        assertEq(nft.ownerOf(1541), address(quiet), "the quiet payer got its token");
        assertEq(nft.ownerOf(1542), address(loud), "and so did the loud one");
        assertEq(address(nft).balance, 3 * PRICE_STEP, "three prices, no change kept");
        assertGt(loudCost - quietCost, 150_000, "the bomb cost its own author real gas");
        assertLt(loudCost - quietCost, 220_000, "and only the memory it asked for");
    }

    /*//////////////////////////////////////////////////////////////
                    THE GAS THE HOOK IS PROMISED
    //////////////////////////////////////////////////////////////*/

    /// The gas suite bounds what a mint costs; this bounds what is left over for
    /// the recipient, which is the number a receiving contract has to budget
    /// against. Two runs with a known difference in budget: the hook sees 63/64
    /// of that difference, exactly, which is the EVM's own rule and nothing
    /// else. Any cap added to the hook call, a `{gas: n}` or a subtraction,
    /// would flatten this delta and fail here.
    function test_theHookIsHandedAllButOneSixtyFourthOfWhatTheMintHasLeft() public {
        _skipUnderCoverage();
        Meter r = new Meter();
        vm.deal(address(this), 100 ether);

        // one call, so the warm up and both measured mints share a transaction
        // even when every call from the test runs as a transaction of its own
        (bool ok1, uint256 seen1, bool ok2, uint256 seen2) = this.meterTwoMints(r);

        assertTrue(ok1 && ok2, "both mints completed");
        assertEq(seen2 - seen1, 1_000_000 * 63 / 64, "the hook gets every extra wei of gas bar the 63/64 reserve");
        assertGt(seen1, 400_000 - 40_000, "and the mint spends under 40k before it hands over");
    }

    /// The absolute floor a well behaved receiver can plan against, stated as
    /// work done rather than as gas left: a hook that burns three hundred
    /// thousand gas completes inside a one million gas budget. That is room for
    /// a vault to index, transfer onward and write a receipt.
    function test_aReceiverThatBurns300kInItsHookStillCompletes() public {
        Worker w = new Worker(300_000);
        vm.deal(address(this), 100 ether);
        uint256 price = _price();

        (bool ok,) =
            address(nft).call{gas: 1_000_000, value: price}(abi.encodeCall(nft.mintBlueFor, (address(w), 1610, price)));

        assertTrue(ok, "the sale completed");
        assertGe(w.burned(), 300_000, "and the hook really did burn its 300k");
        assertEq(nft.ownerOf(1610), address(w), "the token arrived");
    }

    /// The same claim from the other end: a mint to a receiver that does nothing
    /// fits inside a hundred thousand gas, cold receiver and all. This is the
    /// ceiling on the collection's own share, so a future change that spent more
    /// before the handover would be caught here before it starved a hook.
    function test_aPoliteMintFitsInAHundredThousandGas() public {
        _skipUnderCoverage();
        vm.deal(address(this), 100 ether);
        uint256 price = _price();

        (bool ok,) = address(nft).call{gas: 100_000, value: price}(
            abi.encodeCall(nft.mintBlueFor, (address(new Plain()), 1620, price))
        );

        assertTrue(ok, "a plain mint fits in 100k");
        assertEq(nft.blueMinted(), 1, "counted");
        assertTrue(nft.blueTaken(1620), "and the character is gone");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// Warms blueMinted, the bitmap word and the receiver's balance slot, so the
    /// two measured mints differ in nothing but their budget, then mints with a
    /// million gas between the two budgets and reads what the hook was handed.
    function meterTwoMints(Meter r) external returns (bool ok1, uint256 seen1, bool ok2, uint256 seen2) {
        uint256 price = _price();
        nft.mintBlueFor{value: price}(address(r), 1600, price);
        nft.mintBlueFor{value: price}(address(r), 1601, price);

        (ok1,) =
            address(nft).call{gas: 400_000, value: price}(abi.encodeCall(nft.mintBlueFor, (address(r), 1602, price)));
        seen1 = r.seenGas();
        (ok2,) =
            address(nft).call{gas: 1_400_000, value: price}(abi.encodeCall(nft.mintBlueFor, (address(r), 1603, price)));
        seen2 = r.seenGas();
    }

    /// What the EVM charges a frame to grow its memory from nothing to `size`
    /// bytes: three gas a word plus the words squared over 512.
    function _memoryCost(uint256 size) internal pure returns (uint256) {
        uint256 words = (size + 31) / 32;
        return 3 * words + (words * words) / 512;
    }

    /// The count and the answer a Fickle logged for one token, from inside the
    /// hook, so they survive the collection reverting the frame they were
    /// written in.
    function _whatTheHookSaw(Vm.Log[] memory logs, address hook, uint256 tokenId)
        internal
        pure
        returns (uint256 counted, bool said)
    {
        uint256 found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != hook || logs[i].topics[0] != Fickle.Asked.selector) continue;
            (uint256 id, uint256 n, bool yes) = abi.decode(logs[i].data, (uint256, uint256, bool));
            if (id != tokenId) continue;
            (counted, said) = (n, yes);
            ++found;
        }
        require(found == 1, "the hook was not asked exactly once");
    }

    function _prefix(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = b[i];
        }
        return string(out);
    }
}

/*//////////////////////////////////////////////////////////////
                              MOCKS
//////////////////////////////////////////////////////////////*/

/// Every mock below can also start a mint, so a hook can be reached through the
/// self buy and free doors as well as through a gift.
abstract contract Actor {
    function buy(GlamToon nft, uint256 imageId, uint256 maxPrice) external payable {
        nft.mintBlue{value: msg.value}(imageId, maxPrice);
    }

    function green(GlamToon nft, uint256 imageId) external {
        nft.mintGreen(imageId);
    }
}

/// Takes anything, remembers nothing. The baseline the bombs are measured against.
contract Plain is Actor {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// Accepts a fixed number of tokens and refuses everything after. `seen` counts
/// hook calls and `accepted` counts the ones it said yes to, so a test can watch
/// both roll back together when the collection unwinds.
contract Fickle is Actor {
    /// Logged from inside the hook, so what it counted can be read even when
    /// the collection reverts the frame.
    event Asked(uint256 tokenId, uint256 seen, bool accepted);

    uint256 public limit;
    uint256 public seen;
    uint256 public accepted;

    constructor(uint256 limit_) {
        limit = limit_;
    }

    function relent() external {
        limit += 1;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        seen += 1;
        bool yes = accepted < limit;
        emit Asked(tokenId, seen, yes);
        if (!yes) return bytes4(0);
        accepted += 1;
        return this.onERC721Received.selector;
    }
}

/// Reads the whole public surface of the collection from inside the hook, so a
/// test can compare every answer against the settled one.
contract Reader is Actor {
    GlamToon immutable NFT;

    address public seenOwner;
    uint256 public seenBalance;
    uint256 public seenTotalSupply;
    uint256 public seenBlueMinted;
    uint256 public seenBitmapWord;
    uint256 public seenBitmapWords;
    uint256 public seenPrice;
    uint256 public seenGreenCount;
    uint8 public seenTrait0;
    bool public seenIsBlue;
    string public seenUri;
    string public seenJson;

    constructor(GlamToon n) {
        NFT = n;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        (uint256 imageId,) = NFT.decode(tokenId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = imageId;

        seenOwner = NFT.ownerOf(tokenId);
        seenBalance = NFT.balanceOf(address(this));
        seenTotalSupply = NFT.totalSupply();
        seenBlueMinted = NFT.blueMinted();
        seenBitmapWord = NFT.blueTakenBits(imageId >> 8, 1)[0];
        seenBitmapWords = NFT.blueBitmapWords();
        seenPrice = NFT.currentPrice();
        seenGreenCount = NFT.greenCount(imageId);
        seenTrait0 = NFT.traitsBatch(ids)[0][0];
        seenIsBlue = NFT.isBlue(tokenId);
        seenUri = NFT.tokenURI(tokenId);
        seenJson = NFT.tokenJSON(tokenId);
        return this.onERC721Received.selector;
    }
}

/// Reaches back into one named door from inside the hook, or forwards the token
/// with a plain transfer, so the guarded and unguarded calls can be told apart.
/// It reaches once, for a character or a green slot nobody holds and with the
/// ether to pay, so the lock is the only thing that can refuse it.
contract Intruder is Actor {
    enum Door {
        None,
        Blue,
        Gift,
        Green,
        Withdraw
    }

    GlamToon immutable NFT;
    Door immutable DOOR;
    address public vault;
    bool public reached;

    constructor(GlamToon n, Door door) {
        NFT = n;
        DOOR = door;
    }

    function forwardTo(address v) external {
        vault = v;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        (uint256 imageId,) = NFT.decode(tokenId);
        if (DOOR == Door.None) {
            if (vault != address(0)) NFT.transferFrom(address(this), vault, tokenId);
        } else if (!reached) {
            reached = true;
            if (DOOR == Door.Blue) NFT.mintBlue{value: 1 ether}(imageId + 1, 1 ether);
            else if (DOOR == Door.Gift) NFT.mintBlueFor{value: 1 ether}(address(this), imageId + 1, 1 ether);
            else if (DOOR == Door.Green) NFT.mintGreen(imageId);
            else NFT.withdraw();
        }
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/// Passes the token straight on to a third party inside the hook, then either
/// reverts or answers with whatever it was told to answer.
contract Runner is Actor {
    GlamToon immutable NFT;
    address immutable FENCE;
    bool immutable THEN_REVERT;
    bytes4 public answer = 0x150b7a02;

    constructor(GlamToon n, address fence, bool thenRevert) {
        NFT = n;
        FENCE = fence;
        THEN_REVERT = thenRevert;
    }

    function setAnswer(bytes4 a) external {
        answer = a;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        NFT.transferFrom(address(this), FENCE, tokenId);
        if (THEN_REVERT) revert("changed my mind");
        return answer;
    }
}

/// Pays for somebody else's token and refuses the change, so the refund is the
/// only part of the mint that can fail.
contract Tightfisted {
    GlamToon immutable NFT;

    constructor(GlamToon n) {
        NFT = n;
    }

    function giftOverpaying(address to, uint256 imageId, uint256 price) external {
        NFT.mintBlueFor{value: price + 1 ether}(to, imageId, price);
    }

    function giftExactly(address to, uint256 imageId, uint256 price) external {
        NFT.mintBlueFor{value: price}(to, imageId, price);
    }

    receive() external payable {
        revert("keep it");
    }
}

/// Returns the answer followed by a wall of zero bytes. Assembly because
/// Solidity cannot return more than the declared type; the leading word is the
/// answer either way.
contract Bomber is Actor {
    bytes4 immutable ANSWER;
    uint256 immutable SIZE;

    constructor(bytes4 answer, uint256 size) {
        ANSWER = answer;
        SIZE = size;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        bytes4 answer = ANSWER;
        uint256 size = SIZE;
        assembly ("memory-safe") {
            mstore(0x00, answer)
            return(0x00, size)
        }
    }
}

/// Reverts with a wall of zero bytes, which is the branch the collection does
/// copy into memory before bubbling it.
contract Detonator is Actor {
    uint256 immutable SIZE;

    constructor(uint256 size) {
        SIZE = size;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        uint256 size = SIZE;
        assembly ("memory-safe") {
            revert(0x00, size)
        }
    }
}

/// Records how much gas the hook was handed.
contract Meter is Actor {
    uint256 public seenGas;

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        seenGas = gasleft();
        return this.onERC721Received.selector;
    }
}

/// Does a measured amount of real work inside the hook before accepting.
contract Worker is Actor {
    uint256 immutable BURN;
    uint256 public burned;
    uint256 sink;

    constructor(uint256 burn) {
        BURN = burn;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        uint256 start = gasleft();
        uint256 i;
        while (start - gasleft() < BURN) {
            sink = ++i;
        }
        burned = start - gasleft();
        return this.onERC721Received.selector;
    }
}

/// A buyer that overpays on purpose, so the refund calls it back, and then
/// misbehaves in one of three ways while it has control.
contract Returner {
    enum Mode {
        Read,
        Mint,
        Withdraw
    }

    GlamToon immutable NFT;
    Mode immutable MODE;

    address public seenOwner;
    uint256 public seenBitmapWord;
    uint256 public seenNftBalance;
    uint256 pending;

    constructor(GlamToon n, Mode mode) {
        NFT = n;
        MODE = mode;
    }

    function buyOverpaying(uint256 imageId, uint256 price, uint256 extra) external {
        pending = imageId;
        NFT.mintBlue{value: price + extra}(imageId, price);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        uint256 imageId = pending;
        if (MODE == Mode.Mint) {
            NFT.mintBlue{value: 0}(imageId + 1, type(uint256).max);
        } else if (MODE == Mode.Withdraw) {
            NFT.withdraw();
        } else {
            seenOwner = NFT.ownerOf(imageId);
            seenBitmapWord = NFT.blueTakenBits(imageId >> 8, 1)[0];
            seenNftBalance = address(NFT).balance;
        }
    }
}

/// A payer that overpays through either blue door and, from inside its own
/// change, reaches for one more door. It reaches once, pays in full, and asks
/// for a character or a green slot nobody holds, so the lock is the only thing
/// that can refuse it.
contract Reacher {
    enum Door {
        Withdraw,
        Gift,
        Green
    }

    GlamToon immutable NFT;
    Door immutable DOOR;

    uint256 pending;
    bool reached;

    constructor(GlamToon n, Door door) {
        NFT = n;
        DOOR = door;
    }

    function buyOverpaying(uint256 imageId, uint256 price, uint256 extra) external {
        pending = imageId;
        NFT.mintBlue{value: price + extra}(imageId, price);
    }

    function giftOverpaying(address to, uint256 imageId, uint256 price, uint256 extra) external {
        pending = imageId;
        NFT.mintBlueFor{value: price + extra}(to, imageId, price);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (reached) return;
        reached = true;
        uint256 next = pending + 1;
        if (DOOR == Door.Withdraw) NFT.withdraw();
        else if (DOOR == Door.Gift) NFT.mintBlueFor{value: 1 ether}(address(this), next, type(uint256).max);
        else NFT.mintGreen(next);
    }
}

/// A buyer that overpays and then burns every drop of gas it is handed on the
/// way back, so the refund is what runs out of gas rather than the mint.
contract GasEater {
    GlamToon immutable NFT;
    uint256 sink;

    constructor(GlamToon n) {
        NFT = n;
    }

    function buyOverpaying(uint256 imageId, uint256 price, uint256 extra) external {
        NFT.mintBlue{value: price + extra}(imageId, price);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        for (uint256 i = 0; i < type(uint256).max; ++i) {
            sink = i;
        }
    }
}

/// A buyer that overpays and answers the refund with a wall of returndata.
/// Declares only a fallback, because a receive function cannot return anything.
contract BombPayer {
    GlamToon immutable NFT;
    uint256 immutable SIZE;

    constructor(GlamToon n, uint256 size) {
        NFT = n;
        SIZE = size;
    }

    function buyOverpaying(uint256 imageId, uint256 price, uint256 extra) external {
        NFT.mintBlue{value: price + extra}(imageId, price);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    fallback() external payable {
        uint256 size = SIZE;
        assembly ("memory-safe") {
            return(0x00, size)
        }
    }
}
