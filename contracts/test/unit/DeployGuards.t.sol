// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {IPFS_ROOT, ARWEAVE, TOKEN_BASE} from "../../src/GlamToon.sol";
import {TraitSchema} from "../../src/gen/TraitSchema.sol";

/// The deploy script refuses a mainnet broadcast while the art identifiers are
/// still placeholders. That guard is the last thing standing between a typo and
/// ten thousand tokens pointing at nothing, so it gets tested like production
/// code rather than trusted.
contract DeployGuardsTest is Test {
    Exposed internal guards = new Exposed();

    string internal constant CID = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";
    string internal constant AR = "Qh4vLzWCFbdmKk8sB7v2nQx3JYpR5tGeA1cUdN0iMzE";
    string internal constant BASE = "https://glamtoon.com/token/";
    uint256 internal constant ROWS = 10_000;

    /// Placeholders that have the right shape in every other respect, so the
    /// placeholder check is the only thing that can refuse them.
    string internal constant CID_PLACEHOLDER = "bafybeiplaceholderaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    string internal constant AR_PLACEHOLDER = "placeholder_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    string internal constant BASE_PLACEHOLDER = "https://placeholder.glamtoon.com/token/";

    /// Both art identifiers are pinned together or not at all. Replacing one and
    /// forgetting the other is the mistake this catches, and it reads the same
    /// before and after the art lands.
    function test_theArtIdentifiersMoveTogether() public view {
        assertEq(
            guards.hasPlaceholder(ARWEAVE), guards.hasPlaceholder(IPFS_ROOT), "ARWEAVE is not in step with IPFS_ROOT"
        );
    }

    function test_caseDoesNotMatter() public view {
        assertTrue(guards.hasPlaceholder("placeholder"), "lower");
        assertTrue(guards.hasPlaceholder("PLACEHOLDER"), "upper");
        assertTrue(guards.hasPlaceholder("PlAcEhOlDeR"), "mixed");
        assertTrue(guards.hasPlaceholder("bafyplaceholderxyz"), "embedded");
        assertFalse(guards.hasPlaceholder("bafybeirealcidthatsaysnothingofthesort"), "clean");
    }

    /// Every letter of the word has to match, including the first and the last,
    /// and the word still counts when it ends the string.
    function test_placeholderNeedsEveryLetter() public view {
        assertFalse(guards.hasPlaceholder("xlaceholder"), "first letter wrong");
        assertFalse(guards.hasPlaceholder("placeholdex"), "last letter wrong");
        assertFalse(guards.hasPlaceholder("placeholde"), "one short");
        assertTrue(guards.hasPlaceholder("abcplaceholder"), "at the very end");
    }

    /// Folding covers the whole capital range and leaves the characters either
    /// side of it alone. A needle with a z in it depends on the last capital.
    function test_lowerFoldsEveryCapitalAndNothingElse() public view {
        assertEq(guards.lower("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), bytes("abcdefghijklmnopqrstuvwxyz"), "capitals");
        assertEq(guards.lower("@[`{az09"), bytes("@[`{az09"), "neighbours of the capitals");
    }

    /// The host check finds a needle wherever it sits, including when it fills
    /// the haystack or ends on its last byte.
    function test_containsFindsANeedleAtTheVeryEnd() public view {
        assertTrue(guards.contains("abc", "abc"), "the whole haystack");
        assertTrue(guards.contains("xxabc", "abc"), "at the end");
        assertTrue(guards.contains("abcxx", "abc"), "at the start");
        assertFalse(guards.contains("ab", "abc"), "needle longer than haystack");
        assertFalse(guards.contains("xxabd", "abc"), "near miss");
    }

    function test_aRealLookingCidPasses() public view {
        assertTrue(guards.looksLikeCid(CID), "a genuine CIDv1 was rejected");
        assertTrue(guards.looksLikeCid(IPFS_ROOT), "the shipped root was rejected");
    }

    function test_theShapesThatGetPastedByMistake() public view {
        // an ipfs:// prefix left on
        assertFalse(guards.looksLikeCid("ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"), "prefix");
        // a CIDv0
        assertFalse(guards.looksLikeCid("QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG"), "v0");
        // a trailing newline
        assertFalse(guards.looksLikeCid("bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi\n"), "newline");
        // uppercase, which base32 CIDs never are
        assertFalse(guards.looksLikeCid("BAFYBEIGDYRZT5SFP7UDM7HU76UH7Y26NF3EFUYLQABF3OCLGTQY55FBZDI"), "upper");
        assertFalse(guards.looksLikeCid(""), "empty");
        // half a paste, a double paste and a bare prefix
        assertFalse(guards.looksLikeCid(_head(IPFS_ROOT, 29)), "half the root");
        assertFalse(guards.looksLikeCid(string.concat(IPFS_ROOT, IPFS_ROOT)), "the root twice");
        assertFalse(guards.looksLikeCid("baf"), "the prefix alone");
    }

    /// A CID is accepted from 55 to 64 characters and at neither length
    /// outside that.
    function test_cidLengthWindowIsExact() public view {
        assertTrue(guards.looksLikeCid(_cid(55)), "55 is the shortest accepted");
        assertFalse(guards.looksLikeCid(_cid(54)), "54 is too short");
        assertTrue(guards.looksLikeCid(_cid(64)), "64 is the longest accepted");
        assertFalse(guards.looksLikeCid(_cid(65)), "65 is too long");
        assertFalse(guards.looksLikeCid(_cid(200)), "far too long");
    }

    function test_cidPrefixIsCheckedByteByByte() public view {
        assertFalse(guards.looksLikeCid("xafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"), "first");
        assertFalse(guards.looksLikeCid("bxfybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"), "second");
        assertFalse(guards.looksLikeCid("baxybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"), "third");
    }

    /// Base32 is a to z and 2 to 7. The digits either side of that run and the
    /// characters either side of the letters are all refused.
    function test_cidAlphabetIsBase32() public view {
        string[4] memory good = ["2", "7", "a", "z"];
        for (uint256 i = 0; i < good.length; ++i) {
            assertTrue(guards.looksLikeCid(_withLast(CID, good[i])), good[i]);
        }
        string[6] memory bad = ["0", "1", "8", "9", "`", "{"];
        for (uint256 i = 0; i < bad.length; ++i) {
            assertFalse(guards.looksLikeCid(_withLast(CID, bad[i])), bad[i]);
        }
    }

    function test_arweaveIdShape() public view {
        assertTrue(guards.looksLikeArweaveId(AR), "a real id");
        assertTrue(guards.looksLikeArweaveId(ARWEAVE), "the shipped id");
        assertFalse(guards.looksLikeArweaveId("too-short"), "short");
        assertFalse(guards.looksLikeArweaveId("PLACEHOLDER-arweave-manifest-not-yet-uploaded"), "a placeholder");
        assertFalse(guards.looksLikeArweaveId("Qh4vLzWCFbdmKk8sB7v2nQx3JYpR5tGeA1cUdN0iMz!"), "bad character");
    }

    /// An id is exactly 43 characters of url safe base64. Roughly half of all
    /// real ids carry a dash and half carry a capital Z, so both ends of every
    /// range matter on the day.
    function test_anArweaveIdTakesEveryUrlSafeCharacterAndNothingElse() public view {
        string[8] memory good = ["A", "Z", "a", "z", "0", "9", "-", "_"];
        for (uint256 i = 0; i < good.length; ++i) {
            assertTrue(guards.looksLikeArweaveId(_withLast(AR, good[i])), good[i]);
        }
        string[8] memory bad = ["@", "[", "`", "{", "/", ":", ".", "+"];
        for (uint256 i = 0; i < bad.length; ++i) {
            assertFalse(guards.looksLikeArweaveId(_withLast(AR, bad[i])), bad[i]);
        }
    }

    function test_arweaveLengthIsExact() public view {
        assertFalse(guards.looksLikeArweaveId(string.concat(AR, "a")), "44");
        assertFalse(guards.looksLikeArweaveId(_withLast(AR, "")), "42");
    }

    /// The token base the build ships is accepted, and so is the shortest base
    /// the length check lets through.
    function test_theShippedTokenBaseIsAnHttpsBase() public view {
        assertTrue(guards.looksLikeHttpsBase(TOKEN_BASE), "the compiled TOKEN_BASE");
        assertTrue(guards.looksLikeHttpsBase(BASE), "the production base");
        assertTrue(guards.looksLikeHttpsBase("https://a.b/"), "twelve bytes is enough");
        assertFalse(guards.looksLikeHttpsBase("https://ab/"), "eleven is not");
    }

    /// A token id is appended straight to the base, so the scheme has to be
    /// https to the last byte and the base has to end in a slash.
    function test_aTokenBaseNeedsHttpsAndATrailingSlash() public view {
        assertFalse(guards.looksLikeHttpsBase("http://glamtoon.com/token/"), "http");
        assertFalse(guards.looksLikeHttpsBase("xttps://glamtoon.com/token/"), "first scheme byte");
        assertFalse(guards.looksLikeHttpsBase("https:/xglamtoon.com/token/"), "last scheme byte");
        assertFalse(guards.looksLikeHttpsBase("ipfs://bafy/x/"), "ipfs");
        assertFalse(guards.looksLikeHttpsBase("https://glamtoon.com/token"), "no trailing slash");
        assertFalse(guards.looksLikeHttpsBase("https://a/"), "too short");
        assertFalse(guards.looksLikeHttpsBase(""), "empty");
    }

    /// A development host left in the build is refused however it is written.
    function test_aLocalOrExampleHostIsRefusedInAnyCase() public view {
        assertFalse(guards.looksLikeHttpsBase("https://localhost/token/"), "localhost");
        assertFalse(guards.looksLikeHttpsBase("https://localhost:3000/"), "localhost with a port");
        assertFalse(guards.looksLikeHttpsBase("https://LOCALHOST:3000/token/"), "upper");
        assertFalse(guards.looksLikeHttpsBase("https://LocalHost/token/"), "mixed");
        assertFalse(guards.looksLikeHttpsBase("https://example.com/token/"), "example.com");
        assertFalse(guards.looksLikeHttpsBase("https://www.EXAMPLE.org/token/"), "example.org upper");
    }

    /// The example check is for the word followed by a dot, the way a host
    /// name has it. Where the word runs on into more letters, as examples in a
    /// path or counterexamples in a host, the base is left alone.
    function test_onlyAnExampleHostIsRefusedNotTheWord() public view {
        assertTrue(guards.looksLikeHttpsBase("https://glamtoon.com/examples/"), "the word in a path");
        assertTrue(guards.looksLikeHttpsBase("https://counterexamples.io/token/"), "the word inside a host");
        assertFalse(guards.looksLikeHttpsBase("https://example.net/token/"), "an example host");
    }

    /*//////////////////////////////////////////////////////////////
                              THE ART GUARDS
    //////////////////////////////////////////////////////////////*/

    /// What run() hands the art guards on every chain but anvil. The build that
    /// ships has to pass them, or a real chain could never be deployed to.
    function test_theShippedArtPassesEveryArtGuard() public view {
        guards.assertArt(IPFS_ROOT, ARWEAVE, TraitSchema.REAL_ROWS, TOKEN_BASE);
    }

    /// One bad value at a time, everything else good, and each guard names its
    /// own input. Deleting any one guard lets its case through or hands it to
    /// the wrong message.
    function test_eachArtGuardRefusesItsOwnBadValue() public {
        guards.assertArt(CID, AR, ROWS, BASE);
        assertTrue(guards.looksLikeCid(CID_PLACEHOLDER), "the CID placeholder is not shaped like a CID");
        assertTrue(guards.looksLikeArweaveId(AR_PLACEHOLDER), "the Arweave placeholder is not shaped like an id");
        assertTrue(guards.looksLikeHttpsBase(BASE_PLACEHOLDER), "the base placeholder is not shaped like a base");

        _refuses(CID_PLACEHOLDER, AR, ROWS, BASE, "IPFS_ROOT is still a placeholder");
        _refuses("QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG", AR, ROWS, BASE, "IPFS_ROOT is not a base32 CIDv1");
        _refuses(CID, AR_PLACEHOLDER, ROWS, BASE, "ARWEAVE is still a placeholder");
        _refuses(CID, _withLast(AR, ""), ROWS, BASE, "ARWEAVE is not a transaction id");
        _refuses(CID, AR, ROWS - 1, BASE, "trait table is still fixture filler");
        _refuses(CID, AR, 0, BASE, "trait table is still fixture filler");
        _refuses(CID, AR, ROWS, BASE_PLACEHOLDER, "TOKEN_BASE is still a placeholder");
        _refuses(CID, AR, ROWS, "http://glamtoon.com/token/", "TOKEN_BASE is not an https base path");
    }

    /// The row count has to be the character count exactly. A table with more
    /// real rows than there are characters was built for some other collection
    /// and is refused as surely as one with fewer.
    function test_theRowCountHasToMatchTheCharactersExactly() public {
        guards.assertArt(CID, AR, ROWS, BASE);
        _refuses(CID, AR, ROWS + 1, BASE, "trait table is still fixture filler");
        _refuses(CID, AR, type(uint256).max, BASE, "trait table is still fixture filler");
    }

    /// With everything wrong at once the guards speak in a fixed order, and
    /// fixing one value at a time hands the run to the next guard in line. The
    /// token base is both a placeholder and plain http, so the placeholder has
    /// to be named before the shape.
    function test_theArtGuardsNameTheFirstMistakeInOrder() public {
        string memory v0 = "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG";
        string memory short = _withLast(AR, "");
        string memory badBase = "http://placeholder.glamtoon.com/token/";
        assertTrue(guards.hasPlaceholder(badBase), "the bad base is not a placeholder");
        assertFalse(guards.looksLikeHttpsBase(badBase), "the bad base is shaped like a base");

        _refuses(CID_PLACEHOLDER, AR_PLACEHOLDER, 0, badBase, "IPFS_ROOT is still a placeholder");
        _refuses(v0, AR_PLACEHOLDER, 0, badBase, "ARWEAVE is still a placeholder");
        _refuses(v0, short, 0, badBase, "IPFS_ROOT is not a base32 CIDv1");
        _refuses(CID, short, 0, badBase, "ARWEAVE is not a transaction id");
        _refuses(CID, AR, 0, badBase, "trait table is still fixture filler");
        _refuses(CID, AR, ROWS, badBase, "TOKEN_BASE is still a placeholder");
        _refuses(CID, AR, ROWS, "http://glamtoon.com/token/", "TOKEN_BASE is not an https base path");
        guards.assertArt(CID, AR, ROWS, BASE);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _refuses(
        string memory ipfsRoot,
        string memory arweave,
        uint256 realRows,
        string memory tokenBase,
        string memory why
    ) internal {
        vm.expectRevert(bytes(why));
        guards.assertArt(ipfsRoot, arweave, realRows, tokenBase);
    }

    /// A base32 string of the given length that starts with baf.
    function _cid(uint256 len) internal pure returns (string memory) {
        bytes memory b = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            b[i] = "a";
        }
        b[0] = "b";
        b[2] = "f";
        return string(b);
    }

    /// The first `len` characters of a string.
    function _head(string memory s, uint256 len) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory head = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            head[i] = b[i];
        }
        return string(head);
    }

    /// The string with its last character replaced.
    function _withLast(string memory s, string memory last) internal pure returns (string memory) {
        return string.concat(_head(s, bytes(s).length - 1), last);
    }
}

