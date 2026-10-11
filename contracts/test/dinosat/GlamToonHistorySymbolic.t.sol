// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, what no call can undo
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonHistorySymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonHistorySymbolicTest --match-test "test_check_" --no-match-path "test/none/*" --fuzz-runs 100000
/// @dev The collection has no burn, no setter and no owner key, so its history
///      only ever grows. One proof per state changing function in the ABI,
///      each with symbolic arguments, from any caller including the two
///      holders: afterwards the tokens that existed still exist, the sold bit
///      and the green claim are still set, no counter went down, the supply
///      still adds up, and the royalty and the collection label are where
///      they were.
///
///      Before each call Alice holds the blue of character 7 and Bob its first
///      green. No input here is narrowed by a numeric bound, so these have no
///      fuzz wrappers: forge runs the same functions directly.
contract GlamToonHistorySymbolicTest is DinoSatBase {
    function setUp() public override {
        super.setUp();
        (bool bought,) = _tryMintBlue(ALICE, 7, STEP, STEP);
        (bool taken,) = _tryMintGreen(BOB, 7);
        assert(bought && taken);
        vm.deal(ALICE, 0);
    }

    // ════════════════════════════════════════════════
    //  COMPOSITION: no call takes anything out of the collection's history
    //  The domain is the state changing surface of the token, one test each:
    //    mintBlue, mintBlueFor, mintGreen, withdraw,
    //    approve, setApprovalForAll, transferFrom,
    //    safeTransferFrom(3), safeTransferFrom(4),
    //    plain ether with no calldata, and any four byte selector alone.
    //  View and pure functions cannot write: the compiler refuses a store in
    //  either. test/unit pins the compiled ABI to a written list, so a function
    //  added later fails there rather than escaping this list.
    //  Status: 11/11 domain values [PASS].
    // ════════════════════════════════════════════════

    /// @notice AC-3/TOK-1 for mintBlue.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_history_survives_mintBlue(address caller, uint256 imageId, uint256 maxPrice) public {
        _assumeCaller(caller);
        _historySurvives(caller, STEP, abi.encodeCall(nft.mintBlue, (imageId, maxPrice)));
    }

    /// @notice AC-3/TOK-1 for mintBlueFor.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_history_survives_mintBlueFor(address caller, address to, uint256 imageId) public {
        _assumeCaller(caller);
        // Justification: a recipient with code runs a callback, which the reentrancy suite covers;
        // the zero address is left in, as a refusal
        vm.assume(to == address(0) || _isAccount(to));
        _historySurvives(caller, STEP, abi.encodeCall(nft.mintBlueFor, (to, imageId, type(uint256).max)));
    }

    /// @notice AC-3/TOK-1 for mintGreen.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_history_survives_mintGreen(address caller, uint256 imageId) public {
        _assumeCaller(caller);
        _historySurvives(caller, 0, abi.encodeCall(nft.mintGreen, (imageId)));
    }

    /// @notice AC-3/TOK-1 for withdraw.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_history_survives_withdraw(address caller) public {
        _assumeCaller(caller);
        _historySurvives(caller, 0, abi.encodeCall(nft.withdraw, ()));
    }

    /// @notice AC-3/TOK-1 for approve.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_history_survives_approve(address caller, address spender, uint256 tokenId) public {
        _assumeCaller(caller);
        _historySurvives(caller, 0, abi.encodeCall(nft.approve, (spender, tokenId)));
    }

    /// @notice AC-3/TOK-1 for setApprovalForAll.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_history_survives_setApprovalForAll(address caller, address operator, bool approved) public {
        _assumeCaller(caller);
        _historySurvives(caller, 0, abi.encodeCall(nft.setApprovalForAll, (operator, approved)));
    }

    /// @notice AC-3/TOK-1 for transferFrom, from any holder to anywhere.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_history_survives_transferFrom(address caller, address from, address to, uint256 tokenId)
        public
    {
        _assumeCaller(caller);
        _historySurvives(caller, 0, abi.encodeCall(nft.transferFrom, (from, to, tokenId)));
    }

    /// @notice AC-3/TOK-1 for safeTransferFrom without data.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_history_survives_safeTransferFrom(address caller, address from, address to, uint256 tokenId)
        public
    {
        _assumeCaller(caller);
        // Justification: a recipient with code runs a callback, which the reentrancy suite covers;
        // the zero address is left in, as a refusal
        vm.assume(to == address(0) || _isAccount(to));
        _historySurvives(
            caller, 0, abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, tokenId)
        );
    }

    /// @notice AC-3/TOK-1 for safeTransferFrom with data.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_history_survives_safeTransferFromWithData(
        address caller,
        address from,
        address to,
        uint256 tokenId
    ) public {
        _assumeCaller(caller);
        // Justification: a recipient with code runs a callback, which the reentrancy suite covers;
        // the zero address is left in, as a refusal
        vm.assume(to == address(0) || _isAccount(to));
        _historySurvives(
            caller, 0, abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", from, to, tokenId, "")
        );
    }

    /// @notice AC-3/TOK-1 for ether sent with no calldata.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_history_survives_plainEther(address caller) public {
        _assumeCaller(caller);
        _historySurvives(caller, STEP, "");
    }

    /// @notice AC-3/TOK-1 for any four byte selector sent alone.
    /// @dev Technique: T9 concrete enumeration over the ABI.
    /// @dev Classification: ENUMERATE
    function test_check_history_survives_anySelector(address caller, bytes4 selector) public {
        _assumeCaller(caller);
        _historySurvives(caller, 0, abi.encodePacked(selector));
    }

    // ════════════════════════════════════════════════
    //  Helpers
    // ════════════════════════════════════════════════

    /// Any caller that can exist. The zero address has no key, and the token
    /// library skips its authorisation check for it.
    function _assumeCaller(address caller) private view {
        // Justification: a caller signs a transaction, so it is an account (see _isAccount)
        vm.assume(_isAccount(caller));
    }

    /// Make the call whatever its outcome, then check that everything the
    /// collection had recorded is still there.
    function _historySurvives(address caller, uint256 value, bytes memory data) private {
        vm.deal(caller, value);
        vm.prank(caller);
        (bool ok,) = address(nft).call{value: value}(data);
        ok;

        // no counter went down, and none moved by more than the one mint a call can make
        uint256 blue = nft.blueMinted();
        uint256 green = nft.greenMinted();
        assert(blue == 1 || blue == 2);
        assert(green == 1 || green == 2);
        assert(blue + green <= 3);
        assert(nft.totalSupply() == blue + green);
        assert(nft.greenCount(7) >= 1);

        // the sold bit and the claim are still set
        assert(nft.blueTaken(7));
        assert(nft.blueTakenBits(0, 1)[0] & (uint256(1) << 7) != 0);
        assert(nft.greenTaken(7, BOB));

        // both tokens still exist, whoever holds them now
        assert(_exists(7));
        assert(_exists(N + 7));

        // the royalty and the label did not move
        (address receiver, uint256 amount) = nft.royaltyInfo(7, 10_000);
        assert(receiver == address(treasury));
        assert(amount == 200);
        assert(nft.owner() == TREASURY_OWNER);
    }

    /// Whether a token has an owner, without ending the path if it has none.
    function _exists(uint256 tokenId) private view returns (bool) {
        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.ownerOf, (tokenId)));
        return ok && abi.decode(answer, (address)) != address(0);
    }
}
