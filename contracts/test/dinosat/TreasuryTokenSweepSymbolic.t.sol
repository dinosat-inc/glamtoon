// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {Treasury} from "../../src/Treasury.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {NoReturnToken, FalseToken} from "./mocks/OddTokens.sol";
import {DinoSatBase} from "./DinoSatBase.sol";

/// @title DinoSAT Proofs — Treasury, sweeping tokens
/// @notice Halmos: FOUNDRY_PROFILE=dinosat halmos --contract TreasuryTokenSweepSymbolicTest --function "test_check_" --forge-build-out out-dinosat --solver z3 --solver-timeout-assertion 30000
/// @notice Forge:  forge test --match-contract TreasuryTokenSweepSymbolicTest --match-test "test_fuzz_" --no-match-path "test/none/*" --fuzz-runs 1000000
/// @dev Royalties settled in wrapped ether arrive as a token balance, and
///      sweeping that is as open as sweeping ether. The whole balance goes to
///      the beneficiary and none to whoever asked, for a token that follows
///      the standard, one that returns nothing, and one that answers false.
contract TreasuryTokenSweepSymbolicTest is DinoSatBase {
    /// The most tokens any proof mints. Far below a word, so two balances
    /// added together cannot wrap.
    uint256 internal constant MAX_TOKENS = 2 ** 128 - 1;

    MockERC20 internal token;
    NoReturnToken internal quiet;
    FalseToken internal liar;

    function setUp() public override {
        super.setUp();
        token = new MockERC20();
        quiet = new NoReturnToken();
        liar = new FalseToken();
    }

    // ════════════════════════════════════════════════
    //  CC-3: a token sweep reaches the beneficiary and nowhere else
    // ════════════════════════════════════════════════

    /// @notice CC-3: whoever calls it, a token sweep moves the treasury's
    ///         whole balance to the beneficiary and none to the caller.
    /// @dev Technique: T14 conservation, over every caller and balance.
    /// @dev Classification: DIRECT
    function test_check_token_sweep_pays_only_the_beneficiary(address caller, uint256 amount) public {
        // Justification: the beneficiary and the treasury would each count their own balance twice
        vm.assume(caller != BENEFICIARY && caller != address(treasury));
        // Justification: sweepToken reverts with NothingToSweep at zero (Treasury.sol:102); bounded far below a word
        vm.assume(amount >= 1 && amount <= MAX_TOKENS);
        _tokenSweepPays(caller, amount);
    }

    /// @notice Fuzz wrapper for test_check_token_sweep_pays_only_the_beneficiary
    /// @dev See T17 in test-templates.md
    function test_fuzz_token_sweep_pays_only_the_beneficiary(address caller, uint256 rawAmount) public {
        if (caller == BENEFICIARY || caller == address(treasury)) return;
        _tokenSweepPays(caller, bound(rawAmount, 1, MAX_TOKENS));
    }

    function _tokenSweepPays(address caller, uint256 amount) private {
        token.mint(address(treasury), amount);

        vm.prank(caller);
        (bool ok,) = address(treasury).call(abi.encodeCall(treasury.sweepToken, (IERC20(address(token)))));

        assert(ok);
        assert(token.balanceOf(address(treasury)) == 0);
        assert(token.balanceOf(BENEFICIARY) == amount);
        assert(token.balanceOf(caller) == 0);
        assert(token.totalSupply() == amount);
    }

    /// @notice CC-3: after the owner repoints the treasury, a token sweep pays
    ///         the new beneficiary all of it and the old one nothing.
    /// @dev Technique: T14 conservation, across a change of beneficiary.
    /// @dev Classification: DIRECT
    function test_check_token_sweep_follows_a_moved_beneficiary(address next, uint256 amount) public {
        // Justification: setBeneficiary refuses the zero address, and the token refuses it as a recipient
        vm.assume(next != address(0));
        // Justification: the treasury sweeping to itself, or to the same beneficiary, moves nothing to compare
        vm.assume(next != BENEFICIARY && next != address(treasury));
        // Justification: sweepToken reverts with NothingToSweep at zero (Treasury.sol:102); bounded far below a word
        vm.assume(amount >= 1 && amount <= MAX_TOKENS);
        _tokenSweepFollows(next, amount);
    }

    /// @notice Fuzz wrapper for test_check_token_sweep_follows_a_moved_beneficiary
    /// @dev See T17 in test-templates.md
    function test_fuzz_token_sweep_follows_a_moved_beneficiary(address next, uint256 rawAmount) public {
        if (next == address(0) || next == BENEFICIARY || next == address(treasury)) return;
        _tokenSweepFollows(next, bound(rawAmount, 1, MAX_TOKENS));
    }

    function _tokenSweepFollows(address next, uint256 amount) private {
        vm.prank(TREASURY_OWNER);
        (bool moved,) = address(treasury).call(abi.encodeCall(treasury.setBeneficiary, (next)));
        assert(moved);
        token.mint(address(treasury), amount);

        vm.prank(ALICE);
        (bool ok,) = address(treasury).call(abi.encodeCall(treasury.sweepToken, (IERC20(address(token)))));

        assert(ok);
        assert(token.balanceOf(next) == amount);
        assert(token.balanceOf(BENEFICIARY) == 0);
        assert(token.balanceOf(address(treasury)) == 0);
    }

    /// @notice PD-1: sweeping a token leaves the treasury's ether where it
    ///         was, and sweeping ether leaves its tokens where they were.
    /// @dev Technique: T14 conservation, the two sweeps against each other.
    /// @dev Classification: DIRECT
    function test_check_the_two_sweeps_do_not_touch_each_other(uint256 amount, uint256 held) public {
        // Justification: sweepToken reverts with NothingToSweep at zero (Treasury.sol:102); bounded far below a word
        vm.assume(amount >= 1 && amount <= MAX_TOKENS);
        // Justification: sweep reverts with NothingToSweep at zero (Treasury.sol:89); 2**128 wei is more than exists
        vm.assume(held >= 1 && held <= MAX_ETHER);
        _sweepsAreSeparate(amount, held);
    }

    /// @notice Fuzz wrapper for test_check_the_two_sweeps_do_not_touch_each_other
    /// @dev See T17 in test-templates.md
    function test_fuzz_the_two_sweeps_do_not_touch_each_other(uint256 rawAmount, uint256 rawHeld) public {
        _sweepsAreSeparate(bound(rawAmount, 1, MAX_TOKENS), bound(rawHeld, 1, MAX_ETHER));
    }

    function _sweepsAreSeparate(uint256 amount, uint256 held) private {
        token.mint(address(treasury), amount);
        vm.deal(address(treasury), held);
        vm.deal(BENEFICIARY, 0);

        (bool tokensSwept,) = address(treasury).call(abi.encodeCall(treasury.sweepToken, (IERC20(address(token)))));
        assert(tokensSwept);
        assert(address(treasury).balance == held);
        assert(BENEFICIARY.balance == 0);

        token.mint(address(treasury), amount);
        (bool etherSwept,) = address(treasury).call(abi.encodeCall(treasury.sweep, ()));
        assert(etherSwept);
        assert(token.balanceOf(address(treasury)) == amount);
        assert(BENEFICIARY.balance == held);
    }

    // ════════════════════════════════════════════════
    //  The refusals
    // ════════════════════════════════════════════════

    /// @notice PD-1: a treasury that holds none of a token refuses to sweep it with
    ///         NothingToSweep, whoever asks.
    /// @dev Technique: T3 guard, over every caller.
    /// @dev Classification: DIRECT
    function test_check_token_sweep_refuses_when_empty(address caller) public {
        vm.prank(caller);
        (bool ok, bytes memory answer) =
            address(treasury).call(abi.encodeCall(treasury.sweepToken, (IERC20(address(token)))));

        assert(!ok);
        assert(_is(answer, Treasury.NothingToSweep.selector));
    }

    // ════════════════════════════════════════════════
    //  Tokens that do not follow the return convention
    // ════════════════════════════════════════════════

    /// @notice CC-3: a token whose transfer returns nothing, the way USDT's does, is
    ///         swept like any other. Its balance is not left stranded.
    /// @dev Technique: T16 stateful, against a non-standard token.
    /// @dev Classification: DIRECT
    function test_check_token_sweep_handles_a_token_that_returns_nothing(uint256 amount) public {
        // Justification: sweepToken reverts with NothingToSweep at zero (Treasury.sol:102); bounded far below a word
        vm.assume(amount >= 1 && amount <= MAX_TOKENS);
        _sweepsQuietToken(amount);
    }

    /// @notice Fuzz wrapper for test_check_token_sweep_handles_a_token_that_returns_nothing
    /// @dev See T17 in test-templates.md
    function test_fuzz_token_sweep_handles_a_token_that_returns_nothing(uint256 rawAmount) public {
        _sweepsQuietToken(bound(rawAmount, 1, MAX_TOKENS));
    }

    function _sweepsQuietToken(uint256 amount) private {
        quiet.mint(address(treasury), amount);

        (bool ok,) = address(treasury).call(abi.encodeCall(treasury.sweepToken, (IERC20(address(quiet)))));

        assert(ok);
        assert(quiet.balanceOf(address(treasury)) == 0);
        assert(quiet.balanceOf(BENEFICIARY) == amount);
    }

    /// @notice CC-3: a token whose transfer answers false without moving anything
    ///         makes the sweep revert, rather than report tokens as sent that
    ///         are still in the treasury.
    /// @dev Technique: T3 guard, against a non-standard token.
    /// @dev Classification: DIRECT
    function test_check_token_sweep_refuses_a_token_that_answers_false(uint256 amount) public {
        // Justification: sweepToken reverts with NothingToSweep at zero (Treasury.sol:102); bounded far below a word
        vm.assume(amount >= 1 && amount <= MAX_TOKENS);
        _refusesLyingToken(amount);
    }

    /// @notice Fuzz wrapper for test_check_token_sweep_refuses_a_token_that_answers_false
    /// @dev See T17 in test-templates.md
    function test_fuzz_token_sweep_refuses_a_token_that_answers_false(uint256 rawAmount) public {
        _refusesLyingToken(bound(rawAmount, 1, MAX_TOKENS));
    }

    function _refusesLyingToken(uint256 amount) private {
        liar.mint(address(treasury), amount);

        (bool ok,) = address(treasury).call(abi.encodeCall(treasury.sweepToken, (IERC20(address(liar)))));

        assert(!ok);
        assert(liar.balanceOf(address(treasury)) == amount);
        assert(liar.balanceOf(BENEFICIARY) == 0);
    }
}
