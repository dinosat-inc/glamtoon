// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToonHandler} from "./handlers/GlamToonHandler.sol";

/// What has to hold no matter what order anyone does anything in.
contract GlamToonInvariants is BaseTest {
    GlamToonHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new GlamToonHandler(nft);
        targetContract(address(handler));
    }

    /// An invariant that never ran is an invariant that never held. Foundry
    /// calls this once a run is over, which is the only place a claim about
    /// coverage rather than state belongs.
    function afterInvariant() public view {
        assertGt(handler.bluesTakenCount(), 0, "no blue was ever sold");
        assertGt(handler.greensTakenCount(), 0, "no green was ever taken");
        assertGt(handler.giftsCount(), 0, "the gift path was never exercised");
    }

    /// Ten thousand blues, and not one more, however the sale is driven.
    function invariant_genesisSupplyIsCapped() public view {
        assertLe(nft.blueMinted(), BLUE_SUPPLY, "more blues than exist");
        assertEq(nft.blueMinted(), handler.bluesTakenCount(), "the count drifted from the sales");
    }

    /// Every wei in is either still held, refunded to whoever overpaid, or gone
    /// to the one payee. Nothing leaks anywhere else and nothing is conjured.
    function invariant_etherIsAccountedFor() public view {
        uint256 inflow = handler.totalPaid() + handler.totalForceFed();
        uint256 outflow = handler.totalRefunded() + handler.totalWithdrawn();
        assertLe(outflow, inflow, "more ether left than ever arrived");
        assertEq(address(nft).balance, inflow - outflow, "the balance does not add up");
    }

    /// Nothing here ever sweeps the treasury, so it holds every withdrawal and
    /// not a wei more. A refund or a sale that paid the treasury directly would
    /// leave it holding too much.
    function invariant_everythingWithdrawnWentToThePayee() public view {
        assertEq(address(treasury).balance, handler.totalWithdrawn(), "money went somewhere else");
    }

    /// The price follows the stated rule at whatever point the sale has reached.
    /// A run here stays in the first tier. TierInvariants.t.sol starts the sale
    /// below each edge and near the end, and holds every sale to the same rule.
    function invariant_priceMatchesTheRule() public view {
        uint256 sold = nft.blueMinted();
        if (sold >= BLUE_SUPPLY) return;
        assertEq(nft.currentPrice(), _expectedPrice(sold), "price drifted from the rule");
        assertGe(nft.currentPrice(), PRICE_STEP, "below the opening price");
        assertLe(nft.currentPrice(), 4 * PRICE_STEP, "above the last tier");
    }

    /// Supply is the two editions added up, and it never falls, because nothing
    /// can be burned.
    function invariant_supplyIsTheTwoEditions() public view {
        assertEq(nft.totalSupply(), nft.blueMinted() + nft.greenMinted(), "supply is not the sum");
        assertEq(nft.totalSupply(), handler.mintedCount(), "supply drifted from the mints");
    }

    /// Balances add up to supply. This is the ledger property an ERC721 must never
    /// break, and the one a careless mint would break first.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            sum += nft.balanceOf(handler.actors(i));
        }
        sum += nft.balanceOf(address(handler));
        assertEq(sum, nft.totalSupply(), "balances do not add up to supply");
    }

    /// Every token that exists decodes back to the character and generation it was
    /// minted for, and the count of green generations matches what was taken.
    function invariant_everyTokenDecodesToWhatItIs() public view {
        uint256 n = handler.mintedCount();
        uint256 checked = n > 40 ? 40 : n;
        for (uint256 i = 0; i < checked; ++i) {
            uint256 tokenId = handler.mintedAt(n - checked + i);
            (uint256 imageId, uint256 generation) = nft.decode(tokenId);
            assertLt(imageId, BLUE_SUPPLY, "image id out of range");
            assertEq(nft.tokenIdFor(imageId, generation), tokenId, "does not re-encode");
            assertLe(generation, nft.greenCount(imageId), "generation beyond the count");
            if (generation == 0) {
                assertTrue(nft.blueTaken(imageId), "a blue exists that is not recorded as sold");
            }
        }
    }

    /// The bitmap the picker reads has to agree with who actually owns what.
    function invariant_bitmapAgreesWithOwnership() public view {
        uint256 n = handler.mintedCount();
        uint256 checked = n > 40 ? 40 : n;
        for (uint256 i = 0; i < checked; ++i) {
            uint256 tokenId = handler.mintedAt(n - checked + i);
            if (tokenId >= BLUE_SUPPLY) continue;
            uint256[] memory words = nft.blueTakenBits(tokenId >> 8, 1);
            assertEq((words[0] >> (tokenId & 0xff)) & 1, 1, "sold but not marked in the bitmap");
        }
    }

    /// Metadata is a view the whole world calls. It must answer for every token
    /// the collection has ever minted, in any state the collection is in.
    function invariant_metadataAlwaysAnswers() public view {
        uint256 n = handler.mintedCount();
        uint256 checked = n > 15 ? 15 : n;
        for (uint256 i = 0; i < checked; ++i) {
            uint256 tokenId = handler.mintedAt(n - checked + i);
            assertGt(bytes(nft.tokenURI(tokenId)).length, 200, "a token has no metadata");
        }
    }

    /// Every door the handler drove was one it had already checked should open.
    /// A revert means the contract refused a sale, a green, a transfer or a
    /// withdrawal it had no reason to refuse, which a campaign that lets calls
    /// fail quietly would never notice.
    function invariant_callsThatShouldHaveGoneThroughDid() public view {
        assertFalse(handler.unexpectedRevert(), "a call that should have gone through reverted");
    }

    /// Nothing anybody did moved the payee, the royalty, or the renderer.
    function invariant_nothingIsAdministrable() public view {
        assertEq(nft.PAYOUT(), address(treasury), "the payee moved");
        assertEq(address(nft.CHUNK0()), address(chunk0), "a trait chunk moved");
        assertEq(address(nft.NAMES()), address(names), "the name table moved");
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, address(treasury), "the royalty receiver moved");
        assertEq(amount, 0.02 ether, "the royalty rate moved");
        assertEq(nft.owner(), treasury.owner(), "the label stopped following the treasury");
        assertEq(treasury.pendingOwner(), address(0), "somebody was offered the treasury");
    }
}
