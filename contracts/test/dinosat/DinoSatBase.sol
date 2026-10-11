// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {GlamToon, ITraitData, ITraitNames} from "../../src/GlamToon.sol";
import {Treasury} from "../../src/Treasury.sol";
import {TraitData0} from "../../src/gen/TraitData0.sol";
import {TraitData1} from "../../src/gen/TraitData1.sol";
import {TraitNames} from "../../src/gen/TraitNames.sol";

/// The system every stateful DinoSAT proof runs against, wired the way
/// script/Deploy.s.sol wires it: two trait chunks, the name table, a treasury,
/// and the token with that treasury as its payee. Building it is entirely
/// concrete, so the solver only reasons about what each property is about.
///
/// Every call a proof is about is made low level and its outcome asserted. A
/// direct call that reverted would end the path, halmos would drop it, and a
/// proof would pass over a function that refused everything.
abstract contract DinoSatBase is Test {
    /// Characters in the collection, which is also the blue supply.
    uint256 internal constant N = 10_000;

    /// Blue sales between price steps, and the size of each step.
    uint256 internal constant TIER = 2500;
    uint256 internal constant STEP = 0.01 ether;

    /// Words in the sold bitmap, 256 characters to a word.
    uint256 internal constant WORDS = 40;

    /// blueMinted's storage slot, as forge inspect reports it for GlamToon.
    uint256 internal constant BLUE_MINTED_SLOT = 8;

    /// The most ether any proof hands out. More than has ever existed, and far
    /// enough below a word that no sum of balances in a proof can wrap.
    uint256 internal constant MAX_ETHER = 2 ** 128 - 1;

    uint64 internal constant START = 1000;

    address internal constant TREASURY_OWNER = address(0x0117E4);
    address internal constant BENEFICIARY = address(0xBE0BE0);
    address internal constant ALICE = address(0xA11CE0);
    address internal constant BOB = address(0xB0B0B0);

    TraitData0 internal chunk0;
    TraitData1 internal chunk1;
    TraitNames internal names;
    Treasury internal treasury;
    GlamToon internal nft;

    function setUp() public virtual {
        vm.warp(START);

        chunk0 = new TraitData0();
        chunk1 = new TraitData1();
        names = new TraitNames();

        treasury = new Treasury(TREASURY_OWNER, BENEFICIARY);
        nft = new GlamToon(
            ITraitData(address(chunk0)),
            ITraitData(address(chunk1)),
            ITraitNames(address(names)),
            address(treasury),
            START
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// An account a proof may use as a caller: one with no code, outside the
    /// precompile range, and not the test harness's own cheat code or console
    /// address. None of those can sign a transaction, and a recipient with code
    /// is the reentrancy suite's business.
    function _isAccount(address a) internal view returns (bool) {
        return uint160(a) > 0xffff && a.code.length == 0 && a != address(vm) && a != CONSOLE;
    }

    /// Start the sale after sold blues without selling its way there. Read
    /// back, so a storage layout that moved fails here rather than proving
    /// things about slot 8 of something else.
    function _setSold(uint256 sold) internal {
        vm.store(address(nft), bytes32(BLUE_MINTED_SLOT), bytes32(sold));
        assert(nft.blueMinted() == sold);
    }

    /// The published schedule, band by band, so the proofs do not share the
    /// contract's arithmetic.
    function _schedule(uint256 sold) internal pure returns (uint256) {
        if (sold < 2500) return 0.01 ether;
        if (sold < 5000) return 0.02 ether;
        if (sold < 7500) return 0.03 ether;
        return 0.04 ether;
    }

    /// A blue sale whose outcome is a value rather than the end of the path.
    /// Funds the buyer with exactly what it sends.
    function _tryMintBlue(address who, uint256 imageId, uint256 sent, uint256 maxPrice)
        internal
        returns (bool ok, bytes memory answer)
    {
        vm.deal(who, sent);
        vm.prank(who);
        (ok, answer) = address(nft).call{value: sent}(abi.encodeCall(nft.mintBlue, (imageId, maxPrice)));
    }

    /// The same for a gift.
    function _tryMintBlueFor(address payer, address to, uint256 imageId, uint256 sent, uint256 maxPrice)
        internal
        returns (bool ok, bytes memory answer)
    {
        vm.deal(payer, sent);
        vm.prank(payer);
        (ok, answer) = address(nft).call{value: sent}(abi.encodeCall(nft.mintBlueFor, (to, imageId, maxPrice)));
    }

    /// The same for a green mint.
    function _tryMintGreen(address who, uint256 imageId) internal returns (bool ok, bytes memory answer) {
        vm.prank(who);
        (ok, answer) = address(nft).call(abi.encodeCall(nft.mintGreen, (imageId)));
    }

    /// Whether a failed call answered with exactly this custom error.
    function _is(bytes memory answer, bytes4 selector) internal pure returns (bool) {
        return answer.length >= 4 && bytes4(answer) == selector;
    }
}
