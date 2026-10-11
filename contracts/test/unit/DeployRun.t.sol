// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {Exposed, DeployReadingNothing} from "./DeployGuards.t.sol";
import {GlamToon, IPFS_ROOT, ARWEAVE, TOKEN_BASE} from "../../src/GlamToon.sol";
import {TraitSchema} from "../../src/gen/TraitSchema.sol";
import {TraitData0} from "../../src/gen/TraitData0.sol";
import {TraitData1} from "../../src/gen/TraitData1.sol";
import {TraitNames} from "../../src/gen/TraitNames.sol";
import {Treasury} from "../../src/Treasury.sol";

/// The deploy script decides what reaches mainnet and nothing was running it.
/// Its string helpers were covered; run() and _assertWiring were not, so a wrong
/// assertion in either would have been found on launch day.
///
/// setEnv writes the real process environment rather than EVM state, so no test
/// here changes it after setUp. Varying it per test races with the runner and
/// produces failures that look like contract bugs and are not.
contract DeployRunTest is Test {
    Deploy internal script;
    Exposed internal guards = new Exposed();

    address internal constant OWNER_SAFE = address(0xA11CE);
    address internal constant BENEFICIARY = address(0xB0B);

    uint256 internal constant OPTIMISM = 10;
    uint256 internal constant ANVIL = 31_337;

    uint256 internal constant MAX_RUNTIME = 24_576;
    uint256 internal constant MAX_INITCODE = 49_152;

    function setUp() public {
        script = new Deploy();
        vm.setEnv("TREASURY_OWNER", vm.toString(OWNER_SAFE));
        vm.setEnv("BENEFICIARY", vm.toString(BENEFICIARY));
        vm.setEnv("SALE_START", vm.toString(block.timestamp + 1 days));
    }

    /// The whole script end to end, which is the only way _assertWiring runs at
    /// all. A local chain is the one place placeholders are allowed.
    function test_runWiresEverythingOnALocalChain() public {
        vm.chainId(ANVIL);
        Deploy.Deployed memory d = script.run();

        assertEq(d.nft.name(), "Glamtoon", "name");
        assertEq(d.nft.symbol(), "GLAMTOON", "symbol");
        assertEq(d.nft.PAYOUT(), address(d.treasury), "payee");
        assertEq(d.nft.SALE_START(), uint64(block.timestamp + 1 days), "sale start");
        assertEq(d.nft.owner(), OWNER_SAFE, "collection label follows the treasury");
        assertEq(d.treasury.owner(), OWNER_SAFE, "treasury owner");
        assertEq(d.treasury.beneficiary(), BENEFICIARY, "beneficiary");
        assertEq(address(d.nft.CHUNK0()), address(d.chunk0), "chunk 0");
        assertEq(address(d.nft.NAMES()), address(d.names), "names");
        assertEq(address(d.treasury).balance, 0, "the wei did not reach the beneficiary");

        (address receiver, uint256 amount) = d.nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, address(d.treasury), "royalty receiver");
        assertEq(amount, 0.02 ether, "royalty rate");
    }

    /// On OP Mainnet run() hands the compiled art, the real row count and the
    /// token base to the art guards, after the balance floor and before the Safe
    /// guard. Anvil never reaches them. DeployGuards drives each guard to
    /// its own message, and this is what makes those guards part of the run.
    function test_aRealChainRunsTheArtGuardsOnTheCompiledValues() public {
        DeployWatchingArt watched = new DeployWatchingArt();
        bytes memory handed = abi.encodeWithSelector(
            DeployWatchingArt.ArtGuardsReached.selector, IPFS_ROOT, ARWEAVE, TraitSchema.REAL_ROWS, TOKEN_BASE
        );

        vm.chainId(OPTIMISM);
        vm.expectRevert(handed);
        watched.run();

        vm.deal(address(this), 0.01 ether);
        vm.expectRevert(bytes("deployer underfunded"));
        watched.run();

        vm.chainId(ANVIL);
        Deploy.Deployed memory d = watched.run();
        assertEq(d.nft.ipfsRoot(), IPFS_ROOT, "anvil stopped at the art guards");
    }

    /// Every contract the script deploys fits the limits OP enforces: 24,576
    /// bytes of runtime and 49,152 bytes of initcode, constructor arguments
    /// included. The test runner enforces neither, so a contract that outgrew
    /// them would pass everything else here and fail on the day.
    function test_everyContractTheScriptDeploysFitsUnderTheSizeLimits() public {
        // The coverage build is larger than the one that ships, so the limits
        // say nothing there.
        vm.skip(vm.isContext(VmSafe.ForgeContext.Coverage));

        vm.chainId(ANVIL);
        Deploy.Deployed memory d = script.run();

        assertLe(address(d.chunk0).code.length, MAX_RUNTIME, "chunk 0 runtime");
        assertLe(address(d.chunk1).code.length, MAX_RUNTIME, "chunk 1 runtime");
        assertLe(address(d.names).code.length, MAX_RUNTIME, "name table runtime");
        assertLe(address(d.treasury).code.length, MAX_RUNTIME, "treasury runtime");
        assertLe(address(d.nft).code.length, MAX_RUNTIME, "token runtime");

        assertLe(type(TraitData0).creationCode.length, MAX_INITCODE, "chunk 0 initcode");
        assertLe(type(TraitData1).creationCode.length, MAX_INITCODE, "chunk 1 initcode");
        assertLe(type(TraitNames).creationCode.length, MAX_INITCODE, "name table initcode");
        assertLe(type(Treasury).creationCode.length + 2 * 32, MAX_INITCODE, "treasury initcode");
        assertLe(type(GlamToon).creationCode.length + 5 * 32, MAX_INITCODE, "token initcode");
    }

    /// A plain wallet can own the treasury on OP Mainnet when it is asked for,
    /// and the two step handover moves it to a Safe later without touching the
    /// token.
    function test_aPlainWalletMayOwnTheTreasuryOnOpMainnet() public {
        vm.skip(guards.hasPlaceholder(IPFS_ROOT));

        DeployAllowingEoa allowed = new DeployAllowingEoa();
        vm.chainId(OPTIMISM);
        vm.deal(address(allowed), 2 ether);
        vm.deal(OWNER_SAFE, 1 ether);

        Deploy.Deployed memory d = allowed.run();

        assertEq(d.treasury.owner(), OWNER_SAFE, "treasury owner");
        assertEq(OWNER_SAFE.code.length, 0, "a plain wallet owns it");
        assertEq(d.nft.owner(), OWNER_SAFE, "and the label follows it");

        address safe = address(new Treasury(address(0xF00D), address(0xF00D)));
        vm.prank(OWNER_SAFE);
        d.treasury.transferOwnership(safe);
        vm.prank(safe);
        d.treasury.acceptOwnership();

        assertEq(d.treasury.owner(), safe, "handed on after deployment");
        assertEq(d.nft.owner(), safe, "the label came with it");
    }

    /// The chain guard runs before anything is read or deployed. This script
    /// fails if it ever reads its inputs, so the chain message can only come
    /// from a guard that runs first.
    function test_wrongChainIsRefused() public {
        DeployReadingNothing blind = new DeployReadingNothing();
        vm.chainId(999);
        vm.expectRevert(bytes("wrong chain, this collection deploys to OP Mainnet"));
        blind.run();
    }

    /// Ethereum mainnet is not on the list. The collection lives on OP, and a
    /// chain id that used to be allowed is now the likeliest way to deploy to
    /// the wrong one.
    function test_ethereumMainnetIsRefused() public {
        vm.chainId(1);
        vm.expectRevert(bytes("wrong chain, this collection deploys to OP Mainnet"));
        script.run();
    }

    /// REAL_ROWS is the one number standing between filler and a mainnet deploy,
    /// and it is generated rather than typed. This pins it to the provenance file
    /// the generator read it from, so editing either alone is caught, whatever
    /// state the table is in.
    function test_traitProvenanceMatchesTheFixture() public view {
        uint256 recorded = vm.parseJsonUint(vm.readFile("test/fixtures/traits.provenance.json"), ".realRows");
        assertEq(TraitSchema.REAL_ROWS, recorded, "REAL_ROWS does not match traits.provenance.json");
        assertLe(TraitSchema.REAL_ROWS, TraitSchema.IMAGE_COUNT, "more real rows than characters");
    }

    /// A beneficiary that forwards what it receives still took delivery, so the
    /// deploy script asserts the treasury emptied rather than the beneficiary
    /// gaining. With a splitter as the beneficiary the run goes through and the
    /// proof wei ends up downstream of it.
    function test_aForwardingBeneficiaryTakesDelivery() public {
        vm.etch(BENEFICIARY, address(new Forwarder()).code);
        address sink = Forwarder(payable(BENEFICIARY)).sink();
        uint256 before = sink.balance;

        vm.chainId(ANVIL);
        Deploy.Deployed memory d = script.run();

        assertEq(address(d.treasury).balance, 0, "treasury did not empty, which is what deploy asserts");
        assertEq(BENEFICIARY.balance, 0, "forwarder kept what it should have passed on");
        assertEq(sink.balance, before + 1, "the wei did not arrive downstream");
    }
}

