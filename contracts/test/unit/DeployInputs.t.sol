// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {VmSafe} from "forge-std/Vm.sol";
import {Errors} from "openzeppelin/utils/Errors.sol";
import {BaseTest} from "../Base.t.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployReadingNothing} from "./DeployGuards.t.sol";
import {GlamToon, ITraitData, ITraitNames} from "../../src/GlamToon.sol";
import {Treasury} from "../../src/Treasury.sol";

/// The deploy script's inputs are the only part of this system a human types,
/// and every one of them is welded shut the moment the transaction lands. There
/// is no proxy and no admin, so a wrong SALE_START, a wrong chain or a payee
/// that cannot take delivery is not a bug to patch, it is the collection.
///
/// DeployRun covers the happy path end to end and DeployGuards covers the string
/// helpers and the art guards. This file covers the boundaries either side of
/// every accepted value, and proves each wiring assertion is live rather than
/// decoration.
///
/// The three environment variables are process wide and forge runs test
/// functions concurrently, so a test that changes one is read by whatever else
/// is mid flight and fails it, in this file and in DeployRun. setUp writes the
/// three values DeployRunTest writes and nothing here changes them afterwards.
/// Everything that needs a different SALE_START moves the clock instead, and
/// the input guards no clock can reach run on a script that is handed its
/// inputs rather than reading them.
///
/// ALLOW_EOA_TREASURY_OWNER and ALLOW_EOA_BENEFICIARY are each written by one
/// test alone. Every other run that reaches either guard with a plain wallet
/// overrides the read, so none of them depends on what those tests have set.
///
/// forge refuses to broadcast inside a pranked call, so a run cannot be made
/// from a plain wallet. The scripts below that sign as one stand it in through
/// _signer() instead, which is the account the floor and the two address
/// guards read.
contract DeployInputsTest is BaseTest {
    Deploy internal script;
    WiringProbe internal probe;

    /// The same two addresses DeployRunTest writes, so the shared environment
    /// never disagrees with itself.
    address internal constant OWNER_SAFE = address(0xA11CE);
    address internal constant PAYEE = address(0xB0B);

    uint256 internal constant OPTIMISM = 10;
    uint256 internal constant ANVIL = 31_337;

    uint256 internal constant FLOOR = 0.01 ether;

    string internal constant WRONG_CHAIN = "wrong chain, this collection deploys to OP Mainnet";
    string internal constant NEEDS_SAFE =
        "TREASURY_OWNER is not a contract, use a Safe or set ALLOW_EOA_TREASURY_OWNER=true";
    string internal constant NOT_THE_SIGNER =
        "TREASURY_OWNER is a plain wallet other than the signer, deploy to the signer and hand it on";
    string internal constant UNCHECKED_PAYEE =
        "BENEFICIARY is a plain wallet other than the signer, check it and set ALLOW_EOA_BENEFICIARY=true";

    /// One digit away from the owner, the shape of a typed address gone wrong.
    address internal constant NEIGHBOUR = address(0xA11CF);

    /// How far ahead a real chain wants the sale to open, as the script has it.
    uint256 internal constant SALE_LEAD = 1 hours;

    string internal constant TOO_SOON = "SALE_START is less than an hour away";

    /// What SALE_START says. Every run here starts SALE_LEAD before it, the
    /// earliest clock a real chain accepts. Read in the constructor, not in
    /// setUp: BaseTest warps, forge carries that warp into the next setUp, and a
    /// value derived there would drift away from the one DeployRunTest writes
    /// from a fresh clock.
    uint64 internal immutable SALE_START_ENV = uint64(block.timestamp + 1 days);

    Deploy.Deployed internal deployed;

    function setUp() public override {
        super.setUp();

        vm.setEnv("TREASURY_OWNER", vm.toString(OWNER_SAFE));
        vm.setEnv("BENEFICIARY", vm.toString(PAYEE));
        vm.setEnv("SALE_START", vm.toString(uint256(SALE_START_ENV)));

        vm.warp(SALE_START_ENV - SALE_LEAD);

        script = new Deploy();
        probe = new WiringProbe();
        vm.deal(address(script), 1 ether);

        // DeployEoaAllowed signs as the owner, as the runbook has it, so the
        // owner is the account the funding floor reads.
        vm.deal(OWNER_SAFE, 1 ether);
        vm.deal(NEIGHBOUR, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                               THE CHAIN GUARD
    //////////////////////////////////////////////////////////////*/

    /// Two chain ids get past the first line of the script and no others. A
    /// third id slipping into that condition would put an unowned, unpausable
    /// collection somewhere nobody is watching.
    function test_onlyOpMainnetAndAnvilAreAccepted() public {
        DeployEoaAllowed allowed = new DeployEoaAllowed();
        vm.deal(address(allowed), 1 ether);

        uint256[2] memory ok = [OPTIMISM, ANVIL];
        for (uint256 i = 0; i < ok.length; ++i) {
            vm.chainId(ok[i]);
            Deploy.Deployed memory d = allowed.run();
            assertEq(d.nft.SALE_START(), SALE_START_ENV, "a chain that should have deployed did not");
        }
    }

    /// Every id in this list is a chain somebody could plausibly point the RPC
    /// at by mistake. OP Sepolia, Sepolia and Holesky are the sharp ones: each
    /// was on the accepted list once, so a stale runbook would name them. The
    /// script here fails if it ever reads its inputs, so the chain message can
    /// only come from a guard that runs before any read.
    function test_everyOtherChainIsRefusedBeforeAnythingIsRead() public {
        DeployReadingNothing blind = new DeployReadingNothing();
        uint256[10] memory wrong = [
            uint256(0),
            1, // Ethereum
            137, // Polygon
            8453, // Base, the neighbouring L2
            42_161, // Arbitrum One
            56, // BNB
            11_155_420, // OP Sepolia, accepted until the collection went to OP Mainnet only
            11_155_111, // Sepolia, accepted before the move to OP
            17_000, // Holesky, likewise
            999
        ];

        for (uint256 i = 0; i < wrong.length; ++i) {
            vm.chainId(wrong[i]);
            vm.expectRevert(bytes(WRONG_CHAIN));
            blind.run();
        }
    }

    /// Base is one digit away from nothing and shares OP's stack and tooling, so
    /// it gets its own case rather than living only inside a loop.
    function test_baseIsNotOptimism() public {
        vm.chainId(8453);
        vm.expectRevert(bytes(WRONG_CHAIN));
        script.run();
    }

    /*//////////////////////////////////////////////////////////////
                             THE FUNDING FLOOR
    //////////////////////////////////////////////////////////////*/

    /// The floor reads msg.sender, which is the account that signs the
    /// deployment, not the script contract. Funding the script and leaving the
    /// signer empty is the shape of the mistake, and the guard has to notice.
    function test_theFundingFloorReadsTheSignerAndNotTheScript() public {
        vm.deal(address(script), 100 ether);
        vm.deal(address(this), FLOOR);

        vm.chainId(OPTIMISM);
        vm.expectRevert(bytes("deployer underfunded"));
        script.run();

        assertEq(address(script).balance, 100 ether, "a full script balance did not rescue an empty signer");
    }

    /// Exactly at the floor is refused and one wei above it is not, which is the
    /// difference between a strict and a non strict comparison.
    function test_theFloorIsStrict() public {
        DeployEoaAllowed allowed = new DeployEoaAllowed();
        vm.deal(address(allowed), 1 ether);
        vm.chainId(OPTIMISM);

        vm.deal(OWNER_SAFE, FLOOR);
        vm.expectRevert(bytes("deployer underfunded"));
        allowed.run();

        vm.deal(OWNER_SAFE, FLOOR + 1);
        Deploy.Deployed memory d = allowed.run();
        assertEq(d.nft.SALE_START(), SALE_START_ENV, "one wei over the floor should have deployed");
    }

    /// The floor is an OP Mainnet rule. A local anvil runs on whatever it was
    /// given, and a penniless signer there must still deploy.
    function test_theFloorDoesNotApplyToAnvil() public {
        DeployEoaAllowed allowed = new DeployEoaAllowed();
        vm.deal(address(allowed), 1 ether);
        vm.deal(OWNER_SAFE, 0);

        vm.chainId(ANVIL);
        Deploy.Deployed memory d = allowed.run();
        assertEq(d.nft.SALE_START(), SALE_START_ENV, "anvil should not need a balance");
    }

    /*//////////////////////////////////////////////////////////////
                                SALE_START
    //////////////////////////////////////////////////////////////*/

    /// A start already behind the deployment is a sale that opens the instant it
    /// lands, with no time to check anything first. The script refuses it rather
    /// than the constructor, because the constructor has no opinion about the
    /// past.
    function test_aStartInThePastIsRefused() public {
        vm.chainId(ANVIL);
        vm.warp(uint256(SALE_START_ENV) + 1);

        vm.expectRevert(bytes("SALE_START is in the past"));
        script.run();
    }

    /// A start past the end of uint64 is refused by name rather than cut down to
    /// its low 64 bits. Cut down, this one would land exactly on a valid start
    /// and deploy. The largest uint64 itself is a timestamp, so it gets past
    /// this guard and the constructor judges it too far out.
    function test_aSaleStartThatDoesNotFitInUint64IsRefused() public {
        vm.chainId(ANVIL);

        DeployWithInputs wrapped = new DeployWithInputs(OWNER_SAFE, PAYEE, (uint256(1) << 64) + SALE_START_ENV);
        vm.expectRevert(bytes("SALE_START is not a unix timestamp in seconds"));
        wrapped.run();

        DeployWithInputs justOver = new DeployWithInputs(OWNER_SAFE, PAYEE, uint256(type(uint64).max) + 1);
        vm.expectRevert(bytes("SALE_START is not a unix timestamp in seconds"));
        justOver.run();

        DeployWithInputs largest = new DeployWithInputs(OWNER_SAFE, PAYEE, type(uint64).max);
        vm.expectRevert(GlamToon.SaleStartTooFar.selector);
        largest.run();
    }

    /// OP Mainnet wants an hour between the deployment and the sale, so the
    /// source can be verified and the metadata read back while nobody can mint.
    /// A start one second inside that hour is refused, and so is the deployment
    /// block itself, which is what SALE_START=$(date +%s) gives at best.
    function test_aStartLessThanAnHourAwayIsRefusedOnOpMainnet() public {
        DeployEoaAllowed allowed = new DeployEoaAllowed();
        vm.deal(address(allowed), 1 ether);
        vm.chainId(OPTIMISM);

        vm.warp(SALE_START_ENV - SALE_LEAD + 1);
        vm.expectRevert(bytes(TOO_SOON));
        allowed.run();

        vm.warp(SALE_START_ENV);
        vm.expectRevert(bytes(TOO_SOON));
        allowed.run();
    }

    /// Exactly an hour ahead is accepted, and until then both doors are shut to
    /// everybody. The sale opens by itself at the start it was given.
    function test_anHourAheadIsAcceptedAndNobodyMintsUntilThen() public {
        DeployEoaAllowed allowed = new DeployEoaAllowed();
        vm.deal(address(allowed), 1 ether);
        vm.chainId(OPTIMISM);

        Deploy.Deployed memory d = allowed.run();
        assertEq(uint256(d.nft.SALE_START()), block.timestamp + SALE_LEAD, "the start is not an hour out");

        vm.warp(uint256(SALE_START_ENV) - 1);
        vm.startPrank(alice);
        vm.expectRevert(GlamToon.NotStarted.selector);
        d.nft.mintBlue{value: 0.01 ether}(0, 0.01 ether);
        vm.expectRevert(GlamToon.NotStarted.selector);
        d.nft.mintGreen(0);

        vm.warp(SALE_START_ENV);
        d.nft.mintBlue{value: 0.01 ether}(0, 0.01 ether);
        d.nft.mintGreen(0);
        vm.stopPrank();

        assertEq(d.nft.ownerOf(0), alice, "the first character could not be bought at the start");
        assertEq(d.nft.greenCount(0), 1, "the first green could not be taken at the start");
    }

    /// Anvil keeps no lead, so the site can be worked on against a sale that is
    /// open from the deployment block. local-chain.sh deploys exactly that way.
    function test_anvilMayOpenTheSaleOnTheDeploymentBlock() public {
        vm.chainId(ANVIL);
        vm.warp(SALE_START_ENV);

        Deploy.Deployed memory d = script.run();
        assertEq(uint256(d.nft.SALE_START()), block.timestamp, "the sale did not open on the deployment block");

        vm.prank(alice);
        d.nft.mintBlue{value: 0.01 ether}(0, 0.01 ether);
        assertEq(d.nft.ownerOf(0), alice, "the first character could not be bought on the deployment block");
    }

    /// Ninety days exactly is inside the window. A `>=` where the code has `>`
    /// would reject the one value the documented limit promises.
    function test_exactlyNinetyDaysAheadIsAccepted() public {
        uint64 start = uint64(block.timestamp + 90 days);
        GlamToon g = this.deployWith(address(chunk0), address(chunk1), address(names), address(treasury), start);

        assertEq(g.SALE_START(), start, "ninety days out was not accepted");

        vm.warp(uint256(start) - 1);
        vm.expectRevert(GlamToon.NotStarted.selector);
        vm.prank(alice);
        g.mintGreen(0);

        vm.warp(start);
        vm.prank(alice);
        g.mintGreen(0);
        assertEq(g.greenCount(0), 1, "the sale did not open at the start it was given");
    }

    /// One second past the window is refused. A mistyped year locks both editions
    /// for good, and nothing can unlock them.
    function test_oneSecondPastNinetyDaysIsRefused() public {
        uint64 start = uint64(block.timestamp + 90 days + 1);
        vm.expectRevert(GlamToon.SaleStartTooFar.selector);
        this.deployWith(address(chunk0), address(chunk1), address(names), address(treasury), start);
    }

    /// Anywhere inside the window the value survives verbatim. A constructor that
    /// rounded, clamped or rebased the start would still pass both boundary
    /// cases above.
    function test_anyStartInsideTheWindowIsAccepted(uint256 seed) public {
        uint64 start = uint64(bound(seed, block.timestamp, block.timestamp + 90 days));
        GlamToon g = this.deployWith(address(chunk0), address(chunk1), address(names), address(treasury), start);
        assertEq(g.SALE_START(), start, "a start inside the window was not kept verbatim");
    }

    /// The far side of the window, including the values a units slip produces:
    /// milliseconds, a year written as a year, a pasted block number.
    function test_anyStartBeyondTheWindowIsRefused(uint256 seed) public {
        uint64 start = uint64(bound(seed, block.timestamp + 90 days + 1, type(uint64).max));
        vm.expectRevert(GlamToon.SaleStartTooFar.selector);
        this.deployWith(address(chunk0), address(chunk1), address(names), address(treasury), start);
    }

    /// The constructor has no lower bound at all: it takes zero and keeps it.
    /// Everything standing between a deployment and a sale that was already open
    /// is the one line in the script, which is why the case above matters.
    function test_theConstructorHasNoOpinionAboutThePast() public {
        GlamToon g = this.deployWith(address(chunk0), address(chunk1), address(names), address(treasury), 0);
        assertEq(g.SALE_START(), 0, "zero was not kept");
    }

    /*//////////////////////////////////////////////////////////////
                               THE ADDRESSES
    //////////////////////////////////////////////////////////////*/

    /// An empty TREASURY_OWNER is named as such, before the treasury's own
    /// constructor can refuse it with an error that says nothing about where
    /// the zero came from.
    function test_anUnsetTreasuryOwnerIsRefused() public {
        DeployWithInputs unset = new DeployWithInputs(address(0), PAYEE, SALE_START_ENV);

        vm.chainId(ANVIL);
        vm.expectRevert(bytes("TREASURY_OWNER unset"));
        unset.run();
    }

    /// The same for BENEFICIARY.
    function test_anUnsetBeneficiaryIsRefused() public {
        DeployWithInputs unset = new DeployWithInputs(OWNER_SAFE, address(0), SALE_START_ENV);

        vm.chainId(ANVIL);
        vm.expectRevert(bytes("BENEFICIARY unset"));
        unset.run();
    }

    /// The control for the cases above: handed the values the environment
    /// holds, the script deploys exactly as it does when it reads them.
    function test_aScriptHandedItsInputsDeploysTheSame() public {
        DeployWithInputs handed = new DeployWithInputs(OWNER_SAFE, PAYEE, SALE_START_ENV);

        vm.chainId(ANVIL);
        Deploy.Deployed memory d = handed.run();

        assertEq(d.treasury.owner(), OWNER_SAFE, "treasury owner");
        assertEq(d.treasury.beneficiary(), PAYEE, "beneficiary");
        assertEq(d.nft.SALE_START(), SALE_START_ENV, "sale start");
    }

    /*//////////////////////////////////////////////////////////////
                              THE EOA OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /// Without the override a plain wallet is refused on OP Mainnet. A fork of
    /// it carries the same chain id, so the rehearsal fails the same way as the
    /// real run.
    function test_aPlainWalletIsRefusedOnOpMainnet() public {
        assertEq(OWNER_SAFE.code.length, 0, "the point of the test is a codeless owner");

        DeployEoaRefused refused = new DeployEoaRefused();
        vm.deal(address(refused), 1 ether);

        vm.chainId(OPTIMISM);
        vm.expectRevert(bytes(NEEDS_SAFE));
        refused.run();
    }

    /// The flag is the only difference between the run above and this one. Same
    /// chain, same codeless owner, deploys.
    function test_theOverrideIsTheOnlyThingThatChanges() public {
        DeployEoaAllowed allowed = new DeployEoaAllowed();
        vm.deal(address(allowed), 1 ether);

        vm.chainId(OPTIMISM);
        Deploy.Deployed memory d = allowed.run();
        assertEq(d.treasury.owner(), OWNER_SAFE, "treasury owner");
        assertEq(OWNER_SAFE.code.length, 0, "still a plain wallet");
    }

    /// The one run that reads ALLOW_EOA_TREASURY_OWNER from the environment,
    /// with the script's own read. The owner signs and the beneficiary flag is
    /// set, so this flag is the only thing deciding the run. Unset or false, a
    /// plain wallet is refused, and true lets it through. No other test reads
    /// the variable, so this one alone may write it, and it leaves it false. A
    /// shell that already exports the variable hides the unset case, which then
    /// stands aside.
    function test_theRealOverrideIsReadFromTheEnvironment() public {
        DeployReadingOwnerFlag reading = new DeployReadingOwnerFlag();
        vm.deal(address(reading), 1 ether);
        vm.chainId(OPTIMISM);

        if (!vm.envExists("ALLOW_EOA_TREASURY_OWNER")) {
            vm.expectRevert(bytes(NEEDS_SAFE));
            reading.run();
        }

        vm.setEnv("ALLOW_EOA_TREASURY_OWNER", "true");
        assertEq(reading.run().treasury.owner(), OWNER_SAFE, "the override was not read");

        vm.setEnv("ALLOW_EOA_TREASURY_OWNER", "false");
        vm.expectRevert(bytes(NEEDS_SAFE));
        reading.run();
    }

    /// Anvil never asks for a Safe, so a rehearsal against a local node cannot be
    /// read as evidence that the guard is satisfied.
    function test_anvilNeverAsksForASafe() public {
        vm.chainId(ANVIL);
        Deploy.Deployed memory d = script.run();
        assertEq(d.treasury.owner(), OWNER_SAFE, "anvil refused a plain wallet");
    }

    /// The guard is a code length test, not a Safe test. A 7702 delegated wallet
    /// carries twenty three bytes and walks straight through it, and so does one
    /// byte of anything, with the override off and somebody else signing. Worth
    /// knowing before anyone reads a passing deploy as proof that a multisig
    /// holds the treasury.
    function test_anyCodeAtAllSatisfiesTheSafeGuard() public {
        DeploySignedBy stranger = new DeploySignedBy(NEIGHBOUR, false, true);
        vm.deal(address(stranger), 1 ether);
        vm.chainId(OPTIMISM);

        vm.etch(OWNER_SAFE, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        assertEq(OWNER_SAFE.code.length, 23, "a 7702 delegation designator is 23 bytes");
        Deploy.Deployed memory d = stranger.run();
        assertEq(d.treasury.owner(), OWNER_SAFE, "a delegated wallet was refused");

        vm.etch(OWNER_SAFE, hex"00");
        d = stranger.run();
        assertEq(d.treasury.owner(), OWNER_SAFE, "one byte of code was refused");
    }

    /*//////////////////////////////////////////////////////////////
                       THE SIGNER AND THE BENEFICIARY
    //////////////////////////////////////////////////////////////*/

    /// A plain wallet owner has to be the account that signs, because the
    /// signer is the one wallet this run proves somebody holds the key to, and
    /// a wrong owner can never be put right. One digit off is refused with the
    /// override set, and the owner itself signing is the only change that lets
    /// the same run through. There is no flag for this one.
    function test_aPlainWalletOwnerHasToBeTheSigner() public {
        DeploySignedBy typo = new DeploySignedBy(NEIGHBOUR, true, true);
        DeploySignedBy owner = new DeploySignedBy(OWNER_SAFE, true, true);
        vm.deal(address(typo), 1 ether);
        vm.deal(address(owner), 1 ether);
        vm.chainId(OPTIMISM);

        vm.expectRevert(bytes(NOT_THE_SIGNER));
        typo.run();

        assertEq(owner.run().treasury.owner(), OWNER_SAFE, "the owner signing was refused");
    }

    /// The way to give the treasury to another plain wallet is to deploy to the
    /// signer and hand it on. The handover completes only when the new owner
    /// signs, which is the proof the deployment could not ask for.
    function test_anotherPlainWalletTakesTheTreasuryByAcceptingIt() public {
        DeploySignedBy owner = new DeploySignedBy(OWNER_SAFE, true, true);
        vm.deal(address(owner), 1 ether);
        vm.chainId(OPTIMISM);
        Deploy.Deployed memory d = owner.run();

        vm.prank(OWNER_SAFE);
        d.treasury.transferOwnership(NEIGHBOUR);
        assertEq(d.treasury.owner(), OWNER_SAFE, "the owner moved before anyone accepted");

        vm.prank(NEIGHBOUR);
        d.treasury.acceptOwnership();
        assertEq(d.treasury.owner(), NEIGHBOUR, "the new owner could not accept");
        assertEq(d.nft.owner(), NEIGHBOUR, "the label did not follow");
    }

    /// A beneficiary with no code that is not the signer is refused until it is
    /// allowed by name. That is a Safe copied from another chain and never
    /// deployed on OP: it takes ether, the proof sweep passes, and nobody can
    /// spend what it receives. The flag is the only difference between the two
    /// runs.
    function test_aPlainWalletBeneficiaryOtherThanTheSignerNeedsTheFlag() public {
        DeploySignedBy notChecked = new DeploySignedBy(OWNER_SAFE, true, false);
        DeploySignedBy checked = new DeploySignedBy(OWNER_SAFE, true, true);
        vm.deal(address(notChecked), 1 ether);
        vm.deal(address(checked), 1 ether);
        vm.chainId(OPTIMISM);
        assertEq(PAYEE.code.length, 0, "the point of the test is a codeless beneficiary");

        vm.expectRevert(bytes(UNCHECKED_PAYEE));
        notChecked.run();

        assertEq(checked.run().treasury.beneficiary(), PAYEE, "the flag did not let the beneficiary through");
    }

    /// The runbook's own setup, one plain wallet that signs, owns the treasury
    /// and takes the sweeps, needs no beneficiary flag at all.
    function test_theSignerMayBeOwnerAndBeneficiaryWithoutTheFlag() public {
        address me = vm.addr(0xD3);
        vm.deal(me, 1 ether);
        DeployToTheSigner mine = new DeployToTheSigner(me, SALE_START_ENV);
        vm.deal(address(mine), 1 ether);
        vm.chainId(OPTIMISM);

        Deploy.Deployed memory d = mine.run();
        assertEq(d.treasury.owner(), me, "treasury owner");
        assertEq(d.treasury.beneficiary(), me, "beneficiary");
    }

    /// A beneficiary with code passes without the flag. Like the Safe guard it
    /// is a code length test, so a Safe named here still has to be read back on
    /// OP by hand.
    function test_aBeneficiaryWithCodeNeedsNoFlag() public {
        DeploySignedBy owner = new DeploySignedBy(OWNER_SAFE, true, false);
        vm.deal(address(owner), 1 ether);
        vm.chainId(OPTIMISM);

        vm.etch(PAYEE, hex"00");
        assertEq(owner.run().treasury.beneficiary(), PAYEE, "a beneficiary with code was refused");
    }

    /// The one run that reads ALLOW_EOA_BENEFICIARY from the environment, with
    /// the script's own read. Unset or false, a plain wallet beneficiary other
    /// than the signer is refused, and true lets it through. No other test
    /// reads the variable, so this one alone may write it, and it leaves it
    /// false. A shell that already exports it hides the unset case, which then
    /// stands aside.
    function test_theRealBeneficiaryFlagIsReadFromTheEnvironment() public {
        DeployReadingBeneficiaryFlag reading = new DeployReadingBeneficiaryFlag();
        vm.deal(address(reading), 1 ether);
        vm.chainId(OPTIMISM);

        if (!vm.envExists("ALLOW_EOA_BENEFICIARY")) {
            vm.expectRevert(bytes(UNCHECKED_PAYEE));
            reading.run();
        }

        vm.setEnv("ALLOW_EOA_BENEFICIARY", "true");
        assertEq(reading.run().treasury.beneficiary(), PAYEE, "the flag was not read");

        vm.setEnv("ALLOW_EOA_BENEFICIARY", "false");
        vm.expectRevert(bytes(UNCHECKED_PAYEE));
        reading.run();
    }

    /// With every input wrong at once on OP Mainnet the guards speak in a fixed
    /// order, and putting one thing right at a time hands the run to the next
    /// guard in line: the inputs, then the lead, the balance, the art, the
    /// Safe, the signer and last of all the beneficiary. The art guards here
    /// only report that they were reached.
    function test_theRunGuardsNameTheFirstMistakeInOrder() public {
        uint256 start = SALE_START_ENV;
        vm.chainId(OPTIMISM);
        vm.deal(address(this), FLOOR);
        vm.warp(start + 1);

        _refusesInTurn(
            address(0), address(0), (uint256(1) << 64) + start, bytes("SALE_START is not a unix timestamp in seconds")
        );
        _refusesInTurn(address(0), address(0), start, bytes("TREASURY_OWNER unset"));
        _refusesInTurn(OWNER_SAFE, address(0), start, bytes("BENEFICIARY unset"));
        _refusesInTurn(OWNER_SAFE, PAYEE, start, bytes("SALE_START is in the past"));

        vm.warp(start - SALE_LEAD + 1);
        _refusesInTurn(OWNER_SAFE, PAYEE, start, bytes(TOO_SOON));

        vm.warp(start - SALE_LEAD);
        _refusesInTurn(OWNER_SAFE, PAYEE, start, bytes("deployer underfunded"));

        vm.deal(address(this), FLOOR + 1);
        _refusesInTurn(OWNER_SAFE, PAYEE, start, abi.encodeWithSelector(DeployInTurn.ArtGuardsReached.selector));

        DeployEoaRefused real = new DeployEoaRefused();
        vm.expectRevert(bytes(NEEDS_SAFE));
        real.run();

        DeploySignedBy typo = new DeploySignedBy(NEIGHBOUR, true, false);
        vm.expectRevert(bytes(NOT_THE_SIGNER));
        typo.run();

        DeploySignedBy owner = new DeploySignedBy(OWNER_SAFE, true, false);
        vm.expectRevert(bytes(UNCHECKED_PAYEE));
        owner.run();

        DeploySignedBy checked = new DeploySignedBy(OWNER_SAFE, true, true);
        vm.deal(address(checked), 1 ether);
        assertEq(checked.run().treasury.beneficiary(), PAYEE, "every guard satisfied and still refused");
    }

    /*//////////////////////////////////////////////////////////////
                             THE PAYEE PROOF
    //////////////////////////////////////////////////////////////*/

    /// The script sends one wei through the treasury and out to the beneficiary
    /// so that the hop nobody checks is checked once, at deployment. Sweeping is
    /// open to everyone and the owner can retarget it, so this is not fatal the
    /// way a bad payee is, but it is the only moment anyone finds out. A payee
    /// that refuses ether has to stop the run here.
    function test_aBeneficiaryThatRefusesEtherStopsTheDeployment() public {
        vm.chainId(ANVIL);
        vm.etch(PAYEE, hex"60006000fd");

        vm.expectRevert(Errors.FailedCall.selector);
        script.run();
    }

    /// And the wei really does leave. Without this the case above could pass on
    /// a run that never attempted the hop.
    function test_theProofWeiReachesTheBeneficiary() public {
        uint256 before = PAYEE.balance;
        _deployForProbe();

        assertEq(address(deployed.treasury).balance, 0, "the treasury kept the proof wei");
        assertEq(PAYEE.balance, before + 1, "the proof wei never reached the beneficiary");
    }

    /// A beneficiary that hands the wei straight back leaves the treasury
    /// holding it. The sweep itself succeeds, so the emptied treasury check
    /// after it is the only thing that can stop this run.
    function test_aBeneficiaryThatBouncesTheWeiBackIsRefused() public {
        vm.chainId(ANVIL);
        vm.etch(PAYEE, address(new Bouncer()).code);

        vm.expectRevert(bytes("the beneficiary cannot receive ether"));
        script.run();
    }

    /// The proof sweep is a transaction of its own, sent by the account that
    /// deploys everything else. Outside the broadcast it would only ever be
    /// simulated, and on chain the wei would sit in the treasury unproven.
    function test_theProofSweepIsBroadcastByTheDeployer() public {
        vm.chainId(ANVIL);

        vm.startStateDiffRecording();
        Deploy.Deployed memory d = script.run();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        address deployer;
        address sweeper;
        for (uint256 i = 0; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory a = accesses[i];
            if (a.kind == VmSafe.AccountAccessKind.Create && a.account == address(d.nft)) {
                deployer = a.accessor;
            }
            if (
                a.kind == VmSafe.AccountAccessKind.Call && a.account == address(d.treasury) && a.data.length >= 4
                    && bytes4(a.data) == Treasury.sweep.selector
            ) {
                sweeper = a.accessor;
            }
        }

        assertTrue(deployer != address(0), "the token deployment was not recorded");
        assertTrue(deployer != address(script), "the token was not deployed by the broadcasting account");
        assertEq(sweeper, deployer, "the proof sweep was not sent by the deploying account");
    }

    /// Every contract the script makes is created by the account that
    /// broadcasts. One made by the script contract itself exists only in the
    /// simulation, and the token would then be pinned to addresses with no code.
    function test_everyContractIsCreatedByTheBroadcastingAccount() public {
        vm.chainId(ANVIL);

        vm.startStateDiffRecording();
        Deploy.Deployed memory d = script.run();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        address[5] memory made =
            [address(d.chunk0), address(d.chunk1), address(d.names), address(d.treasury), address(d.nft)];
        string[5] memory what = ["chunk 0", "chunk 1", "name table", "treasury", "token"];

        address deployer;
        for (uint256 k = 0; k < made.length; ++k) {
            address creator;
            for (uint256 i = 0; i < accesses.length; ++i) {
                if (accesses[i].kind == VmSafe.AccountAccessKind.Create && accesses[i].account == made[k]) {
                    creator = accesses[i].accessor;
                }
            }
            assertTrue(creator != address(0), string.concat(what[k], " was never created"));
            assertTrue(creator != address(script), string.concat(what[k], " was created outside the broadcast"));
            if (k == 0) deployer = creator;
            assertEq(creator, deployer, string.concat(what[k], " has a different creator"));
        }
    }

    /*//////////////////////////////////////////////////////////////
                           THE WIRING ASSERTIONS
    //////////////////////////////////////////////////////////////*/

    /// The baseline the failure cases below are measured against. Without this,
    /// an assertion that can never pass would look exactly like one that works.
    function test_theWiringAssertionsAcceptARealDeployment() public {
        _deployForProbe();
        probe.check(deployed, OWNER_SAFE, PAYEE, SALE_START_ENV);
    }

    /// run() reads the wiring back after the proof sweep, the one moment it
    /// hands control to someone else. A beneficiary that also owns the treasury
    /// and points it elsewhere as the wei arrives has to stop the run.
    function test_theWiringIsReadAfterTheProofSweep() public {
        Retargeter both = new Retargeter();
        DeployWithInputs handed = new DeployWithInputs(address(both), address(both), SALE_START_ENV);
        vm.chainId(ANVIL);

        vm.expectRevert(bytes("beneficiary"));
        handed.run();
    }

    /// The three data contracts are pinned by hash, then pinned again by address
    /// inside the token. Both halves have to be able to fail or the deployment
    /// could carry one build and point at another.
    function test_everyDataAssertionCanFail() public {
        _deployForProbe();

        _rejects(address(deployed.chunk0), "dataHash()", abi.encode(bytes32(0)), "chunk 0 data");
        _rejects(address(deployed.chunk1), "dataHash()", abi.encode(bytes32(0)), "chunk 1 data");
        _rejects(address(deployed.names), "namesHash()", abi.encode(bytes32(0)), "name table");

        _rejects(address(deployed.nft), "CHUNK0()", abi.encode(address(0xDEAD)), "chunk 0 not wired");
        _rejects(address(deployed.nft), "CHUNK1()", abi.encode(address(0xDEAD)), "chunk 1 not wired");
        _rejects(address(deployed.nft), "NAMES()", abi.encode(address(0xDEAD)), "name table not wired");
    }

    /// Where the money goes, who may move it and what the collection calls
    /// itself. Each of these is a separate require and each one is checked here
    /// on its own, because a run that trips on the first never reaches the rest.
    /// The numbers are lied about on both sides, so each require has to be an
    /// equality and not a bound.
    function test_everyIdentityAssertionCanFail() public {
        _deployForProbe();

        _rejects(address(deployed.nft), "PAYOUT()", abi.encode(address(0xDEAD)), "payee not wired");
        _rejects(address(deployed.nft), "SALE_START()", abi.encode(uint64(SALE_START_ENV + 1)), "sale start");
        _rejects(address(deployed.nft), "SALE_START()", abi.encode(uint64(SALE_START_ENV - 1)), "sale start");
        _rejects(
            address(deployed.nft),
            "owner()",
            abi.encode(address(0xDEAD)),
            "collection label does not follow the treasury"
        );
        _rejects(address(deployed.nft), "BLUE_SUPPLY()", abi.encode(uint256(9999)), "wrong supply");
        _rejects(address(deployed.nft), "BLUE_SUPPLY()", abi.encode(uint256(10_001)), "wrong supply");
        _rejects(address(deployed.nft), "IMAGE_COUNT()", abi.encode(uint256(9999)), "wrong character count");
        _rejects(address(deployed.nft), "IMAGE_COUNT()", abi.encode(uint256(10_001)), "wrong character count");
        _rejects(address(deployed.nft), "name()", abi.encode(string("Glamtoons")), "wrong name");
        _rejects(address(deployed.nft), "symbol()", abi.encode(string("GLAM")), "wrong symbol");

        _rejects(address(deployed.treasury), "beneficiary()", abi.encode(address(0xDEAD)), "beneficiary");
    }

    /// The token has no owner of its own: it reads the treasury's and reports it
    /// as the marketplace label. So a lie told to the treasury trips the label
    /// require first, and the treasury require can only be reached by holding the
    /// label steady. Worth pinning, because it means those two lines are one
    /// check and not two.
    function test_theTreasuryOwnerAssertionSitsBehindTheLabel() public {
        _deployForProbe();

        bytes memory ownerCall = abi.encodeWithSignature("owner()");

        vm.mockCall(address(deployed.treasury), ownerCall, abi.encode(address(0xDEAD)));
        vm.expectRevert(bytes("collection label does not follow the treasury"));
        probe.check(deployed, OWNER_SAFE, PAYEE, SALE_START_ENV);

        vm.mockCall(address(deployed.nft), ownerCall, abi.encode(OWNER_SAFE));
        vm.expectRevert(bytes("treasury owner"));
        probe.check(deployed, OWNER_SAFE, PAYEE, SALE_START_ENV);
        vm.clearMockedCalls();
    }

    /// The royalty is two percent to the treasury. Receiver and rate are two
    /// requires and a single mocked answer can only be caught by one of them at a
    /// time, so both are driven separately, and the rate from above and below.
    function test_bothHalvesOfTheRoyaltyAssertionCanFail() public {
        _deployForProbe();

        bytes memory call = abi.encodeWithSignature("royaltyInfo(uint256,uint256)", uint256(1), uint256(1 ether));

        vm.mockCall(address(deployed.nft), call, abi.encode(address(0xDEAD), uint256(0.02 ether)));
        vm.expectRevert(bytes("royalty receiver"));
        probe.check(deployed, OWNER_SAFE, PAYEE, SALE_START_ENV);
        vm.clearMockedCalls();

        uint256[3] memory wrongRates = [uint256(0.05 ether), 0.01 ether, 0];
        for (uint256 i = 0; i < wrongRates.length; ++i) {
            vm.mockCall(address(deployed.nft), call, abi.encode(address(deployed.treasury), wrongRates[i]));
            vm.expectRevert(bytes("royalty rate"));
            probe.check(deployed, OWNER_SAFE, PAYEE, SALE_START_ENV);
            vm.clearMockedCalls();
        }
    }

    /// The art root, the token base and the two metadata probes. These are the
    /// assertions that would catch a build whose compiled constants drifted from
    /// the ones the deployed bytecode answers with.
    function test_everyMetadataAssertionCanFail() public {
        _deployForProbe();

        _rejects(
            address(deployed.nft),
            "ipfsRoot()",
            abi.encode(string("bafybeiaaaa")),
            "deployed art root is not the compiled one"
        );
        _rejects(
            address(deployed.nft),
            "tokenBase()",
            abi.encode(string("https://elsewhere.invalid/")),
            "deployed token base is not the compiled one"
        );

        vm.mockCall(
            address(deployed.nft), abi.encodeWithSignature("tokenJSON(uint256)", uint256(0)), abi.encode(string(""))
        );
        vm.expectRevert(bytes("first character has no metadata"));
        probe.check(deployed, OWNER_SAFE, PAYEE, SALE_START_ENV);
        vm.clearMockedCalls();

        vm.mockCall(
            address(deployed.nft),
            abi.encodeWithSignature("tokenJSON(uint256)", uint256(9999)),
            abi.encode(string("{}"))
        );
        vm.expectRevert(bytes("last character has no metadata"));
        probe.check(deployed, OWNER_SAFE, PAYEE, SALE_START_ENV);
        vm.clearMockedCalls();
    }

    /// Both metadata probes draw the line in the same place: exactly two hundred
    /// bytes is refused and one more is accepted, for the first character and
    /// for the last.
    function test_theMetadataProbesNeedMoreThanTwoHundredBytes() public {
        _deployForProbe();

        _rejects(
            address(deployed.nft),
            "tokenJSON(uint256)",
            uint256(0),
            abi.encode(_text(200)),
            "first character has no metadata"
        );
        _rejects(
            address(deployed.nft),
            "tokenJSON(uint256)",
            uint256(9999),
            abi.encode(_text(200)),
            "last character has no metadata"
        );

        vm.mockCall(
            address(deployed.nft), abi.encodeWithSignature("tokenJSON(uint256)", uint256(0)), abi.encode(_text(201))
        );
        vm.mockCall(
            address(deployed.nft), abi.encodeWithSignature("tokenJSON(uint256)", uint256(9999)), abi.encode(_text(201))
        );
        probe.check(deployed, OWNER_SAFE, PAYEE, SALE_START_ENV);
        vm.clearMockedCalls();
    }

    /*//////////////////////////////////////////////////////////////
                            THE PRICE SCHEDULE
    //////////////////////////////////////////////////////////////*/

    /// The script pins three numbers that decide what ten thousand buyers pay.
    /// They are written as literals there, so they are recomputed here from the
    /// rule the README states rather than read back from the same constants.
    function test_thePinnedPricesAreTheOnesTheCollectionCharges() public view {
        assertEq(nft.priceAt(0), 0.01 ether, "opening price");
        assertEq(nft.priceAt(BLUE_SUPPLY - 1), 0.04 ether, "closing price");
        assertEq(nft.TIER_SIZE(), 2500, "tier size");

        assertEq(BLUE_SUPPLY / TIER_SIZE, 4, "four tiers");
        for (uint256 tier = 0; tier < 4; ++tier) {
            assertEq(nft.priceAt(tier * TIER_SIZE), PRICE_STEP * (tier + 1), "tier opens at the wrong price");
            assertEq(
                nft.priceAt(tier * TIER_SIZE + TIER_SIZE - 1), PRICE_STEP * (tier + 1), "tier ends at the wrong price"
            );
        }
    }

    /// A step of the wrong size, an opening price off by a decimal place and a
    /// tier of the wrong width all land on one of these three requires. Each is
    /// lied to from above and from below, so a cheaper schedule is caught as
    /// surely as a dearer one.
    function test_aWrongScheduleIsCaughtByTheScript() public {
        _deployForProbe();

        _rejects(
            address(deployed.nft), "priceAt(uint256)", uint256(0), abi.encode(uint256(0.1 ether)), "wrong opening price"
        );
        _rejects(
            address(deployed.nft),
            "priceAt(uint256)",
            uint256(0),
            abi.encode(uint256(0.001 ether)),
            "wrong opening price"
        );
        _rejects(
            address(deployed.nft),
            "priceAt(uint256)",
            uint256(9999),
            abi.encode(uint256(0.06 ether)),
            "wrong closing price"
        );
        _rejects(
            address(deployed.nft),
            "priceAt(uint256)",
            uint256(9999),
            abi.encode(uint256(0.03 ether)),
            "wrong closing price"
        );
        _rejects(address(deployed.nft), "TIER_SIZE()", abi.encode(uint256(2000)), "wrong tier size");
        _rejects(address(deployed.nft), "TIER_SIZE()", abi.encode(uint256(2501)), "wrong tier size");
    }

    /*//////////////////////////////////////////////////////////////
                            THE CONSTRUCTOR PINS
    //////////////////////////////////////////////////////////////*/

    /// The three data contracts in every possible arrangement. Exactly one of the
    /// twenty seven is the collection, and each of the other twenty six is
    /// refused by the first pin it reaches: a trait chunk in the other chunk's
    /// slot by that slot's hash, and a contract asked for a hash it has no
    /// function for by the call itself, which carries no data. A reordered or
    /// dropped pin hands at least one arrangement to a different check.
    function test_onlyOneArrangementOfTheDataContractsDeploys() public {
        address[3] memory slot = [address(chunk0), address(chunk1), address(names)];
        uint256 accepted;

        for (uint256 a = 0; a < 3; ++a) {
            for (uint256 b = 0; b < 3; ++b) {
                for (uint256 c = 0; c < 3; ++c) {
                    bool real = a == 0 && b == 1 && c == 2;
                    string memory which = _arrangement(a, b, c);

                    try this.deployWith(slot[a], slot[b], slot[c], address(treasury), SALE_START_ENV) returns (
                        GlamToon
                    ) {
                        assertTrue(real, string.concat("accepted ", which));
                        ++accepted;
                    } catch (bytes memory err) {
                        assertFalse(real, "the real arrangement was refused");
                        assertEq(err, _firstPinToRefuse(a, b), string.concat("the wrong check refused ", which));
                    }
                }
            }
        }

        assertEq(accepted, 1, "the real arrangement did not deploy");
    }

    /// Swapping the halves is the arrangement a human actually produces, and it
    /// has to be the pin that catches it rather than a later read happening to
    /// go wrong.
    function test_theChunksInTheWrongOrderNameTheirOwnError() public {
        vm.expectRevert(GlamToon.BadTraitData.selector);
        this.deployWith(address(chunk1), address(chunk0), address(names), address(treasury), SALE_START_ENV);
    }

    /// A trait chunk in the name slot fails on the call, not on the hash: it has
    /// no namesHash to answer with, so there is nothing to compare. That is what
    /// the empty returndata means, and it is the reason BadTraitNames only ever
    /// fires for a contract that answers the right shape with the wrong bytes.
    function test_aChunkInTheNameSlotFailsBeforeTheHashIsEverCompared() public {
        try this.deployWith(
            address(chunk0), address(chunk1), address(chunk0), address(treasury), SALE_START_ENV
        ) returns (
            GlamToon
        ) {
            fail();
        } catch (bytes memory err) {
            assertEq(err.length, 0, "the name slot failed on a comparison, not on the missing function");
        }
    }

    /// A payee of zero burns every sale, and a payee of the token itself strands
    /// the takings inside a contract with no way to move them. Both are one
    /// mistyped line in the environment and both are permanent.
    function test_aPayeeThatCannotBePaidIsRefused() public {
        vm.expectRevert(GlamToon.InvalidPayout.selector);
        this.deployWith(address(chunk0), address(chunk1), address(names), address(0), SALE_START_ENV);

        vm.expectRevert(GlamToon.InvalidPayout.selector);
        this.deployPayingItself(address(chunk0), address(chunk1), address(names), SALE_START_ENV);
    }

    /// The deployed contract is the address the payee check compares against, so
    /// the prediction the case above relies on has to be the real one.
    function test_theSelfPayoutCaseIsAimedAtTheRightAddress() public {
        (GlamToon g, address predicted) =
            this.deployPredicted(address(chunk0), address(chunk1), address(names), SALE_START_ENV);
        assertEq(address(g), predicted, "the predicted address was not where the token landed");
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

    /// What the constructor refuses an arrangement with, given the contracts in
    /// the two chunk slots. Its pins run chunk zero, chunk one, then the name
    /// table. A trait chunk in the other chunk's slot answers with the wrong
    /// hash, and a contract asked for a hash it has no function for fails with
    /// no data.
    function _firstPinToRefuse(uint256 a, uint256 b) internal pure returns (bytes memory) {
        if (a != 0) return a == 1 ? abi.encodeWithSelector(GlamToon.BadTraitData.selector) : bytes("");
        if (b != 1) return b == 0 ? abi.encodeWithSelector(GlamToon.BadTraitData.selector) : bytes("");
        return bytes("");
    }

    /// An arrangement spelled out, so a failure says which one it was.
    function _arrangement(uint256 a, uint256 b, uint256 c) internal pure returns (string memory) {
        string[3] memory label = ["chunk0", "chunk1", "names"];
        return string.concat(label[a], " ", label[b], " ", label[c]);
    }

    /// A string of `len` bytes.
    function _text(uint256 len) internal pure returns (string memory) {
        bytes memory b = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            b[i] = "x";
        }
        return string(b);
    }

    function _deployForProbe() internal {
        vm.chainId(ANVIL);
        deployed = script.run();
    }

    /// Run a script handed these inputs and require it to refuse with this.
    function _refusesInTurn(address owner, address payee, uint256 start, bytes memory why) internal {
        DeployInTurn handed = new DeployInTurn(owner, payee, start);
        vm.expectRevert(why);
        handed.run();
    }

    /// Answer one call in the deployment with a lie and require the script to
    /// name it. The mock is cleared afterwards so the next case starts honest.
    function _rejects(address target, string memory signature, bytes memory answer, string memory why) internal {
        vm.mockCall(target, abi.encodeWithSignature(signature), answer);
        vm.expectRevert(bytes(why));
        probe.check(deployed, OWNER_SAFE, PAYEE, SALE_START_ENV);
        vm.clearMockedCalls();
    }

    /// The same, for a call whose argument decides which require it lands on.
    function _rejects(address target, string memory signature, uint256 arg, bytes memory answer, string memory why)
        internal
    {
        vm.mockCall(target, abi.encodeWithSignature(signature, arg), answer);
        vm.expectRevert(bytes(why));
        probe.check(deployed, OWNER_SAFE, PAYEE, SALE_START_ENV);
        vm.clearMockedCalls();
    }
}

/// The script signed by a plain wallet the test names, with each plain wallet
/// flag set or not, without touching the process environment every other test
/// contract shares.
contract DeploySignedBy is Deploy {
    address private immutable SIGNER;
    bool private immutable EOA_OWNER;
    bool private immutable EOA_BENEFICIARY;

    constructor(address signer, bool eoaOwner, bool eoaBeneficiary) {
        SIGNER = signer;
        EOA_OWNER = eoaOwner;
        EOA_BENEFICIARY = eoaBeneficiary;
    }

    function _signer() internal view override returns (address) {
        return SIGNER;
    }

    function _allowEoaTreasuryOwner() internal view override returns (bool) {
        return EOA_OWNER;
    }

    function _allowEoaBeneficiary() internal view override returns (bool) {
        return EOA_BENEFICIARY;
    }
}

/// The script as the runbook runs it with a plain wallet: the treasury owner
/// written to the environment signs, and both plain wallet flags are set.
contract DeployEoaAllowed is DeploySignedBy {
    constructor() DeploySignedBy(address(0xA11CE), true, true) {}
}

/// The script reading ALLOW_EOA_TREASURY_OWNER for itself, signed by the owner
/// and with the beneficiary allowed, so that flag alone decides the run.
contract DeployReadingOwnerFlag is Deploy {
    function _signer() internal pure override returns (address) {
        return address(0xA11CE);
    }

    function _allowEoaBeneficiary() internal pure override returns (bool) {
        return true;
    }
}

/// The script reading ALLOW_EOA_BENEFICIARY for itself, signed by the owner with
/// the owner allowed, so that flag alone decides the run.
contract DeployReadingBeneficiaryFlag is Deploy {
    function _signer() internal pure override returns (address) {
        return address(0xA11CE);
    }

    function _allowEoaTreasuryOwner() internal pure override returns (bool) {
        return true;
    }
}

/// The script with ALLOW_EOA_TREASURY_OWNER unset, whatever the shell running
/// the tests has exported.
contract DeployEoaRefused is Deploy {
    function _allowEoaTreasuryOwner() internal pure override returns (bool) {
        return false;
    }
}

/// _assertWiring on a deployment the test supplies, so each of its requires can
/// be driven to failure one at a time.
contract WiringProbe is Deploy {
    function check(Deployed memory d, address treasuryOwner, address beneficiary, uint64 saleStart) external view {
        _assertWiring(d, treasuryOwner, beneficiary, saleStart);
    }
}

/// The script handed its three inputs instead of reading them, so a test can
/// present values no other test may see in the shared environment.
contract DeployWithInputs is Deploy {
    address private immutable TREASURY_OWNER;
    address private immutable BENEFICIARY;
    uint256 private immutable SALE_START_SECONDS;

    constructor(address treasuryOwner, address beneficiary, uint256 saleStartSeconds) {
        TREASURY_OWNER = treasuryOwner;
        BENEFICIARY = beneficiary;
        SALE_START_SECONDS = saleStartSeconds;
    }

    function _inputs() internal view override returns (address, address, uint256) {
        return (TREASURY_OWNER, BENEFICIARY, SALE_START_SECONDS);
    }
}

/// The script handed its inputs, with the override off and the art guards
/// reduced to a report that they were reached, so each guard in run() can be
/// met in turn.
contract DeployInTurn is DeployWithInputs {
    error ArtGuardsReached();

    constructor(address treasuryOwner, address beneficiary, uint256 saleStartSeconds)
        DeployWithInputs(treasuryOwner, beneficiary, saleStartSeconds)
    {}

    function _assertArt(string memory, string memory, uint256, string memory) internal pure override {
        // run() always arrives with calldata, so this always reverts. A bare
        // revert would have the compiler flag the rest of run() as unreachable.
        if (msg.data.length > 0) revert ArtGuardsReached();
    }

    function _allowEoaTreasuryOwner() internal pure override returns (bool) {
        return false;
    }
}

/// One plain wallet that signs, owns the treasury and takes the sweeps, with
/// only the owner flag set.
contract DeployToTheSigner is DeployWithInputs {
    address private immutable ME;

    constructor(address me, uint256 saleStartSeconds) DeployWithInputs(me, me, saleStartSeconds) {
        ME = me;
    }

    function _signer() internal view override returns (address) {
        return ME;
    }

    function _allowEoaTreasuryOwner() internal pure override returns (bool) {
        return true;
    }

    function _allowEoaBeneficiary() internal pure override returns (bool) {
        return false;
    }
}

/// Hands whatever it receives straight back to the sender.
contract Bouncer {
    receive() external payable {
        (bool ok,) = msg.sender.call{value: msg.value}("");
        require(ok, "bounce failed");
    }
}

/// Owns the treasury and is its beneficiary, and points the treasury elsewhere
/// as soon as it is paid.
contract Retargeter {
    receive() external payable {
        Treasury(payable(msg.sender)).setBeneficiary(address(0xD00D));
    }
}
