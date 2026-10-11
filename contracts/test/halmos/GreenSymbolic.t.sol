// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {GlamToon, ITraitData, ITraitNames} from "../../src/GlamToon.sol";
import {Treasury} from "../../src/Treasury.sol";
import {TraitData0} from "../../src/gen/TraitData0.sol";
import {TraitData1} from "../../src/gen/TraitData1.sol";
import {TraitNames} from "../../src/gen/TraitNames.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {SVM} from "./Svm.sol";

/// Run: FOUNDRY_PROFILE=halmos halmos --contract GreenSymbolicTest --function check_ \
///        --forge-build-out out-halmos --solver-timeout-assertion 240000
///
/// Symbolic only. check_ rather than test_ so forge leaves these alone.
///
/// The free edition, for every character rather than for the handful a fuzzer
/// reached, and the treasury's one privileged setter. Green is the half of the
/// collection anyone can mint for the price of gas, so a way to take two of a
/// character, or a green id that lands on a blue one, is the failure that costs
/// the collection its supply story with no way to correct it.
///
/// Every call is made low level and its outcome asserted, including the ones
/// that are meant to go through. A direct call that reverted would end the path
/// and halmos would drop it, so a mutation that locked green minting altogether
/// would pass a suite written the obvious way.
///
/// Addresses are assumed to carry no code. A recipient with code would hand
/// control to _safeMint's callback, which the concrete reentrancy tests in
/// test/unit already drive with real attacker mocks; here it would only make the
/// solver enumerate every deployed account. The any call proofs are the
/// exception: their caller and arguments are left free.
///
/// The treasury is the token's payee, as the deploy script wires it.
contract GreenSymbolicTest is Test {
    uint256 constant N = 10_000;

    GlamToon internal nft;
    Treasury internal treasury;

    address internal treasuryOwner = address(0x0117E4);
    address internal beneficiary = address(0xB0B);
    uint64 internal constant START = 1000;

    address internal constant TAKER_0 = address(0x1001);
    address internal constant TAKER_1 = address(0x1002);
    address internal constant TAKER_2 = address(0x1003);
    address internal constant TAKER_3 = address(0x1004);

    function setUp() public {
        vm.warp(START);
        treasury = new Treasury(treasuryOwner, beneficiary);
        nft = new GlamToon(
            ITraitData(address(new TraitData0())),
            ITraitData(address(new TraitData1())),
            ITraitNames(address(new TraitNames())),
            address(treasury),
            START
        );
    }

    /*//////////////////////////////////////////////////////////////
                           ONE GREEN PER ADDRESS
    //////////////////////////////////////////////////////////////*/

    /// GN-1: two people want the same character and neither is in the other's
    /// way. They get generation one and generation two, in the order they
    /// arrived, whichever character it is.
    function check_two_addresses_never_block_each_other(uint256 imageId, address a, address b) public {
        vm.assume(imageId < N);
        vm.assume(a != address(0) && b != address(0) && a != b);
        vm.assume(a.code.length == 0 && b.code.length == 0);

        assert(_tryMintGreen(a, imageId));
        assert(_tryMintGreen(b, imageId));

        assert(nft.ownerOf(nft.tokenIdFor(imageId, 1)) == a);
        assert(nft.ownerOf(nft.tokenIdFor(imageId, 2)) == b);
        assert(nft.greenCount(imageId) == 2);
        assert(nft.greenMinted() == 2);
        assert(nft.totalSupply() == 2);
        assert(nft.greenTaken(imageId, a));
        assert(nft.greenTaken(imageId, b));
    }

    /// GN-2: and exactly one each. The second attempt fails and leaves the
    /// counters where they were, so a failed mint cannot burn a generation.
    function check_one_green_each_and_no_more(uint256 imageId, address a, address b) public {
        vm.assume(imageId < N);
        vm.assume(a != address(0) && b != address(0) && a != b);
        vm.assume(a.code.length == 0 && b.code.length == 0);

        assert(_tryMintGreen(a, imageId));
        assert(!_tryMintGreen(a, imageId));

        assert(nft.greenCount(imageId) == 1);
        assert(nft.greenMinted() == 1);

        // the refusal is a's alone: b is still free to take the next generation
        assert(_tryMintGreen(b, imageId));
        assert(nft.ownerOf(nft.tokenIdFor(imageId, 2)) == b);
        assert(nft.greenCount(imageId) == 2);
    }

    /// GN-3: n takers of one character produce generations 1 to n, each to the
    /// address that asked for it, and nothing else exists afterwards. Distinct
    /// ids, each owned, and a supply of exactly n together say no id was handed
    /// out twice.
    ///
    /// n is bounded to four because every extra mint forks the solver on another
    /// _safeMint; the ten thousand deep run is in the unit sweeps. Written out
    /// rather than looped because halmos unrolls a loop two deep by default and
    /// would quietly stop at the second taker.
    function check_n_takers_get_generations_one_to_n(uint256 imageId, uint256 n) public {
        vm.assume(imageId < N);
        vm.assume(n <= 4);

        if (n >= 1) assert(_tryMintGreen(TAKER_0, imageId));
        if (n >= 2) assert(_tryMintGreen(TAKER_1, imageId));
        if (n >= 3) assert(_tryMintGreen(TAKER_2, imageId));
        if (n >= 4) assert(_tryMintGreen(TAKER_3, imageId));

        assert(nft.greenCount(imageId) == n);
        assert(nft.greenMinted() == n);
        assert(nft.totalSupply() == n);

        if (n >= 1) _generationWentTo(imageId, 1, TAKER_0);
        if (n >= 2) _generationWentTo(imageId, 2, TAKER_1);
        if (n >= 3) _generationWentTo(imageId, 3, TAKER_2);
        if (n >= 4) _generationWentTo(imageId, 4, TAKER_3);
    }

    /*//////////////////////////////////////////////////////////////
                          GREEN NEVER TOUCHES BLUE
    //////////////////////////////////////////////////////////////*/

    /// GN-4: a green mint leaves the character's blue untouched and unsold, and
    /// the blue is still there to buy afterwards. Two editions of one character
    /// sharing an id is the collision this rules out on the live path rather than
    /// in the arithmetic alone.
    function check_green_never_occupies_a_blue_id(uint256 imageId, address who) public {
        vm.assume(imageId < N);
        vm.assume(who != address(0) && who.code.length == 0);

        assert(_tryMintGreen(who, imageId));

        uint256 tokenId = nft.tokenIdFor(imageId, 1);
        assert(tokenId >= N);
        assert(!nft.isBlue(tokenId));
        assert(!nft.blueTaken(imageId));
        assert(nft.blueMinted() == 0);
        assert(address(nft).balance == 0);

        address buyer = address(0xA11CE);
        assert(_tryMintBlue(buyer, imageId, 0.01 ether));

        assert(nft.ownerOf(imageId) == buyer);
        assert(nft.ownerOf(tokenId) == who);
        assert(nft.totalSupply() == 2);
    }

    /// GN-5: and no generation at all lands in the blue range, for any character.
    /// Unbounded, unlike PackingSymbolic's round trip: only the multiplication is
    /// in play here, and a generation big enough to overflow it reverts in
    /// tokenIdFor rather than wrapping onto a blue id. The decode side, which is
    /// the division the solver struggles with, is left to PK-1 and its bound.
    function check_no_reachable_generation_is_blue(uint256 imageId, uint256 generation) public view {
        vm.assume(imageId < N);
        vm.assume(generation >= 1);

        uint256 tokenId = nft.tokenIdFor(imageId, generation);

        assert(tokenId >= N);
        assert(!nft.isBlue(tokenId));
    }

    /*//////////////////////////////////////////////////////////////
                              OUT OF RANGE
    //////////////////////////////////////////////////////////////*/

    /// GN-6: asking for a character that does not exist changes nothing at all,
    /// and in particular does not spend the caller's one green of a character
    /// that does.
    function check_out_of_range_green_changes_nothing(uint256 imageId, address who) public {
        vm.assume(imageId >= N);
        vm.assume(who != address(0) && who.code.length == 0);

        assert(_tryMintGreen(who, 7412));
        uint256 supplyBefore = nft.totalSupply();

        assert(!_tryMintGreen(who, imageId));

        assert(nft.totalSupply() == supplyBefore);
        assert(nft.greenMinted() == 1);
        assert(nft.greenCount(imageId) == 0);
        assert(!nft.greenTaken(imageId, who));
        assert(address(nft).balance == 0);

        // the real one it did have is still intact
        assert(nft.greenCount(7412) == 1);
        assert(nft.ownerOf(nft.tokenIdFor(7412, 1)) == who);
    }

    /*//////////////////////////////////////////////////////////////
                          THE CLAIM NEVER LAPSES
    //////////////////////////////////////////////////////////////*/

    /// GN-7: nothing any caller can do clears a green claim, winds a count back,
    /// clears a sold bit or moves the royalty. The call is any state changing
    /// function in the ABI with symbolic arguments, or empty calldata, or a
    /// selector the contract does not have, from anybody, with any value
    /// including none.
    ///
    /// View and pure functions are left out, as createCalldata does by default.
    /// The compiler refuses a state write in either, and halmos cannot build
    /// tokenJSON's strings from a symbolic id.
    function check_no_call_clears_a_green_claim_or_moves_the_royalty(
        uint256 imageId,
        address who,
        address caller,
        uint256 value,
        uint256 tokenId
    ) public {
        vm.assume(imageId < N);
        vm.assume(who != address(0) && who.code.length == 0);

        assert(_tryMintGreen(who, imageId));
        assert(_tryMintBlue(address(0xA11CE), 1, 0.01 ether));
        uint256 sold = nft.blueTakenBits(0, 1)[0];

        _tryAnyCall(address(nft), "GlamToon", caller, value);

        assert(nft.greenTaken(imageId, who));
        assert(nft.greenCount(imageId) >= 1);
        assert(nft.greenMinted() >= 1);
        assert(nft.blueMinted() >= 1);
        assert(nft.blueTakenBits(0, 1)[0] & sold == sold);
        _royaltyGoesToTheTreasury(tokenId);
        assert(!_tryMintGreen(who, imageId));
    }

    /// GN-7b: the same call, kept only where it landed. Some of it has to, or
    /// GN-7 would hold over calls that all bounced. Were every path to revert,
    /// the assume would leave none, and halmos fails a proof with no path left
    /// rather than passing it.
    function check_some_call_lands_and_the_green_claim_still_holds(
        uint256 imageId,
        address who,
        address caller,
        uint256 value
    ) public {
        vm.assume(imageId < N);
        vm.assume(who != address(0) && who.code.length == 0);

        assert(_tryMintGreen(who, imageId));

        vm.assume(_tryAnyCall(address(nft), "GlamToon", caller, value));

        assert(nft.greenTaken(imageId, who));
        assert(!_tryMintGreen(who, imageId));
    }

    /// GN-8: the claim records the mint and not the holding, so giving the token
    /// away does not buy a second one. This is the one people will try.
    function check_sending_the_token_away_does_not_free_the_claim(uint256 imageId, address who, address other) public {
        vm.assume(imageId < N);
        vm.assume(who != address(0) && other != address(0) && who != other);
        vm.assume(who.code.length == 0 && other.code.length == 0);

        assert(_tryMintGreen(who, imageId));
        uint256 tokenId = nft.tokenIdFor(imageId, 1);

        vm.prank(who);
        (bool moved,) = address(nft).call(abi.encodeCall(nft.transferFrom, (who, other, tokenId)));

        assert(moved);
        assert(nft.ownerOf(tokenId) == other);
        assert(nft.greenTaken(imageId, who));
        assert(!_tryMintGreen(who, imageId));
        assert(nft.greenCount(imageId) == 1);
    }

    /*//////////////////////////////////////////////////////////////
                                TREASURY
    //////////////////////////////////////////////////////////////*/

    /// TR-1: a sweep empties the treasury into the beneficiary and reaches
    /// nowhere else, whoever pushed it and whatever had arrived. Anyone may call
    /// it, so the caller keeping none of it is the whole safety of that.
    function check_a_sweep_reaches_only_the_beneficiary(address caller, uint256 amount) public {
        vm.assume(amount > 0 && amount < 2 ** 128);
        vm.assume(caller != beneficiary && caller != address(treasury));
        vm.assume(caller.code.length == 0);

        vm.deal(address(treasury), amount);
        uint256 callerBefore = caller.balance;
        uint256 beneficiaryBefore = beneficiary.balance;

        vm.prank(caller);
        (bool ok,) = address(treasury).call(abi.encodeCall(treasury.sweep, ()));

        assert(ok);
        assert(address(treasury).balance == 0);
        assert(beneficiary.balance == beneficiaryBefore + amount);
        assert(caller.balance == callerBefore);
        assert(treasury.beneficiary() == beneficiary);
    }

    /// TR-1b: the same for a token. Royalties settled in wrapped ether arrive as
    /// a token balance, and sweeping that is just as open, so the whole balance
    /// goes to the beneficiary and none of it to whoever asked.
    function check_a_token_sweep_reaches_only_the_beneficiary(address caller, uint256 amount) public {
        vm.assume(amount > 0);
        vm.assume(caller != beneficiary && caller != address(treasury));

        MockERC20 token = new MockERC20();
        token.mint(address(treasury), amount);

        vm.prank(caller);
        (bool ok,) = address(treasury).call(abi.encodeCall(treasury.sweepToken, (IERC20(address(token)))));

        assert(ok);
        assert(token.balanceOf(address(treasury)) == 0);
        assert(token.balanceOf(beneficiary) == amount);
        assert(token.balanceOf(caller) == 0);
        assert(treasury.beneficiary() == beneficiary);
    }

    /// TR-2: and only the owner says where that is. Every other caller is
    /// refused, for every destination they might name.
    function check_only_the_owner_moves_the_beneficiary(address caller, address to) public {
        vm.assume(caller != treasuryOwner);

        vm.prank(caller);
        (bool ok,) = address(treasury).call(abi.encodeCall(treasury.setBeneficiary, (to)));

        assert(!ok);
        assert(treasury.beneficiary() == beneficiary);

        // and the owner does move it, so the refusal above is about the caller
        // and not about the destination
        vm.assume(to != address(0));
        vm.prank(treasuryOwner);
        (bool byOwner,) = address(treasury).call(abi.encodeCall(treasury.setBeneficiary, (to)));

        assert(byOwner);
        assert(treasury.beneficiary() == to);
    }

    /// TR-3: no call a stranger can make moves the owner, names a pending one or
    /// moves the beneficiary, and so the collection label stays put too.
    /// Sweeping is open to everyone, so what has to hold is that the open door
    /// and the closed one stay separate. The handover is two step, so even a
    /// leaked pending owner would not be enough, and renouncing is refused.
    ///
    /// The call is any state changing function of the treasury with symbolic
    /// arguments, or plain ether, or a selector it does not have, with any
    /// value including none. The treasury holds ether, so a stranger's sweep
    /// really lands. createCalldata leaves out view and pure functions, which
    /// cannot write, and renounceOwnership is pure here.
    function check_no_stranger_moves_owner_or_beneficiary(address caller, uint256 value) public {
        vm.assume(caller != treasuryOwner);
        // address zero has no key, and would otherwise accept a handover nobody offered
        vm.assume(caller != address(0));

        vm.deal(address(treasury), 1 ether);

        _tryAnyCall(address(treasury), "Treasury", caller, value);

        assert(treasury.owner() == treasuryOwner);
        assert(treasury.pendingOwner() == address(0));
        assert(treasury.beneficiary() == beneficiary);
        assert(nft.owner() == treasuryOwner);
    }

    /// TR-3b: the same call, kept only where it landed, so TR-3 cannot pass on
    /// calls that all bounced. Were every path to revert, none would be left
    /// here, and halmos fails a proof with no path left rather than passing it.
    function check_some_stranger_call_lands_and_the_owner_stays(address caller, uint256 value) public {
        vm.assume(caller != treasuryOwner);
        vm.assume(caller != address(0));

        vm.deal(address(treasury), 1 ether);

        vm.assume(_tryAnyCall(address(treasury), "Treasury", caller, value));

        assert(treasury.owner() == treasuryOwner);
        assert(treasury.pendingOwner() == address(0));
        assert(treasury.beneficiary() == beneficiary);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// A green mint whose outcome is a value rather than the end of the path.
    function _tryMintGreen(address who, uint256 imageId) private returns (bool ok) {
        vm.prank(who);
        (ok,) = address(nft).call(abi.encodeCall(nft.mintGreen, (imageId)));
    }

    /// The same for a blue sale, funding the buyer and paying its own ceiling.
    function _tryMintBlue(address who, uint256 imageId, uint256 value) private returns (bool ok) {
        vm.deal(who, value);
        vm.prank(who);
        (ok,) = address(nft).call{value: value}(abi.encodeCall(nft.mintBlue, (imageId, value)));
    }

    /// Any call halmos can build for the named contract, from anybody, funded
    /// with whatever it sends.
    function _tryAnyCall(address target, string memory name, address caller, uint256 value) private returns (bool ok) {
        vm.assume(value < 2 ** 128);
        bytes memory data = SVM.createCalldata(name);
        vm.deal(caller, value);
        vm.prank(caller);
        (ok,) = target.call{value: value}(data);
    }

    /// Two percent to the treasury, for a token that may or may not exist.
    function _royaltyGoesToTheTreasury(uint256 tokenId) private view {
        (address receiver, uint256 amount) = nft.royaltyInfo(tokenId, 10_000);
        assert(receiver == address(treasury));
        assert(amount == 200);
    }

    /// One generation of one character, in the hands of whoever took it.
    function _generationWentTo(uint256 imageId, uint256 generation, address taker) private view {
        uint256 tokenId = nft.tokenIdFor(imageId, generation);
        assert(tokenId == imageId + generation * N);
        assert(!nft.isBlue(tokenId));
        assert(nft.ownerOf(tokenId) == taker);
        assert(nft.greenTaken(imageId, taker));
    }
}
