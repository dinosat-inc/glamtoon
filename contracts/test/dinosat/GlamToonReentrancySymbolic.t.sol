// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {ReentrancyGuardTransient} from "openzeppelin/utils/ReentrancyGuardTransient.sol";
import {MintReenterer, RefundReenterer, RejectsETH, NotAReceiver} from "../mocks/Attackers.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, the two places it hands control away
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonReentrancySymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonReentrancySymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev A mint calls into untrusted code twice: the receiver hook inside
///      _safeMint, and the refund of the buyer's change. These drive the
///      project's own attacker contracts through both, for every character
///      and amount, and prove the re-entry is refused by the lock and that the
///      refused transaction leaves nothing behind.
contract GlamToonReentrancySymbolicTest is DinoSatBase {
    MintReenterer internal hookAttacker;
    RefundReenterer internal refundAttacker;
    RejectsETH internal noChange;
    NotAReceiver internal noHook;

    function setUp() public override {
        super.setUp();
        hookAttacker = new MintReenterer(nft);
        refundAttacker = new RefundReenterer(nft);
        noChange = new RejectsETH(nft);
        noHook = new NotAReceiver(nft);
    }

    // ════════════════════════════════════════════════
    //  NFT-4: re-entry through the receiver hook
    // ════════════════════════════════════════════════

    /// @notice NFT-4: a receiver that asks for a second green from inside its
    ///         hook is refused by the lock, the whole mint reverts, and no
    ///         generation or claim is spent on either character.
    /// @dev Technique: T16 stateful, with a contract as the minter.
    /// @dev Classification: DIRECT
    function test_check_green_reentry_from_the_hook_is_refused(uint256 imageId, uint256 otherId) public {
        // Justification: mintGreen reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:272)
        vm.assume(imageId < N && otherId < N);
        // Justification: asking for the same character again is stopped by the claim; this is about the lock
        vm.assume(imageId != otherId);
        _hookReentryGreen(imageId, otherId);
    }

    /// @notice Fuzz wrapper for test_check_green_reentry_from_the_hook_is_refused
    /// @dev See T17 in test-templates.md
    function test_fuzz_green_reentry_from_the_hook_is_refused(uint256 rawImage, uint256 rawOther) public {
        uint256 imageId = bound(rawImage, 0, N - 1);
        uint256 otherId = bound(rawOther, 0, N - 1);
        if (imageId == otherId) return;
        _hookReentryGreen(imageId, otherId);
    }

    function _hookReentryGreen(uint256 imageId, uint256 otherId) private {
        (bool ok, bytes memory answer) =
            address(hookAttacker).call(abi.encodeCall(hookAttacker.attackGreen, (imageId, otherId)));

        assert(!ok);
        assert(_is(answer, ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));
        assert(nft.greenMinted() == 0);
        assert(nft.greenCount(imageId) == 0);
        assert(nft.greenCount(otherId) == 0);
        assert(!nft.greenTaken(imageId, address(hookAttacker)));
        assert(!nft.greenTaken(otherId, address(hookAttacker)));
    }

    /// @notice NFT-4: the same re-entry from inside a blue sale is refused,
    ///         the sale reverts, and the payment comes back in full.
    /// @dev Technique: T16 stateful, with a contract as the buyer.
    /// @dev Classification: DIRECT
    function test_check_green_reentry_from_a_blue_sale_is_refused(uint256 imageId, uint256 otherId) public {
        // Justification: mintBlue and mintGreen revert with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N && otherId < N);
        _hookReentryBlue(imageId, otherId);
    }

    /// @notice Fuzz wrapper for test_check_green_reentry_from_a_blue_sale_is_refused
    /// @dev See T17 in test-templates.md
    function test_fuzz_green_reentry_from_a_blue_sale_is_refused(uint256 rawImage, uint256 rawOther) public {
        _hookReentryBlue(bound(rawImage, 0, N - 1), bound(rawOther, 0, N - 1));
    }

    function _hookReentryBlue(uint256 imageId, uint256 otherId) private {
        vm.deal(address(this), STEP);

        (bool ok, bytes memory answer) =
            address(hookAttacker).call{value: STEP}(abi.encodeCall(hookAttacker.attackBlue, (imageId, STEP, otherId)));

        assert(!ok);
        assert(_is(answer, ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));
        assert(nft.blueMinted() == 0);
        assert(nft.greenMinted() == 0);
        assert(!nft.blueTaken(imageId));
        assert(address(nft).balance == 0);
        assert(address(this).balance == STEP);
    }

    // ════════════════════════════════════════════════
    //  NFT-4: re-entry through the refund
    // ════════════════════════════════════════════════

    /// @notice NFT-4: a buyer that calls withdraw from inside its refund is
    ///         refused by the lock. The sale reverts, nothing reaches the
    ///         treasury early, and the payment comes back in full.
    /// @dev Technique: T16 stateful, with a contract as the buyer.
    /// @dev Classification: DIRECT
    function test_check_withdraw_reentry_from_the_refund_is_refused(uint256 imageId, uint256 change) public {
        // Justification: mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: the refund only runs when more than the price was sent; 2**128 wei is more than exists
        vm.assume(change >= 1 && change <= MAX_ETHER);
        _refundReentry(imageId, change);
    }

    /// @notice Fuzz wrapper for test_check_withdraw_reentry_from_the_refund_is_refused
    /// @dev See T17 in test-templates.md
    function test_fuzz_withdraw_reentry_from_the_refund_is_refused(uint256 rawImage, uint256 rawChange) public {
        _refundReentry(bound(rawImage, 0, N - 1), bound(rawChange, 1, MAX_ETHER));
    }

    function _refundReentry(uint256 imageId, uint256 change) private {
        uint256 sent = STEP + change;
        vm.deal(address(this), sent);

        (bool ok,) =
            address(refundAttacker).call{value: sent}(abi.encodeCall(refundAttacker.attack, (imageId, sent, STEP)));

        assert(!ok);
        assert(nft.blueMinted() == 0);
        assert(!nft.blueTaken(imageId));
        assert(address(nft).balance == 0);
        assert(address(treasury).balance == 0);
        assert(address(this).balance == sent);
    }

    // ════════════════════════════════════════════════
    //  PD-1: a buyer that cannot take its change
    // ════════════════════════════════════════════════

    /// @notice PD-1: a buyer whose contract refuses ether completes a sale
    ///         exactly when it sent the exact price. Sent more, the sale
    ///         reverts cleanly and the contract never keeps change it could
    ///         not return.
    /// @dev Technique: T14 conservation, both sides asserted.
    /// @dev Classification: DIRECT
    function test_check_unreturnable_change_refuses_the_sale(uint256 imageId, uint256 change) public {
        // Justification: mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        // Justification: change is ether above the price, and 2**128 wei is more than exists
        vm.assume(change <= MAX_ETHER);
        _unreturnableChange(imageId, change);
    }

    /// @notice Fuzz wrapper for test_check_unreturnable_change_refuses_the_sale
    /// @dev See T17 in test-templates.md
    function test_fuzz_unreturnable_change_refuses_the_sale(uint256 rawImage, uint256 rawChange) public {
        _unreturnableChange(bound(rawImage, 0, N - 1), bound(rawChange, 0, MAX_ETHER));
    }

    function _unreturnableChange(uint256 imageId, uint256 change) private {
        uint256 sent = STEP + change;
        vm.deal(address(this), sent);

        (bool ok,) = address(noChange).call{value: sent}(abi.encodeCall(noChange.mint, (imageId, sent, STEP)));

        assert(ok == (change == 0));
        if (ok) {
            assert(nft.ownerOf(imageId) == address(noChange));
            assert(address(nft).balance == STEP);
        } else {
            assert(nft.blueMinted() == 0);
            assert(address(nft).balance == 0);
            assert(address(this).balance == sent);
        }
    }

    // ════════════════════════════════════════════════
    //  A minter that cannot hold a token
    // ════════════════════════════════════════════════

    /// @notice NFT-4/SM-1: a contract with no receiver hook cannot take a green, and
    ///         trying does not spend its claim or a generation.
    /// @dev Technique: T3 guard, with a contract as the minter.
    /// @dev Classification: DIRECT
    function test_check_minter_without_a_hook_spends_nothing(uint256 imageId) public {
        // Justification: mintGreen reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:272)
        vm.assume(imageId < N);
        _noHookSpendsNothing(imageId);
    }

    /// @notice Fuzz wrapper for test_check_minter_without_a_hook_spends_nothing
    /// @dev See T17 in test-templates.md
    function test_fuzz_minter_without_a_hook_spends_nothing(uint256 rawImage) public {
        _noHookSpendsNothing(bound(rawImage, 0, N - 1));
    }

    function _noHookSpendsNothing(uint256 imageId) private {
        (bool ok,) = address(noHook).call(abi.encodeCall(noHook.mint, (imageId)));

        assert(!ok);
        assert(nft.greenMinted() == 0);
        assert(nft.greenCount(imageId) == 0);
        assert(!nft.greenTaken(imageId, address(noHook)));
    }
}
