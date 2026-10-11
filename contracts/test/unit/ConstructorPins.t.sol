// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon, ITraitData, ITraitNames} from "../../src/GlamToon.sol";
import {TraitSchema} from "../../src/gen/TraitSchema.sol";
import {TraitData0} from "../../src/gen/TraitData0.sol";
import {TraitData1} from "../../src/gen/TraitData1.sol";

/// Every check in the GlamToon constructor, one at a time, each in the one
/// arrangement where it is the only thing standing between the deployment and a
/// permanently broken contract. Other suites prove these checks fire; this one
/// proves none of them can be deleted, because the case that reaches each check
/// sails through all the others.
///
/// The four seam reads map onto tests like this:
///   _record(0)                -> test_theFirstCharacterOfChunkZeroIsRead
///   _record(per - 1)          -> test_theLastCharacterOfChunkZeroIsRead
///   _record(per)              -> test_theFirstCharacterOfChunkOneIsRead
///   _record(IMAGE_COUNT - 1)  -> test_theLastCharacterOfChunkOneIsRead
/// Each of those deploys a chunk with exactly one hole in it, so deleting any
/// one read lets exactly one of those tests through a deployment it should not.
contract ConstructorPinsTest is BaseTest {
    uint256 internal constant PER = TraitSchema.IMAGES_PER_CHUNK;
    uint256 internal constant LAST = TraitSchema.IMAGE_COUNT - 1;
    uint256 internal constant NO_HOLE = type(uint256).max;

    bytes32 internal constant NOT_A_REAL_HASH = keccak256("a build that never shipped");

    /*//////////////////////////////////////////////////////////////
                            THE FOUR SEAM READS
    //////////////////////////////////////////////////////////////*/

    /// The control for everything below. A stand in chunk that reports the right
    /// hash and answers for every character is accepted, so when one of the
    /// tests after this reverts it is the hole that did it and not the mock.
    function test_aStandInChunkThatAnswersEverywhereIsAccepted() public {
        HoleChunk c0 = new HoleChunk(TraitSchema.DATA_HASH_0, NO_HOLE);
        HoleChunk c1 = new HoleChunk(TraitSchema.DATA_HASH_1, NO_HOLE);

        GlamToon g = this.deployWith(address(c0), address(c1), address(names), address(treasury), SALE_START);

        assertEq(address(g.CHUNK0()), address(c0), "the stand in was not pinned");
        assertEq(address(g.CHUNK1()), address(c1), "the stand in was not pinned");
    }

    /// A chunk carrying the right bytes for the wrong range starts one character
    /// late. Nothing but _record(0) looks there.
    function test_theFirstCharacterOfChunkZeroIsRead() public {
        HoleChunk c0 = new HoleChunk(TraitSchema.DATA_HASH_0, 0);
        _assertAnswersFor(c0, PER - 1);

        vm.expectRevert(abi.encodeWithSelector(HoleChunk.NotThisCharacter.selector, uint256(0)));
        this.deployWith(address(c0), address(chunk1), address(names), address(treasury), SALE_START);
    }

    /// And one that stops a character early. The hash says nothing about where a
    /// chunk thinks its own records end, so only _record(per - 1) catches a half
    /// that is short at the top.
    function test_theLastCharacterOfChunkZeroIsRead() public {
        HoleChunk c0 = new HoleChunk(TraitSchema.DATA_HASH_0, PER - 1);
        _assertAnswersFor(c0, 0);

        vm.expectRevert(abi.encodeWithSelector(HoleChunk.NotThisCharacter.selector, PER - 1));
        this.deployWith(address(c0), address(chunk1), address(names), address(treasury), SALE_START);
    }

    /// The two reads on chunk zero are satisfied by the real chunk zero here, so
    /// this deployment gets all the way across the seam before anything notices.
    /// Only _record(per) is looking.
    function test_theFirstCharacterOfChunkOneIsRead() public {
        HoleChunk c1 = new HoleChunk(TraitSchema.DATA_HASH_1, PER);
        _assertAnswersFor(c1, LAST);

        vm.expectRevert(abi.encodeWithSelector(HoleChunk.NotThisCharacter.selector, PER));
        this.deployWith(address(chunk0), address(c1), address(names), address(treasury), SALE_START);
    }

    /// The far end of the collection. This chunk answers for 5000 and is wrong
    /// only about 9999, which is the last read and the easiest one to drop.
    function test_theLastCharacterOfChunkOneIsRead() public {
        HoleChunk c1 = new HoleChunk(TraitSchema.DATA_HASH_1, LAST);
        _assertAnswersFor(c1, PER);

        vm.expectRevert(abi.encodeWithSelector(HoleChunk.NotThisCharacter.selector, LAST));
        this.deployWith(address(chunk0), address(c1), address(names), address(treasury), SALE_START);
    }

    /// The mistake the seam reads exist for, in the shape a human makes it: the
    /// second half's records built into a contract that reports the first half's
    /// hash. The bytes are the right bytes and the hash is the right hash. The
    /// mapping from character to record is the thing nobody hashed.
    function test_aChunkHoldingTheWrongHalfOfTheCollectionIsRead() public {
        RangeChunk c0 = new RangeChunk(TraitSchema.DATA_HASH_0, PER, LAST);

        vm.expectRevert(abi.encodeWithSelector(RangeChunk.OutsideMyRange.selector, uint256(0)));
        this.deployWith(address(c0), address(chunk1), address(names), address(treasury), SALE_START);
    }

    /// The same in the other slot, short at the top rather than shifted: it
    /// answers for 5000 and not for 9999.
    function test_aChunkThatRunsOutBeforeTheEndIsRead() public {
        RangeChunk c1 = new RangeChunk(TraitSchema.DATA_HASH_1, PER, LAST - 1);

        vm.expectRevert(abi.encodeWithSelector(RangeChunk.OutsideMyRange.selector, LAST));
        this.deployWith(address(chunk0), address(c1), address(names), address(treasury), SALE_START);
    }

    /*//////////////////////////////////////////////////////////////
                               THE HASH PINS
    //////////////////////////////////////////////////////////////*/

    /// A chunk that answers for every character in the collection and carries
    /// the wrong records. Every seam read passes. The hash is the only check
    /// left, and without it this deployment ships a contract whose traits are a
    /// fabrication that never reverts.
    function test_onlyTheChunkZeroHashRefusesATableThatAnswersEverywhere() public {
        HoleChunk c0 = new HoleChunk(NOT_A_REAL_HASH, NO_HOLE);

        vm.expectRevert(GlamToon.BadTraitData.selector);
        this.deployWith(address(c0), address(chunk1), address(names), address(treasury), SALE_START);
    }

    /// The same for the second half. Worth its own case because a deployment
    /// wrong in only the second half passes every check that runs before it.
    function test_onlyTheChunkOneHashRefusesATableThatAnswersEverywhere() public {
        HoleChunk c1 = new HoleChunk(NOT_A_REAL_HASH, NO_HOLE);

        vm.expectRevert(GlamToon.BadTraitData.selector);
        this.deployWith(address(chunk0), address(c1), address(names), address(treasury), SALE_START);
    }

    /// Each half is hashed against its own constant. Both of these chunks answer
    /// for the whole collection, so the seam reads cannot help and the pin has
    /// to be comparing the right constant against the right slot.
    function test_eachChunkIsHashedAgainstItsOwnConstant() public {
        HoleChunk crossed0 = new HoleChunk(TraitSchema.DATA_HASH_1, NO_HOLE);
        vm.expectRevert(GlamToon.BadTraitData.selector);
        this.deployWith(address(crossed0), address(chunk1), address(names), address(treasury), SALE_START);

        HoleChunk crossed1 = new HoleChunk(TraitSchema.DATA_HASH_0, NO_HOLE);
        vm.expectRevert(GlamToon.BadTraitData.selector);
        this.deployWith(address(chunk0), address(crossed1), address(names), address(treasury), SALE_START);
    }

    /// The name table is never read during construction, so its hash is the
    /// whole of its protection. Delete that one line and this table, which
    /// answers every call and returns the wrong strings, is pinned forever.
    function test_onlyTheNamesHashRefusesANameTableThatAnswersEverything() public {
        TalkativeNames n = new TalkativeNames(NOT_A_REAL_HASH);

        uint256[] memory slots = new uint256[](1);
        assertEq(n.namesAt(slots)[0], "wrong", "the mock has to answer, or the hash is not what refused it");

        vm.expectRevert(GlamToon.BadTraitNames.selector);
        this.deployWith(address(chunk0), address(chunk1), address(n), address(treasury), SALE_START);
    }

    /// The control for the name table cases: the same mock with the real hash is
    /// accepted. Without it, a deployment that could never succeed for some
    /// unrelated reason would look exactly like a working hash pin.
    function test_aStandInNameTableWithTheRealHashIsAccepted() public {
        TalkativeNames n = new TalkativeNames(TraitSchema.NAMES_HASH);

        GlamToon g = this.deployWith(address(chunk0), address(chunk1), address(n), address(treasury), SALE_START);

        assertEq(address(g.NAMES()), address(n), "the stand in was not pinned");
    }

    /*//////////////////////////////////////////////////////////////
                           THE PAYEE AND THE START
    //////////////////////////////////////////////////////////////*/

    /// The payee check runs before anything is hashed. A deployment wrong in
    /// both ways has to name the payee, because that is the error the operator
    /// reads to decide what to fix.
    function test_theZeroPayeeIsRefusedBeforeAnythingIsHashed() public {
        HoleChunk junk = new HoleChunk(NOT_A_REAL_HASH, NO_HOLE);

        vm.expectRevert(GlamToon.InvalidPayout.selector);
        this.deployWith(address(junk), address(chunk1), address(names), address(0), SALE_START);
    }

    /// The other half of that condition, and the only one of the two that needs
    /// the address predicted. Takings sent to the token itself are stuck: there
    /// is no door in this contract that moves them.
    function test_theTokenItselfAsPayeeIsRefusedBeforeAnythingIsHashed() public {
        HoleChunk junk = new HoleChunk(NOT_A_REAL_HASH, NO_HOLE);

        vm.expectRevert(GlamToon.InvalidPayout.selector);
        this.deployPayingItself(address(junk), address(chunk1), address(names), SALE_START);
    }

    /// The prediction the case above rests on. Aimed one address off, that test
    /// would be passing on the zero branch or on nothing at all.
    function test_thePredictedSelfAddressIsWhereTheTokenLands() public {
        (GlamToon g, address predicted) =
            this.deployPredicted(address(chunk0), address(chunk1), address(names), SALE_START);

        assertEq(address(g), predicted, "the self payee case was aimed at the wrong address");
    }

    /// The start bound sits ahead of the hashes too, for the same reason.
    function test_aStartTooFarOutIsRefusedBeforeAnythingIsHashed() public {
        HoleChunk junk = new HoleChunk(NOT_A_REAL_HASH, NO_HOLE);

        vm.expectRevert(GlamToon.SaleStartTooFar.selector);
        this.deployWith(
            address(junk), address(chunk1), address(names), address(treasury), uint64(block.timestamp + 90 days + 1)
        );
    }

    /// The payee is checked before the start. A deployment wrong about both is
    /// told about the payee, whichever half of the payee check it trips, and
    /// with the payee put right the same start is then refused on its own.
    function test_aPayeeThatCannotBePaidIsNamedBeforeAStartTooFarOut() public {
        uint64 tooFar = uint64(block.timestamp + 90 days + 1);

        vm.expectRevert(GlamToon.InvalidPayout.selector);
        this.deployWith(address(chunk0), address(chunk1), address(names), address(0), tooFar);

        vm.expectRevert(GlamToon.InvalidPayout.selector);
        this.deployPayingItself(address(chunk0), address(chunk1), address(names), tooFar);

        vm.expectRevert(GlamToon.SaleStartTooFar.selector);
        this.deployWith(address(chunk0), address(chunk1), address(names), address(treasury), tooFar);
    }

    /// The bound is arithmetic on uint256, not on the uint64 the start is
    /// declared as. Deployed late enough that block.timestamp + 90 days no
    /// longer fits in a uint64, the largest start there is still has to be
    /// accepted rather than panicking on an overflow nobody sees in testing.
    function test_theStartBoundDoesNotOverflowAtTheEndOfTime() public {
        vm.warp(uint256(type(uint64).max) - 1 days);

        GlamToon g =
            this.deployWith(address(chunk0), address(chunk1), address(names), address(treasury), type(uint64).max);

        assertEq(g.SALE_START(), type(uint64).max, "the start was not pinned");
    }

    /*//////////////////////////////////////////////////////////////
                     THE SEAM IS WHERE THE DATA SPLITS
    //////////////////////////////////////////////////////////////*/

    /// The four reads are worth something only if they land on the real
    /// boundary. This evaluates the same four expressions the constructor does
    /// and checks each falls inside the chunk it routes to, and that one step
    /// over the line falls outside. A drift in IMAGES_PER_CHUNK would move the
    /// probes off the seam and leave them reading the middle of a chunk twice.
    function test_theFourProbesLandOnTheRealSeam() public {
        assertEq(nft.IMAGE_COUNT(), TraitSchema.IMAGE_COUNT, "the packing and the schema disagree");
        assertEq(PER * TraitSchema.CHUNK_COUNT, TraitSchema.IMAGE_COUNT, "the chunks do not cover the collection");

        chunk0.record(0);
        chunk0.record(PER - 1);
        chunk1.record(PER);
        chunk1.record(LAST);

        vm.expectRevert(TraitData0.OutOfChunk.selector);
        chunk0.record(PER);
        vm.expectRevert(TraitData1.OutOfChunk.selector);
        chunk1.record(PER - 1);
        vm.expectRevert(TraitData1.OutOfChunk.selector);
        chunk1.record(LAST + 1);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// External so vm.expectRevert watches the deployment and not the arguments.
    function deployWith(address c0, address c1, address n, address payout, uint64 start) public returns (GlamToon) {
        return new GlamToon(ITraitData(c0), ITraitData(c1), ITraitNames(n), payout, start);
    }

    /// The same, with the token's own address as the payee.
    function deployPayingItself(address c0, address c1, address n, uint64 start) public returns (GlamToon) {
        return deployWith(c0, c1, n, _nextDeployment(), start);
    }

    /// A deployment with the real payee, and the address predicted for it.
    function deployPredicted(address c0, address c1, address n, uint64 start)
        public
        returns (GlamToon g, address predicted)
    {
        predicted = _nextDeployment();
        g = deployWith(c0, c1, n, address(treasury), start);
    }

    /// Where this contract's next deployment lands. Read in the frame that
    /// deploys, because an isolated run sends each outer call as a transaction
    /// of its own and spends a nonce before that frame starts.
    function _nextDeployment() internal view returns (address) {
        return vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
    }

    /// A holed chunk has to answer for the other seam character it covers, or
    /// the test proves only that some read happened somewhere.
    function _assertAnswersFor(HoleChunk c, uint256 imageId) internal view {
        c.record(imageId);
    }
}

/*//////////////////////////////////////////////////////////////
                                MOCKS
//////////////////////////////////////////////////////////////*/

/// Reports whatever hash it was built with and answers for every character but
/// one. The record it returns is a constant because the constructor throws the
/// value away: all it is doing is proving the character can be reached.
contract HoleChunk {
    error NotThisCharacter(uint256 imageId);

    bytes32 private immutable HASH;
    uint256 private immutable HOLE;

    constructor(bytes32 hash_, uint256 hole) {
        HASH = hash_;
        HOLE = hole;
    }

    function dataHash() external view returns (bytes32) {
        return HASH;
    }

    function record(uint256 imageId) external view returns (uint40) {
        if (imageId == HOLE) revert NotThisCharacter(imageId);
        return 0x1234;
    }

    function data() external pure returns (bytes memory) {
        return "";
    }
}

/// A chunk that knows its own range and nothing outside it, which is what a
/// data contract built for the wrong half of the collection looks like.
contract RangeChunk {
    error OutsideMyRange(uint256 imageId);

    bytes32 private immutable HASH;
    uint256 private immutable LO;
    uint256 private immutable HI;

    constructor(bytes32 hash_, uint256 lo, uint256 hi) {
        HASH = hash_;
        LO = lo;
        HI = hi;
    }

    function dataHash() external view returns (bytes32) {
        return HASH;
    }

    function record(uint256 imageId) external view returns (uint40) {
        if (imageId < LO || imageId > HI) revert OutsideMyRange(imageId);
        return 0x1234;
    }

    function data() external pure returns (bytes memory) {
        return "";
    }
}

/// A name table that answers every call with the wrong string. Nothing reads it
/// at construction, so the hash is the only thing that tells it apart from the
/// real one.
contract TalkativeNames {
    bytes32 private immutable HASH;

    constructor(bytes32 hash_) {
        HASH = hash_;
    }

    function namesHash() external view returns (bytes32) {
        return HASH;
    }

    function namesAt(uint256[] calldata slots) external pure returns (string[] memory out) {
        out = new string[](slots.length);
        for (uint256 i = 0; i < slots.length; ++i) {
            out[i] = "wrong";
        }
    }

    function data() external pure returns (bytes memory) {
        return "";
    }
}