contract Exposed is Deploy {
    function hasPlaceholder(string memory v) external pure returns (bool) {
        return _hasPlaceholder(v);
    }

    function lower(string memory v) external pure returns (bytes memory) {
        return _lower(v);
    }

    function contains(bytes memory haystack, bytes memory needle) external pure returns (bool) {
        return _contains(haystack, needle);
    }

    function looksLikeHttpsBase(string memory v) external pure returns (bool) {
        return _looksLikeHttpsBase(v);
    }

    function looksLikeCid(string memory v) external pure returns (bool) {
        return _looksLikeCid(v);
    }

    function looksLikeArweaveId(string memory v) external pure returns (bool) {
        return _looksLikeArweaveId(v);
    }

    function assertArt(string memory ipfsRoot, string memory arweave, uint256 realRows, string memory tokenBase)
        external
        pure
    {
        _assertArt(ipfsRoot, arweave, realRows, tokenBase);
    }
}

/// The script with inputs that refuse to be read, so a test can show a guard
/// fires before the script reads anything a human typed.
contract DeployReadingNothing is Deploy {
    function _inputs() internal view override returns (address, address, uint256) {
        // Always true when it runs. A bare revert would have the compiler flag
        // the rest of run() as unreachable.
        if (address(this).code.length > 0) revert("the inputs were read");
        return (address(0), address(0), 0);
    }
}
