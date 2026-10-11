// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";

/// Whole days rather than single calls. Every other file here pins one rule in
/// isolation; these walk a sequence the way a real buyer would and check that
/// the counters, the money and the metadata all still agree at the end of it.
/// A break that only shows up when two features meet has nowhere to hide here.
contract LifecycleTest is BaseTest {
    /*//////////////////////////////////////////////////////////////
                                LAUNCH DAY
    //////////////////////////////////////////////////////////////*/

    /// The day the sale opens, start to finish: the door shut a second early,
    /// twenty wallets through it, gifts and overpayments mixed in, free
    /// generations taken on the way, and the treasury pushed on twice. At the
    /// close every wallet must be down exactly one character's price and the
    /// whole day's takings must be sitting with the beneficiary.
    function test_launchDayTakesTwentyBuyersAndBalancesToTheWei() public {
        for (uint256 i = 0; i < 20; ++i) {
            vm.deal(_buyer(i), 5 ether);
        }

        vm.warp(SALE_START - 1);
        vm.prank(_buyer(0));
        vm.expectRevert(GlamToon.NotStarted.selector);
        nft.mintBlue{value: 1 ether}(100, 1 ether);
        vm.warp(SALE_START);

        address[20] memory expectedOwner;
        uint256 greens;

        for (uint256 i = 0; i < 20; ++i) {
            uint256 imageId = 100 + i;
            uint256 price = nft.currentPrice();
            assertEq(price, PRICE_STEP, "twenty sales never leave the opening tier");

            address who = _buyer(i);
            if (i % 4 == 2) {
                address gift = _buyer((i + 1) % 20);
                vm.prank(who);
                nft.mintBlueFor{value: price + 0.25 ether}(gift, imageId, price);
                expectedOwner[i] = gift;
            } else if (i % 4 == 1) {
                vm.prank(who);
                nft.mintBlue{value: price + 0.5 ether}(imageId, price);
                expectedOwner[i] = who;
            } else {
                vm.prank(who);
                nft.mintBlue{value: price}(imageId, price);
                expectedOwner[i] = who;
            }

            assertEq(nft.ownerOf(imageId), expectedOwner[i], "the character landed on the intended wallet");
            assertEq(nft.blueMinted(), i + 1, "one more sale on the books");
            assertTrue(nft.blueTaken(imageId), "and the character reads as sold");

            // a third of the room also takes the free edition of what they just touched
            if (i % 3 == 0) {
                vm.prank(who);
                nft.mintGreen(imageId);
                ++greens;
                assertEq(
                    nft.ownerOf(nft.tokenIdFor(imageId, 1)), who, "the first generation belongs to whoever took it"
                );
            }

            // midday push, by somebody with no role in the sale at all
            if (i == 9) {
                vm.prank(carol);
                nft.withdraw();
                vm.prank(carol);
                treasury.sweep();
                assertEq(beneficiary.balance, 10 * PRICE_STEP, "the midday sweep carried the first ten sales");
                assertEq(address(nft).balance, 0, "and left the collection empty behind it");
            }
        }

        vm.prank(carol);
        nft.withdraw();
        vm.prank(carol);
        treasury.sweep();

        for (uint256 i = 0; i < 20; ++i) {
            assertEq(_buyer(i).balance, 5 ether - PRICE_STEP, "every wallet paid one price and got the rest back");
            assertTrue(nft.blueTaken(100 + i), "every character of the day is spoken for");
            uint256[] memory word = nft.blueTakenBits((100 + i) >> 8, 1);
            assertEq((word[0] >> ((100 + i) & 0xff)) & 1, 1, "and its bit is up in the bitmap");
        }

        assertFalse(nft.blueTaken(120), "the character after the last sale is untouched");
        assertEq(nft.blueMinted(), 20, "twenty genesis sales");
        assertEq(nft.greenMinted(), greens, "and the free editions that were taken");
        assertEq(nft.totalSupply(), 20 + greens, "supply is both editions added up");

        assertEq(beneficiary.balance, 20 * PRICE_STEP, "the day's takings all reached the beneficiary");
        assertEq(address(nft).balance, 0, "nothing stranded in the collection");
        assertEq(address(treasury).balance, 0, "nothing stranded in the treasury");
    }

    /*//////////////////////////////////////////////////////////////
                       THE TIER BOUNDARY UNDER LOAD
    //////////////////////////////////////////////////////////////*/

    /// Three buyers quote the opening tier at the same moment with two sales
    /// left in it. Two land and close the tier; the third arrives at the new
    /// price with the old ceiling and must be turned away rather than quietly
    /// charged double out of the buffer it sent.
    function test_theTierBoundaryHoldsWhenThreeBuyersRaceAcrossIt() public {
        _sell(2498);
        assertEq(nft.blueMinted(), 2498, "two sales short of the boundary");

        address first = _buyer(30);
        address second = _buyer(31);
        address loser = _buyer(32);
        vm.deal(first, 5 ether);
        vm.deal(second, 5 ether);
        vm.deal(loser, 5 ether);

        uint256 quoted = nft.currentPrice();
        assertEq(quoted, PRICE_STEP, "all three are quoting the opening tier");

        // sale 2499 of the tier
        vm.prank(first);
        nft.mintBlue{value: quoted}(2500, quoted);
        assertEq(first.balance, 5 ether - PRICE_STEP, "charged the tier it quoted");

        // sale 2500, the last of the tier, still at the tier that it closes
        vm.prank(second);
        nft.mintBlue{value: quoted + 1 ether}(2501, quoted);
        assertEq(second.balance, 5 ether - PRICE_STEP, "the last sale of a tier pays that tier, not the next");
        assertEq(nft.blueMinted(), 2500, "the tier is full");

        // the straggler's quote is now stale, and the ceiling is what saves it
        vm.prank(loser);
        vm.expectRevert(GlamToon.PriceTooHigh.selector);
        nft.mintBlue{value: quoted + 1 ether}(2502, quoted);
        assertEq(loser.balance, 5 ether, "a refused racer is not charged");
        assertFalse(nft.blueTaken(2502), "and takes no character with it");
        assertEq(nft.blueMinted(), 2500, "a refusal moves nothing");

        uint256 requoted = nft.currentPrice();
        assertEq(requoted, 2 * PRICE_STEP, "the boundary stepped exactly once");

        // sale 2501, the first of the new tier
        vm.prank(loser);
        nft.mintBlue{value: requoted + 3 ether}(2502, requoted);
        assertEq(loser.balance, 5 ether - 2 * PRICE_STEP, "the retry pays the new tier and gets the buffer back");
        assertEq(nft.ownerOf(2502), loser, "and the character is theirs");

        assertEq(
            address(nft).balance,
            2500 * PRICE_STEP + 2 * PRICE_STEP,
            "two and a half thousand at one tier and one at the next"
        );
    }

    /*//////////////////////////////////////////////////////////////
                           A COLLECTOR'S COURSE
    //////////////////////////////////////////////////////////////*/

    /// One collector doing everything the contract offers, then lending two
    /// tokens to a marketplace escrow and taking them back. The escrow is
    /// called into by the collection without asking for it, which is how a real
    /// listing works. Nothing about a token moving may move a counter.
    function test_aCollectorBuysGiftsGreensAndListsWithoutLosingCount() public {
        uint256[3] memory mine = [uint256(11), 22, 33];
        for (uint256 i = 0; i < 3; ++i) {
            _buy(alice, mine[i]);
        }
        assertEq(nft.balanceOf(alice), 3, "three genesis characters");

        uint256 giftPrice = nft.currentPrice();
        vm.prank(alice);
        nft.mintBlueFor{value: giftPrice}(bob, 44, giftPrice);
        assertEq(nft.ownerOf(44), bob, "the gift is the recipient's outright");
        assertEq(nft.balanceOf(alice), 3, "and never touches the payer's shelf");

        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(alice);
            nft.mintGreen(mine[i]);
            assertEq(nft.ownerOf(nft.tokenIdFor(mine[i], 1)), alice, "the free edition of a character they own");
        }
        assertEq(nft.balanceOf(alice), 6, "three blue and three green");
        assertEq(nft.totalSupply(), 7, "plus the gift");

        MarketEscrow escrow = new MarketEscrow(IERC721(address(nft)));
        uint256 green11 = nft.tokenIdFor(11, 1);

        vm.startPrank(alice);
        nft.safeTransferFrom(alice, address(escrow), 11);
        nft.safeTransferFrom(alice, address(escrow), green11);
        vm.stopPrank();

        assertEq(escrow.taken(), 2, "the escrow was handed both tokens by the collection itself");
        assertEq(escrow.depositor(11), alice, "and knows who to give them back to");
        assertEq(nft.balanceOf(address(escrow)), 2, "held by the escrow");
        assertEq(nft.balanceOf(alice), 4, "and off the collector's shelf meanwhile");

        // listing a token does not put the character back on sale
        uint256 price = nft.currentPrice();
        vm.prank(carol);
        vm.expectRevert(GlamToon.BlueAlreadyTaken.selector);
        nft.mintBlue{value: price}(11, price);

        // nor does it hand the collector a second free edition
        vm.prank(alice);
        vm.expectRevert(GlamToon.GreenAlreadyTaken.selector);
        nft.mintGreen(11);

        escrow.release(11);
        escrow.release(green11);
        assertEq(nft.ownerOf(11), alice, "the genesis came home");
        assertEq(nft.ownerOf(green11), alice, "and so did the generation");
        assertEq(nft.balanceOf(alice), 6, "the shelf is whole again");
        assertEq(nft.balanceOf(address(escrow)), 0, "and the escrow holds nothing");

        assertEq(nft.blueMinted(), 4, "the round trip sold nothing");
        assertEq(nft.greenMinted(), 3, "and minted nothing");
        assertEq(nft.greenCount(11), 1, "the character still has one generation");
        assertTrue(nft.greenTaken(11, alice), "and the collector's slot is still spent");
        assertEq(nft.totalSupply(), 7, "supply is where it was");

        uint256[] memory words = nft.blueTakenBits(0, 1);
        uint256 expectedBits = (uint256(1) << 11) | (uint256(1) << 22) | (uint256(1) << 33) | (uint256(1) << 44);
        assertEq(words[0], expectedBits, "exactly the four characters bought, and no others");
    }

    /*//////////////////////////////////////////////////////////////
                       TWO CHARACTERS WORTH PINNING
    //////////////////////////////////////////////////////////////*/

    /// The first character of the collection and the one swapped in for it
    /// during production. They sit either side of the chunk seam, so between
    /// them they prove both data contracts answer for their own range, and the
    /// rows below are the shipped table read straight off the sheet: if the
    /// trait data is ever rebuilt against different art, this is where it shows.
    function test_characterZeroAndTheSixThreeThreeFourSwapBothShipAsTheSheetSays() public {
        _buy(alice, 0);
        _buy(bob, 6334);
        assertEq(nft.ownerOf(0), alice, "character zero sold");
        assertEq(nft.ownerOf(6334), bob, "and its stand in too");

        assertEq(nft.recordOf(0), 0x1012, "character zero's packed row");
        assertEq(nft.recordOf(6334), 0x0211, "and 6334's, from the far side of the chunk seam");

        uint8[4] memory zero = nft.traitsOf(0);
        assertEq(zero[0], 1, "Dress Code index");
        assertEq(zero[1], 0, "Age index");
        assertEq(zero[2], 1, "Hair Cut index");
        assertEq(zero[3], 2, "Hair Colour index");

        uint8[4] memory swap = nft.traitsOf(6334);
        assertEq(swap[0], 0, "Dress Code index");
        assertEq(swap[1], 2, "Age index");
        assertEq(swap[2], 1, "Hair Cut index");
        assertEq(swap[3], 1, "Hair Colour index");

        _assertTraits(0, "Masculine", "18-25", "Medium", "Medium");
        _assertTraits(6334, "Feminine", "41-70", "Medium", "Light");

        _assertArt(0, 0);
        _assertArt(6334, 6334);

        assertEq(_field(0, ".name"), "Glamtoon #0", "title");
        assertEq(_field(6334, ".name"), "Glamtoon #6334", "title");
        assertEq(_attr(0, 0, "value"), "Genesis Blue", "edition");
        assertEq(_attr(6334, 0, "value"), "Genesis Blue", "edition");

        // and the free edition of each, which is the same character on the other background
        vm.prank(carol);
        nft.mintGreen(0);
        vm.prank(carol);
        nft.mintGreen(6334);

        uint256 green0 = nft.tokenIdFor(0, 1);
        uint256 green6334 = nft.tokenIdFor(6334, 1);
        assertEq(_field(green0, ".name"), "Glamtoon #0 Gen 1", "the generation is in the title");
        assertEq(_field(green6334, ".name"), "Glamtoon #6334 Gen 1", "the generation is in the title");
        assertEq(
            _field(green0, ".external_url"),
            "https://glamtoon.com/token/10000",
            "the page is the token, not the character"
        );
        assertEq(
            _field(green6334, ".external_url"),
            "https://glamtoon.com/token/16334",
            "the page is the token, not the character"
        );
        _assertArt(green0, 0);
        _assertArt(green6334, 6334);

        // the paint changed, the character did not
        _assertTraits(green0, "Masculine", "18-25", "Medium", "Medium");
        _assertTraits(green6334, "Feminine", "41-70", "Medium", "Light");
        assertEq(_attr(green0, 0, "value"), "Generation Green", "edition");
        assertEq(_attr(green6334, 0, "value"), "Generation Green", "edition");
    }

    /*//////////////////////////////////////////////////////////////
                        THE LONG GENERATION WALK
    //////////////////////////////////////////////////////////////*/

    /// One character taken as deep as a collector is likely to see it. From the
    /// ninth generation on the filter row groups, but the id, the title and the
    /// page must all still say exactly which generation is being held, or the
    /// grouping has swallowed something it was never meant to.
    function test_oneCharacterWalkedToGenerationTwelveKeepsItsIdWhileTheLabelGroups() public {
        uint256 imageId = 777;
        _buy(alice, imageId);
        assertEq(_attr(imageId, 5, "trait_type"), "Generation", "the row exists on the genesis too");
        assertEq(_attr(imageId, 5, "value"), "0", "and the genesis is generation zero");

        for (uint256 g = 1; g <= 12; ++g) {
            address who = _buyer(50 + g);
            vm.prank(who);
            nft.mintGreen(imageId);

            uint256 id = nft.tokenIdFor(imageId, g);
            assertEq(id, g * 10_000 + imageId, "the id is the generation in front of the character");

            (uint256 gotImage, uint256 gotGeneration) = nft.decode(id);
            assertEq(gotImage, imageId, "decode still names the character");
            assertEq(gotGeneration, g, "and the generation, however deep");
            assertEq(nft.ownerOf(id), who, "the generation is the wallet's that took it");
            assertEq(nft.greenCount(imageId), g, "the count is the generation just taken");

            string memory label = _attr(id, 5, "value");
            if (g < 9) {
                assertEq(label, vm.toString(g), "below the threshold a generation shows its own number");
            } else {
                assertEq(label, "9+", "from the ninth on they share one row");
            }

            // grouped in the filter, exact everywhere a holder actually looks
            assertEq(
                _field(id, ".name"),
                string.concat("Glamtoon #777 Gen ", vm.toString(g)),
                "the title carries the exact generation"
            );
            assertEq(
                _field(id, ".external_url"),
                string.concat("https://glamtoon.com/token/", vm.toString(id)),
                "and so does the page"
            );
            assertEq(_attr(id, 0, "value"), "Generation Green", "no generation is ever the genesis");
        }

        assertEq(nft.greenCount(imageId), 12, "twelve generations");
        assertEq(nft.greenMinted(), 12, "and nothing else was minted free");
        assertEq(nft.totalSupply(), 13, "twelve generations and the genesis");
        assertEq(nft.blueMinted(), 1, "the depth of a character says nothing about the sale");
    }

    /*//////////////////////////////////////////////////////////////
                              A TIER SOLD OUT
    //////////////////////////////////////////////////////////////*/

    /// Two and a half thousand sales, alternating between the two mint doors,
    /// so the tier closes on a gift rather than a plain buy. The price must hold
    /// for every one of them and step on the sale after, the treasury must end
    /// up holding the exact twenty five ether the tier is worth, and the three
    /// ways of asking what was sold must give the same answer.
    function test_aWholeTierSellsOutThroughBothDoorsAndStepsOnTheSaleAfter() public {
        address door = _buyer(60);
        address giver = _buyer(61);
        address recipient = _buyer(62);
        vm.deal(door, 100 ether);
        vm.deal(giver, 100 ether);

        for (uint256 id = 0; id < TIER_SIZE; ++id) {
            uint256 price = nft.currentPrice();
            assertEq(price, PRICE_STEP, "the opening tier holds for every one of its sales");
            if (id % 2 == 0) {
                vm.prank(door);
                nft.mintBlue{value: price}(id, price);
            } else {
                vm.prank(giver);
                nft.mintBlueFor{value: price}(recipient, id, price);
            }
        }

        assertEq(nft.currentPrice(), 2 * PRICE_STEP, "the step lands on the sale after the tier, not inside it");
        assertEq(nft.blueMinted(), TIER_SIZE, "the tier is sold");
        assertEq(nft.totalSupply(), TIER_SIZE, "and with no free editions taken that is the whole supply");

        assertEq(door.balance, 100 ether - (TIER_SIZE / 2) * PRICE_STEP, "the buyer paid for half the tier");
        assertEq(giver.balance, 100 ether - (TIER_SIZE / 2) * PRICE_STEP, "and the gifter for the other half");
        assertEq(recipient.balance, 0, "a gift recipient neither pays nor is paid");
        assertEq(nft.balanceOf(door), TIER_SIZE / 2, "half the tier through the front door");
        assertEq(nft.balanceOf(recipient), TIER_SIZE / 2, "and half through the gift door");

        vm.prank(carol);
        nft.withdraw();
        assertEq(
            address(treasury).balance,
            TIER_SIZE * PRICE_STEP,
            "the opening tier is worth twenty five ether and the treasury has all of it"
        );
        assertEq(address(nft).balance, 0, "with nothing left behind");

        uint256[] memory words = nft.blueTakenBits(0, nft.blueBitmapWords());
        uint256 set;
        for (uint256 w = 0; w < words.length; ++w) {
            for (uint256 b = 0; b < 256; ++b) {
                set += (words[w] >> b) & 1;
            }
        }
        assertEq(set, TIER_SIZE, "the bitmap counts exactly what was sold");

        uint256 solid = TIER_SIZE / 256;
        uint256 tail = TIER_SIZE % 256;
        for (uint256 w = 0; w < solid; ++w) {
            assertEq(words[w], type(uint256).max, "every word below the tier is solid");
        }
        assertEq(words[solid], (uint256(1) << tail) - 1, "the next word stops dead on the last character sold");
        for (uint256 w = solid + 1; w < words.length; ++w) {
            assertEq(words[w], 0, "and nothing above the tier is marked");
        }

        assertTrue(nft.blueTaken(TIER_SIZE - 1), "the last character of the tier is sold");
        assertFalse(nft.blueTaken(TIER_SIZE), "the first one past it is not");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// A fresh wallet, keyed well clear of the fixture's own addresses.
    function _buyer(uint256 n) internal pure returns (address) {
        return vm.addr(0x1000 + n);
    }

    function _field(uint256 tokenId, string memory path) internal view returns (string memory) {
        return vm.parseJsonString(nft.tokenJSON(tokenId), path);
    }

    function _attr(uint256 tokenId, uint256 index, string memory field) internal view returns (string memory) {
        return
            vm.parseJsonString(nft.tokenJSON(tokenId), string.concat(".attributes[", vm.toString(index), "].", field));
    }

    /// The four trait rows of a token, in record order after the edition row.
    function _assertTraits(
        uint256 tokenId,
        string memory dress,
        string memory age,
        string memory cut,
        string memory colour
    ) internal view {
        assertEq(_attr(tokenId, 1, "trait_type"), "Dress Code", "first category");
        assertEq(_attr(tokenId, 1, "value"), dress, "Dress Code");
        assertEq(_attr(tokenId, 2, "trait_type"), "Age", "second category");
        assertEq(_attr(tokenId, 2, "value"), age, "Age");
        assertEq(_attr(tokenId, 3, "trait_type"), "Hair Cut", "third category");
        assertEq(_attr(tokenId, 3, "value"), cut, "Hair Cut");
        assertEq(_attr(tokenId, 4, "trait_type"), "Hair Colour", "fourth category");
        assertEq(_attr(tokenId, 4, "value"), colour, "Hair Colour");
    }

    /// All four art URLs of a token, against the getters and the edition folder.
    function _assertArt(uint256 tokenId, uint256 imageId) internal view {
        bool blue = nft.isBlue(tokenId);
        string memory dir = blue ? "/blue/" : "/green/";
        string memory id = vm.toString(imageId);

        assertEq(
            _field(tokenId, ".image"), string.concat("ipfs://", nft.ipfsRoot(), dir, id, ".png"), "full resolution art"
        );
        assertEq(
            _field(tokenId, ".glamtoon.optimized"),
            string.concat("ipfs://", nft.ipfsRoot(), dir, id, ".webp"),
            "the lighter copy"
        );
        assertEq(
            _field(tokenId, ".glamtoon.arweave"),
            string.concat("ar://", nft.arweaveManifest(), dir, id, ".png"),
            "the second home of the art"
        );
        assertEq(
            _field(tokenId, ".glamtoon.arweave_optimized"),
            string.concat("ar://", nft.arweaveManifest(), dir, id, ".webp"),
            "and of the lighter copy"
        );

        assertEq(_field(tokenId, ".image"), nft.imageURI(imageId, blue), "the getter agrees with the metadata");
        assertEq(_field(tokenId, ".glamtoon.optimized"), nft.optimizedURI(imageId, blue), "and for the lighter copy");
        assertEq(_field(tokenId, ".glamtoon.arweave"), nft.arweaveURI(imageId, blue), "and on arweave");
        assertEq(
            _field(tokenId, ".glamtoon.arweave_optimized"),
            nft.arweaveOptimizedURI(imageId, blue),
            "and for the lighter copy there"
        );
    }
}

/*//////////////////////////////////////////////////////////////
                                MOCKS
//////////////////////////////////////////////////////////////*/

/// A marketplace escrow. It never calls the collection to fetch a token: the
/// token is pushed into it by a transfer somebody else starts, which is the
/// case a mock that only fires on its own calls would miss.
contract MarketEscrow {
    IERC721 public immutable COLLECTION;

    mapping(uint256 tokenId => address) public depositor;
    uint256 public taken;

    constructor(IERC721 collection) {
        COLLECTION = collection;
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(COLLECTION), "not the collection");
        depositor[tokenId] = from;
        ++taken;
        return this.onERC721Received.selector;
    }

    function release(uint256 tokenId) external {
        address to = depositor[tokenId];
        require(to != address(0), "not held");
        delete depositor[tokenId];
        COLLECTION.safeTransferFrom(address(this), to, tokenId);
    }
}
