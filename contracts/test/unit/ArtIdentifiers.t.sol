// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";

/// The two strings nothing else checks. Swap IPFS_ROOT or ARWEAVE for another
/// well formed identifier and every other test in this repository still passes:
/// they assert the shape of a URL, never the root inside it. The deploy script
/// does not help either, because it compares the deployed root against the same
/// compiled constant, which is a value compared to itself.
///
/// They are also the two values that can never be corrected. A wrong CID ships a
/// collection whose art nobody can fetch, forever, with no admin to fix it.
///
/// So this file pins them three ways: the literal the contract must carry, the
/// shape that literal must have, and agreement with PROVENANCE.md, which is the
/// document telling the world how to rebuild the art.
contract ArtIdentifiersTest is BaseTest {
    /// The CAR that produced this root is 24,360,504,083 bytes and its sha256 is
    /// recorded in PROVENANCE.md. Both were verified against Filebase, Pinata
    /// and arweave.net before the constants were set.
    string internal constant EXPECTED_IPFS = "bafybeide2rqgoymdal3bhump5imrmladdo73umdro4ezbswmvnuprvqdeu";
    string internal constant EXPECTED_ARWEAVE = "h9hcgqPaUnpUDbwyXkdoRE_mFuRUN_jFNBPd2Kz4jBM";
    string internal constant EXPECTED_BASE = "https://glamtoon.com/token/";

    string internal constant PROVENANCE = "../PROVENANCE.md";

    /*//////////////////////////////////////////////////////////////
                              THE LITERALS
    //////////////////////////////////////////////////////////////*/

    function test_theArtRootsAreTheOnesThatWerePinned() public view {
        assertEq(nft.ipfsRoot(), EXPECTED_IPFS, "the IPFS root is not the pinned one");
        assertEq(nft.arweaveManifest(), EXPECTED_ARWEAVE, "the Arweave manifest is not the pinned one");
        assertEq(nft.tokenBase(), EXPECTED_BASE, "the token base moved");
    }

    /// Every URL the contract can build, for both editions and both file types,
    /// against strings written out in full. A getter that quietly dropped the
    /// root, or built the path from the wrong constant, reads as correct in a
    /// shape test and fails here.
    function test_everyUrlIsBuiltFromThePinnedRoots() public view {
        assertEq(
            nft.imageURI(7412, true),
            "ipfs://bafybeide2rqgoymdal3bhump5imrmladdo73umdro4ezbswmvnuprvqdeu/blue/7412.png",
            "blue png"
        );
        assertEq(
            nft.optimizedURI(7412, true),
            "ipfs://bafybeide2rqgoymdal3bhump5imrmladdo73umdro4ezbswmvnuprvqdeu/blue/7412.webp",
            "blue webp"
        );
        assertEq(
            nft.imageURI(0, false),
            "ipfs://bafybeide2rqgoymdal3bhump5imrmladdo73umdro4ezbswmvnuprvqdeu/green/0.png",
            "green png"
        );
        assertEq(
            nft.arweaveURI(9999, true), "ar://h9hcgqPaUnpUDbwyXkdoRE_mFuRUN_jFNBPd2Kz4jBM/blue/9999.png", "arweave png"
        );
        assertEq(
            nft.arweaveOptimizedURI(9999, false),
            "ar://h9hcgqPaUnpUDbwyXkdoRE_mFuRUN_jFNBPd2Kz4jBM/green/9999.webp",
            "arweave webp"
        );
    }

    /// The metadata is what a marketplace reads, so the roots have to survive
    /// the trip through tokenJSON rather than only through the getters.
    function test_theMetadataCarriesThePinnedRoots() public {
        _buy(alice, 6334);
        string memory json = nft.tokenJSON(6334);

        assertEq(
            vm.parseJsonString(json, ".image"),
            "ipfs://bafybeide2rqgoymdal3bhump5imrmladdo73umdro4ezbswmvnuprvqdeu/blue/6334.png",
            "image"
        );
        assertEq(
            vm.parseJsonString(json, ".glamtoon.optimized"),
            "ipfs://bafybeide2rqgoymdal3bhump5imrmladdo73umdro4ezbswmvnuprvqdeu/blue/6334.webp",
            "optimized"
        );
        assertEq(
            vm.parseJsonString(json, ".glamtoon.arweave"),
            "ar://h9hcgqPaUnpUDbwyXkdoRE_mFuRUN_jFNBPd2Kz4jBM/blue/6334.png",
            "arweave"
        );
        assertEq(
            vm.parseJsonString(json, ".glamtoon.arweave_optimized"),
            "ar://h9hcgqPaUnpUDbwyXkdoRE_mFuRUN_jFNBPd2Kz4jBM/blue/6334.webp",
            "arweave optimized"
        );
    }

    /// The collection page reads its own image from the same root.
    function test_theCollectionImageUsesThePinnedRoot() public view {
        assertEq(
            vm.parseJsonString(nft.collectionJSON(), ".image"),
            "ipfs://bafybeide2rqgoymdal3bhump5imrmladdo73umdro4ezbswmvnuprvqdeu/blue/0.webp",
            "collection image"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                THE SHAPE
    //////////////////////////////////////////////////////////////*/

    /// A CIDv1 in base32 is 59 characters and starts with bafybei. The deploy
    /// script only checks a looser shape, 55 to 64 base32 characters starting
    /// baf, so the exact one is pinned here, where a broken root fails in a
    /// checkout rather than on the day.
    function test_theIpfsRootHasTheShapeOfACidV1() public view {
        bytes memory root = bytes(nft.ipfsRoot());
        assertEq(root.length, 59, "a base32 CIDv1 is 59 characters");

        bytes memory prefix = "bafybei";
        for (uint256 i = 0; i < prefix.length; ++i) {
            assertEq(root[i], prefix[i], "the root does not start with bafybei");
        }

        for (uint256 i = 0; i < root.length; ++i) {
            bytes1 c = root[i];
            bool lower = c >= 0x61 && c <= 0x7a;
            bool digit = c >= 0x32 && c <= 0x37;
            assertTrue(lower || digit, "base32 holds lowercase letters and the digits two to seven only");
        }
    }

    /// An Arweave transaction id is 43 characters of base64url, which is what a
    /// 32 byte hash encodes to without padding.
    function test_theArweaveIdHasTheShapeOfATransactionId() public view {
        bytes memory id = bytes(nft.arweaveManifest());
        assertEq(id.length, 43, "an Arweave id is 43 characters");

        for (uint256 i = 0; i < id.length; ++i) {
            bytes1 c = id[i];
            bool upper = c >= 0x41 && c <= 0x5a;
            bool lower = c >= 0x61 && c <= 0x7a;
            bool digit = c >= 0x30 && c <= 0x39;
            bool sign = c == 0x2d || c == 0x5f;
            assertTrue(upper || lower || digit || sign, "base64url holds letters, digits, minus and underscore only");
        }
    }

    /*//////////////////////////////////////////////////////////////
                             THE PAPER TRAIL
    //////////////////////////////////////////////////////////////*/

    /// PROVENANCE.md is how anyone rebuilds the art and puts it back at the same
    /// CID. If the contract and that document disagree, one of them is lying to
    /// whoever tries, and neither can be corrected once this is deployed.
    function test_theRootsAgreeWithProvenance() public view {
        string memory doc = vm.readFile(PROVENANCE);

        assertTrue(vm.contains(doc, nft.ipfsRoot()), "PROVENANCE.md does not name the deployed IPFS root");
        assertTrue(vm.contains(doc, nft.arweaveManifest()), "PROVENANCE.md does not name the deployed Arweave id");
    }

    /// The same document, read the other way: the identifiers it tells people to
    /// fetch must be the ones the contract serves, with no second candidate
    /// left over from an earlier pin. Every bafy CID, every ipfs:// and ar://
    /// path, every CID a pin check is aimed at and every arweave.net URL in it
    /// is counted, and each count has to be made up entirely of the deployed
    /// root or manifest.
    function test_provenanceNamesNoOtherRoot() public view {
        string memory doc = vm.readFile(PROVENANCE);
        string memory root = nft.ipfsRoot();
        string memory manifest = nft.arweaveManifest();

        assertFalse(vm.contains(doc, "bafybeiplaceholder"), "a placeholder root survives in PROVENANCE.md");
        assertFalse(vm.contains(doc, "PLACEHOLDER"), "a placeholder survives in PROVENANCE.md");

        assertGt(_count(doc, root), 0, "PROVENANCE.md never names the root");
        assertEq(_count(doc, "bafy"), _count(doc, root), "PROVENANCE.md names a CID that is not the root");
        assertEq(
            _count(doc, "ipfs://"), _count(doc, string.concat("ipfs://", root)), "an ipfs:// path uses another root"
        );
        assertEq(
            _count(doc, "--cid "), _count(doc, string.concat("--cid ", root)), "a pin check is aimed at another root"
        );

        assertGt(_count(doc, manifest), 0, "PROVENANCE.md never names the manifest");
        assertEq(
            _count(doc, "ar://"), _count(doc, string.concat("ar://", manifest)), "an ar:// path uses another manifest"
        );
        assertEq(
            _count(doc, "arweave.net/"),
            _count(doc, string.concat("arweave.net/", manifest)),
            "a gateway URL fetches another manifest"
        );

        // The table that says what the contract points at.
        assertTrue(
            vm.contains(doc, string.concat("| `IPFS_ROOT` | `", root, "` |")), "the table lists another IPFS root"
        );
        assertTrue(
            vm.contains(doc, string.concat("| `ARWEAVE` | `", manifest, "` |")), "the table lists another manifest"
        );
    }

    /// How many times `needle` appears in `hay`, without overlaps.
    function _count(string memory hay, string memory needle) internal pure returns (uint256) {
        return vm.split(hay, needle).length - 1;
    }
}
