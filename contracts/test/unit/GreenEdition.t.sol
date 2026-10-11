// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {stdError} from "forge-std/StdError.sol";
import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {Address} from "openzeppelin/utils/Address.sol";

/// Green is the half of the collection with no cap on it: free, unbounded in
/// generations, and held back by one rule only, which is that an address gets
/// one green of a character and never another. That rule is written once, at
/// mint, and nothing in the contract can clear it. These tests push on it from
/// every side a live collection will: many wallets, many characters, years of
/// elapsed time, tokens moved away, and a paid blue running alongside.
contract GreenEditionTest is BaseTest {
    event GreenMinted(address indexed minter, uint256 indexed imageId, uint256 generation);

    /// Storage slots as forge inspect GlamToon storage-layout reports them.
    bytes32 internal constant BLUE_MINTED_SLOT = bytes32(uint256(8));
    bytes32 internal constant GREEN_MINTED_SLOT = bytes32(uint256(9));
    uint256 internal constant GREEN_COUNT_SLOT = 10;

    /*//////////////////////////////////////////////////////////////
                            THE RECORD, FOREVER
    //////////////////////////////////////////////////////////////*/

    /// A character being busy is not a reason to let somebody in twice. Ten more
    /// generations move greenCount a long way past where alice's mint left it,
    /// and the flag is the only thing still saying no.
    function test_theSlotStaysSpentAfterTenMoreGenerationsByOthers() public {
        uint256 imageId = 812;
        vm.prank(alice);
        nft.mintGreen(imageId);

        for (uint256 i = 0; i < 10; ++i) {
            address who = _actor(i);
            vm.prank(who);
            nft.mintGreen(imageId);
        }
        assertEq(nft.greenCount(imageId), 11, "eleven generations exist");

        vm.prank(alice);
        vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
        nft.mintGreen(imageId);

        assertEq(nft.greenCount(imageId), 11, "and the refusal minted nothing");
        assertEq(nft.balanceOf(alice), 1, "alice still holds the one she took");
    }

    /// Nothing about the flag decays. A collector coming back in ten years is
    /// still the same address that already took its green.
    function test_theSlotStaysSpentYearsLater() public {
        uint256 imageId = 3;
        vm.prank(alice);
        nft.mintGreen(imageId);

        vm.warp(SALE_START + 3650 days);

        vm.prank(alice);
        vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
        nft.mintGreen(imageId);

        vm.prank(bob);
        nft.mintGreen(imageId);
        assertEq(nft.ownerOf(nft.tokenIdFor(imageId, 2)), bob, "a fresh wallet is still served");
    }

    /// The other side of the transfer case: holding somebody else's green is not
    /// taking one. A buyer on a marketplace must still be able to mint their own.
    function test_receivingSomebodyElsesGreenDoesNotSpendYourSlot() public {
        uint256 imageId = 77;
        vm.prank(alice);
        nft.mintGreen(imageId);
        uint256 first = nft.tokenIdFor(imageId, 1);

        vm.prank(alice);
        nft.transferFrom(alice, bob, first);
        assertFalse(nft.greenTaken(imageId, bob), "receiving records nothing");

        vm.prank(bob);
        nft.mintGreen(imageId);

        assertEq(nft.ownerOf(nft.tokenIdFor(imageId, 2)), bob, "bob minted his own generation");
        assertEq(nft.balanceOf(bob), 2, "the gift and his own");
        assertEq(nft.greenCount(imageId), 2, "two generations taken in all");
    }

    /// One address filling its slot must never touch another's. Fuzzed over the
    /// character and over which two wallets are involved, because the mapping is
    /// keyed on both and a collapse to a single key would pass a fixed pair.
    function testFuzz_oneWalletIsNeverBlockedByAnother(uint256 seed) public {
        uint256 imageId = bound(seed, 0, 9999);
        address first = _actor(uint256(keccak256(abi.encode(seed, "first"))));
        address second = _actor(uint256(keccak256(abi.encode(seed, "second"))));
        vm.assume(first != second);

        vm.prank(first);
        nft.mintGreen(imageId);

        vm.prank(second);
        nft.mintGreen(imageId);

        assertTrue(nft.greenTaken(imageId, first), "first recorded");
        assertTrue(nft.greenTaken(imageId, second), "second recorded");
        assertEq(nft.ownerOf(nft.tokenIdFor(imageId, 1)), first, "generation one");
        assertEq(nft.ownerOf(nft.tokenIdFor(imageId, 2)), second, "generation two");

        vm.prank(first);
        vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
        nft.mintGreen(imageId);

        vm.prank(second);
        vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
        nft.mintGreen(imageId);
    }

    /// The rule is per character, so one wallet collecting the whole cast is the
    /// intended behaviour rather than an abuse. Thirty two characters drawn from
    /// the seed, since ten thousand mints in one test is not worth the minute.
    function testFuzz_oneWalletMayTakeAGreenOfEveryCharacterItLikes(uint256 seed) public {
        uint256[] memory picked = new uint256[](32);
        uint256 taken;

        for (uint256 i = 0; i < 32; ++i) {
            uint256 imageId = uint256(keccak256(abi.encode(seed, i))) % 10_000;
            if (nft.greenTaken(imageId, alice)) continue;

            vm.prank(alice);
            nft.mintGreen(imageId);
            picked[taken] = imageId;
            taken += 1;
        }

        assertGt(taken, 0, "the seed picked nothing at all");
        assertEq(nft.balanceOf(alice), taken, "one token per character taken");
        assertEq(nft.greenMinted(), taken, "and the collection counted the same");

        for (uint256 i = 0; i < taken; ++i) {
            uint256 imageId = picked[i];
            assertEq(nft.ownerOf(nft.tokenIdFor(imageId, 1)), alice, "held the first generation");

            vm.prank(alice);
            vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
            nft.mintGreen(imageId);
        }
    }

    /// The slot belongs to the caller, not to whoever signed the transaction. A
    /// contract minting on a user's behalf spends its own slot once and is then
    /// finished, however many different people push it afterwards.
    function test_theCallerIsWhatCountsNotTheOriginOfTheTransaction() public {
        GreenForwarder forwarder = new GreenForwarder(nft);
        uint256 imageId = 651;

        vm.expectEmit(true, true, false, true, address(nft));
        emit GreenMinted(address(forwarder), imageId, 1);

        vm.prank(alice, alice);
        forwarder.take(imageId);

        assertTrue(nft.greenTaken(imageId, address(forwarder)), "the caller spent its slot");
        assertFalse(nft.greenTaken(imageId, alice), "and not the signer's");
        assertEq(nft.ownerOf(nft.tokenIdFor(imageId, 1)), address(forwarder), "the caller holds it");

        vm.prank(bob, bob);
        vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
        forwarder.take(imageId);

        vm.prank(alice);
        nft.mintGreen(imageId);
        assertEq(nft.ownerOf(nft.tokenIdFor(imageId, 2)), alice, "alice's own slot was untouched");
    }

    /// A contract minting from its own constructor has no code yet, so the hook
    /// is skipped and the token lands with nothing to accept it. The slot is
    /// still spent by that address, and building the same contract at the same
    /// address again with CREATE2 does not buy a second one.
    function test_aConstructorMintSkipsTheHookAndACreate2RedeployIsRefused() public {
        ConstructorMinterFactory factory = new ConstructorMinterFactory();
        bytes32 salt = keccak256("glamtoon constructor minter");
        uint256 imageId = 42;

        address minter = factory.make(salt, nft, imageId, alice);

        assertTrue(nft.greenTaken(imageId, minter), "the constructor spent its own slot");
        assertFalse(nft.greenTaken(imageId, alice), "and not the recipient's");
        assertEq(nft.ownerOf(nft.tokenIdFor(imageId, 1)), alice, "handed on from inside the constructor");
        assertEq(nft.greenCount(imageId), 1, "one generation");

        // A contract that destroys itself in the transaction that made it leaves
        // no code and no nonce behind, which is what lets CREATE2 land there again.
        vm.etch(minter, "");
        vm.resetNonce(minter);

        vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
        factory.make(salt, nft, imageId, alice);
        assertEq(nft.greenCount(imageId), 1, "the redeploy minted nothing");

        address other = factory.make(keccak256("another salt"), nft, imageId, alice);
        assertTrue(other != minter, "a new salt is a new address");
        assertTrue(nft.greenTaken(imageId, other), "with a slot of its own");
        assertEq(nft.ownerOf(nft.tokenIdFor(imageId, 2)), alice, "which mints the next generation");
    }

    /// A real signed EIP-7702 delegation, so the wallet carries the 23 byte
    /// designator and the delegate's hook runs when the token lands. The wallet
    /// mints as itself, and a second green of the same character is refused
    /// whether it comes straight from the wallet or through the delegate.
    function test_aRealSignedDelegationCannotTakeASecondGreen() public {
        uint256 pk = 0x77026;
        address wallet = vm.addr(pk);
        GreenExecutor delegate = new GreenExecutor();

        vm.signAndAttachDelegation(address(delegate), pk);
        assertEq(wallet.code, abi.encodePacked(hex"ef0100", address(delegate)), "a delegation designator");

        vm.prank(wallet);
        nft.mintGreen(7);
        assertEq(nft.ownerOf(nft.tokenIdFor(7, 1)), wallet, "the wallet minted as itself");
        assertTrue(nft.greenTaken(7, wallet), "and spent its own slot");

        vm.prank(wallet);
        vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
        GreenExecutor(wallet).execute(address(nft), abi.encodeCall(GlamToon.mintGreen, (7)));

        vm.prank(wallet);
        vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
        nft.mintGreen(7);

        assertEq(nft.greenCount(7), 1, "one generation");
        assertEq(nft.balanceOf(wallet), 1, "one token");
    }

    /*//////////////////////////////////////////////////////////////
                               GENERATIONS
    //////////////////////////////////////////////////////////////*/

    /// The long walk. Twelve wallets on one character must produce generations 1
    /// to 12 with no gap, no repeat and no id shared with anything else.
    function test_aCharacterReachesGenerationTwelveWithTwelveWallets() public {
        uint256 imageId = 4242;
        uint256[] memory ids = new uint256[](12);

        for (uint256 g = 1; g <= 12; ++g) {
            address who = _actor(g);
            vm.prank(who);
            nft.mintGreen(imageId);

            uint256 id = nft.tokenIdFor(imageId, g);
            ids[g - 1] = id;

            assertEq(nft.ownerOf(id), who, "the generation landed on the wallet that took it");
            assertEq(nft.greenCount(imageId), g, "the count is the generation just taken");

            (uint256 gotImage, uint256 gotGeneration) = nft.decode(id);
            assertEq(gotImage, imageId, "decode returns the character");
            assertEq(gotGeneration, g, "decode returns the generation");
            assertFalse(nft.isBlue(id), "no green is ever blue");
        }

        for (uint256 i = 0; i < 12; ++i) {
            for (uint256 j = i + 1; j < 12; ++j) {
                assertTrue(ids[i] != ids[j], "two generations share an id");
            }
        }

        assertEq(nft.greenCount(imageId), 12, "twelve generations");
        assertEq(nft.greenMinted(), 12, "and twelve greens in all");
        assertEq(nft.totalSupply(), 12, "with no blue sold");

        uint256 unminted = nft.tokenIdFor(imageId, 13);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, unminted));
        nft.ownerOf(unminted);
    }

    /// Whatever order the mints arrive in, every character's generations must run
    /// 1..greenCount with nothing missing and nothing beyond. Four characters and
    /// eight wallets interleaved, with the refusals exercised on the way through.
    function testFuzz_generationsStayDenseHoweverTheMintsInterleave(uint256 seed) public {
        uint256 minted;
        uint256 refused;

        for (uint256 i = 0; i < 40; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 imageId = r % 4;
            address who = _actor(1000 + ((r >> 8) % 8));

            if (nft.greenTaken(imageId, who)) {
                vm.prank(who);
                vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
                nft.mintGreen(imageId);
                refused += 1;
                continue;
            }

            vm.prank(who);
            nft.mintGreen(imageId);
            minted += 1;
        }

        assertEq(nft.greenMinted(), minted, "the global count is every mint that went through");
        assertEq(minted + refused, 40, "every attempt was one or the other");

        uint256 summed;
        for (uint256 imageId = 0; imageId < 4; ++imageId) {
            uint256 count = nft.greenCount(imageId);
            summed += count;

            for (uint256 g = 1; g <= count; ++g) {
                assertTrue(_exists(nft.tokenIdFor(imageId, g)), "a generation below the count is missing");
            }
            assertFalse(_exists(nft.tokenIdFor(imageId, count + 1)), "a generation beyond the count exists");
        }
        assertEq(summed, minted, "the per character counts do not add up to the mints");

        for (uint256 a = 0; a < 8; ++a) {
            address who = _actor(1000 + a);
            uint256 flags;
            for (uint256 imageId = 0; imageId < 4; ++imageId) {
                if (nft.greenTaken(imageId, who)) flags += 1;
            }
            assertEq(nft.balanceOf(who), flags, "the flags and the tokens held disagree");
        }
    }

    /// totalSupply is the only number a marketplace reads, and it is a sum of two
    /// counters that move for different reasons. Walk both and check each step.
    function test_theSupplyIsBluePlusGreenAsBothSidesMove() public {
        assertEq(nft.totalSupply(), 0, "nothing minted yet");

        _green(alice, 5);
        assertEq(nft.totalSupply(), 1, "one green");
        assertEq(nft.blueMinted(), 0, "no blue");

        _buy(bob, 5);
        assertEq(nft.totalSupply(), 2, "the blue of the same character");

        _green(bob, 5);
        _green(bob, 6);
        assertEq(nft.greenMinted(), 3, "greens across two characters");
        assertEq(nft.blueMinted(), 1, "blues untouched by greens");
        assertEq(nft.totalSupply(), 4, "the sum");

        _buy(carol, 6);
        assertEq(nft.totalSupply(), nft.blueMinted() + nft.greenMinted(), "supply is the sum of the two");
        assertEq(nft.totalSupply(), 5, "two blue and three green");
    }

    /*//////////////////////////////////////////////////////////////
                                BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    /// The comparison is on the second itself. One second early is refused and
    /// the second the sale names is open, which is what SALE_START promises.
    function test_theSaleOpensOnTheSecondItNames() public {
        vm.warp(SALE_START - 1);
        vm.prank(alice);
        vm.expectRevert(GlamToon.NotStarted.selector);
        nft.mintGreen(9);

        vm.warp(SALE_START);
        vm.prank(alice);
        nft.mintGreen(9);
        assertEq(nft.greenCount(9), 1, "open on the exact second");
    }

    /// Any moment before the start, not only the second before it.
    function testFuzz_noGreenBeforeTheSaleOpens(uint256 seed) public {
        uint256 when = bound(seed, 1, SALE_START - 1);
        vm.warp(when);

        vm.prank(alice);
        vm.expectRevert(GlamToon.NotStarted.selector);
        nft.mintGreen(1);

        assertEq(nft.greenMinted(), 0, "nothing minted before the start");
    }

    /// Before the start the answer is NotStarted whatever the id, the same order
    /// the blue door keeps. A character that does not exist is only called
    /// invalid once the sale is open.
    function test_beforeTheStartAGreenIsRefusedAsNotStartedWhateverTheId() public {
        vm.warp(SALE_START - 1);

        uint256[3] memory ids = [uint256(10_000), 123_456_789, type(uint256).max];
        for (uint256 i = 0; i < ids.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(GlamToon.NotStarted.selector);
            nft.mintGreen(ids[i]);
        }

        vm.warp(SALE_START);
        vm.prank(alice);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.mintGreen(10_000);
    }

    /// There is no character above 9999, and an id that slipped through would
    /// mint a token whose art does not exist.
    function testFuzz_everyCharacterAtOrAboveTenThousandIsRefused(uint256 seed) public {
        uint256 imageId = bound(seed, 10_000, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(GlamToon.InvalidImageId.selector);
        nft.mintGreen(imageId);

        assertEq(nft.greenMinted(), 0, "nothing minted");
    }

    /// Both ends of the range, because an off by one at either edge loses a
    /// character forever.
    function test_theFirstAndLastCharacterBothMint() public {
        vm.prank(alice);
        nft.mintGreen(0);
        vm.prank(alice);
        nft.mintGreen(9999);

        assertEq(nft.ownerOf(10_000), alice, "character zero, generation one");
        assertEq(nft.ownerOf(19_999), alice, "character 9999, generation one");
        assertEq(nft.imageIdOf(19_999), 9999, "the last character");
        assertEq(nft.greenCount(0), 1, "counted");
        assertEq(nft.greenCount(9999), 1, "counted");
        assertEq(nft.greenMinted(), 2, "two greens");
    }

    /// No run of mints can reach these counts, so they are written straight into
    /// storage. Every counter mintGreen touches is checked arithmetic, so an
    /// overflow in any of them is the arithmetic panic, which undoes the whole
    /// mint: no flag, no count and no token, least of all a blue id reached by
    /// wrapping. The panic is what each refusal is held to, and the reads after
    /// it spell out what that leaves.
    function test_forcedCounterOverflowRevertsWithoutSideEffects() public {
        uint256 top = type(uint256).max / 10_000;

        // A real mint of each kind proves the slots are the counters before
        // anything is written into them.
        _buy(carol, 500);
        vm.prank(carol);
        nft.mintGreen(5);
        assertEq(uint256(vm.load(address(nft), _greenCountSlot(5))), 1, "slot 10 is greenCount");
        assertEq(uint256(vm.load(address(nft), GREEN_MINTED_SLOT)), 1, "slot 9 is greenMinted");
        assertEq(uint256(vm.load(address(nft), BLUE_MINTED_SLOT)), 1, "slot 8 is blueMinted");

        // One below the top generation, character 0 still fits and takes it.
        vm.store(address(nft), _greenCountSlot(0), bytes32(top - 1));
        vm.prank(alice);
        nft.mintGreen(0);
        assertEq(nft.ownerOf(top * 10_000), alice, "the top generation of character 0");
        assertEq(nft.greenCount(0), top, "counted");

        uint256 minted = nft.greenMinted();
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        nft.mintGreen(0);
        _assertNoGreenLanded(0, bob, top, minted);

        // Character 9999 at the top generation would wrap to token 63.
        vm.store(address(nft), _greenCountSlot(9999), bytes32(top - 1));
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        nft.mintGreen(9999);
        _assertNoGreenLanded(9999, bob, top - 1, minted);
        assertFalse(_exists(63), "a wrapped id minted a blue");

        // A count that wrapped to generation 0 would mint character 1's blue.
        vm.store(address(nft), _greenCountSlot(1), bytes32(type(uint256).max));
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        nft.mintGreen(1);
        _assertNoGreenLanded(1, bob, type(uint256).max, minted);
        assertFalse(_exists(1), "a wrapped generation minted the blue of character 1");

        vm.store(address(nft), GREEN_MINTED_SLOT, bytes32(type(uint256).max));
        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        nft.mintGreen(2);
        _assertNoGreenLanded(2, bob, 0, type(uint256).max);

        // totalSupply is the sum of the two, and overflows only past the top.
        vm.store(address(nft), GREEN_MINTED_SLOT, bytes32(type(uint256).max - 1));
        vm.store(address(nft), BLUE_MINTED_SLOT, bytes32(uint256(1)));
        assertEq(nft.totalSupply(), type(uint256).max, "the largest supply there is");
        vm.store(address(nft), BLUE_MINTED_SLOT, bytes32(uint256(2)));
        vm.expectRevert(stdError.arithmeticError);
        nft.totalSupply();
    }

    /// The log is what an indexer builds the generation list from, so it has to
    /// carry the generation that was actually minted and not a stale count.
    function test_greenMintedCarriesTheMinterAndTheGeneration() public {
        uint256 imageId = 1234;

        vm.expectEmit(true, true, false, true, address(nft));
        emit GreenMinted(alice, imageId, 1);
        vm.prank(alice);
        nft.mintGreen(imageId);

        vm.prank(bob);
        nft.mintGreen(imageId);

        vm.expectEmit(true, true, false, true, address(nft));
        emit GreenMinted(carol, imageId, 3);
        vm.prank(carol);
        nft.mintGreen(imageId);

        assertEq(nft.ownerOf(nft.tokenIdFor(imageId, 3)), carol, "the logged generation is the minted one");
    }

    /*//////////////////////////////////////////////////////////////
                         GREEN AND BLUE DO NOT TOUCH
    //////////////////////////////////////////////////////////////*/

    /// Free mints must not move the paid curve. If the price ever read the total
    /// supply instead of the blue count, a busy character would quietly cost the
    /// next buyer more.
    function test_greensNeverRaiseThePriceOrTheBlueCount() public {
        uint256 before = nft.currentPrice();
        assertEq(before, PRICE_STEP, "the opening tier");

        for (uint256 i = 0; i < 5; ++i) {
            address who = _actor(i);
            vm.prank(who);
            nft.mintGreen(70);
        }
        assertEq(nft.greenCount(70), 5, "five generations taken");

        uint256 after_ = nft.currentPrice();
        assertEq(after_, before, "the price did not move");
        assertEq(nft.blueMinted(), 0, "and no blue was counted");

        uint256 paid = _buy(bob, 70);
        assertEq(paid, PRICE_STEP, "the buyer still paid the opening tier");
        assertEq(nft.blueMinted(), 1, "the sale counted one blue and no green");
        assertEq(nft.totalSupply(), 6, "five green and one blue");
    }

    /// The tier boundary is where a price counting the free edition would first
    /// show itself. One short of the first step, with greens taken on top, the
    /// blue that fills the tier must still close it at the opening price.
    function test_greensDoNotMoveTheTierBoundary() public {
        _sell(TIER_SIZE - 1);
        assertEq(nft.blueMinted(), TIER_SIZE - 1, "one short of the step");

        for (uint256 i = 0; i < 6; ++i) {
            address who = _actor(i);
            vm.prank(who);
            nft.mintGreen(9000);
        }
        assertEq(nft.currentPrice(), PRICE_STEP, "six greens did not step the price");

        uint256 paid = _buy(bob, 9500);
        assertEq(paid, PRICE_STEP, "the last of the tier cost the opening price");
        assertEq(nft.blueMinted(), TIER_SIZE, "the tier filled with blues alone");
        assertEq(nft.currentPrice(), _expectedPrice(TIER_SIZE), "and only now does it step");
    }

    /// Buying the blue is not taking the green. A collector who bought the paid
    /// edition, and a recipient who was given one, both still have their slot.
    function test_buyingBlueDoesNotSpendAGreenSlot() public {
        uint256 price = nft.currentPrice();
        vm.prank(alice);
        nft.mintBlue{value: price}(31, price);

        price = nft.currentPrice();
        vm.prank(alice);
        nft.mintBlueFor{value: price}(bob, 32, price);

        assertFalse(nft.greenTaken(31, alice), "the buyer's slot is untouched");
        assertFalse(nft.greenTaken(32, bob), "the recipient's slot is untouched");
        assertFalse(nft.greenTaken(32, alice), "and so is the payer's");
        assertEq(nft.greenMinted(), 0, "no green was minted by a purchase");

        vm.prank(alice);
        nft.mintGreen(31);
        vm.prank(bob);
        nft.mintGreen(32);
        vm.prank(alice);
        nft.mintGreen(32);

        assertEq(nft.greenCount(31), 1, "the buyer took the first generation");
        assertEq(nft.greenCount(32), 2, "the recipient and the payer both took one");
    }

    /// The bitmap is the blue sale's record and a page reads it to decide what is
    /// still for sale. A green must leave every word of it exactly as it was,
    /// the sold neighbour below its bit and the unsold one above included, and
    /// the sale that follows must set that one bit and nothing else.
    function test_greenLeavesTheBlueBitmapAlone() public {
        uint256 imageId = 513;
        _buy(carol, 512);
        _buy(carol, 9999);
        uint256 words = nft.blueBitmapWords();
        uint256[] memory before = nft.blueTakenBits(0, words);

        vm.prank(alice);
        nft.mintGreen(imageId);
        vm.prank(bob);
        nft.mintGreen(imageId);

        uint256[] memory afterGreens = nft.blueTakenBits(0, words);
        for (uint256 w = 0; w < words; ++w) {
            assertEq(afterGreens[w], before[w], string.concat("a green moved word ", vm.toString(w)));
        }
        assertFalse(nft.blueTaken(imageId), "the blue is still for sale");

        _buy(carol, imageId);
        assertTrue(nft.blueTaken(imageId), "and the sale sets it");

        // Character 513 is word 2 bit 1.
        uint256[] memory afterSale = nft.blueTakenBits(0, words);
        for (uint256 w = 0; w < words; ++w) {
            uint256 want = w == 2 ? before[w] | (uint256(1) << 1) : before[w];
            assertEq(afterSale[w], want, string.concat("the sale set the wrong bits in word ", vm.toString(w)));
        }
    }

    /// The free edition has no cap and shares none of blue's. Ten thousand sold
    /// closes the paid side and leaves green running.
    function test_greenKeepsWorkingAfterTheBlueEditionSellsOut() public {
        _sell(BLUE_SUPPLY);
        assertEq(nft.blueMinted(), BLUE_SUPPLY, "every character sold");

        uint256 ceiling = 1 ether;
        vm.prank(bob);
        vm.expectRevert(GlamToon.SoldOut.selector);
        nft.mintBlue{value: ceiling}(4242, ceiling);

        vm.prank(bob);
        nft.mintGreen(4242);
        vm.prank(carol);
        nft.mintGreen(4242);

        assertEq(nft.greenCount(4242), 2, "green carried on past the sell out");
        assertEq(nft.ownerOf(nft.tokenIdFor(4242, 2)), carol, "generation two minted");
        assertEq(nft.totalSupply(), BLUE_SUPPLY + 2, "supply counts both sides");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// A fresh wallet with no code, derived so the same index always gives the
    /// same address within a run.
    function _actor(uint256 index) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("glamtoon green actor", index)))));
    }

    function _exists(uint256 tokenId) internal view returns (bool ok) {
        (ok,) = address(nft).staticcall(abi.encodeWithSelector(nft.ownerOf.selector, tokenId));
    }

    function _greenCountSlot(uint256 imageId) internal pure returns (bytes32) {
        return keccak256(abi.encode(imageId, GREEN_COUNT_SLOT));
    }

    /// What a refused green must leave behind: the slot still free, the counts
    /// where they were and nothing in the wallet that tried.
    function _assertNoGreenLanded(uint256 imageId, address who, uint256 count, uint256 minted) internal view {
        assertFalse(nft.greenTaken(imageId, who), "the refused mint spent a slot");
        assertEq(nft.greenCount(imageId), count, "the refused mint moved the count");
        assertEq(nft.greenMinted(), minted, "the refused mint moved the total");
        assertEq(nft.balanceOf(who), 0, "the refused mint delivered a token");
    }
}

