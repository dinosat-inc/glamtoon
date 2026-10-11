// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, where ether can go
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonEtherFlowSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonEtherFlowSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev Ether leaves the token only for the treasury, or as the caller's own
///      change. One proof per state changing function in the ABI, each with
///      symbolic arguments, from any account, with any value attached and any
///      balance already held. After the call the token, the treasury and the
///      caller hold as much between them as before, and the caller holds no
///      more than it had. A withdraw that paid its caller, change sent to
///      somebody else, or ether sent anywhere besides breaks one or the other.
///
///      Before each call a blue and a green of character 7 exist, so the
///      transfer and approval functions have something real to act on when the
///      caller is their owner.
contract GlamToonEtherFlowSymbolicTest is DinoSatBase {
    function setUp() public override {
        super.setUp();
        (bool bought,) = _tryMintBlue(ALICE, 7, STEP, STEP);
        (bool taken,) = _tryMintGreen(BOB, 7);
        assert(bought && taken);
    }

    // ════════════════════════════════════════════════
    //  COMPOSITION: no call moves ether anywhere but to the payee or back to its caller
    //  The domain is the state changing surface of the token, one test each:
    //    mintBlue, mintBlueFor, mintGreen, withdraw,
    //    approve, setApprovalForAll, transferFrom,
    //    safeTransferFrom(3), safeTransferFrom(4),
    //    plain ether with no calldata, and any four byte selector alone.
    //  View and pure functions cannot send ether: the compiler refuses a call
    //  with value in either. test/unit pins the compiled ABI to a written list,
    //  so a function added later fails there rather than escaping this list.
    //  Status: 11/11 domain values [PASS].
    // ════════════════════════════════════════════════

    /// @notice PD-1/CC-3 for mintBlue.
    /// @dev Technique: T9 concrete enumeration over the ABI, T14 conservation.
    /// @dev Classification: ENUMERATE
    function test_check_ether_stays_put_mintBlue(
        address caller,
        uint256 value,
        uint256 held,
        uint256 imageId,
        uint256 maxPrice
    ) public {
        _assumeFlow(caller, value, held);
        _etherStaysPut(caller, value, held, abi.encodeCall(nft.mintBlue, (imageId, maxPrice)));
    }

    /// @notice Fuzz wrapper for test_check_ether_stays_put_mintBlue
    /// @dev See T17 in test-templates.md
    function test_fuzz_ether_stays_put_mintBlue(
        address caller,
        uint256 rawValue,
        uint256 rawHeld,
        uint256 imageId,
        uint256 maxPrice
    ) public {
        if (!_isAccount(caller)) return;
        _etherStaysPut(
            caller,
            bound(rawValue, 0, MAX_ETHER),
            bound(rawHeld, 0, MAX_ETHER),
            abi.encodeCall(nft.mintBlue, (imageId, maxPrice))
        );
    }

    /// @notice PD-1/CC-3 for mintBlueFor.
    /// @dev Technique: T9 concrete enumeration over the ABI, T14 conservation.
    /// @dev Classification: ENUMERATE
    function test_check_ether_stays_put_mintBlueFor(
        address caller,
        uint256 value,
        uint256 held,
        address to,
        uint256 imageId
    ) public {
        _assumeFlow(caller, value, held);
        // Justification: a recipient with code runs a callback, which the reentrancy suite covers;
        // the zero address is left in, as a refusal
        vm.assume(to == address(0) || _isAccount(to));
        _etherStaysPut(caller, value, held, abi.encodeCall(nft.mintBlueFor, (to, imageId, type(uint256).max)));
    }

    /// @notice Fuzz wrapper for test_check_ether_stays_put_mintBlueFor
    /// @dev See T17 in test-templates.md
    function test_fuzz_ether_stays_put_mintBlueFor(
        address caller,
        uint256 rawValue,
        uint256 rawHeld,
        address to,
        uint256 imageId
    ) public {
        if (!_isAccount(caller)) return;
        if (to != address(0) && !_isAccount(to)) return;
        _etherStaysPut(
            caller,
            bound(rawValue, 0, MAX_ETHER),
            bound(rawHeld, 0, MAX_ETHER),
            abi.encodeCall(nft.mintBlueFor, (to, imageId, type(uint256).max))
        );
    }

    /// @notice PD-1/CC-3 for mintGreen.
    /// @dev Technique: T9 concrete enumeration over the ABI, T14 conservation.
    /// @dev Classification: ENUMERATE
    function test_check_ether_stays_put_mintGreen(address caller, uint256 value, uint256 held, uint256 imageId) public {
        _assumeFlow(caller, value, held);
        _etherStaysPut(caller, value, held, abi.encodeCall(nft.mintGreen, (imageId)));
    }

    /// @notice Fuzz wrapper for test_check_ether_stays_put_mintGreen
    /// @dev See T17 in test-templates.md
    function test_fuzz_ether_stays_put_mintGreen(address caller, uint256 rawValue, uint256 rawHeld, uint256 imageId)
        public
    {
        if (!_isAccount(caller)) return;
        _etherStaysPut(
            caller,
            bound(rawValue, 0, MAX_ETHER),
            bound(rawHeld, 0, MAX_ETHER),
            abi.encodeCall(nft.mintGreen, (imageId))
        );
    }

    /// @notice PD-1/CC-3 for withdraw.
    /// @dev Technique: T9 concrete enumeration over the ABI, T14 conservation.
    /// @dev Classification: ENUMERATE
    function test_check_ether_stays_put_withdraw(address caller, uint256 value, uint256 held) public {
        _assumeFlow(caller, value, held);
        _etherStaysPut(caller, value, held, abi.encodeCall(nft.withdraw, ()));
    }

    /// @notice Fuzz wrapper for test_check_ether_stays_put_withdraw
    /// @dev See T17 in test-templates.md
    function test_fuzz_ether_stays_put_withdraw(address caller, uint256 rawValue, uint256 rawHeld) public {
        if (!_isAccount(caller)) return;
        _etherStaysPut(
            caller, bound(rawValue, 0, MAX_ETHER), bound(rawHeld, 0, MAX_ETHER), abi.encodeCall(nft.withdraw, ())
        );
    }

    /// @notice PD-1/CC-3 for approve.
    /// @dev Technique: T9 concrete enumeration over the ABI, T14 conservation.
    /// @dev Classification: ENUMERATE
    function test_check_ether_stays_put_approve(
        address caller,
        uint256 value,
        uint256 held,
        address spender,
        uint256 tokenId
    ) public {
        _assumeFlow(caller, value, held);
        _etherStaysPut(caller, value, held, abi.encodeCall(nft.approve, (spender, tokenId)));
    }

    /// @notice Fuzz wrapper for test_check_ether_stays_put_approve
    /// @dev See T17 in test-templates.md
    function test_fuzz_ether_stays_put_approve(
        address caller,
        uint256 rawValue,
        uint256 rawHeld,
        address spender,
        uint256 tokenId
    ) public {
        if (!_isAccount(caller)) return;
        _etherStaysPut(
            caller,
            bound(rawValue, 0, MAX_ETHER),
            bound(rawHeld, 0, MAX_ETHER),
            abi.encodeCall(nft.approve, (spender, tokenId))
        );
    }

    /// @notice PD-1/CC-3 for setApprovalForAll.
    /// @dev Technique: T9 concrete enumeration over the ABI, T14 conservation.
    /// @dev Classification: ENUMERATE
    function test_check_ether_stays_put_setApprovalForAll(
        address caller,
        uint256 value,
        uint256 held,
        address operator,
        bool approved
    ) public {
        _assumeFlow(caller, value, held);
        _etherStaysPut(caller, value, held, abi.encodeCall(nft.setApprovalForAll, (operator, approved)));
    }

    /// @notice Fuzz wrapper for test_check_ether_stays_put_setApprovalForAll
    /// @dev See T17 in test-templates.md
    function test_fuzz_ether_stays_put_setApprovalForAll(
        address caller,
        uint256 rawValue,
        uint256 rawHeld,
        address operator,
        bool approved
    ) public {
        if (!_isAccount(caller)) return;
        _etherStaysPut(
            caller,
            bound(rawValue, 0, MAX_ETHER),
            bound(rawHeld, 0, MAX_ETHER),
            abi.encodeCall(nft.setApprovalForAll, (operator, approved))
        );
    }

    /// @notice PD-1/CC-3 for transferFrom.
    /// @dev Technique: T9 concrete enumeration over the ABI, T14 conservation.
    /// @dev Classification: ENUMERATE
    function test_check_ether_stays_put_transferFrom(
        address caller,
        uint256 value,
        uint256 held,
        address to,
        uint256 tokenId
    ) public {
        _assumeFlow(caller, value, held);
        _etherStaysPut(caller, value, held, abi.encodeCall(nft.transferFrom, (caller, to, tokenId)));
    }

    /// @notice Fuzz wrapper for test_check_ether_stays_put_transferFrom
    /// @dev See T17 in test-templates.md
    function test_fuzz_ether_stays_put_transferFrom(
        address caller,
        uint256 rawValue,
        uint256 rawHeld,
        address to,
        uint256 tokenId
    ) public {
        if (!_isAccount(caller)) return;
        _etherStaysPut(
            caller,
            bound(rawValue, 0, MAX_ETHER),
            bound(rawHeld, 0, MAX_ETHER),
            abi.encodeCall(nft.transferFrom, (caller, to, tokenId))
        );
    }

    /// @notice PD-1/CC-3 for safeTransferFrom without data.
    /// @dev Technique: T9 concrete enumeration over the ABI, T14 conservation.
    /// @dev Classification: ENUMERATE
    function test_check_ether_stays_put_safeTransferFrom(
        address caller,
        uint256 value,
        uint256 held,
        address to,
        uint256 tokenId
    ) public {
        _assumeFlow(caller, value, held);
        // Justification: a recipient with code runs a callback, which the reentrancy suite covers;
        // the zero address is left in, as a refusal
        vm.assume(to == address(0) || _isAccount(to));
        _etherStaysPut(caller, value, held, _safeTransfer(caller, to, tokenId));
    }

    /// @notice Fuzz wrapper for test_check_ether_stays_put_safeTransferFrom
    /// @dev See T17 in test-templates.md
    function test_fuzz_ether_stays_put_safeTransferFrom(
        address caller,
        uint256 rawValue,
        uint256 rawHeld,
        address to,
        uint256 tokenId
    ) public {
        if (!_isAccount(caller)) return;
        if (to != address(0) && !_isAccount(to)) return;
        _etherStaysPut(
            caller, bound(rawValue, 0, MAX_ETHER), bound(rawHeld, 0, MAX_ETHER), _safeTransfer(caller, to, tokenId)
        );
    }

    /// @notice PD-1/CC-3 for safeTransferFrom with data.
    /// @dev Technique: T9 concrete enumeration over the ABI, T14 conservation.
    /// @dev Classification: ENUMERATE
    function test_check_ether_stays_put_safeTransferFromWithData(
        address caller,
        uint256 value,
        uint256 held,
        address to,
        uint256 tokenId
    ) public {
        _assumeFlow(caller, value, held);
        // Justification: a recipient with code runs a callback, which the reentrancy suite covers;
        // the zero address is left in, as a refusal
        vm.assume(to == address(0) || _isAccount(to));
        _etherStaysPut(caller, value, held, _safeTransferWithData(caller, to, tokenId));
    }

    /// @notice Fuzz wrapper for test_check_ether_stays_put_safeTransferFromWithData
    /// @dev See T17 in test-templates.md
    function test_fuzz_ether_stays_put_safeTransferFromWithData(
        address caller,
        uint256 rawValue,
        uint256 rawHeld,
        address to,
        uint256 tokenId
    ) public {
        if (!_isAccount(caller)) return;
        if (to != address(0) && !_isAccount(to)) return;
        _etherStaysPut(
            caller,
            bound(rawValue, 0, MAX_ETHER),
            bound(rawHeld, 0, MAX_ETHER),
            _safeTransferWithData(caller, to, tokenId)
        );
    }

    /// @notice PD-1/CC-3 for ether sent with no calldata. The token has no
    ///         receive and no fallback, so this has to bounce.
    /// @dev Technique: T9 concrete enumeration over the ABI, T14 conservation.
    /// @dev Classification: ENUMERATE
    function test_check_ether_stays_put_plainEther(address caller, uint256 value, uint256 held) public {
        _assumeFlow(caller, value, held);
        _etherStaysPut(caller, value, held, "");
        assert(address(nft).balance == held);
    }

    /// @notice Fuzz wrapper for test_check_ether_stays_put_plainEther
    /// @dev See T17 in test-templates.md
    function test_fuzz_ether_stays_put_plainEther(address caller, uint256 rawValue, uint256 rawHeld) public {
        if (!_isAccount(caller)) return;
        uint256 held = bound(rawHeld, 0, MAX_ETHER);
        _etherStaysPut(caller, bound(rawValue, 0, MAX_ETHER), held, "");
        assert(address(nft).balance == held);
    }

    /// @notice PD-1/CC-3 for any four byte selector sent alone: every function
    ///         that takes no argument, view or not, and every selector the
    ///         contract does not have.
    /// @dev Technique: T9 concrete enumeration over the ABI, T14 conservation.
    /// @dev Classification: ENUMERATE
    function test_check_ether_stays_put_anySelector(address caller, uint256 value, uint256 held, bytes4 selector)
        public
    {
        _assumeFlow(caller, value, held);
        _etherStaysPut(caller, value, held, abi.encodePacked(selector));
    }

    /// @notice Fuzz wrapper for test_check_ether_stays_put_anySelector
    /// @dev See T17 in test-templates.md
    function test_fuzz_ether_stays_put_anySelector(address caller, uint256 rawValue, uint256 rawHeld, bytes4 selector)
        public
    {
        if (!_isAccount(caller)) return;
        _etherStaysPut(caller, bound(rawValue, 0, MAX_ETHER), bound(rawHeld, 0, MAX_ETHER), abi.encodePacked(selector));
    }

    // ════════════════════════════════════════════════
    //  Helpers
    // ════════════════════════════════════════════════

    /// The domain every proof here shares.
    function _assumeFlow(address caller, uint256 value, uint256 held) private view {
        // Justification: a caller signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(caller));
        // Justification: msg.value is ether, and 2**128 wei is more than exists
        vm.assume(value <= MAX_ETHER);
        // Justification: the contract's balance is ether, and 2**128 wei is more than exists
        vm.assume(held <= MAX_ETHER);
    }

    /// Give the token and the caller their balances, make the call whatever
    /// its outcome, and check where the ether is afterwards.
    function _etherStaysPut(address caller, uint256 value, uint256 held, bytes memory data) private {
        vm.deal(address(nft), held);
        vm.deal(caller, value);
        uint256 total = held + address(treasury).balance + value;

        vm.prank(caller);
        (bool ok,) = address(nft).call{value: value}(data);
        ok;

        assert(caller.balance <= value);
        assert(address(nft).balance + address(treasury).balance + caller.balance == total);
    }

    /// The two safeTransferFrom overloads, which abi.encodeCall cannot tell apart.
    function _safeTransfer(address from, address to, uint256 tokenId) private pure returns (bytes memory) {
        return abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, tokenId);
    }

    function _safeTransferWithData(address from, address to, uint256 tokenId) private pure returns (bytes memory) {
        return abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", from, to, tokenId, "");
    }
}
