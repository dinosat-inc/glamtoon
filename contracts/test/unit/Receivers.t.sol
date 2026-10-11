// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "openzeppelin/utils/ReentrancyGuardTransient.sol";

/// Who is allowed to end up holding a Glamtoon, and what happens to the sale when
/// the recipient's code misbehaves. _safeMint hands control to the recipient in
/// the middle of every mint, so the recipient is the one piece of untrusted code
/// that runs on the happy path. On OP with Isthmus live an address that looks
/// like a wallet may be EIP-7702 delegated and run code on receipt, so "the
/// recipient is a contract" is the ordinary case now, not the exotic one.
///
/// The claim under test throughout: a mint either settles completely or moves
/// nothing at all. There is no burn and no admin, so a half settled sale would
/// strand a character forever.
contract ReceiversTest is BaseTest {
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

    bytes4 constant MAGIC = 0x150b7a02;

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

    /// Run all three doors at one recipient and require every one of them to
    /// revert with `err` and to leave the world untouched. imageId is per door so
    /// a door that wrongly succeeded cannot be excused by the previous one.
    function _rejectedEverywhere(Caller r, bytes memory err, uint256 imageId) internal {
        uint256 price = _price();
        vm.deal(address(r), 10 ether);

        State memory before = _snap(imageId, address(r));
        vm.expectRevert(err);
        r.buy{value: price}(nft, imageId, price);
        _assertUnmoved(before, imageId, address(r), "mintBlue");

        before = _snap(imageId + 1, address(r));
        vm.prank(alice);
        vm.expectRevert(err);
        nft.mintBlueFor{value: price}(address(r), imageId + 1, price);
        _assertUnmoved(before, imageId + 1, address(r), "mintBlueFor");

        before = _snap(imageId + 2, address(r));
        vm.expectRevert(err);
        r.green(nft, imageId + 2);
        _assertUnmoved(before, imageId + 2, address(r), "mintGreen");
    }

    /*//////////////////////////////////////////////////////////////
                            A PLAIN EOA
    //////////////////////////////////////////////////////////////*/

    /// No code means no hook is called at all, so every address that is not a
    /// contract can hold a token. Precompiles included: they have no code, and
    /// treating them as special would be a rule the standard does not have.
    function test_anyAddressWithoutCodeCanHoldEitherEdition(address to) public {
        vm.assume(to != address(0));
        vm.assume(to.code.length == 0);
        assumeNotForgeAddress(to);

        uint256 price = _price();
        vm.prank(alice);
        nft.mintBlueFor{value: price}(to, 4242, price);
        assertEq(nft.ownerOf(4242), to, "blue arrived");

        vm.prank(to);
        nft.mintGreen(4242);
        assertEq(nft.ownerOf(14_242), to, "green arrived");
        assertEq(nft.totalSupply(), 2, "both counted");
    }

    /// address(0) is the one recipient the token standard itself forbids, and the
    /// paid door must not be the place that discovers it late. Checked at all
    /// three doors, because only one of them takes the recipient as an argument.
    function test_nobodyCanBeARecipient() public {
        uint256 price = _price();
        bytes memory err = abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0));

        State memory before = _snap(1, address(0));

        vm.deal(address(0), 10 ether);
        vm.prank(address(0));
        vm.expectRevert(err);
        nft.mintBlue{value: price}(1, price);

        vm.prank(address(0));
        vm.expectRevert(err);
        nft.mintGreen(1);

        vm.prank(alice);
        vm.expectRevert(err);
        nft.mintBlueFor{value: price}(address(0), 1, price);

        _assertUnmoved(before, 1, address(0), "address zero");
    }

    /*//////////////////////////////////////////////////////////////
                          A CORRECT RECEIVER
    //////////////////////////////////////////////////////////////*/

    function test_aCorrectReceiverHoldsBothEditions() public {
        Polite r = new Polite();
        vm.deal(address(r), 10 ether);
        uint256 price = _price();

        r.buy{value: price}(nft, 11, price);
        assertEq(nft.ownerOf(11), address(r), "bought its own blue");

        r.green(nft, 11);
        assertEq(nft.ownerOf(10_011), address(r), "and a green");
        assertEq(nft.balanceOf(address(r)), 2, "holds both");
    }

    /// The hook is the only place the recipient learns anything about the mint,
    /// and a gift is the case where the payer is not the recipient. `operator`
    /// has to be whoever called the door, or a receiving contract that trusts
    /// only certain senders would be told the wrong thing.
    function test_theHookIsToldWhoCalledTheDoorAndThatItIsAMint() public {
        Polite r = new Polite();
        vm.deal(address(r), 10 ether);
        uint256 price = _price();

        r.buy{value: price}(nft, 20, price);
        assertEq(r.lastOperator(), address(r), "a self buy names the buyer");
        assertEq(r.lastFrom(), address(0), "minted, not transferred");
        assertEq(r.lastTokenId(), 20, "the blue token id is the image id");
        assertEq(r.lastData().length, 0, "no data is attached");

        vm.prank(alice);
        nft.mintBlueFor{value: price}(address(r), 21, price);
        assertEq(r.lastOperator(), alice, "a gift names the payer, not the recipient");
        assertEq(r.lastFrom(), address(0), "still a mint");
        assertEq(r.lastTokenId(), 21, "the gifted character");

        r.green(nft, 22);
        assertEq(r.lastOperator(), address(r), "green names the minter");
        assertEq(r.lastTokenId(), 10_022, "generation one of character 22");
    }

    /*//////////////////////////////////////////////////////////////
                         THE WRONG MAGIC VALUE
    //////////////////////////////////////////////////////////////*/

    /// A hook that answers with anything but the magic value is refusing the
    /// token, and the sale must unwind rather than record a character as sold to
    /// a contract that did not want it. There would be no way back: no burn.
    function test_aHookThatAnswersWithTheWrongValueIsRefusedEverywhere() public {
        Rude r = new Rude(bytes4(0xdeadbeef));
        _rejectedEverywhere(r, abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(r)), 100);
    }

    /// Zero is the answer a stub or a fallback-only proxy gives, so it is the
    /// likeliest wrong answer in the wild rather than a made up one.
    function test_aHookThatAnswersZeroIsRefused() public {
        Rude r = new Rude(bytes4(0));
        _rejectedEverywhere(r, abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(r)), 110);
    }

    /// One bit out from the real selector. Catches a receiver check loosened to a
    /// prefix or a length comparison.
    function test_almostTheMagicValueIsStillRefused() public {
        Rude r = new Rude(MAGIC ^ bytes4(uint32(1)));
        _rejectedEverywhere(r, abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(r)), 120);
    }

    function test_theMagicValueIsTheOneTheStandardNames() public {
        Rude r = new Rude(MAGIC);
        vm.deal(address(r), 10 ether);
        uint256 price = _price();
        r.buy{value: price}(nft, 130, price);
        assertEq(nft.ownerOf(130), address(r), "the literal 0x150b7a02 is accepted");
    }

    /*//////////////////////////////////////////////////////////////
                        A HOOK THAT REVERTS
    //////////////////////////////////////////////////////////////*/

    /// A revert with a reason is passed through untouched, so the buyer sees why
    /// their wallet refused rather than a generic receiver error.
    function test_aHookThatRevertsWithAReasonBubblesItAndUnwinds() public {
        Refuses r = new Refuses();
        _rejectedEverywhere(r, abi.encodeWithSignature("Error(string)", "wallet says no"), 140);
    }

    /// An empty revert is indistinguishable from calling a contract with no hook,
    /// so the standard's own error is the right answer here.
    function test_aHookThatRevertsWithNothingIsReportedAsABadReceiver() public {
        Silent r = new Silent();
        _rejectedEverywhere(r, abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(r)), 150);
    }

    /// A buggy wallet panics rather than reverting politely. The panic must reach
    /// the caller and the sale must still unwind.
    function test_aHookThatPanicsUnwindsTheSale() public {
        Buggy r = new Buggy();
        _rejectedEverywhere(r, abi.encodeWithSignature("Panic(uint256)", uint256(0x12)), 160);
    }

    /// A contract with no receiver hook at all. Already known for one door each;
    /// asserted here at all three together with the state, because a door that
    /// forgot to unwind is the failure that matters.
    function test_aContractWithNoHookIsRefusedAtEveryDoor() public {
        Deafened r = new Deafened();
        _rejectedEverywhere(r, abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(r)), 170);
    }

    /*//////////////////////////////////////////////////////////////
                            GAS GRIEFING
    //////////////////////////////////////////////////////////////*/

    /// A recipient that burns every drop of gas it is handed. The 63/64 rule
    /// leaves the collection enough to unwind, so this costs the payer their gas
    /// and nothing else. The call is given a bounded budget so the test itself
    /// has gas left to check the aftermath.
    function test_aRecipientThatBurnsAllItsGasCannotHalfSettleASale() public {
        Greedy r = new Greedy();
        vm.deal(address(this), 10 ether);
        uint256 price = _price();
        State memory before = _snap(200, address(r));

        (bool ok, bytes memory ret) =
            address(nft).call{gas: 3_000_000, value: price}(abi.encodeCall(nft.mintBlueFor, (address(r), 200, price)));

        assertFalse(ok, "the sale must not go through");
        assertEq(
            ret,
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(r)),
            "an out of gas hook reads as a bad receiver"
        );
        _assertUnmoved(before, 200, address(r), "gas guzzler");
    }

    /// The same griefing on the free door, where there is no payer to lose ether
    /// and the only thing at stake is the generation counter.
    function test_aGasBurningMinterCannotTakeAGenerationSlot() public {
        Greedy r = new Greedy();
        State memory before = _snap(201, address(r));

        (bool ok,) = address(r).call{gas: 3_000_000}(abi.encodeCall(Caller.green, (nft, 201)));

        assertFalse(ok, "no generation taken");
        _assertUnmoved(before, 201, address(r), "gas guzzler on green");
    }

    /// The character a guzzler failed on must still be for sale at the same
    /// price. This is what "nothing moved" is actually worth.
    function test_aCharacterSurvivesAGriefedMintAndSellsNormally() public {
        Greedy r = new Greedy();
        vm.deal(address(this), 10 ether);
        uint256 price = _price();

        (bool ok,) =
            address(nft).call{gas: 3_000_000, value: price}(abi.encodeCall(nft.mintBlueFor, (address(r), 202, price)));
        assertFalse(ok, "griefed");

        assertEq(nft.currentPrice(), price, "the price did not move");
        _buy(bob, 202);
        assertEq(nft.ownerOf(202), bob, "still for sale");
        assertEq(nft.blueMinted(), 1, "exactly one sale ever happened");
    }

    /*//////////////////////////////////////////////////////////////
                             RETURN BOMBS
    //////////////////////////////////////////////////////////////*/

    /// Padding after a correct answer is not an answer of its own. A receiver
    /// that returns the magic value followed by kilobytes of rubbish is still
    /// saying yes, and the sale settles normally.
    function test_aReturnBombWithTheRightAnswerStillSettlesCorrectly() public {
        Bomb r = new Bomb(MAGIC, 2048);
        vm.deal(address(r), 10 ether);
        uint256 price = _price();

        r.buy{value: price}(nft, 300, price);

        assertEq(nft.ownerOf(300), address(r), "accepted");
        assertEq(nft.blueMinted(), 1, "one sale");
        assertTrue(nft.blueTaken(300), "marked sold");
        assertEq(nft.blueTakenBits(300 >> 8, 1)[0] >> (300 & 0xff) & 1, 1, "bit set");
        assertEq(address(nft).balance, price, "the money landed");
    }

    /// The other half: a bomb whose leading word is not the magic value is a
    /// refusal, however much data follows it. Catches a receiver check that looks
    /// at the returndata length instead of the value.
    function test_aReturnBombWithTheWrongAnswerIsRefused() public {
        Bomb r = new Bomb(bytes4(0xdeadbeef), 2048);
        _rejectedEverywhere(r, abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(r)), 310);
    }

    /// A bomb so big the receiver cannot pay for its own memory. The collection
    /// never copies a hook's answer, so the budget that runs out is the
    /// receiver's: the hook dies inside its own return, with no data, and that
    /// reads as a bad receiver. The point is that it can only fail the whole
    /// call: there is no size of return that lets a sale settle halfway.
    function test_aBombTooBigForTheReceiverToPayForFailsTheWholeSale() public {
        Bomb r = new Bomb(MAGIC, 200_000);
        vm.deal(address(this), 10 ether);
        uint256 price = _price();
        State memory before = _snap(320, address(r));

        // three gas a word plus the words squared over 512, for the bomb alone
        uint256 words = 200_000 + 1;
        assertGt(3 * words + (words * words) / 512, 3_000_000, "the receiver could afford its own bomb");

        (bool ok, bytes memory retx) =
            address(nft).call{gas: 3_000_000, value: price}(abi.encodeCall(nft.mintBlueFor, (address(r), 320, price)));

        assertFalse(ok, "the sale must not go through");
        assertEq(
            retx,
            abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(r)),
            "a return the receiver cannot pay for reads as a bad receiver, not as a silent success"
        );
        _assertUnmoved(before, 320, address(r), "oversized return");
    }

    /*//////////////////////////////////////////////////////////////
                    WHAT THE RECIPIENT CAN SEE AND DO
    //////////////////////////////////////////////////////////////*/

    /// The hook is the one moment a stranger runs while a sale is half spoken
    /// for, so every write has to be on the books before it starts. A recipient
    /// that reads the collection from inside its own hook must see the finished
    /// sale, not the one before it.
    function test_theSaleIsFullyRecordedBeforeTheRecipientRunsAtAll() public {
        Nosy r = new Nosy(nft);
        vm.deal(address(r), 10 ether);
        uint256 price = _price();

        r.buy{value: price}(nft, 410, price);

        assertEq(r.seenBlueMinted(), 1, "the sale was counted before the handover");
        assertTrue(r.seenBlueTaken(), "the character was marked sold before the handover");
        assertEq(r.seenBitmapWord() >> (410 & 0xff) & 1, 1, "the bitmap bit was set before the handover");
        assertEq(r.seenOwner(), address(r), "the recipient already owned it");
        assertEq(r.seenTotalSupply(), 1, "supply already included it");
    }

    /// Same question on the free door, where the counter that stops a second
    /// generation is the thing at stake.
    function test_theGenerationIsRecordedBeforeTheMinterRuns() public {
        Nosy r = new Nosy(nft);

        r.green(nft, 411);

        assertEq(r.seenGreenCount(), 1, "the generation was counted before the handover");
        assertTrue(r.seenGreenTaken(), "the slot was spent before the handover");
        assertEq(r.seenOwner(), address(r), "already the owner");
        assertEq(r.seenTotalSupply(), 1, "supply already included it");
    }

    /// withdraw shares the lock with the mint doors, so a recipient cannot drain
    /// the sale's takings from inside the hook that the sale itself called.
    function test_aRecipientCannotWithdrawFromInsideItsOwnHook() public {
        _buy(alice, 412);
        uint256 held = address(nft).balance;

        Raider r = new Raider(nft);
        uint256 price = _price();
        State memory before = _snap(413, address(r));

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        nft.mintBlueFor{value: price}(address(r), 413, price);

        _assertUnmoved(before, 413, address(r), "withdraw from the hook");
        assertEq(address(nft).balance, held, "the takings are still here");
        assertEq(address(treasury).balance, 0, "and nothing was pushed out early");
    }

    /*//////////////////////////////////////////////////////////////
                     THE SYSTEM'S OWN ADDRESSES
    //////////////////////////////////////////////////////////////*/

    /// Neither the collection nor the treasury implements the hook, so a token
    /// cannot be parked in either. Worth pinning: both are immutable and neither
    /// has a way to move an ERC-721 back out.
    function test_aTokenCannotBeParkedInTheCollectionOrTheTreasury() public {
        uint256 price = _price();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(nft)));
        nft.mintBlueFor{value: price}(address(nft), 400, price);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(treasury)));
        nft.mintBlueFor{value: price}(address(treasury), 401, price);

        assertEq(nft.blueMinted(), 0, "no sale counted");
        assertEq(address(nft).balance, 0, "no ether kept");
    }

    /*//////////////////////////////////////////////////////////////
                      EIP-7702 DELEGATED WALLETS
    //////////////////////////////////////////////////////////////*/

    /// An ordinary address that now runs code on receipt and sweeps the token to
    /// a vault. The sale must settle against the address that was named, while
    /// the token ends up wherever the delegate sent it. The delegate reads no
    /// storage, so etching its runtime code onto an empty account is faithful.
    function test_aDelegatedWalletThatForwardsTheTokenStillCompletesTheSale() public {
        address wallet = vm.addr(0x7702);
        address vault = vm.addr(0x7703);
        vm.etch(wallet, address(new Forwards(nft, vault)).code);

        uint256 price = _price();
        uint256 payerBefore = alice.balance;

        vm.expectEmit(true, true, true, true, address(nft));
        emit GlamToon.BlueMinted(wallet, alice, 500, price);

        vm.prank(alice);
        nft.mintBlueFor{value: price + 3 ether}(wallet, 500, price);

        assertEq(nft.ownerOf(500), vault, "the delegate forwarded it on");
        assertEq(nft.balanceOf(wallet), 0, "the wallet kept nothing");
        assertEq(nft.blueMinted(), 1, "counted as a sale");
        assertTrue(nft.blueTaken(500), "the character is gone for good");
        assertEq(nft.blueTakenBits(500 >> 8, 1)[0] >> (500 & 0xff) & 1, 1, "bit set");
        assertEq(alice.balance, payerBefore - price, "the payer got the change, not the wallet or the vault");
        assertEq(vault.balance, 0, "the vault was sent no ether");
    }

    /// The same wallet taking a free generation. The slot is spent by the minter,
    /// so forwarding the token away does not buy a second one, exactly as it
    /// would not for a plain wallet that transferred it.
    function test_aDelegatedWalletSpendsItsGreenSlotEvenAfterForwarding() public {
        address wallet = vm.addr(0x7712);
        address vault = vm.addr(0x7713);
        vm.etch(wallet, address(new Forwards(nft, vault)).code);

        vm.prank(wallet);
        nft.mintGreen(501);

        assertEq(nft.ownerOf(10_501), vault, "forwarded");
        assertEq(nft.balanceOf(wallet), 0, "holds nothing");
        assertTrue(nft.greenTaken(501, wallet), "the slot is spent by the minter");
        assertEq(nft.greenCount(501), 1, "one generation");

        vm.prank(wallet);
        vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
        nft.mintGreen(501);
    }

    /// A delegate that refuses. Somebody buying a gift for a friend whose wallet
    /// was delegated to something unfriendly gets a clean revert and keeps their
    /// ether, and the character stays for sale.
    function test_aDelegatedWalletThatRevertsFailsTheMintCleanly() public {
        address wallet = vm.addr(0x7722);
        vm.etch(wallet, address(new Refuses()).code);

        uint256 price = _price();
        uint256 payerBefore = alice.balance;
        State memory before = _snap(510, wallet);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "wallet says no"));
        nft.mintBlueFor{value: price}(wallet, 510, price);

        _assertUnmoved(before, 510, wallet, "reverting delegate");
        assertEq(alice.balance, payerBefore, "the payer kept everything");

        _buy(bob, 510);
        assertEq(nft.ownerOf(510), bob, "the character was never consumed");
    }

    /// The quiet hazard of 7702: a wallet delegated to something that simply has
    /// no receiver hook. It looks like an ordinary address and can no longer be
    /// sent a token at all.
    function test_aWalletDelegatedToACodeThatHasNoHookCannotBeGifted() public {
        address wallet = vm.addr(0x7732);
        vm.etch(wallet, address(new Deafened()).code);

        uint256 price = _price();
        State memory before = _snap(520, wallet);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, wallet));
        nft.mintBlueFor{value: price}(wallet, 520, price);

        _assertUnmoved(before, 520, wallet, "hookless delegate");
    }

    /// The same wallet as its own buyer. A 7702 account is still the transaction
    /// sender, so it cannot dodge the one-per-character rules by being a contract
    /// for the purposes of the hook.
    function test_aDelegatedWalletGetsNoExtraTurnAtEitherEdition() public {
        address wallet = vm.addr(0x7742);
        address vault = vm.addr(0x7743);
        vm.etch(wallet, address(new Forwards(nft, vault)).code);
        vm.deal(wallet, 10 ether);

        uint256 price = _price();
        vm.prank(wallet);
        nft.mintBlue{value: price}(530, price);
        assertEq(nft.ownerOf(530), vault, "forwarded to the vault");

        vm.prank(wallet);
        vm.expectRevert(GlamToon.BlueAlreadyTaken.selector);
        nft.mintBlue{value: price}(530, price);

        vm.prank(wallet);
        nft.mintGreen(530);
        vm.prank(wallet);
        vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
        nft.mintGreen(530);
    }

    /// A delegate that tries to mint again from inside its own receive hook. The
    /// lock on the outer door is what stops it, and it stops it whether the
    /// wallet started the call or was handed a gift. What it reaches for is a
    /// green slot it has never used, so the lock is the only thing refusing it.
    function test_aDelegatedWalletCannotReEnterFromItsHook() public {
        address wallet = vm.addr(0x7752);
        vm.etch(wallet, address(new Grabs(nft)).code);
        vm.deal(wallet, 10 ether);

        uint256 price = _price();
        State memory before = _snap(540, wallet);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        nft.mintBlueFor{value: price}(wallet, 540, price);

        _assertUnmoved(before, 540, wallet, "reentrant delegate, given a gift");

        before = _snap(541, wallet);
        vm.prank(wallet);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        nft.mintBlue{value: price}(541, price);

        _assertUnmoved(before, 541, wallet, "reentrant delegate, buying for itself");
    }

    /// vm.etch stands in for the delegation everywhere above because it survives
    /// across calls. This one uses the real thing: a signed authorisation, so the
    /// account carries the 23 byte designator rather than a copy of the code. It
    /// is here to prove the etched tests are not testing a different animal.
    function test_aRealSignedDelegationBehavesTheSameAsTheEtchedOne() public {
        uint256 pk = 0x7762;
        address wallet = vm.addr(pk);
        address vault = vm.addr(0x7763);
        address impl = address(new Forwards(nft, vault));

        vm.signAndAttachDelegation(impl, pk);
        assertGt(wallet.code.length, 0, "the account carries code now");
        assertEq(wallet.code.length, 23, "and it is a delegation designator, not a copy");

        uint256 price = _price();
        vm.prank(alice);
        nft.mintBlueFor{value: price}(wallet, 550, price);

        assertEq(nft.ownerOf(550), vault, "the delegate ran and forwarded it");
        assertEq(nft.blueMinted(), 1, "counted once");
    }

    /*//////////////////////////////////////////////////////////////
                           THE GIFT PAYER
    //////////////////////////////////////////////////////////////*/

    /// The gift is the case where the person who loses money is not the person
    /// whose code decides. If the recipient refuses, the payer must be exactly
    /// where they started, not out the price with nothing to show.
    function test_aRejectedGiftCostsThePayerNothingButGas() public {
        Rude r = new Rude(bytes4(0xdeadbeef));
        uint256 price = _price();
        uint256 payerBefore = alice.balance;
        State memory before = _snap(600, address(r));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(r)));
        nft.mintBlueFor{value: price + 5 ether}(address(r), 600, price + 5 ether);

        assertEq(alice.balance, payerBefore, "not a wei moved");
        assertEq(address(nft).balance, 0, "the collection kept nothing");
        _assertUnmoved(before, 600, address(r), "rejected gift");

        _buy(alice, 600);
        assertEq(nft.ownerOf(600), alice, "she bought it herself in the end");
    }

    /// Whatever the recipient does, a gift never pays the recipient. The refund
    /// follows msg.sender, so a refusing recipient cannot end up with the change.
    function test_aGiftNeverSendsEtherToTheRecipientWhateverItsCodeDoes(uint256 seed) public {
        uint256 imageId = bound(seed, 0, 9999);
        uint256 extra = bound(uint256(keccak256(abi.encode(seed))), 1, 100 ether);

        Polite r = new Polite();
        uint256 price = _price();
        uint256 payerBefore = alice.balance;

        vm.prank(alice);
        nft.mintBlueFor{value: price + extra}(address(r), imageId, price + extra);

        assertEq(address(r).balance, 0, "the recipient was sent no ether");
        assertEq(alice.balance, payerBefore - price, "the payer paid the price and no more");
        assertEq(address(nft).balance, price, "the collection kept the price");
        assertEq(nft.ownerOf(imageId), address(r), "and the token arrived");
    }

    /// A paying contract that accepts the token but cannot take change is a
    /// different failure from one that refuses the token, and it must not be
    /// confused with one. Overpaying reverts; paying exactly works.
    function test_aBuyerThatTakesTokensButNotEtherOnlyFailsOnTheRefund() public {
        Tightfisted r = new Tightfisted();
        vm.deal(address(r), 10 ether);
        uint256 price = _price();
        State memory before = _snap(610, address(r));

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "keep it"));
        r.buy{value: price + 1 wei}(nft, 610, price + 1 wei);
        _assertUnmoved(before, 610, address(r), "refund refused");

        r.buy{value: price}(nft, 610, price);
        assertEq(nft.ownerOf(610), address(r), "exact payment needs no refund");
    }

    /*//////////////////////////////////////////////////////////////
                      THE MATRIX, ALL AT ONCE
    //////////////////////////////////////////////////////////////*/

    /// One sweep over every recipient shape in this file against one running
    /// collection, to catch a door that only unwinds correctly when it is the
    /// first thing to happen. The accepting recipients land in order and the
    /// refusing ones leave no trace between them.
    function test_theSaleCounterOnlyEverMovesForRecipientsThatAccepted() public {
        address[] memory accepts = new address[](3);
        accepts[0] = address(new Polite());
        accepts[1] = address(new Bomb(MAGIC, 512));
        accepts[2] = vm.addr(0x9001);

        Caller[] memory refuses = new Caller[](4);
        refuses[0] = new Rude(bytes4(0));
        refuses[1] = new Refuses();
        refuses[2] = new Silent();
        refuses[3] = new Deafened();

        // only the one that gives a reason gets it passed on
        bytes[] memory why = new bytes[](4);
        why[0] = abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(refuses[0]));
        why[1] = abi.encodeWithSignature("Error(string)", "wallet says no");
        why[2] = abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(refuses[2]));
        why[3] = abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(refuses[3]));

        uint256 sold;
        uint256 imageId = 700;

        for (uint256 i = 0; i < refuses.length; ++i) {
            uint256 price = _price();
            vm.prank(alice);
            vm.expectRevert(why[i]);
            nft.mintBlueFor{value: price}(address(refuses[i]), imageId, price);
            assertEq(nft.blueMinted(), sold, "a refusal counted as a sale");
            assertFalse(nft.blueTaken(imageId), "a refusal burned a character");
            ++imageId;
        }

        for (uint256 i = 0; i < accepts.length; ++i) {
            uint256 price = _price();
            vm.prank(alice);
            nft.mintBlueFor{value: price}(accepts[i], imageId, price);
            ++sold;
            assertEq(nft.blueMinted(), sold, "an acceptance was not counted");
            assertEq(nft.ownerOf(imageId), accepts[i], "wrong holder");
            ++imageId;
        }

        assertEq(nft.blueMinted(), 3, "three sales out of seven attempts");
        assertEq(nft.totalSupply(), 3, "and nothing else exists");
        assertEq(address(nft).balance, 3 * PRICE_STEP, "three prices, no more");
    }
}

