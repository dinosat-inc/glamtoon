// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, who may move a token
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonTransferSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonTransferSymbolicTest --match-test "test_check_" --no-match-path "test/none/*" --fuzz-runs 100000
/// @dev The ERC-721 the collection inherits, proved on the deployed contract
///      rather than taken on trust: a token moves only for its owner or
///      somebody its owner approved, an approval moves nothing by itself, and
///      nothing can be sent to nobody, which would be a burn.
///
///      Alice holds the blue of character 7 and Bob its first green. No input
///      here is narrowed by a numeric bound, so these have no fuzz wrappers:
///      forge runs the same functions directly.
///
///      Callers are never the zero address. It has no key, and the token
///      library deliberately skips its authorisation check for it.
contract GlamToonTransferSymbolicTest is DinoSatBase {
    uint256 internal constant BLUE = 7;
    uint256 internal constant GREEN = N + 7;

    function setUp() public override {
        super.setUp();
        (bool bought,) = _tryMintBlue(ALICE, BLUE, STEP, STEP);
        (bool taken,) = _tryMintGreen(BOB, BLUE);
        assert(bought && taken);
    }

    // ════════════════════════════════════════════════
    //  AC-1: a stranger cannot move or approve a token
    // ════════════════════════════════════════════════

    /// @notice AC-1: nobody but its owner can move a token, to anywhere, by
    ///         either transfer function.
    /// @dev Technique: T3 guard, over every caller and destination.
    /// @dev Classification: DIRECT
    function test_check_stranger_cannot_move_a_token(address stranger, address to) public {
        // Justification: msg.sender is never the zero address, which has no key
        vm.assume(stranger != address(0));
        // Justification: Alice is the owner; the property is about everybody else
        vm.assume(stranger != ALICE);

        vm.prank(stranger);
        (bool plain,) = address(nft).call(abi.encodeCall(nft.transferFrom, (ALICE, to, BLUE)));
        vm.prank(stranger);
        (bool safe,) =
            address(nft).call(abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", ALICE, to, BLUE));

        assert(!plain);
        assert(!safe);
        assert(nft.ownerOf(BLUE) == ALICE);
        assert(nft.balanceOf(ALICE) == 1);
    }

    /// @notice AC-1: the one caller the owner check lets through is the zero
    ///         address. For every caller but the owner, a transfer goes through
    ///         exactly when that caller is address zero. Nobody holds its key,
    ///         so nobody can be that caller; this pins the assumption every
    ///         other proof here makes, and shows it is the only one needed.
    /// @dev Technique: T3 guard, both sides of the check asserted.
    /// @dev Classification: DIRECT
    function test_check_only_the_zero_address_escapes_the_owner_check(address stranger, address to) public {
        // Justification: Alice is the owner; the property is about everybody else
        vm.assume(stranger != ALICE);
        // Justification: the zero address as a recipient is a refusal for every caller, proved below
        vm.assume(to != address(0));

        vm.prank(stranger);
        (bool ok,) = address(nft).call(abi.encodeCall(nft.transferFrom, (ALICE, to, BLUE)));

        assert(ok == (stranger == address(0)));
    }

    /// @notice AC-1: nobody but its owner can approve a spender for a token.
    /// @dev Technique: T3 guard, over every caller and spender.
    /// @dev Classification: DIRECT
    function test_check_stranger_cannot_approve(address stranger, address spender) public {
        // Justification: msg.sender is never the zero address, which has no key
        vm.assume(stranger != address(0));
        // Justification: Alice is the owner; the property is about everybody else
        vm.assume(stranger != ALICE);

        vm.prank(stranger);
        (bool ok,) = address(nft).call(abi.encodeCall(nft.approve, (spender, BLUE)));

        assert(!ok);
        assert(nft.getApproved(BLUE) == address(0));
    }

    /// @notice AC-1: naming the wrong owner is refused even by the real one.
    /// @dev Technique: T3 guard.
    /// @dev Classification: DIRECT
    function test_check_wrong_from_is_refused(address from, address to) public {
        // Justification: the branch under test, a from that is not the owner
        vm.assume(from != ALICE);

        vm.prank(ALICE);
        (bool ok,) = address(nft).call(abi.encodeCall(nft.transferFrom, (from, to, BLUE)));

        assert(!ok);
        assert(nft.ownerOf(BLUE) == ALICE);
    }

    /// @notice AC-1: a token that was never minted cannot be moved by anybody.
    /// @dev Technique: T3 guard, over every id but the two that exist.
    /// @dev Classification: DIRECT
    function test_check_unminted_token_cannot_move(address caller, address from, address to, uint256 tokenId) public {
        // Justification: msg.sender is never the zero address, which has no key
        vm.assume(caller != address(0));
        // Justification: these two are the only tokens that exist
        vm.assume(tokenId != BLUE && tokenId != GREEN);

        vm.prank(caller);
        (bool ok,) = address(nft).call(abi.encodeCall(nft.transferFrom, (from, to, tokenId)));

        assert(!ok);
        (bool exists,) = address(nft).staticcall(abi.encodeCall(nft.ownerOf, (tokenId)));
        assert(!exists);
    }

    // ════════════════════════════════════════════════
    //  TOK-2: a transfer moves one token and conserves the rest
    // ════════════════════════════════════════════════

    /// @notice TOK-2: the owner can move its token to any address but the
    ///         zero one. The sender's balance falls by one and the receiver's
    ///         rises by one, and a transfer to oneself changes nothing.
    /// @dev Technique: T14 conservation, over every destination.
    /// @dev Classification: DIRECT
    function test_check_owner_moves_its_token(address to) public {
        // Justification: the zero address is the refusal proved below
        vm.assume(to != address(0));
        uint256 toBefore = nft.balanceOf(to);

        vm.prank(ALICE);
        (bool ok,) = address(nft).call(abi.encodeCall(nft.transferFrom, (ALICE, to, BLUE)));

        assert(ok);
        assert(nft.ownerOf(BLUE) == to);
        if (to == ALICE) {
            assert(nft.balanceOf(ALICE) == 1);
        } else {
            assert(nft.balanceOf(ALICE) == 0);
            assert(nft.balanceOf(to) == toBefore + 1);
        }
    }

    /// @notice TOK-2: a transfer leaves the supply, the counters, the sold bit
    ///         and the green claim as they were.
    /// @dev Technique: T14 conservation.
    /// @dev Classification: DIRECT
    function test_check_transfer_changes_no_supply(address to) public {
        // Justification: the zero address is the refusal proved below
        vm.assume(to != address(0));

        vm.prank(ALICE);
        (bool ok,) = address(nft).call(abi.encodeCall(nft.transferFrom, (ALICE, to, BLUE)));

        assert(ok);
        assert(nft.totalSupply() == 2);
        assert(nft.blueMinted() == 1);
        assert(nft.greenMinted() == 1);
        assert(nft.blueTaken(BLUE));
        assert(nft.greenTaken(BLUE, BOB));
        assert(nft.ownerOf(GREEN) == BOB);
    }

    // ════════════════════════════════════════════════
    //  TOK-4: there is no burn
    // ════════════════════════════════════════════════

    /// @notice TOK-4: a token cannot be sent to the zero address by its owner,
    ///         by either transfer function. With no burn function either, a
    ///         token that exists always will.
    /// @dev Technique: T3 guard, over constants.
    /// @dev Classification: DIRECT
    function test_check_transfer_to_nobody_is_refused() public {
        vm.prank(ALICE);
        (bool plain, bytes memory answer) =
            address(nft).call(abi.encodeCall(nft.transferFrom, (ALICE, address(0), BLUE)));
        vm.prank(ALICE);
        (bool safe,) = address(nft)
            .call(abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", ALICE, address(0), BLUE));

        assert(!plain);
        assert(_is(answer, IERC721Errors.ERC721InvalidReceiver.selector));
        assert(!safe);
        assert(nft.ownerOf(BLUE) == ALICE);
    }

    // ════════════════════════════════════════════════
    //  TOK-5: an approval is not a transfer
    // ════════════════════════════════════════════════

    /// @notice TOK-5: approving a spender records the approval and moves
    ///         nothing.
    /// @dev Technique: T16 stateful, over every spender.
    /// @dev Classification: DIRECT
    function test_check_approval_alone_moves_nothing(address spender) public {
        vm.prank(ALICE);
        (bool ok,) = address(nft).call(abi.encodeCall(nft.approve, (spender, BLUE)));

        assert(ok);
        assert(nft.getApproved(BLUE) == spender);
        assert(nft.ownerOf(BLUE) == ALICE);
        assert(nft.balanceOf(ALICE) == 1);
    }

    /// @notice TOK-5: an approved spender can move the token once. The
    ///         approval is spent by the transfer and does not follow the token
    ///         to its new owner.
    /// @dev Technique: T16 stateful, over every spender and destination.
    /// @dev Classification: DIRECT
    function test_check_approved_spender_moves_it_once(address spender, address to) public {
        // Justification: msg.sender is never the zero address, which has no key
        vm.assume(spender != address(0));
        // Justification: Alice approving herself is the owner's own transfer, proved above
        vm.assume(spender != ALICE);
        // Justification: the zero address is a refusal, and a spender that receives the token owns it
        vm.assume(to != address(0) && to != spender);

        vm.prank(ALICE);
        nft.approve(spender, BLUE);

        vm.prank(spender);
        (bool first,) = address(nft).call(abi.encodeCall(nft.transferFrom, (ALICE, to, BLUE)));
        assert(first);
        assert(nft.ownerOf(BLUE) == to);
        assert(nft.getApproved(BLUE) == address(0));

        vm.prank(spender);
        (bool second,) = address(nft).call(abi.encodeCall(nft.transferFrom, (to, spender, BLUE)));
        assert(!second);
        assert(nft.ownerOf(BLUE) == to);
    }

    /// @notice AC-1: an operator approval covers the tokens of the account
    ///         that granted it and nobody else's.
    /// @dev Technique: T3 guard, over every operator and destination.
    /// @dev Classification: DIRECT
    function test_check_operator_approval_is_scoped_to_its_grantor(address operator, address to) public {
        // Justification: setApprovalForAll refuses the zero address as an operator
        vm.assume(operator != address(0));
        // Justification: Alice moving her own token is not the operator's doing
        vm.assume(operator != ALICE);
        // Justification: the zero address is the refusal proved above
        vm.assume(to != address(0));

        vm.prank(BOB);
        nft.setApprovalForAll(operator, true);
        assert(nft.isApprovedForAll(BOB, operator));
        assert(!nft.isApprovedForAll(ALICE, operator));

        // Bob's operator cannot touch Alice's token
        vm.prank(operator);
        (bool others,) = address(nft).call(abi.encodeCall(nft.transferFrom, (ALICE, to, BLUE)));
        assert(!others);
        assert(nft.ownerOf(BLUE) == ALICE);

        // but it can move Bob's
        vm.prank(operator);
        (bool grantors,) = address(nft).call(abi.encodeCall(nft.transferFrom, (BOB, to, GREEN)));
        assert(grantors);
        assert(nft.ownerOf(GREEN) == to);
    }
}
