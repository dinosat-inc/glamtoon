// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon, ITraitData, ITraitNames} from "../../src/GlamToon.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";

/// The claim is that the token contract cannot be administered by anyone. These
/// are the tests that make it a claim about the code rather than about intent.
contract OwnerlessTest is BaseTest {
    /// owner() exists so a marketplace will let the collection page be edited. It
    /// must not be wired to anything.
    function test_theOwnerLabelGrantsNothing() public {
        _buy(alice, 1);
        // Read it first. Evaluating it inside the call would be the call
        // expectRevert is watching.
        address label = nft.owner();

        vm.startPrank(label);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, label, uint256(1)));
        nft.transferFrom(alice, label, 1);
        vm.stopPrank();

        assertEq(nft.ownerOf(1), alice, "the label moved nothing");
        assertEq(nft.PAYOUT(), address(treasury), "the label redirects nothing");
    }

    /// The label is the treasury's owner, so handing the treasury on hands the
    /// collection page on with it. This is the only way it ever moves.
    function test_theLabelFollowsTheTreasury() public {
        assertEq(nft.owner(), treasuryOwner, "starts with the treasury owner");

        vm.prank(treasuryOwner);
        treasury.transferOwnership(bob);
        assertEq(nft.owner(), treasuryOwner, "a pending handover moves nothing");

        vm.prank(bob);
        treasury.acceptOwnership();
        assertEq(nft.owner(), bob, "the label followed");
    }

    /// Every marketplace reads owner(), so a payee that answers badly has to
    /// leave the label empty rather than revert. A try/catch would let three of
    /// these five through: it covers the payee with no owner function, which
    /// reverts, and the one that never answers, which runs out of gas, and not
    /// an account with no code or an answer that will not decode.
    function test_aPayeeWithNoOwnerLeavesTheLabelEmpty() public {
        assertEq(_withPayee(address(0xBEEF)).owner(), address(0), "an account with no code");
        assertEq(_withPayee(address(new NoOwner())).owner(), address(0), "a contract with no owner");
        assertEq(_withPayee(address(new SilentOwner())).owner(), address(0), "answers with no data");
        assertEq(_withPayee(address(new JunkOwner())).owner(), address(0), "answers with a dirty word");
        assertEq(_withPayee(address(new GreedyOwner())).owner(), address(0), "never answers");
    }

    function _withPayee(address payee) internal returns (GlamToon) {
        return new GlamToon(
            ITraitData(address(chunk0)), ITraitData(address(chunk1)), ITraitNames(address(names)), payee, SALE_START
        );
    }

    /// Selectors for the setters a collection like this usually has. None of
    /// them may exist. Each call carries arguments its signature can decode and
    /// is made by the label holder, the one caller a gated setter would let
    /// through, and each has to fail with no data at all, which is how a
    /// selector the contract does not have fails. A setter that exists and says
    /// no answers with an error instead. The allowlist further down is what
    /// rules out one under any other name.
    function test_thereIsNoFunctionThatChangesThePayee() public {
        address label = nft.owner();
        assertEq(label, treasuryOwner, "the probes are made by the label holder");

        string[8] memory absent = [
            "setPayout(address)",
            "setBaseURI(string)",
            "setTokenURI(uint256,string)",
            "setDefaultRoyalty(address,uint96)",
            "setMeta(address)",
            "pause()",
            "transferOwnership(address)",
            "upgradeTo(address)"
        ];

        bytes[8] memory calls = [
            abi.encodeWithSignature(absent[0], address(this)),
            abi.encodeWithSignature(absent[1], "ipfs://elsewhere/"),
            abi.encodeWithSignature(absent[2], uint256(1), "ipfs://elsewhere/1.json"),
            abi.encodeWithSignature(absent[3], address(this), uint96(10_000)),
            abi.encodeWithSignature(absent[4], address(this)),
            abi.encodeWithSignature(absent[5]),
            abi.encodeWithSignature(absent[6], address(this)),
            abi.encodeWithSignature(absent[7], address(this))
        ];

        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(label);
            (bool ok, bytes memory answer) = address(nft).call(calls[i]);
            assertFalse(ok, string.concat("this contract answers ", absent[i]));
            assertEq(answer.length, 0, string.concat("this contract knows ", absent[i]));
        }
        assertEq(nft.PAYOUT(), address(treasury), "the payee never moved");
    }

    /// The royalty receiver lives in storage because that is where OpenZeppelin
    /// keeps it. Nothing reachable writes it, which is what makes it fixed.
    function test_theRoyaltyCannotBeMovedByAnybody() public {
        (address before,) = nft.royaltyInfo(1, 1 ether);

        _buy(alice, 1);
        _green(bob, 1);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        nft.withdraw();
        vm.prank(treasuryOwner);
        treasury.setBeneficiary(carol);

        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, before, "receiver moved");
        assertEq(receiver, address(treasury), "still the treasury");
        assertEq(amount, 0.02 ether, "still two percent");
    }

    /// The three data contracts are pinned at construction, and every read goes
    /// through those pins rather than through anything that could be pointed
    /// elsewhere. The allowlist below is what shows no function exists to do
    /// the pointing.
    function test_theTraitDataCannotBeSwapped() public view {
        assertEq(address(nft.CHUNK0()), address(chunk0), "pinned at construction");
        assertEq(address(nft.CHUNK1()), address(chunk1), "pinned at construction");
        assertEq(address(nft.NAMES()), address(names), "pinned at construction");

        assertEq(nft.traitChunk(0), chunk0.data(), "the first chunk is read from its pin");
        assertEq(nft.traitChunk(1), chunk1.data(), "the second chunk is read from its pin");
        assertEq(nft.allTraits(), bytes.concat(chunk0.data(), chunk1.data()), "the whole table is read from both");
        assertEq(nft.traitNames(), names.data(), "the names are read from their pin");
        assertEq(nft.recordOf(4999), chunk0.record(4999), "the last record of the first chunk");
        assertEq(nft.recordOf(5000), chunk1.record(5000), "the first record of the second chunk");
    }

    /// No burn exists anywhere, which is what makes token existence a permanent
    /// answer to whether a character's genesis has been sold. The holder asks
    /// under the usual name and is refused, and sending the token to zero is
    /// refused by name. The allowlist below is what shows the compiler never
    /// built a burn, under that name or any other.
    function test_thereIsNoBurn() public {
        _buy(alice, 1);
        vm.prank(alice);
        (bool ok,) = address(nft).call(abi.encodeWithSignature("burn(uint256)", uint256(1)));
        assertFalse(ok, "burn exists");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        nft.transferFrom(alice, address(0), 1);

        assertEq(nft.ownerOf(1), alice, "still owned");
        assertTrue(nft.blueTaken(1), "still counted as sold");
    }

    /*//////////////////////////////////////////////////////////////
                           THE COMPILED SURFACE
    //////////////////////////////////////////////////////////////*/

    /// Every function GlamToon has, spelled the way the compiler spells it.
    string[] internal glamToonFunctions = [
        "BLUE_SUPPLY()",
        "CHUNK0()",
        "CHUNK1()",
        "GENERATION_SHOWN()",
        "IMAGE_COUNT()",
        "NAMES()",
        "PAYOUT()",
        "PRICE_STEP()",
        "ROYALTY_BPS()",
        "SALE_START()",
        "TIER_SIZE()",
        "allTraits()",
        "approve(address,uint256)",
        "arweaveManifest()",
        "arweaveOptimizedURI(uint256,bool)",
        "arweaveURI(uint256,bool)",
        "balanceOf(address)",
        "blueBitmapWords()",
        "blueMinted()",
        "blueTaken(uint256)",
        "blueTakenBits(uint256,uint256)",
        "categoryNames()",
        "collectionJSON()",
        "contractURI()",
        "currentPrice()",
        "decode(uint256)",
        "generationOf(uint256)",
        "getApproved(uint256)",
        "greenCount(uint256)",
        "greenCountBatch(uint256[])",
        "greenMinted()",
        "greenTaken(uint256,address)",
        "greenTakenBatch(uint256[],address)",
        "imageIdOf(uint256)",
        "imageURI(uint256,bool)",
        "ipfsRoot()",
        "isApprovedForAll(address,address)",
        "isBlue(uint256)",
        "mintBlue(uint256,uint256)",
        "mintBlueFor(address,uint256,uint256)",
        "mintGreen(uint256)",
        "name()",
        "optimizedURI(uint256,bool)",
        "owner()",
        "ownerOf(uint256)",
        "priceAt(uint256)",
        "recordOf(uint256)",
        "royaltyInfo(uint256,uint256)",
        "safeTransferFrom(address,address,uint256)",
        "safeTransferFrom(address,address,uint256,bytes)",
        "setApprovalForAll(address,bool)",
        "supportsInterface(bytes4)",
        "symbol()",
        "tokenBase()",
        "tokenIdFor(uint256,uint256)",
        "tokenJSON(uint256)",
        "tokenURI(uint256)",
        "totalSupply()",
        "traitChunk(uint256)",
        "traitNames()",
        "traitsBatch(uint256[])",
        "traitsOf(uint256)",
        "transferFrom(address,address,uint256)",
        "valueNames(uint256)",
        "withdraw()"
    ];

    /// The ones among them that can change state and take no ether.
    string[] internal glamToonWrites = [
        "approve(address,uint256)",
        "setApprovalForAll(address,bool)",
        "transferFrom(address,address,uint256)",
        "safeTransferFrom(address,address,uint256)",
        "safeTransferFrom(address,address,uint256,bytes)",
        "mintGreen(uint256)",
        "withdraw()"
    ];

    /// The ones that take ether.
    string[] internal glamToonPaid = ["mintBlue(uint256,uint256)", "mintBlueFor(address,uint256,uint256)"];

    /// Every function the treasury has.
    string[] internal treasuryFunctions = [
        "acceptOwnership()",
        "beneficiary()",
        "owner()",
        "pendingOwner()",
        "renounceOwnership()",
        "setBeneficiary(address)",
        "sweep()",
        "sweepToken(address)",
        "transferOwnership(address)"
    ];

    /// The ones among them that can change state.
    string[] internal treasuryWrites = [
        "setBeneficiary(address)", "sweep()", "sweepToken(address)", "transferOwnership(address)", "acceptOwnership()"
    ];

    /// Every function each trait chunk has.
    string[] internal chunkFunctions =
        ["FIRST_IMAGE_ID()", "IMAGE_COUNT()", "STRIDE()", "data()", "dataHash()", "record(uint256)"];

    /// Every function the name table has.
    string[] internal nameTableFunctions = ["SLOT()", "SLOT_COUNT()", "data()", "namesAt(uint256[])", "namesHash()"];

    /// The list for a contract that has none of a kind.
    string[] internal none;

    /// Everything above asks after names somebody thought of. This reads what the
    /// compiler actually emitted and holds it to the written list, so a function
    /// under any name at all, gated or not, fails here until it has been looked
    /// at and added. Of the sixty five, nine can change state, only the two blue
    /// doors take ether, and there is no receive or fallback.
    function test_theCompiledAbiIsExactlyTheDesignedSurface() public {
        // Coverage writes no build output, so the ABI read here could be
        // missing or stale.
        _skipUnderCoverage();
        string memory json = _artifact("GlamToon");
        _assertSelectorsAre(json, glamToonFunctions, "GlamToon");
        _assertWritersAre(json, glamToonWrites, glamToonPaid, false, "GlamToon");
    }

    /// The treasury is the one contract with an owner, and its surface is small
    /// enough to state whole: the beneficiary setter, the two sweeps, the two
    /// halves of a handover and a receive. Renouncing is declared pure, since it
    /// only ever refuses.
    function test_theTreasuryAbiIsExactlyItsDesignedSurface() public {
        // Coverage writes no build output, so the ABI read here could be
        // missing or stale.
        _skipUnderCoverage();
        string memory json = _artifact("Treasury");
        _assertSelectorsAre(json, treasuryFunctions, "Treasury");
        _assertWritersAre(json, treasuryWrites, none, true, "Treasury");
        assertEq(_mutabilityOf(json, "renounceOwnership"), "pure", "renouncing can only ever refuse");
    }

    /// The data contracts answer questions and nothing else. Not one function on
    /// any of the three can change state or take ether.
    function test_theTraitContractsExposeNothingThatWrites() public {
        // Coverage writes no build output, so the ABI read here could be
        // missing or stale.
        _skipUnderCoverage();
        string memory json = _artifact("TraitData0");
        _assertSelectorsAre(json, chunkFunctions, "TraitData0");
        _assertWritersAre(json, none, none, false, "TraitData0");

        json = _artifact("TraitData1");
        _assertSelectorsAre(json, chunkFunctions, "TraitData1");
        _assertWritersAre(json, none, none, false, "TraitData1");

        json = _artifact("TraitNames");
        _assertSelectorsAre(json, nameTableFunctions, "TraitNames");
        _assertWritersAre(json, none, none, false, "TraitNames");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// The build artifact forge writes for a contract in src.
    function _artifact(string memory name) internal view returns (string memory) {
        return vm.readFile(string.concat("out/", name, ".sol/", name, ".json"));
    }

    /// The compiler's selector table has to hold exactly the listed signatures,
    /// nothing more and nothing less.
    function _assertSelectorsAre(string memory json, string[] memory listed, string memory what) internal pure {
        string[] memory compiled = vm.parseJsonKeys(json, ".methodIdentifiers");
        for (uint256 i = 0; i < compiled.length; ++i) {
            assertTrue(_has(listed, compiled[i]), string.concat(what, " exposes an unlisted function: ", compiled[i]));
        }
        for (uint256 i = 0; i < listed.length; ++i) {
            assertTrue(_has(compiled, listed[i]), string.concat(what, " no longer has ", listed[i]));
        }
        assertEq(compiled.length, listed.length, string.concat(what, " has a different number of functions"));
    }

    /// Walks the ABI and holds every entry that can change state to the lists:
    /// nonpayable functions to `writes`, payable ones to `paid`, and a receive
    /// only where one is expected. A fallback is never expected.
    function _assertWritersAre(
        string memory json,
        string[] memory writes,
        string[] memory paid,
        bool receives,
        string memory what
    ) internal view {
        uint256 wrote;
        uint256 took;
        uint256 received;
        for (uint256 i = 0; vm.keyExistsJson(json, _entry(i, "")); ++i) {
            bytes32 kind = keccak256(bytes(vm.parseJsonString(json, _entry(i, ".type"))));
            assertTrue(kind != keccak256("fallback"), string.concat(what, " has a fallback"));
            if (kind == keccak256("receive")) {
                ++received;
                continue;
            }
            if (kind != keccak256("function")) continue;

            bytes32 mutability = keccak256(bytes(vm.parseJsonString(json, _entry(i, ".stateMutability"))));
            if (mutability == keccak256("nonpayable")) {
                string memory sig = _signature(json, i);
                assertTrue(_has(writes, sig), string.concat(what, " has an unlisted function that writes: ", sig));
                ++wrote;
            } else if (mutability == keccak256("payable")) {
                string memory sig = _signature(json, i);
                assertTrue(_has(paid, sig), string.concat(what, " has an unlisted function that takes ether: ", sig));
                ++took;
            }
        }
        assertEq(wrote, writes.length, string.concat(what, " writes through fewer functions than listed"));
        assertEq(took, paid.length, string.concat(what, " takes ether through fewer functions than listed"));
        assertEq(received, receives ? 1 : 0, string.concat(what, " has the wrong receive"));
    }

    /// The declared mutability of the function with this name.
    function _mutabilityOf(string memory json, string memory name) internal view returns (string memory) {
        for (uint256 i = 0; vm.keyExistsJson(json, _entry(i, "")); ++i) {
            if (!vm.keyExistsJson(json, _entry(i, ".name"))) continue;
            if (keccak256(bytes(vm.parseJsonString(json, _entry(i, ".name")))) == keccak256(bytes(name))) {
                return vm.parseJsonString(json, _entry(i, ".stateMutability"));
            }
        }
        return "";
    }

    /// The signature of ABI entry i, spelled the way solc spells it when it
    /// hashes a selector.
    function _signature(string memory json, uint256 i) internal view returns (string memory sig) {
        sig = string.concat(vm.parseJsonString(json, _entry(i, ".name")), "(");
        for (uint256 j = 0; vm.keyExistsJson(json, _entry(i, string.concat(".inputs[", vm.toString(j), "]"))); ++j) {
            if (j > 0) sig = string.concat(sig, ",");
            sig = string.concat(
                sig, vm.parseJsonString(json, _entry(i, string.concat(".inputs[", vm.toString(j), "].type")))
            );
        }
        sig = string.concat(sig, ")");
    }

    function _entry(uint256 i, string memory field) internal pure returns (string memory) {
        return string.concat(".abi[", vm.toString(i), "]", field);
    }

    function _has(string[] memory list, string memory item) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (keccak256(bytes(list[i])) == keccak256(bytes(item))) return true;
        }
        return false;
    }
}

/// A payee with code and nothing to ask about ownership.
contract NoOwner {
    receive() external payable {}
}

/// The right selector, answering with no data at all.
contract SilentOwner {
    function owner() external {}
}

/// The right selector, answering with a word that is not a clean address.
contract JunkOwner {
    function owner() external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// The right selector, never answering.
contract GreedyOwner {
    function owner() external pure returns (address) {
        while (true) {}
        return address(0);
    }
}