/*//////////////////////////////////////////////////////////////
                              MOCKS
//////////////////////////////////////////////////////////////*/

/// Every recipient below can also start a mint, so the matrix can be run at the
/// self-buy door and the free door as well as at the gift door.
abstract contract Caller {
    function buy(GlamToon nft, uint256 imageId, uint256 maxPrice) external payable {
        nft.mintBlue{value: msg.value}(imageId, maxPrice);
    }

    function green(GlamToon nft, uint256 imageId) external {
        nft.mintGreen(imageId);
    }

    receive() external payable virtual {}
}

/// Accepts, and remembers what the hook was told.
contract Polite is Caller {
    address public lastOperator;
    address public lastFrom;
    uint256 public lastTokenId;
    bytes public lastData;

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4)
    {
        lastOperator = operator;
        lastFrom = from;
        lastTokenId = tokenId;
        lastData = data;
        return this.onERC721Received.selector;
    }
}

/// Answers with whatever it was built with, magic value or not.
contract Rude is Caller {
    bytes4 immutable ANSWER;

    constructor(bytes4 answer) {
        ANSWER = answer;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        return ANSWER;
    }
}

/// Reverts with a reason, the way a wallet with a deny list would.
contract Refuses is Caller {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("wallet says no");
    }
}

/// Reverts with no data at all, which is what the standard's own error is for.
contract Silent is Caller {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert();
    }
}