/// The script as the runbook runs it with a plain wallet: the treasury owner
/// signs, and ALLOW_EOA_TREASURY_OWNER and ALLOW_EOA_BENEFICIARY are set,
/// without writing the environment the other tests read.
contract DeployAllowingEoa is Deploy {
    function _signer() internal pure override returns (address) {
        return address(0xA11CE);
    }

    function _allowEoaTreasuryOwner() internal pure override returns (bool) {
        return true;
    }

    function _allowEoaBeneficiary() internal pure override returns (bool) {
        return true;
    }
}

/// The script with its art guards swapped for a report of what they were
/// handed, so a test can see when run() calls them and with what.
contract DeployWatchingArt is Deploy {
    error ArtGuardsReached(string ipfsRoot, string arweave, uint256 realRows, string tokenBase);

    function _assertArt(string memory ipfsRoot, string memory arweave, uint256 realRows, string memory tokenBase)
        internal
        pure
        override
    {
        // run() always arrives with calldata, so this always reverts. A bare
        // revert would have the compiler flag the rest of run() as unreachable.
        if (msg.data.length > 0) revert ArtGuardsReached(ipfsRoot, arweave, realRows, tokenBase);
    }
}

/// A splitter or auto sweeper: takes delivery, keeps nothing.
contract Forwarder {
    address public immutable sink = address(0xDEAD5);

    receive() external payable {
        (bool ok,) = sink.call{value: msg.value}("");
        require(ok, "forward failed");
    }
}
