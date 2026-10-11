// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {GlamToon, ITraitData, ITraitNames} from "../../src/GlamToon.sol";
import {Treasury} from "../../src/Treasury.sol";
import {TraitData0} from "../../src/gen/TraitData0.sol";
import {TraitData1} from "../../src/gen/TraitData1.sol";
import {TraitNames} from "../../src/gen/TraitNames.sol";
import {SVM} from "./Svm.sol";

/// Run: FOUNDRY_PROFILE=halmos halmos --contract MintSymbolicTest --function check_ \
///        --forge-build-out out-halmos --solver-timeout-assertion 240000
///
/// Symbolic only. check_ rather than test_ so forge leaves these alone.
///
/// The money, for every amount rather than for the ones a fuzzer tried. What a
/// buyer is charged, what comes back, and where anything can go.
///
/// Runs against the system as the deploy script wires it, with a real treasury
/// as the payee. Building it is entirely concrete, so the solver only reasons
/// about the arithmetic each property is actually about.
///
/// Every sale or withdraw a proof is about is made low level and its outcome
/// asserted. A direct call that reverted would end the path and halmos would
/// drop it, so a sale that refused some amounts would pass.
contract MintSymbolicTest is Test {
    uint256 constant N = 10_000;

    /// blueMinted's storage slot, as forge inspect reports it for GlamToon.
    uint256 constant BLUE_MINTED_SLOT = 8;

    GlamToon internal nft;
    Treasury internal treasury;
    address internal treasuryOwner = address(0x0117E4);
    address internal beneficiary = address(0xBE0);
    uint64 internal constant START = 1000;

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

    /// PR-1: the price is the published schedule at every point in the sale.
    /// 0.01 for the first 2,500, then 0.02, 0.03 and 0.04, and no price at all
    /// once the ten thousandth has sold.
    function check_the_price_steps_every_2500_sales(uint256 sold) public {
        _setSold(sold);

        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.currentPrice, ()));

        if (sold < N) {
            assert(ok);
            assert(abi.decode(answer, (uint256)) == _schedule(sold));
        } else {
            assert(!ok);
        }
    }

    /// CV-1: a buyer is charged the price of the tier the sale is in and gets
    /// back everything above it, for every amount, every ceiling that allows
    /// the price, every character and every point in the sale. The price is
    /// read off the schedule here rather than asked of the contract, so a tier
    /// that moved would refuse the sale or charge the wrong amount, and a sale
    /// that charged the ceiling would keep too much.
    function check_conservation(uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice) public {
        vm.assume(imageId < N);
        vm.assume(sold < N);
        vm.assume(sent < 2 ** 128);
        _setSold(sold);
        uint256 price = _schedule(sold);
        vm.assume(sent >= price);
        vm.assume(maxPrice >= price);

        address buyer = address(0xA11CE);
        vm.deal(buyer, sent);
        uint256 held = address(nft).balance;

        vm.prank(buyer);
        (bool ok,) = address(nft).call{value: sent}(abi.encodeCall(nft.mintBlue, (imageId, maxPrice)));

        assert(ok);
        assert(address(nft).balance == held + price);
        assert(buyer.balance == sent - price);
        assert(nft.ownerOf(imageId) == buyer);
        assert(nft.blueMinted() == sold + 1);
    }

    /// CV-1b: the same conservation when the payer and the recipient are two
    /// different addresses. The token goes one way and the change the other, for
    /// every amount, every ceiling that allows the price, every character and
    /// every point in the sale.
    function check_gift_conservation(uint256 imageId, uint256 sold, uint256 sent, uint256 maxPrice) public {
        vm.assume(imageId < N);
        vm.assume(sold < N);
        vm.assume(sent < 2 ** 128);
        _setSold(sold);
        uint256 price = _schedule(sold);
        vm.assume(sent >= price);
        vm.assume(maxPrice >= price);

        address payer = address(0xA11CE);
        address recipient = address(0xB0B);
        vm.deal(payer, sent);
        uint256 recipientBefore = recipient.balance;
        uint256 held = address(nft).balance;

        vm.prank(payer);
        (bool ok,) = address(nft).call{value: sent}(abi.encodeCall(nft.mintBlueFor, (recipient, imageId, maxPrice)));

        assert(ok);
        assert(address(nft).balance == held + price);
        assert(payer.balance == sent - price);
        assert(recipient.balance == recipientBefore);
        assert(nft.ownerOf(imageId) == recipient);
        assert(nft.blueMinted() == sold + 1);
    }

    /// AC-1b: a gift cannot mint a character twice either, whoever it is for.
    function check_gift_cannot_take_a_sold_character(address recipient, uint256 sent) public {
        vm.assume(recipient != address(0));
        vm.assume(sent < 2 ** 128);

        address buyer = address(0xA11CE);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        nft.mintBlue{value: 0.01 ether}(1, 0.01 ether);

        address payer = address(0xCA11);
        vm.deal(payer, sent);
        vm.prank(payer);
        (bool ok,) = address(nft).call{value: sent}(
            abi.encodeWithSelector(nft.mintBlueFor.selector, recipient, uint256(1), type(uint256).max)
        );

        assert(!ok);
        assert(nft.ownerOf(1) == buyer);
        assert(nft.blueMinted() == 1);
    }

    /// CV-2: below the price, nothing happens at all.
    function check_underpaying_changes_nothing(uint256 sent) public {
        uint256 price = nft.currentPrice();
        vm.assume(sent < price);

        address buyer = address(0xA11CE);
        vm.deal(buyer, sent);

        vm.prank(buyer);
        (bool ok,) = address(nft).call{value: sent}(abi.encodeWithSelector(nft.mintBlue.selector, uint256(1), price));

        assert(!ok);
        assert(nft.blueMinted() == 0);
        assert(address(nft).balance == 0);
    }

    /// CV-3: the sale settles exactly when the price is within the buyer's
    /// ceiling, for every ceiling. This is what the ceiling is for.
    function check_settles_iff_within_ceiling(uint256 maxPrice) public {
        uint256 price = nft.currentPrice();

        address buyer = address(0xA11CE);
        vm.deal(buyer, 1 ether);

        vm.prank(buyer);
        (bool ok,) =
            address(nft).call{value: price}(abi.encodeWithSelector(nft.mintBlue.selector, uint256(1), maxPrice));

        assert(ok == (maxPrice >= price));
    }

    /// AC-1: a character can only be sold once, to anybody, at any price.
    function check_no_second_sale(address second, uint256 sent) public {
        vm.assume(second != address(0));
        vm.assume(sent < 2 ** 128);

        address buyer = address(0xA11CE);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        nft.mintBlue{value: 0.01 ether}(1, 0.01 ether);

        vm.deal(second, sent);
        vm.prank(second);
        (bool ok,) =
            address(nft).call{value: sent}(abi.encodeWithSelector(nft.mintBlue.selector, uint256(1), type(uint256).max));

        assert(!ok);
        assert(nft.ownerOf(1) == buyer);
        assert(nft.blueMinted() == 1);
    }

    /// AC-2: no character outside the collection can be minted, in either edition.
    function check_out_of_range_never_mints(uint256 imageId) public {
        vm.assume(imageId >= 10_000);

        address buyer = address(0xA11CE);
        vm.deal(buyer, 100 ether);

        vm.prank(buyer);
        (bool paid,) =
            address(nft).call{value: 1 ether}(abi.encodeWithSelector(nft.mintBlue.selector, imageId, type(uint256).max));
        vm.prank(buyer);
        (bool free,) = address(nft).call(abi.encodeWithSelector(nft.mintGreen.selector, imageId));

        assert(!paid);
        assert(!free);
        assert(nft.totalSupply() == 0);
    }

    /// SO-1: once the ten thousandth blue has sold, nothing more sells. No
    /// character, no amount and no ceiling gets a sale through, bought or
    /// given, and no ether stays behind.
    function check_sold_out_refuses_everything(uint256 imageId, uint256 sent, uint256 maxPrice, address to) public {
        vm.assume(sent < 2 ** 128);
        _setSold(N);

        address buyer = address(0xA11CE);
        vm.deal(buyer, 2 * sent);

        vm.prank(buyer);
        (bool bought,) = address(nft).call{value: sent}(abi.encodeCall(nft.mintBlue, (imageId, maxPrice)));
        vm.prank(buyer);
        (bool given,) = address(nft).call{value: sent}(abi.encodeCall(nft.mintBlueFor, (to, imageId, maxPrice)));

        assert(!bought);
        assert(!given);
        assert(nft.blueMinted() == N);
        assert(address(nft).balance == 0);
        assert(buyer.balance == 2 * sent);
    }

    /// SG-1: before the sale opens nothing mints in either edition, for any
    /// character, any amount and any ceiling, and no ether stays behind.
    function check_nothing_mints_before_the_sale_opens(uint256 t, uint256 imageId, uint256 sent, uint256 maxPrice)
        public
    {
        vm.assume(t < START);
        vm.assume(sent < 2 ** 128);
        vm.warp(t);

        address buyer = address(0xA11CE);
        vm.deal(buyer, 2 * sent);

        vm.prank(buyer);
        (bool bought,) = address(nft).call{value: sent}(abi.encodeCall(nft.mintBlue, (imageId, maxPrice)));
        vm.prank(buyer);
        (bool given,) =
            address(nft).call{value: sent}(abi.encodeCall(nft.mintBlueFor, (address(0xB0B), imageId, maxPrice)));
        vm.prank(buyer);
        (bool taken,) = address(nft).call(abi.encodeCall(nft.mintGreen, (imageId)));

        assert(!bought);
        assert(!given);
        assert(!taken);
        assert(nft.totalSupply() == 0);
        assert(address(nft).balance == 0);
    }

    /// BM-1: a sale sets its own character's bit in the sold bitmap and nothing
    /// else. Each word holds 256 characters, so the sold character's word holds
    /// exactly its one bit, and any other of the forty words stays empty.
    function check_a_sale_sets_exactly_its_own_bit(uint256 imageId, uint256 otherWord) public {
        vm.assume(imageId < N);
        vm.assume(otherWord < 40 && otherWord != imageId / 256);

        address buyer = address(0xA11CE);
        vm.deal(buyer, 0.01 ether);
        vm.prank(buyer);
        (bool ok,) = address(nft).call{value: 0.01 ether}(abi.encodeCall(nft.mintBlue, (imageId, 0.01 ether)));

        assert(ok);
        assert(nft.blueTakenBits(imageId / 256, 1)[0] == uint256(1) << (imageId % 256));
        assert(nft.blueTakenBits(otherWord, 1)[0] == 0);
        assert(nft.blueTaken(imageId));
    }

    /// WD-1: whoever calls it, a withdraw empties the contract into the treasury
    /// and reaches nowhere else, for every balance.
    function check_withdraw_only_reaches_the_payee(address caller, uint256 forced) public {
        vm.assume(caller != address(treasury));
        vm.assume(caller != address(nft));
        vm.assume(forced > 0 && forced < 2 ** 128);

        vm.deal(address(nft), forced);
        uint256 callerBefore = caller.balance;
        uint256 payeeBefore = address(treasury).balance;

        vm.prank(caller);
        (bool ok,) = address(nft).call(abi.encodeCall(nft.withdraw, ()));

        assert(ok);
        assert(address(nft).balance == 0);
        assert(address(treasury).balance == payeeBefore + forced);
        assert(caller.balance == callerBefore);
    }

    /// WD-2: ether leaves the contract only for the payee, or as the caller's
    /// own change. Whatever call anybody makes, with any value including none,
    /// the contract, the treasury and the caller hold as much between them
    /// afterwards as before, and the caller never ends up with more than it
    /// had. A withdraw that paid its caller, change sent to somebody else, or
    /// ether sent anywhere at all besides breaks one or the other.
    ///
    /// The call is any state changing function in the ABI with symbolic
    /// arguments, or empty calldata, or a selector the contract does not have.
    /// createCalldata leaves out view and pure functions, which cannot send
    /// ether, and halmos cannot build tokenJSON's strings from a symbolic id.
    function check_ether_leaves_only_for_the_payee_or_as_change(address caller, uint256 value, uint256 held) public {
        vm.assume(caller != address(nft) && caller != address(treasury));
        vm.assume(held < 2 ** 128);
        vm.deal(address(nft), held);

        (uint256 callerBefore, uint256 total) = _fundAndCount(caller, value);

        _tryAnyCall(caller, value);

        assert(caller.balance <= callerBefore);
        assert(address(nft).balance + address(treasury).balance + caller.balance == total);
    }

    /// WD-2b: the same call, kept only where it landed. Some of it has to, or
    /// WD-2 would hold over calls that all bounced. Were every path to revert,
    /// the assume would leave none, and halmos fails a proof with no path left
    /// rather than passing it.
    function check_some_call_lands_and_no_ether_goes_astray(address caller, uint256 value, uint256 held) public {
        vm.assume(caller != address(nft) && caller != address(treasury));
        vm.assume(held < 2 ** 128);
        vm.deal(address(nft), held);

        (uint256 callerBefore, uint256 total) = _fundAndCount(caller, value);

        vm.assume(_tryAnyCall(caller, value));

        assert(caller.balance <= callerBefore);
        assert(address(nft).balance + address(treasury).balance + caller.balance == total);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// Start the sale after sold blues without selling its way there. Read
    /// back, so a storage layout that moved fails here rather than proving
    /// things about slot 8 of something else.
    function _setSold(uint256 sold) private {
        vm.store(address(nft), bytes32(BLUE_MINTED_SLOT), bytes32(sold));
        assert(nft.blueMinted() == sold);
    }

    /// The published schedule, band by band, so the proofs do not share the
    /// contract's arithmetic.
    function _schedule(uint256 sold) private pure returns (uint256) {
        if (sold < 2500) return 0.01 ether;
        if (sold < 5000) return 0.02 ether;
        if (sold < 7500) return 0.03 ether;
        return 0.04 ether;
    }

    /// Give the caller exactly what it will send, then total the ether the
    /// contract, the treasury and the caller hold between them.
    function _fundAndCount(address caller, uint256 value) private returns (uint256 callerBefore, uint256 total) {
        vm.assume(value < 2 ** 128);
        vm.deal(caller, value);
        callerBefore = caller.balance;
        total = address(nft).balance + address(treasury).balance + callerBefore;
    }

    /// Any call halmos can build for the token, from anybody, with any value.
    function _tryAnyCall(address caller, uint256 value) private returns (bool ok) {
        bytes memory data = SVM.createCalldata("GlamToon");
        vm.prank(caller);
        (ok,) = address(nft).call{value: value}(data);
    }
}
