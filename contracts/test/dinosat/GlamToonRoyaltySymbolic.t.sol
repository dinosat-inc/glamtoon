// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — GlamToon, the royalty the contract reports
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract GlamToonRoyaltySymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract GlamToonRoyaltySymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev royaltyInfo on the deployed contract: two percent of any price, to the
///      treasury, for every token id whether it exists or not, with no
///      function that can change it. RoyaltyLemmasTest proves the arithmetic.
contract GlamToonRoyaltySymbolicTest is DinoSatBase {
    /// The highest sale price the proofs range over: a billion ether.
    uint256 internal constant MAX_PRICE = 1e27;

    // ════════════════════════════════════════════════
    //  PD-3 / CC-3: two percent, to the treasury
    // ════════════════════════════════════════════════

    /// @notice PD-3/CC-3: the royalty on any sale is the price times two
    ///         hundred over ten thousand, and its receiver is the treasury,
    ///         for every token id.
    /// @dev Technique: T16 stateful. The expected amount is the same
    ///      expression RoyaltyLemmasTest reasons about.
    /// @dev Classification: DIRECT
    function test_check_royalty_is_two_percent_to_the_treasury(uint256 tokenId, uint256 salePrice) public view {
        // Justification: a sale price in wei; 1e27 is a billion ether, more than exists
        vm.assume(salePrice <= MAX_PRICE);
        _twoPercent(tokenId, salePrice);
    }

    /// @notice Fuzz wrapper for test_check_royalty_is_two_percent_to_the_treasury
    /// @dev See T17 in test-templates.md
    function test_fuzz_royalty_is_two_percent_to_the_treasury(uint256 tokenId, uint256 rawPrice) public view {
        _twoPercent(tokenId, bound(rawPrice, 0, MAX_PRICE));
    }

    function _twoPercent(uint256 tokenId, uint256 salePrice) private view {
        (address receiver, uint256 amount) = nft.royaltyInfo(tokenId, salePrice);
        assert(receiver == address(treasury));
        assert(amount == (salePrice * 200) / 10_000);
    }

    /// @notice PD-3: the royalty does not depend on the token. Blue or green,
    ///         minted or not, two ids at one price answer the same.
    /// @dev Technique: T16 stateful, two symbolic ids against each other.
    /// @dev Classification: DIRECT
    function test_check_royalty_is_the_same_for_every_token(uint256 tokenA, uint256 tokenB, uint256 salePrice)
        public
        view
    {
        // Justification: a sale price in wei; 1e27 is a billion ether, more than exists
        vm.assume(salePrice <= MAX_PRICE);
        _sameForAll(tokenA, tokenB, salePrice);
    }

    /// @notice Fuzz wrapper for test_check_royalty_is_the_same_for_every_token
    /// @dev See T17 in test-templates.md
    function test_fuzz_royalty_is_the_same_for_every_token(uint256 tokenA, uint256 tokenB, uint256 rawPrice)
        public
        view
    {
        _sameForAll(tokenA, tokenB, bound(rawPrice, 0, MAX_PRICE));
    }

    function _sameForAll(uint256 tokenA, uint256 tokenB, uint256 salePrice) private view {
        (address receiverA, uint256 amountA) = nft.royaltyInfo(tokenA, salePrice);
        (address receiverB, uint256 amountB) = nft.royaltyInfo(tokenB, salePrice);
        assert(receiverA == receiverB);
        assert(amountA == amountB);
    }

    /// @notice AC-3: minting, selling and withdrawing leave the royalty where
    ///         the constructor set it.
    /// @dev Technique: T16 stateful, across a sale, a green mint and a withdraw.
    /// @dev Classification: DIRECT
    function test_check_royalty_is_untouched_by_the_sale(uint256 imageId, uint256 tokenId) public {
        // Justification: _mintBlue reverts with InvalidImageId unless imageId < IMAGE_COUNT (GlamToon.sol:243)
        vm.assume(imageId < N);
        _untouched(imageId, tokenId);
    }

    /// @notice Fuzz wrapper for test_check_royalty_is_untouched_by_the_sale
    /// @dev See T17 in test-templates.md
    function test_fuzz_royalty_is_untouched_by_the_sale(uint256 rawImage, uint256 tokenId) public {
        _untouched(bound(rawImage, 0, N - 1), tokenId);
    }

    function _untouched(uint256 imageId, uint256 tokenId) private {
        (bool bought,) = _tryMintBlue(ALICE, imageId, STEP, STEP);
        (bool taken,) = _tryMintGreen(BOB, imageId);
        (bool withdrawn,) = address(nft).call(abi.encodeCall(nft.withdraw, ()));
        assert(bought && taken && withdrawn);

        (address receiver, uint256 amount) = nft.royaltyInfo(tokenId, 10_000);
        assert(receiver == address(treasury));
        assert(amount == 200);
    }

    // ════════════════════════════════════════════════
    //  The interfaces the contract answers to
    // ════════════════════════════════════════════════

    /// @notice NFT-5: supportsInterface is true for ERC-165, ERC-721, ERC-721 metadata
    ///         and ERC-2981, and false for every other four bytes.
    /// @dev Technique: T2, over every interface id.
    /// @dev Classification: DIRECT
    function test_check_supported_interfaces_are_exactly_four(bytes4 interfaceId) public view {
        bool expected = interfaceId == 0x01ffc9a7 // ERC-165
            || interfaceId == 0x80ac58cd // ERC-721
            || interfaceId == 0x5b5e139f // ERC-721 metadata
            || interfaceId == 0x2a55205a; // ERC-2981
        assert(nft.supportsInterface(interfaceId) == expected);
    }

    // ════════════════════════════════════════════════
    //  AS-1: the product inside royaltyInfo
    //  The library's overflow check divides by the symbolic price, which is
    //  the solver's hard case. Both were classified for fuzzing before the
    //  run and keep their fuzz wrappers, and the solver proved both: the
    //  second within the usual timeout, the first only with it doubled.
    // ════════════════════════════════════════════════

    /// @notice AS-1: royaltyInfo answers, rather than reverts, for every price
    ///         up to a billion ether and every token id, and the royalty is
    ///         never more than the price.
    /// @dev Technique: T2 constant bound. Needs --solver-timeout-assertion
    ///      60000: the solver takes about 36 seconds and times out at 30.
    /// @dev Classification: DIRECT
    function test_check_royalty_always_answers_in_range(uint256 tokenId, uint256 salePrice) public view {
        // Justification: a sale price in wei; 1e27 is a billion ether, more than exists
        vm.assume(salePrice <= MAX_PRICE);
        _alwaysAnswers(tokenId, salePrice);
    }

    /// @notice Fuzz wrapper for test_check_royalty_always_answers_in_range
    /// @dev See T17 in test-templates.md
    function test_fuzz_royalty_always_answers_in_range(uint256 tokenId, uint256 rawPrice) public view {
        _alwaysAnswers(tokenId, bound(rawPrice, 0, MAX_PRICE));
    }

    function _alwaysAnswers(uint256 tokenId, uint256 salePrice) private view {
        (bool ok, bytes memory answer) = address(nft).staticcall(abi.encodeCall(nft.royaltyInfo, (tokenId, salePrice)));
        assert(ok);
        (, uint256 amount) = abi.decode(answer, (address, uint256));
        assert(amount <= salePrice);
    }

    /// @notice AS-1: a price so large that two hundred times it would not fit
    ///         a word is refused. The product never wraps into a small royalty.
    /// @dev Technique: T2 constant bound.
    /// @dev Classification: DIRECT
    function test_check_royalty_refuses_a_price_that_would_overflow(uint256 tokenId, uint256 salePrice) public view {
        // Justification: the branch under test, salePrice * 200 past uint256.max
        vm.assume(salePrice > type(uint256).max / 200);
        _refusesOverflow(tokenId, salePrice);
    }

    /// @notice Fuzz wrapper for test_check_royalty_refuses_a_price_that_would_overflow
    /// @dev See T17 in test-templates.md
    function test_fuzz_royalty_refuses_a_price_that_would_overflow(uint256 tokenId, uint256 rawPrice) public view {
        _refusesOverflow(tokenId, bound(rawPrice, type(uint256).max / 200 + 1, type(uint256).max));
    }

    function _refusesOverflow(uint256 tokenId, uint256 salePrice) private view {
        (bool ok,) = address(nft).staticcall(abi.encodeCall(nft.royaltyInfo, (tokenId, salePrice)));
        assert(!ok);
    }
}
