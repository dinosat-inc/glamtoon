// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import {Ownable, Ownable2Step} from "openzeppelin/access/Ownable2Step.sol";
import {Address} from "openzeppelin/utils/Address.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Treasury
 * @notice Where the sale proceeds and royalties are paid, and the only contract
 *         in the collection with an owner.
 *         This software is provided as is, without warranty. Use at your own risk.
 * @dev The owner sets the beneficiary, and GlamToon reports this owner as its own.
 *      Anyone may sweep, and a sweep only ever pays the beneficiary.
 */
contract Treasury is Ownable2Step {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error NothingToSweep();
    error CannotRenounce();

    /**
     * @notice The beneficiary was set.
     */
    event BeneficiarySet(address indexed previous, address indexed current);

    /**
     * @notice Ether was sent to the beneficiary.
     */
    event Swept(address indexed to, uint256 amount);

    /**
     * @notice A token balance was sent to the beneficiary.
     */
    event SweptToken(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Ether arrived.
     */
    event Received(address indexed from, uint256 amount);

    /**
     * @notice Where sweeps send the ether and ERC20 tokens held here.
     */
    address public beneficiary;

    /**
     * @notice Deploy the treasury.
     * @param initialOwner Who may change the beneficiary
     * @param initialBeneficiary Where sweeps go until the owner changes it
     */
    constructor(address initialOwner, address initialBeneficiary) Ownable(initialOwner) {
        if (initialOwner == address(0) || initialBeneficiary == address(0)) revert ZeroAddress();
        beneficiary = initialBeneficiary;
        emit BeneficiarySet(address(0), initialBeneficiary);
    }

    /**
     * @notice Receives sale proceeds and ether royalties.
     */
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /**
     * @notice Always reverts. Ownership can be transferred but not renounced.
     */
    function renounceOwnership() public pure override {
        revert CannotRenounce();
    }

    /**
     * @notice Point future sweeps somewhere else.
     * @param to The new beneficiary
     */
    function setBeneficiary(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit BeneficiarySet(beneficiary, to);
        beneficiary = to;
    }

    /**
     * @notice Send every wei held here to the beneficiary. Anyone may call it.
     */
    function sweep() external {
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToSweep();
        address to = beneficiary;
        emit Swept(to, amount);
        Address.sendValue(payable(to), amount);
    }

    /**
     * @notice Send a token balance, such as royalties paid in wrapped ether, to
     *         the beneficiary. Anyone may call it.
     * @param token The token to sweep
     */
    function sweepToken(IERC20 token) external {
        uint256 amount = token.balanceOf(address(this));
        if (amount == 0) revert NothingToSweep();
        address to = beneficiary;
        emit SweptToken(address(token), to, amount);
        token.safeTransfer(to, amount);
    }
}