/// Mints in its own name on somebody else's instruction, which is what a relayer
/// or a shop contract looks like from inside mintGreen.
contract GreenForwarder {
    GlamToon immutable nft;

    constructor(GlamToon n) {
        nft = n;
    }

    function take(uint256 imageId) external {
        nft.mintGreen(imageId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// Mints from inside its constructor and hands the token on. It has no receiver
/// hook at all, so the mint only lands because an account under construction
/// has no code for the hook to be asked through.
contract ConstructorMinter {
    constructor(GlamToon nft, uint256 imageId, address to) {
        nft.mintGreen(imageId);
        nft.transferFrom(address(this), to, nft.tokenIdFor(imageId, nft.greenCount(imageId)));
    }
}

/// Builds a ConstructorMinter at an address fixed by the salt.
contract ConstructorMinterFactory {
    function make(bytes32 salt, GlamToon nft, uint256 imageId, address to) external returns (address) {
        return address(new ConstructorMinter{salt: salt}(nft, imageId, to));
    }
}

/// The plain kind of EIP-7702 delegate a wallet signs over to: it runs a call
/// when the wallet asks itself to, and accepts any token it is sent.
contract GreenExecutor {
    error NotTheWallet();

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(this)) revert NotTheWallet();
        return Address.functionCall(target, data);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