/// Divides by zero, so the hook fails with a panic rather than a revert. The
/// divisor lives in storage so the optimizer cannot fold the division away.
contract Buggy is Caller {
    uint256 zero;

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (1 / zero == 0) return bytes4(0);
        return this.onERC721Received.selector;
    }
}

/// No hook and no fallback, so the call into it reverts empty.
contract Deafened is Caller {}

/// Burns every drop of gas the hook is handed.
contract Greedy is Caller {
    uint256 sink;

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        for (uint256 i = 0; i < type(uint256).max; ++i) {
            sink = i;
        }
        return this.onERC721Received.selector;
    }
}

/// Returns the answer followed by a wall of zero bytes, paying for every byte of
/// the memory it returns from. Assembly because Solidity has no way to return
/// more than the declared type; the first four bytes are the answer either way.
contract Bomb is Caller {
    bytes4 immutable ANSWER;
    uint256 immutable WORDS;

    constructor(bytes4 answer, uint256 words) {
        ANSWER = answer;
        WORDS = words;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        bytes4 answer = ANSWER;
        uint256 size = (WORDS + 1) * 32;
        assembly ("memory-safe") {
            mstore(0x00, answer)
            return(0x00, size)
        }
    }
}

/// Takes tokens, refuses ether, so only the refund can fail.
contract Tightfisted is Caller {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable override {
        revert("keep it");
    }
}

