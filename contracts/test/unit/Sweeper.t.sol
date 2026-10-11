// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {GlamToon} from "../../src/GlamToon.sol";
import {ReentrancyGuardTransient} from "openzeppelin/utils/ReentrancyGuardTransient.sol";

/// A wallet that moves the token on the moment it arrives. Since EIP-7702 a
/// plain wallet can carry code like this, and on mainnet many well known
/// addresses already do: the delegate takes delivery, forwards whatever it
/// receives, and answers the hook. The sale has to survive that, because the
/// buyer looks like an ordinary address right up to the moment it does not.
contract SweeperTest is BaseTest {
    function test_aBuyerThatForwardsTheTokenInItsHookStillBuys() public {
        Sweeper wallet = new Sweeper(nft, carol);
        vm.deal(address(wallet), 1 ether);

        wallet.buy(1, _price());

        assertEq(nft.ownerOf(1), carol, "the token was forwarded");
        assertEq(nft.blueMinted(), 1, "the sale counted once");
        assertTrue(nft.blueTaken(1), "and the character is gone");
    }

    function test_aGiftToSuchAWalletAlsoSettles() public {
        Sweeper wallet = new Sweeper(nft, carol);
        uint256 price = _price();

        vm.prank(alice);
        nft.mintBlueFor{value: price}(address(wallet), 2, price);

        assertEq(nft.ownerOf(2), carol, "forwarded on arrival");
        assertEq(nft.blueMinted(), 1, "one sale");
    }

    /// The same wallet taking a green, where the hook fires inside a function
    /// that is also the one the reentrancy guard protects.
    function test_suchAWalletCanStillTakeAGreen() public {
        Sweeper wallet = new Sweeper(nft, carol);

        wallet.takeGreen(3);

        assertEq(nft.greenCount(3), 1, "a generation was taken");
        assertTrue(nft.greenTaken(3, address(wallet)), "the slot is spent by the minter");
        assertEq(nft.ownerOf(nft.tokenIdFor(3, 1)), carol, "and the token moved on");
    }

    /// Forwarding is fine. Re-entering the mint is not, whichever door it uses.
    /// The wallet reaches once, pays in full, and asks for a character or a
    /// green slot nobody holds, so the lock is the only thing that can refuse it.
    function test_aWalletThatMintsAgainInsideItsHookIsRefused() public {
        // Read the price first. Asking for it inside the call would be the call
        // expectRevert is watching.
        uint256 price = _price();

        for (uint256 door = 0; door < 3; ++door) {
            Greedy wallet = new Greedy(nft, Greedy.Door(door));
            vm.deal(address(wallet), 1 ether);

            vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
            wallet.buy(4, price);
        }

        assertEq(nft.blueMinted(), 0, "nothing sold");
        assertFalse(nft.blueTaken(9999), "the character it reached for is still for sale");
        assertEq(nft.greenCount(4), 0, "and no green was taken");
    }
}

/// Takes delivery, forwards, answers the hook.
contract Sweeper {
    GlamToon immutable nft;
    address immutable sink;

    constructor(GlamToon n, address s) {
        nft = n;
        sink = s;
    }

    function buy(uint256 imageId, uint256 price) external {
        nft.mintBlue{value: price}(imageId, price);
    }

    function takeGreen(uint256 imageId) external {
        nft.mintGreen(imageId);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        nft.transferFrom(address(this), sink, tokenId);
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/// Mints again from inside the hook rather than forwarding, through one of the
/// three mint doors: character 9999 through either blue door, or a green of the
/// token it was handed. It reaches once.
contract Greedy {
    enum Door {
        Blue,
        Gift,
        Green
    }

    GlamToon immutable NFT;
    Door immutable DOOR;
    bool reached;

    constructor(GlamToon n, Door door) {
        NFT = n;
        DOOR = door;
    }

    function buy(uint256 imageId, uint256 price) external {
        NFT.mintBlue{value: price}(imageId, price);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (!reached) {
            reached = true;
            if (DOOR == Door.Blue) NFT.mintBlue{value: 0.01 ether}(9999, 1 ether);
            else if (DOOR == Door.Gift) NFT.mintBlueFor{value: 0.01 ether}(address(this), 9999, 1 ether);
            else NFT.mintGreen(tokenId);
        }
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
