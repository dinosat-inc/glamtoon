// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {GlamToon, ITraitData, ITraitNames} from "../../src/GlamToon.sol";
import {TraitData0} from "../../src/gen/TraitData0.sol";
import {TraitData1} from "../../src/gen/TraitData1.sol";
import {TraitNames} from "../../src/gen/TraitNames.sol";

/// Run: FOUNDRY_PROFILE=halmos halmos --contract PackingSymbolicTest \
///        --function check_ --forge-build-out out-halmos --solver-timeout-assertion 240000
///
/// Symbolic only. These carry the check_ prefix rather than test_, so forge does
/// not pick them up; the same properties are fuzzed in test/unit.
///
/// The packing, for every input rather than for the ones a fuzzer happened to
/// pick. Two characters sharing a token id, or a token naming the wrong artwork,
/// are the failures that could not be repaired after deployment.
contract PackingSymbolicTest is Test {
    uint256 constant N = 10_000;

    GlamToon internal nft;
    address internal payee = address(0xBEEF);
    uint64 internal constant START = 1000;

    function setUp() public {
        vm.warp(START);
        nft = new GlamToon(
            ITraitData(address(new TraitData0())),
            ITraitData(address(new TraitData1())),
            ITraitNames(address(new TraitNames())),
            payee,
            START
        );
    }

    /// PK-1: encode and decode are inverses across the whole valid domain.
    /// Generation is bounded to 2**16 so the division stays within what the solver
    /// discharges directly; the unbounded case is covered by fuzzing.
    function check_round_trip(uint256 imageId, uint256 generation) public view {
        vm.assume(imageId < N);
        vm.assume(generation < 2 ** 16);

        uint256 tokenId = nft.tokenIdFor(imageId, generation);
        (uint256 gotImage, uint256 gotGeneration) = nft.decode(tokenId);

        assert(gotImage == imageId);
        assert(gotGeneration == generation);
    }

    /// PK-2: a token is a blue genesis exactly when its generation is zero. This
    /// is what lets the collection treat ids 0 to 9999 as the genesis edition.
    function check_genesis_iff_generation_zero(uint256 imageId, uint256 generation) public view {
        vm.assume(imageId < N);
        vm.assume(generation < 2 ** 16);

        uint256 tokenId = nft.tokenIdFor(imageId, generation);
        assert((tokenId < N) == (generation == 0));
        assert(nft.isBlue(tokenId) == (generation == 0));
    }

    /// PK-3: decoding any token id at all lands inside the collection. There is no
    /// value of a uint256 that names a character outside 0 to 9999.
    function check_decode_always_in_range(uint256 tokenId) public view {
        (uint256 imageId,) = nft.decode(tokenId);
        assert(imageId < N);
    }

    /// PK-4: distinct inputs never collide. Stated as its contrapositive, which is
    /// the form the solver works with directly.
    function check_no_collision(uint256 imageA, uint256 genA, uint256 imageB, uint256 genB) public view {
        vm.assume(imageA < N);
        vm.assume(imageB < N);
        vm.assume(genA < 2 ** 16);
        vm.assume(genB < 2 ** 16);

        if (nft.tokenIdFor(imageA, genA) == nft.tokenIdFor(imageB, genB)) {
            assert(imageA == imageB);
            assert(genA == genB);
        }
    }

    /// PK-5: every multiple of ten thousand is character zero of its generation.
    /// Zero based has no awkward boundary here, and this pins that.
    function check_multiples_of_ten_thousand(uint256 generation) public view {
        vm.assume(generation < 2 ** 16);
        (uint256 imageId, uint256 gotGeneration) = nft.decode(generation * N);
        assert(imageId == 0);
        assert(gotGeneration == generation);
    }
}
