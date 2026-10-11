// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {console} from "forge-std/console.sol";
import {BaseTest} from "../Base.t.sol";
import {GlamToon, ITraitData, ITraitNames} from "../../src/GlamToon.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {B64} from "./MetadataJson.t.sol";

/// Nothing else in the suite asserts a cost. There is no proxy and no admin, so
/// a change that doubles the price of a mint, or puts the metadata past what an
/// RPC will answer, is permanent. Every ceiling here is a measured number with
/// headroom, and the measurement is printed beside it at -vv, so the next person
/// can tell a regression from an improvement instead of guessing.
///
/// Measured 2026-09-23 with solc 0.8.36, via-ir, optimizer 200 runs, prague.
/// 0.8.37 compiles every contract to the same bytecode, so the numbers stand.
/// These are the costs a caller sees inside a transaction: no 21,000 intrinsic
/// and no calldata. Memory is the reason a number moves when the call around it
/// moves, so each measurement is taken in a fresh frame.
contract GasBoundsTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                                CEILINGS
    //////////////////////////////////////////////////////////////*/

    uint256 constant MINT_BLUE_MAX = 150_000; // measured 100,927
    uint256 constant MINT_BLUE_REFUND_MAX = 160_000; // measured 108,059
    uint256 constant MINT_BLUE_FOR_MAX = 160_000; // measured 106,660 with the collection cold
    uint256 constant MINT_GREEN_MAX = 175_000; // measured 121,516

    /// Narrow headroom on purpose. The metadata takes all eight of its names in
    /// one batched read, and the table is copied per read: unpicking that batch
    /// costs about 26,000, which these four have to fail rather than absorb.
    uint256 constant TOKEN_JSON_MAX = 105_000; // measured 82,529 for a blue
    uint256 constant TOKEN_URI_MAX = 150_000; // measured 127,350 for a blue
    uint256 constant TOKEN_JSON_DEEPEST_MAX = 125_000; // measured 107,090 at type(uint256).max
    uint256 constant TOKEN_URI_DEEPEST_MAX = 190_000; // measured 168,327 at type(uint256).max, cold

    uint256 constant TRAITS_OF_MAX = 28_000; // measured 18,453
    uint256 constant BITMAP_40_WORDS_MAX = 150_000; // measured 103,530 with every word set

    uint256 constant TRAITS_BATCH_1_MAX = 22_000; // measured 13,211
    uint256 constant TRAITS_BATCH_100_MAX = 1_600_000; // measured 1,116,800
    uint256 constant TRAITS_BATCH_1000_MAX = 18_000_000; // measured 12,959,434

    uint256 constant GREEN_BATCH_1_MAX = 12_000; // measured 6,623
    uint256 constant GREEN_BATCH_100_MAX = 450_000; // measured 297,359
    uint256 constant GREEN_BATCH_1000_MAX = 4_000_000; // measured 2,786,459

    uint256 constant ALL_TRAITS_MAX = 150_000; // measured 69,484
    uint256 constant TRAIT_NAMES_MAX = 30_000; // measured 10,052

    uint256 constant HOSTILE_MINT_MAX = 150_000; // measured 73,722 against a 64 kB reply
    uint256 constant OWNER_HOSTILE_MAX = 50_000; // measured 37,142 against a 64 kB reply
    uint256 constant OWNER_HONEST_MAX = 8_000; // measured 2,643 against the real treasury
    uint256 constant OWNER_HONEST_COLD_MAX = 15_000; // measured 9,619 with both accounts cold

    /// Memory is quadratic, so a batch is never exactly linear. Ten times the ids
    /// costs about eleven and a half times the gas at a thousand. Thirteen leaves
    /// room for that and still fails anything genuinely quadratic, which would be
    /// a hundred times over.
    uint256 constant LINEAR_SLACK = 13;

    /// A reply big enough that any per byte handling on our side would show, and
    /// small enough that the attacker can still afford to return it.
    uint256 constant BLOB = 64 * 1024;

    /// ERC721's _owners mapping, from forge inspect GlamToon storageLayout. Only
    /// the worst case tokenURI needs it, to own an id nobody can mint.
    uint256 constant OWNERS_SLOT = 2;

    string constant PREFIX = "data:application/json;base64,";

    /*//////////////////////////////////////////////////////////////
                                MINTING
    //////////////////////////////////////////////////////////////*/

    /// The first buyer in a transaction pays for every cold slot. That is the
    /// number a wallet quotes, so it is the one worth pinning.
    function test_buyingABlueStaysUnderTheCeilingEvenPayingForEveryColdSlot() public {
        _skipUnderCoverage();
        uint256 price = nft.currentPrice();
        vm.prank(alice);
        uint256 start = gasleft();
        nft.mintBlue{value: price}(7412, price);
        _check("mintBlue", start - gasleft(), MINT_BLUE_MAX);
    }

    /// Overpaying adds a transfer back to the buyer. It has to stay a rounding
    /// error against the mint rather than a second one.
    function test_theRefundOnAnOverpaymentIsNotASecondMint() public {
        _skipUnderCoverage();
        uint256 price = nft.currentPrice();
        vm.prank(alice);
        uint256 start = gasleft();
        nft.mintBlue{value: price + 1 ether}(7412, price);
        _check("mintBlue with refund", start - gasleft(), MINT_BLUE_REFUND_MAX);
    }

    /// Gifting touches a second account, so it costs more. Not so much more that
    /// gifting stops being worth offering. Both sales start from the same
    /// snapshot with the collection cooled, so each pays for the same cold sale
    /// slots and what is left between them is the recipient the gift touches.
    function test_giftingABlueCostsOneColdAccountMoreThanBuyingOne() public {
        _skipUnderCoverage();
        uint256 price = nft.currentPrice();
        uint256 fresh = vm.snapshotState();

        vm.cool(address(nft));
        vm.prank(alice);
        uint256 start = gasleft();
        nft.mintBlueFor{value: price}(bob, 7412, price);
        uint256 gift = start - gasleft();
        _check("mintBlueFor", gift, MINT_BLUE_FOR_MAX);

        vm.revertToState(fresh);
        vm.cool(address(nft));
        vm.prank(alice);
        start = gasleft();
        nft.mintBlue{value: price}(7412, price);
        uint256 self = start - gasleft();

        console.log("mintBlueFor", gift, "mintBlue", self);
        assertGt(gift, self, "a gift touches an account a purchase does not");
        assertLt(gift, self + 6_000, "a gift must cost about one cold account more, not a second mint");
    }

    /// Green is the free edition. If it stops being cheap it stops being free in
    /// the only sense that matters.
    function test_takingAGreenStaysUnderTheCeiling() public {
        _skipUnderCoverage();
        vm.prank(alice);
        uint256 start = gasleft();
        nft.mintGreen(7412);
        _check("mintGreen", start - gasleft(), MINT_GREEN_MAX);
    }

    /// Generations are uncapped. Taking the hundredth has to cost what taking
    /// the second did, or a popular character prices out its own latecomers.
    function test_aLateGenerationCostsWhatTheFirstOneDid() public {
        _skipUnderCoverage();
        vm.prank(alice);
        nft.mintGreen(7412);
        vm.prank(bob);
        uint256 start = gasleft();
        nft.mintGreen(7412);
        uint256 second = start - gasleft();

        for (uint256 i = 0; i < 100; ++i) {
            vm.prank(address(uint160(0x5000 + i)));
            nft.mintGreen(7412);
        }
        vm.prank(carol);
        start = gasleft();
        nft.mintGreen(7412);
        uint256 late = start - gasleft();

        console.log("mintGreen generation 2", second, "generation 103", late);
        assertLe(late, second + 1000, "the depth of a character must not price its next green");
    }

    /*//////////////////////////////////////////////////////////////
                                METADATA
    //////////////////////////////////////////////////////////////*/

    /// tokenURI is what every wallet and marketplace calls. It assembles the
    /// JSON, reads the trait table and Base64 encodes the lot, all on chain.
    function test_theMetadataOfABlueFitsInsideAnOrdinaryCall() public {
        _skipUnderCoverage();
        _buy(alice, 7412);

        uint256 start = gasleft();
        nft.tokenJSON(7412);
        _check("tokenJSON blue", start - gasleft(), TOKEN_JSON_MAX);

        start = gasleft();
        nft.tokenURI(7412);
        _check("tokenURI blue", start - gasleft(), TOKEN_URI_MAX);
    }

    /// A green carries one more number in its name and one more in its URL.
    /// Nothing else differs, so nothing else should be paid for: if a generation
    /// ever cost a second trait read, the free edition would be the expensive
    /// one to look at.
    function test_generationOneCostsAboutWhatABlueCosts() public {
        _skipUnderCoverage();
        _buy(alice, 7412);
        uint256 gen1 = _green(alice, 7412);
        nft.tokenJSON(7412); // warm the chunk and the name table for both reads

        uint256 start = gasleft();
        nft.tokenJSON(7412);
        uint256 blue = start - gasleft();

        start = gasleft();
        nft.tokenJSON(gen1);
        uint256 green = start - gasleft();

        // A green measures about 900 more for the longer name and page. A
        // second trait read would add about seven thousand.
        console.log("tokenJSON blue", blue, "generation 1", green);
        assertLt(green, blue + 4_000, "a generation number must not cost a second trait read");

        start = gasleft();
        nft.tokenURI(gen1);
        _check("tokenURI generation 1", start - gasleft(), TOKEN_URI_MAX);
    }

    /// The label collapses at GENERATION_SHOWN, so a token far past it must not
    /// cost more to describe than a shallow one, beyond the few digits its
    /// longer number takes. If it did, minting a character deep would be a way
    /// to make it unlistable.
    function test_aVeryDeepGenerationIsNoDearerToDescribeThanAShallowOne() public {
        _skipUnderCoverage();
        for (uint256 i = 0; i < 25; ++i) {
            vm.prank(address(uint160(0x5000 + i)));
            nft.mintGreen(7412);
        }
        uint256 shallowId = nft.tokenIdFor(7412, 1);
        uint256 deepId = nft.tokenIdFor(7412, nft.greenCount(7412));
        assertEq(nft.greenCount(7412), 25, "twenty five generations deep");

        // warm, so what is compared is the work not the slots
        nft.tokenJSON(shallowId);
        nft.tokenJSON(deepId);

        uint256 start = gasleft();
        nft.tokenURI(shallowId);
        uint256 shallowUri = start - gasleft();

        start = gasleft();
        nft.tokenURI(deepId);
        uint256 deepUri = start - gasleft();
        _check("tokenURI generation 25", deepUri, TOKEN_URI_MAX);

        start = gasleft();
        nft.tokenJSON(shallowId);
        uint256 shallowJson = start - gasleft();

        start = gasleft();
        nft.tokenJSON(deepId);
        uint256 deepJson = start - gasleft();
        _check("tokenJSON generation 25", deepJson, TOKEN_JSON_MAX);

        console.log("tokenURI generation 1", shallowUri, "generation 25", deepUri);
        console.log("tokenJSON generation 1", shallowJson, "generation 25", deepJson);
        assertLt(deepUri, shallowUri + 1_000, "a deep generation costs more than a shallow one to describe");
        assertLt(deepJson, shallowJson + 1_000, "a deep generation costs more than a shallow one to build");
    }

    /// tokenJSON answers for any id, minted or not, so the worst case is the
    /// largest uint256: a 74 digit generation and a 78 digit token id, both
    /// rendered as decimal. Nobody can reach it, and nobody should be able to
    /// wedge an explorer with it either.
    function test_theDeepestIdThatCanBeAskedAboutStillAnswers() public {
        _skipUnderCoverage();
        uint256 start = gasleft();
        nft.tokenJSON(type(uint256).max);
        _check("tokenJSON type(uint256).max", start - gasleft(), TOKEN_JSON_DEEPEST_MAX);
    }

    /// tokenURI refuses an id nobody owns, so its worst case can only be reached
    /// by writing an owner into storage: the largest uint256, and character zero
    /// at the deepest generation there is. Both are measured cold, both have to
    /// stay under their own ceiling, and both have to decode back to tokenJSON
    /// byte for byte.
    function test_theWorstCaseTokenUriDecodesToTokenJsonWithinBudget() public {
        _skipUnderCoverage();
        uint256[2] memory ids = [type(uint256).max, nft.tokenIdFor(0, type(uint256).max / 10_000)];
        string[2] memory what = ["tokenURI type(uint256).max", "tokenURI character 0 deepest"];

        for (uint256 i = 0; i < ids.length; ++i) {
            vm.store(address(nft), keccak256(abi.encode(ids[i], OWNERS_SLOT)), bytes32(uint256(uint160(alice))));
            assertEq(nft.ownerOf(ids[i]), alice, "the owner was not written where ERC721 reads it");

            vm.cool(address(nft));
            vm.cool(address(chunk0));
            vm.cool(address(chunk1));
            vm.cool(address(names));
            uint256 start = gasleft();
            string memory uri = nft.tokenURI(ids[i]);
            _check(what[i], start - gasleft(), TOKEN_URI_DEEPEST_MAX);

            assertEq(vm.indexOf(uri, PREFIX), 0, "the data URI prefix");
            assertEq(string(B64.decode(vm.replace(uri, PREFIX, ""))), nft.tokenJSON(ids[i]), what[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             THE SITE'S READS
    //////////////////////////////////////////////////////////////*/

    /// One character's traits costs a call into the chunk, which copies its whole
    /// ten thousand byte table into memory to read two bytes of it. That copy is
    /// the price, and it is what makes the batches below worth watching.
    function test_readingOneCharactersTraitsCostsOneTableCopy() public {
        _skipUnderCoverage();
        uint256 start = gasleft();
        nft.traitsOf(7412);
        _check("traitsOf", start - gasleft(), TRAITS_OF_MAX);
    }

    /// The whole bitmap in one call, which the site makes on every page load.
    /// Every word is set here, so this is the worst it ever gets.
    function test_theWholeBlueBitmapCostsOneCallEvenWithEveryWordSet() public {
        _skipUnderCoverage();
        // Word 39 starts at character 9,984, so one bit of every word is real.
        for (uint256 w = 0; w < 40; ++w) {
            _buy(alice, w * 256);
        }
        // Those mints warmed every word. A visitor's call has not, so cool them
        // back down or the number here is a fiction.
        vm.cool(address(nft));

        uint256 start = gasleft();
        uint256[] memory taken = nft.blueTakenBits(0, 40);
        _check("blueTakenBits(0,40) all set", start - gasleft(), BITMAP_40_WORDS_MAX);
        assertEq(taken.length, 40, "forty words");
    }

    /// The bitmap exists because the alternative is one ownership read per
    /// character. Forty words must beat a hundred single reads, never mind ten
    /// thousand, or the packing has quietly been undone.
    function test_theBitmapBeatsAskingCharacterByCharacter() public {
        _skipUnderCoverage();
        for (uint256 w = 0; w < 40; ++w) {
            _buy(alice, w * 256);
        }
        vm.cool(address(nft));
        uint256 start = gasleft();
        nft.blueTakenBits(0, 40);
        uint256 bitmap = start - gasleft();

        vm.cool(address(nft));
        start = gasleft();
        for (uint256 i = 0; i < 100; ++i) {
            nft.blueTaken(i * 100);
        }
        uint256 oneByOne = start - gasleft();

        console.log("blueTakenBits for 10,000 characters", bitmap, "100 single reads", oneByOne);
        assertLt(bitmap, oneByOne, "forty words must cost less than a hundred ownership reads");
    }

    /// A page of a thousand characters. The ceilings keep the call inside what an
    /// RPC will answer; the shape check is the real test, because a reader that
    /// went quadratic would pass a ceiling set at one size and fail everyone at
    /// the next.
    function test_traitsBatchStaysLinearInTheNumberOfCharactersAsked() public {
        _skipUnderCoverage();
        _traitsBatch(1); // warm the chunk, so the three numbers differ by work

        uint256 one = _traitsBatch(1);
        uint256 hundred = _traitsBatch(100);
        uint256 thousand = _traitsBatch(1000);

        _check("traitsBatch 1", one, TRAITS_BATCH_1_MAX);
        _check("traitsBatch 100", hundred, TRAITS_BATCH_100_MAX);
        _check("traitsBatch 1000", thousand, TRAITS_BATCH_1000_MAX);

        assertLt(hundred, one * 100 * LINEAR_SLACK / 10, "a hundred characters, about a hundred reads");
        assertLt(thousand, hundred * LINEAR_SLACK, "ten times the ids, about ten times the gas");
    }

    /// The same shape over the mapping the green mint writes. Measured with every
    /// slot set, since an unset slot is the cheap case.
    function test_greenTakenBatchStaysLinearWithEverySlotSet() public {
        _skipUnderCoverage();
        uint256[] memory thousand = _ids(1000);
        for (uint256 i = 0; i < 1000; ++i) {
            vm.prank(carol);
            nft.mintGreen(thousand[i]);
        }
        vm.cool(address(nft));

        uint256 start = gasleft();
        nft.greenTakenBatch(_ids(1), carol);
        uint256 one = start - gasleft();

        start = gasleft();
        nft.greenTakenBatch(_ids(100), carol);
        uint256 hundred = start - gasleft();

        vm.cool(address(nft));
        start = gasleft();
        bool[] memory taken = nft.greenTakenBatch(thousand, carol);
        uint256 thousandCost = start - gasleft();

        _check("greenTakenBatch 1", one, GREEN_BATCH_1_MAX);
        _check("greenTakenBatch 100", hundred, GREEN_BATCH_100_MAX);
        _check("greenTakenBatch 1000", thousandCost, GREEN_BATCH_1000_MAX);

        assertTrue(taken[999], "the last slot really was set");
        assertLt(thousandCost, hundred * LINEAR_SLACK, "ten times the ids, about ten times the gas");
    }

    /// The counts the site shows beside each character.
    function test_greenCountBatchStaysLinearWithEveryCountSet() public {
        _skipUnderCoverage();
        uint256[] memory thousand = _ids(1000);
        for (uint256 i = 0; i < 1000; ++i) {
            vm.prank(carol);
            nft.mintGreen(thousand[i]);
        }
        vm.cool(address(nft));

        uint256 start = gasleft();
        nft.greenCountBatch(_ids(1));
        uint256 one = start - gasleft();

        start = gasleft();
        nft.greenCountBatch(_ids(100));
        uint256 hundred = start - gasleft();

        vm.cool(address(nft));
        start = gasleft();
        uint256[] memory counts = nft.greenCountBatch(thousand);
        uint256 thousandCost = start - gasleft();

        _check("greenCountBatch 1", one, GREEN_BATCH_1_MAX);
        _check("greenCountBatch 100", hundred, GREEN_BATCH_100_MAX);
        _check("greenCountBatch 1000", thousandCost, GREEN_BATCH_1000_MAX);

        assertEq(counts[999], 1, "the last count really was set");
        assertLt(thousandCost, hundred * LINEAR_SLACK, "ten times the ids, about ten times the gas");
    }

    /// Both whole tables, one call each. This is the read the site is meant to
    /// make instead of ten thousand traitsOf calls, so it has to fit in one.
    function test_theWholeTablesComeBackInOneCallEach() public {
        _skipUnderCoverage();
        uint256 start = gasleft();
        bytes memory all = nft.allTraits();
        _check("allTraits", start - gasleft(), ALL_TRAITS_MAX);

        start = gasleft();
        bytes memory table = nft.traitNames();
        _check("traitNames", start - gasleft(), TRAIT_NAMES_MAX);

        assertEq(all.length, 20_000, "two bytes a character");
        assertEq(table.length, 68 * 32, "every name slot");
    }

    /// And pulling the table once must beat reading it a character at a time.
    /// A hundred single reads already cost more than all ten thousand records.
    function test_pullingTheWholeTableBeatsReadingItCharacterByCharacter() public {
        _skipUnderCoverage();
        uint256 start = gasleft();
        nft.allTraits();
        uint256 whole = start - gasleft();

        start = gasleft();
        for (uint256 i = 0; i < 100; ++i) {
            nft.traitsOf(i);
        }
        uint256 oneByOne = start - gasleft();

        console.log("allTraits", whole, "100 traitsOf", oneByOne);
        assertLt(whole, oneByOne, "the bulk read is the point of the bulk read");
    }

    /*//////////////////////////////////////////////////////////////
                          HOSTILE COUNTERPARTIES
    //////////////////////////////////////////////////////////////*/

    /// _safeMint hands control to the recipient, and the recipient chooses how
    /// much it says back. The collection reads the first word of that answer and
    /// leaves the rest where it is, so the payer's surcharge is the recipient's
    /// own memory and nothing more. A copy of the reply on our side would add
    /// about as much again, and this has to fail it.
    function test_aRecipientReturningSixtyFourKilobytesCannotInflateTheMintersBill() public {
        _skipUnderCoverage();
        PlainReceiver plain = new PlainReceiver();
        ReturnBomb bomb = new ReturnBomb(BLOB);

        _buy(alice, 1); // warm the sale slots so the two mints below compare fairly

        uint256 price = nft.currentPrice();
        vm.prank(alice);
        uint256 start = gasleft();
        nft.mintBlueFor{value: price}(address(plain), 2, price);
        uint256 honest = start - gasleft();

        price = nft.currentPrice();
        vm.prank(alice);
        start = gasleft();
        nft.mintBlueFor{value: price}(address(bomb), 3, price);
        uint256 hostile = start - gasleft();

        console.log("mintBlueFor honest", honest, "into a 64 kB reply", hostile);
        _check("mintBlueFor into a return bomb", hostile, HOSTILE_MINT_MAX);
        assertLt(hostile, honest * 3, "a hostile reply must not multiply the bill");
        assertGt(hostile, honest + _memoryCost(BLOB) - 2_000, "the bomb really returned its 64 kB");
        assertLt(hostile, honest + _memoryCost(BLOB) + 2_000, "the surcharge is the recipient's memory, no copy of it");
        assertEq(nft.ownerOf(3), address(bomb), "and the mint still lands");
    }

    /// owner() is the marketplace label. It reads the payee low level so that a
    /// bad answer cannot revert, and it keeps the whole answer before checking
    /// its length. So a long answer is paid for by whoever opens the collection
    /// page: the payee's memory and one copy of it into ours. The ceiling holds
    /// it to that one copy. Only an answer of fixed size is measured. A payee
    /// that sized its answer to the gas it was handed could run the read out of
    /// gas, but the payee is always a fresh Treasury, which answers one word.
    /// The read measured is the second of two in one call, so both accounts are
    /// warm, as a second visitor would find them, however the suite is run.
    function test_aPayeeReturningSixtyFourKilobytesCannotInflateTheOwnerRead() public {
        _skipUnderCoverage();
        OwnerBomb payee = new OwnerBomb(BLOB);
        GlamToon victim = new GlamToon(
            ITraitData(address(chunk0)),
            ITraitData(address(chunk1)),
            ITraitNames(address(names)),
            address(payee),
            SALE_START
        );

        (, uint256 warm, address label) = this.readTheLabelTwice(victim);
        _check("owner() against a return bomb payee", warm, OWNER_HOSTILE_MAX);
        assertGt(warm, _memoryCost(BLOB), "the bomb really returned its 64 kB");
        assertEq(label, address(0), "an answer that is not one word names nobody");
    }

    /// The honest case, for scale. Anything near the hostile number here would
    /// mean the low level read had grown a copy it does not need. Both reads
    /// run inside one call, so the second finds the two accounts and the owner
    /// slot warm however the suite is run, and the first, cold one is held to a
    /// ceiling of its own.
    function test_theOwnerLabelOnTheRealTreasuryIsAlmostFree() public {
        _skipUnderCoverage();
        vm.cool(address(nft));
        vm.cool(address(treasury));
        (uint256 cold, uint256 warm, address label) = this.readTheLabelTwice(nft);
        _check("owner() against the treasury, cold", cold, OWNER_HONEST_COLD_MAX);
        _check("owner() against the treasury", warm, OWNER_HONEST_MAX);
        assertEq(label, treasuryOwner, "the label follows the treasury");
    }

    /// A recipient that eats every wei of gas it is handed. The sub call runs out
    /// and comes back with nothing, which ERC721 turns into a clean rejection.
    /// The mint must not survive that: no token, no counter, no bitmap bit, no
    /// money moved, and the character still for sale to somebody else.
    function test_aRecipientThatBurnsAllTheGasCannotLeaveABlueHalfMinted() public {
        _skipUnderCoverage();
        GasBurner burner = new GasBurner(nft);
        uint256 price = nft.currentPrice();
        uint256 before = alice.balance;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(burner)));
        nft.mintBlueFor{value: price, gas: 5_000_000}(address(burner), 7412, price);

        assertEq(nft.blueMinted(), 0, "nothing was sold");
        assertEq(nft.totalSupply(), 0, "nothing exists");
        assertFalse(nft.blueTaken(7412), "the character is still for sale");
        assertEq(nft.blueTakenBits(7412 >> 8, 1)[0], 0, "and the bitmap agrees");
        assertEq(address(nft).balance, 0, "no money was taken");
        assertEq(alice.balance, before, "and none of it was alice's");

        _buy(bob, 7412);
        assertEq(nft.ownerOf(7412), bob, "the slot was never consumed");
    }

    /// Same for the free edition, where the per address slot is the thing worth
    /// wasting. Burning the gas must not mark a character taken for an address
    /// that never received anything, because that slot never comes back.
    function test_aRecipientThatBurnsAllTheGasCannotLeaveAGreenHalfMinted() public {
        _skipUnderCoverage();
        GasBurner burner = new GasBurner(nft);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(burner)));
        burner.takeGreen{gas: 5_000_000}(7412);

        assertEq(nft.greenMinted(), 0, "nothing exists");
        assertEq(nft.greenCount(7412), 0, "no generation was spent");
        assertFalse(nft.greenTaken(7412, address(burner)), "and the slot is still there to use");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// The label read twice in one frame, the first time cold and the second
    /// warm. External so the two reads share a call even when every call the
    /// test makes runs as a transaction of its own. The token is passed in, so
    /// no read of this contract's storage lands inside either measurement.
    function readTheLabelTwice(GlamToon token) external view returns (uint256 cold, uint256 warm, address label) {
        uint256 start = gasleft();
        token.owner();
        cold = start - gasleft();

        start = gasleft();
        label = token.owner();
        warm = start - gasleft();
    }

    /// What it costs to grow memory from nothing to `size` bytes.
    function _memoryCost(uint256 size) private pure returns (uint256) {
        uint256 words = (size + 31) / 32;
        return 3 * words + words * words / 512;
    }

    /// Print what it cost beside what it is allowed to cost, then hold it to the
    /// ceiling. The printed number is what to edit the constant to when a change
    /// is meant.
    function _check(string memory what, uint256 used, uint256 ceiling) private pure {
        console.log(what, used, "of", ceiling);
        assertLe(used, ceiling, what);
    }

    function _ids(uint256 n) private pure returns (uint256[] memory out) {
        out = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = i * 7;
        }
    }

    function _traitsBatch(uint256 n) private view returns (uint256) {
        uint256[] memory ids = _ids(n);
        uint256 start = gasleft();
        nft.traitsBatch(ids);
        return start - gasleft();
    }
}