/// Reads the collection back from inside the hook, to show what a recipient can
/// already see at the moment control reaches it.
contract Nosy is Caller {
    GlamToon immutable NFT;

    uint256 public seenBlueMinted;
    uint256 public seenGreenCount;
    uint256 public seenTotalSupply;
    uint256 public seenBitmapWord;
    address public seenOwner;
    bool public seenBlueTaken;
    bool public seenGreenTaken;

    constructor(GlamToon n) {
        NFT = n;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        uint256 imageId = tokenId % 10_000;
        seenBlueMinted = NFT.blueMinted();
        seenGreenCount = NFT.greenCount(imageId);
        seenTotalSupply = NFT.totalSupply();
        seenBitmapWord = NFT.blueTakenBits(imageId >> 8, 1)[0];
        seenOwner = NFT.ownerOf(tokenId);
        seenBlueTaken = NFT.blueTaken(imageId);
        seenGreenTaken = NFT.greenTaken(imageId, address(this));
        return this.onERC721Received.selector;
    }
}

/// Tries to empty the collection from inside the hook the sale handed it.
contract Raider is Caller {
    GlamToon immutable NFT;

    constructor(GlamToon n) {
        NFT = n;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        NFT.withdraw();
        return this.onERC721Received.selector;
    }
}

/// An EIP-7702 delegate that sweeps anything it is sent to a vault. Holds its
/// two addresses as immutables, so it reads no storage and behaves identically
/// whether it is deployed or etched onto an account that has none.
contract Forwards {
    GlamToon immutable NFT;
    address immutable VAULT;

    constructor(GlamToon n, address v) {
        NFT = n;
        VAULT = v;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        NFT.transferFrom(address(this), VAULT, tokenId);
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/// A delegate that reaches back into the collection from inside the hook, for a
/// green of the blue it was just handed. It reaches only when handed a blue, so
/// it reaches once, and it reads no storage, so it can be etched.
contract Grabs {
    GlamToon immutable NFT;

    constructor(GlamToon n) {
        NFT = n;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (tokenId < 10_000) NFT.mintGreen(tokenId);
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
