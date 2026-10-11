// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Errors} from "openzeppelin/utils/Errors.sol";
import {BaseTest} from "../Base.t.sol";
import {GlamToon, ITraitData, ITraitNames} from "../../src/GlamToon.sol";
import {TraitSchema} from "../../src/gen/TraitSchema.sol";

/// What the constructor refuses. Every one of these is a mistake that would
/// otherwise be permanent, so it has to fail at deployment and not later.
contract DeploymentTest is BaseTest {
    /// The real wiring, with any one piece swappable.
    function _deploy(address c0, address c1, address n) public returns (GlamToon) {
        return new GlamToon(ITraitData(c0), ITraitData(c1), ITraitNames(n), address(treasury), SALE_START);
    }

    /// The real data with any payee, sent `seed` wei at construction.
    function _deployPaying(address payee, uint256 seed) public returns (GlamToon) {
        return new GlamToon{value: seed}(
            ITraitData(address(chunk0)), ITraitData(address(chunk1)), ITraitNames(address(names)), payee, SALE_START
        );
    }

    /// Ether left at the address the next deployment lands on, then the real
    /// deployment there with a one wei seed. The address is read in the frame
    /// that deploys, because an isolated run sends each outer call as a
    /// transaction of its own and spends a nonce before that frame starts.
    function _deployWithEtherWaiting(uint256 waiting) public returns (GlamToon g, address predicted) {
        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.deal(predicted, waiting);
        g = _deployPaying(address(treasury), 1 wei);
    }

    function _good() internal view returns (address, address, address) {
        return (address(chunk0), address(chunk1), address(names));
    }

    function test_identity() public view {
        assertEq(nft.name(), "Glamtoon", "collection name");
        assertEq(nft.symbol(), "GLAMTOON", "collection symbol");
        assertEq(nft.PAYOUT(), address(treasury), "payee wired");
        assertEq(nft.SALE_START(), SALE_START, "sale start");
        assertEq(nft.owner(), treasuryOwner, "marketplace owner label");
        assertEq(nft.BLUE_SUPPLY(), 10_000, "genesis supply");
        assertEq(nft.IMAGE_COUNT(), 10_000, "characters");
        assertEq(nft.ROYALTY_BPS(), 200, "two percent");
    }

    function test_dataContractsAreWired() public view {
        assertEq(address(nft.CHUNK0()), address(chunk0), "chunk 0");
        assertEq(address(nft.CHUNK1()), address(chunk1), "chunk 1");
        assertEq(address(nft.NAMES()), address(names), "name table");
    }

    /// The contract holds its own character count so the packing does not depend on
    /// generated code. The constructor checks the two still agree.
    function test_schemaAgreesWithPacking() public view {
        assertEq(nft.IMAGE_COUNT(), TraitSchema.IMAGE_COUNT, "image count drifted");
        assertEq(
            TraitSchema.IMAGES_PER_CHUNK * TraitSchema.CHUNK_COUNT,
            TraitSchema.IMAGE_COUNT,
            "chunks do not cover the collection"
        );
    }

    function test_royaltyPointsAtTreasury() public view {
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, address(treasury), "royalty receiver");
        assertEq(amount, 0.02 ether, "two percent of one ether");
    }

    function test_supportsInterfaces() public view {
        assertTrue(nft.supportsInterface(0x01ffc9a7), "ERC165");
        assertTrue(nft.supportsInterface(0x80ac58cd), "ERC721");
        assertTrue(nft.supportsInterface(0x5b5e139f), "ERC721Metadata");
        assertTrue(nft.supportsInterface(0x2a55205a), "ERC2981");
        assertFalse(nft.supportsInterface(0xdeadbeef), "nothing else");
    }

    function test_zeroPayoutReverts() public {
        vm.expectRevert(GlamToon.InvalidPayout.selector);
        new GlamToon(
            ITraitData(address(chunk0)),
            ITraitData(address(chunk1)),
            ITraitNames(address(names)),
            address(0),
            SALE_START
        );
    }

    function test_saleStartTooFarReverts() public {
        vm.expectRevert(GlamToon.SaleStartTooFar.selector);
        new GlamToon(
            ITraitData(address(chunk0)),
            ITraitData(address(chunk1)),
            ITraitNames(address(names)),
            address(treasury),
            uint64(block.timestamp + 91 days)
        );
    }

    function test_chunksOutOfOrderRevert() public {
        vm.expectRevert(GlamToon.BadTraitData.selector);
        this._deploy(address(chunk1), address(chunk0), address(names));
    }

    /// Every other negative test trips on the first pin, so the second had never
    /// been shown to reject anything. They are the only thing standing between
    /// the deployment and a wrong trait table, so each fires on its own here.
    function test_eachChunkPinRejectsIndependently() public {
        // the second half in both slots: pin 0 catches it
        vm.expectRevert(GlamToon.BadTraitData.selector);
        this._deploy(address(chunk1), address(chunk1), address(names));

        // the first half in both slots: pin 1 catches it
        vm.expectRevert(GlamToon.BadTraitData.selector);
        this._deploy(address(chunk0), address(chunk0), address(names));
    }

    /// An address with no code in the first chunk slot is asked for its hash
    /// first. Nothing is there to answer, so the deployment fails on the empty
    /// reply and not on a comparison. The exact revert data is not pinned,
    /// because forge rewrites it when tracing is on.
    function test_traitChunkThatIsAnAccountReverts() public {
        vm.expectCall(address(0xbeef), abi.encodeCall(ITraitData.dataHash, ()));
        try this._deploy(address(0xbeef), address(chunk1), address(names)) returns (GlamToon) {
            fail();
        } catch (bytes memory err) {
            assertNotEq(err, abi.encodeWithSelector(GlamToon.BadTraitData.selector), "failed on a comparison");
            assertNotEq(err, abi.encodeWithSelector(GlamToon.BadTraitNames.selector), "failed on a comparison");
        }
    }

    /// A trait chunk in the name slot gets past both chunk pins and is then
    /// asked for a namesHash it has no function for. The call itself fails,
    /// with no data, before there is any hash to compare.
    function test_nameTableThatIsTheWrongContractReverts() public {
        vm.expectCall(address(chunk0), abi.encodeCall(ITraitNames.namesHash, ()));
        try this._deploy(address(chunk0), address(chunk1), address(chunk0)) returns (GlamToon) {
            fail();
        } catch (bytes memory err) {
            assertEq(err.length, 0, "failed on a comparison, not on the missing function");
        }
    }

    function test_nameTableWithWrongDataReverts() public {
        WrongNames wrong = new WrongNames();
        vm.expectRevert(GlamToon.BadTraitNames.selector);
        this._deploy(address(chunk0), address(chunk1), address(wrong));
    }

    /// The hashes alone would accept a contract carrying the right bytes but
    /// answering for the wrong range of characters. Reading across every seam is
    /// what catches that, and this proves the probe is not dead code.
    function test_dataThatHashesRightButAnswersWrongReverts() public {
        LyingChunk lying = new LyingChunk();
        vm.expectRevert(LyingChunk.NotMyCharacters.selector);
        this._deploy(address(lying), address(chunk1), address(names));
    }

    /// The one wei proves the payee can take delivery, at deployment rather than
    /// at every withdraw forever.
    function test_constructorForwardsSeedToPayee() public {
        uint256 before = address(treasury).balance;
        new GlamToon{value: 1 wei}(
            ITraitData(address(chunk0)),
            ITraitData(address(chunk1)),
            ITraitNames(address(names)),
            address(treasury),
            SALE_START
        );
        assertEq(address(treasury).balance, before + 1, "seed reached the payee");
    }

    /// The seed goes out with a checked transfer. A payee that refuses ether
    /// fails the deployment with its own reason, and one with no way to take
    /// ether fails with the transfer error. Unseeded, the same payees deploy,
    /// which is why the script always sends the wei.
    function test_aSeededPayeeThatRefusesEtherFailsTheDeployment() public {
        address shut = address(new Shut());
        address doorless = address(new Doorless());

        vm.expectRevert(bytes("shut"));
        this._deployPaying(shut, 1 wei);

        vm.expectRevert(Errors.FailedCall.selector);
        this._deployPaying(doorless, 1 wei);

        assertEq(this._deployPaying(shut, 0).PAYOUT(), shut, "an unseeded deployment should not test the payee");
        assertEq(this._deployPaying(doorless, 0).PAYOUT(), doorless, "an unseeded deployment should not test the payee");
    }

    /// Anyone can send ether to the token's address before it exists, because
    /// that address is predictable. The constructor forwards the seed and
    /// nothing more, and what was already waiting stays for withdraw.
    function test_theConstructorForwardsOnlyTheSeed() public {
        uint256 before = address(treasury).balance;

        (GlamToon g, address predicted) = this._deployWithEtherWaiting(5 ether);

        assertEq(address(g), predicted, "the ether was not waiting where the token landed");
        assertEq(address(treasury).balance, before + 1, "more than the seed was forwarded");
        assertEq(address(g).balance, 5 ether, "the waiting ether did not stay put");

        g.withdraw();
        assertEq(address(treasury).balance, before + 1 + 5 ether, "withdraw did not collect the rest");
    }
}

/// Reports the hash the build expects, then refuses to answer for the characters
/// it claims to hold. Only a read catches this.
contract LyingChunk {
    error NotMyCharacters();

    function dataHash() external pure returns (bytes32) {
        return TraitSchema.DATA_HASH_0;
    }

    function record(uint256) external pure returns (uint40) {
        revert NotMyCharacters();
    }

    function data() external pure returns (bytes memory) {
        return "";
    }
}

/// Answers the right shape and the wrong bytes: the case a length check would
/// wave through and a hash will not.
contract WrongNames {
    function namesHash() external pure returns (bytes32) {
        return keccak256("not the name table");
    }

    function data() external pure returns (bytes memory) {
        return "";
    }

    function namesAt(uint256[] calldata) external pure returns (string[] memory) {
        return new string[](0);
    }
}

/// Refuses ether with a reason of its own.
contract Shut {
    receive() external payable {
        revert("shut");
    }
}

/// No receive and no fallback, so any ether sent to it bounces with no data.
contract Doorless {}
