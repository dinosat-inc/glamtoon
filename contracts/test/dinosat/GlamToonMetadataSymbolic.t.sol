// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Base64} from "openzeppelin/utils/Base64.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {GlamToon, IPFS_ROOT, ARWEAVE, TOKEN_BASE} from "../../src/GlamToon.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, the metadata and the art addresses
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonMetadataSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonMetadataSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev The metadata is built on chain and can never be corrected, so what
///      matters is that it always answers and always points at the right art.
///      Building a string from a symbolic number runs the library's digit and
///      base64 loops over symbolic data, which the symbolic engine cannot do.
///      So the refusals are proved for every input, the answers are proved at
///      the ids where the format changes, and every other id is fuzzed.
contract GlamToonMetadataSymbolicTest is DinoSatBase {
    string internal constant JSON_PREFIX = "data:application/json;base64,";

    // ════════════════════════════════════════════════
    //  NFT-5: the refusals
    // ════════════════════════════════════════════════

    /// @notice NFT-5: tokenURI refuses a token that was never minted, for
    ///         every id, as ERC-721 requires.
    /// @dev Technique: T3 guard. The refusal comes before any string is built.
    /// @dev Classification: DIRECT
    function test_check_tokenURI_refuses_an_unminted_token(uint256 tokenId) public view {
        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.tokenURI, (tokenId)));

        assert(!ok);
        assert(_is(answer, IERC721Errors.ERC721NonexistentToken.selector));
    }

    /// @notice NFT-5: the four art address functions refuse a character past
    ///         the collection with InvalidImageId, in either edition.
    /// @dev Technique: T3 guard. The refusal comes before any string is built.
    /// @dev Classification: DIRECT
    function test_check_art_addresses_refuse_an_unknown_character(uint256 imageId, bool blue) public view {
        // Justification: the branch under test, imageId >= IMAGE_COUNT (GlamToon.sol:752)
        vm.assume(imageId >= N);

        _refusesUnknown(abi.encodeCall(nft.imageURI, (imageId, blue)));
        _refusesUnknown(abi.encodeCall(nft.optimizedURI, (imageId, blue)));
        _refusesUnknown(abi.encodeCall(nft.arweaveURI, (imageId, blue)));
        _refusesUnknown(abi.encodeCall(nft.arweaveOptimizedURI, (imageId, blue)));
    }

    function _refusesUnknown(bytes memory data) private view {
        (bool ok, bytes memory answer) = address(nft).staticcall(data);
        assert(!ok);
        assert(_is(answer, GlamToon.InvalidImageId.selector));
    }

    // ════════════════════════════════════════════════
    //  NFT-5: what never changes
    // ════════════════════════════════════════════════

    /// @notice NFT-5: the art identifiers the contract reports are the ones in
    ///         its source, and the collection metadata is its JSON in base64.
    /// @dev Technique: T2 constant bound, over constants.
    /// @dev Classification: DIRECT
    function test_check_collection_metadata_is_fixed() public view {
        assert(_same(nft.ipfsRoot(), IPFS_ROOT));
        assert(_same(nft.arweaveManifest(), ARWEAVE));
        assert(_same(nft.tokenBase(), TOKEN_BASE));

        string memory json = nft.collectionJSON();
        assert(_same(nft.contractURI(), string.concat(JSON_PREFIX, Base64.encode(bytes(json)))));
        assert(_startsWith(json, '{"name":"Glamtoon"'));
        assert(_same(nft.imageURI(0, true), string.concat("ipfs://", IPFS_ROOT, "/blue/0.png")));
    }

    // ════════════════════════════════════════════════
    //  Composition: token ids {0, 9999, 10000, 19999, 90000, uint256.max}.
    //  The first and last blue, the first and last of generation one, the
    //  first id whose Generation trait reads "9+", and the largest id there
    //  is, with the longest generation number a word can spell.
    // ════════════════════════════════════════════════

    /// @notice NFT-5, token 0: the first blue has well formed metadata.
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_token_json_answers_0() public view {
        _jsonAnswers(0);
    }

    /// @notice NFT-5, token 9999: the last blue.
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_token_json_answers_9999() public view {
        _jsonAnswers(9999);
    }

    /// @notice NFT-5, token 10000: the first green of character 0.
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_token_json_answers_10000() public view {
        _jsonAnswers(10_000);
    }

    /// @notice NFT-5, token 19999: the first green of the last character.
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_token_json_answers_19999() public view {
        _jsonAnswers(19_999);
    }

    /// @notice NFT-5, token 90000: generation nine, where the Generation trait
    ///         starts to read "9+".
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_token_json_answers_90000() public view {
        _jsonAnswers(90_000);
    }

    /// @notice NFT-5, the largest token id: metadata still answers.
    /// @dev Technique: T9 concrete enumeration.
    /// @dev Classification: ENUMERATE
    function test_check_token_json_answers_max() public view {
        _jsonAnswers(type(uint256).max);
    }

    // ════════════════════════════════════════════════
    //  NFT-5: every id
    //  Strings built from a symbolic number. Intractable symbolically, so
    //  these three are fuzz verified.
    // ════════════════════════════════════════════════

    /// @notice NFT-5: tokenJSON answers for every token id there is, minted or
    ///         not, and what it answers opens and closes as one JSON object.
    /// @dev Technique: T2, over every id.
    /// @dev Classification: FUZZ
    function test_check_token_json_answers_for_every_id(uint256 tokenId) public view {
        _jsonAnswers(tokenId);
    }

    /// @notice Fuzz wrapper for test_check_token_json_answers_for_every_id
    /// @dev See T17 in test-templates.md
    function test_fuzz_token_json_answers_for_every_id(uint256 tokenId) public view {
        _jsonAnswers(tokenId);
    }

    /// @notice NFT-5: for a minted blue and its first green, tokenURI is the
    ///         token's JSON in base64 behind the data URI prefix.
    /// @dev Technique: T2, against an independent encoding of tokenJSON.
    /// @dev Classification: FUZZ
    function test_check_tokenURI_wraps_the_json(uint256 imageId) public {
        // Justification: mintBlue and mintGreen revert with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        _uriWrapsJson(imageId);
    }

    /// @notice Fuzz wrapper for test_check_tokenURI_wraps_the_json
    /// @dev See T17 in test-templates.md
    function test_fuzz_tokenURI_wraps_the_json(uint256 rawImage) public {
        _uriWrapsJson(bound(rawImage, 0, N - 1));
    }

    function _uriWrapsJson(uint256 imageId) private {
        (bool bought,) = _tryMintBlue(ALICE, imageId, STEP, STEP);
        (bool taken,) = _tryMintGreen(BOB, imageId);
        assert(bought && taken);

        assert(_same(nft.tokenURI(imageId), string.concat(JSON_PREFIX, Base64.encode(bytes(nft.tokenJSON(imageId))))));
        assert(
            _same(
                nft.tokenURI(N + imageId), string.concat(JSON_PREFIX, Base64.encode(bytes(nft.tokenJSON(N + imageId))))
            )
        );
    }

    /// @notice NFT-5: for every character and either edition, each of the four
    ///         art addresses is the scheme, the root, the edition's folder, the
    ///         character's number in decimal and the extension, nothing else.
    /// @dev Technique: T2, against a decimal rendering written here rather
    ///      than the library's.
    /// @dev Classification: FUZZ
    function test_check_art_addresses_have_the_right_shape(uint256 imageId, bool blue) public view {
        // Justification: the art functions revert with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:752)
        vm.assume(imageId < N);
        _artShape(imageId, blue);
    }

    /// @notice Fuzz wrapper for test_check_art_addresses_have_the_right_shape
    /// @dev See T17 in test-templates.md
    function test_fuzz_art_addresses_have_the_right_shape(uint256 rawImage, bool blue) public view {
        _artShape(bound(rawImage, 0, N - 1), blue);
    }

    function _artShape(uint256 imageId, bool blue) private view {
        string memory tail = string.concat(blue ? "/blue/" : "/green/", _decimal(imageId));

        assert(_same(nft.imageURI(imageId, blue), string.concat("ipfs://", IPFS_ROOT, tail, ".png")));
        assert(_same(nft.optimizedURI(imageId, blue), string.concat("ipfs://", IPFS_ROOT, tail, ".webp")));
        assert(_same(nft.arweaveURI(imageId, blue), string.concat("ar://", ARWEAVE, tail, ".png")));
        assert(_same(nft.arweaveOptimizedURI(imageId, blue), string.concat("ar://", ARWEAVE, tail, ".webp")));
    }

    // ════════════════════════════════════════════════
    //  Helpers
    // ════════════════════════════════════════════════

    /// tokenJSON answers, and what it answers is one JSON object that names
    /// the collection.
    function _jsonAnswers(uint256 tokenId) private view {
        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.tokenJSON, (tokenId)));
        assert(ok);

        string memory json = abi.decode(answer, (string));
        assert(_startsWith(json, '{"name":"Glamtoon #'));
        assert(bytes(json)[bytes(json).length - 1] == "}");
    }

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _startsWith(string memory text, string memory prefix) private pure returns (bool) {
        bytes memory t = bytes(text);
        bytes memory p = bytes(prefix);
        if (t.length < p.length) return false;
        for (uint256 i = 0; i < p.length; ++i) {
            if (t[i] != p[i]) return false;
        }
        return true;
    }

    /// A number in decimal, written out here so the proofs do not share the
    /// library's rendering.
    function _decimal(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 digits;
        for (uint256 rest = value; rest != 0; rest /= 10) {
            ++digits;
        }
        bytes memory out = new bytes(digits);
        for (uint256 rest = value; rest != 0; rest /= 10) {
            out[--digits] = bytes1(uint8(48 + rest % 10));
        }
        return string(out);
    }
}