/*//////////////////////////////////////////////////////////////
                                MOCKS
//////////////////////////////////////////////////////////////*/

/// An ordinary recipient, the baseline the hostile ones are measured against.
contract PlainReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// Answers the receiver hook with a huge blob. The magic value sits in the first
/// word, so the mint succeeds and what is left to measure is the cost of the
/// reply alone. Assembly because Solidity will not return more than it declares.
contract ReturnBomb {
    uint256 private immutable SIZE;

    constructor(uint256 size) {
        SIZE = size;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        uint256 n = SIZE;
        assembly {
            mstore(0, 0x150b7a0200000000000000000000000000000000000000000000000000000000)
            return(0, n)
        }
    }
}

/// A payee whose owner() answers with a huge blob. It needs no arming: the token
/// calls into it unprompted, on behalf of whoever asked for the label.
contract OwnerBomb {
    uint256 private immutable SIZE;

    constructor(uint256 size) {
        SIZE = size;
    }

    function owner() external view returns (address) {
        uint256 n = SIZE;
        assembly {
            mstore(0, 0)
            return(0, n)
        }
    }

    receive() external payable {}
}

/// Spends every wei of gas the mint forwards it, then never returns.
contract GasBurner {
    GlamToon private immutable NFT;

    constructor(GlamToon n) {
        NFT = n;
    }

    function takeGreen(uint256 imageId) external {
        NFT.mintGreen(imageId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        while (gasleft() > 0) {}
        return this.onERC721Received.selector;
    }
}
