// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {GlamToon} from "../../src/GlamToon.sol";

/// Re-enters once through onERC721Received, the callback _safeMint hands to the
/// recipient in the middle of a mint. It asks for a green of another character
/// it has never minted, so nothing but the lock stands in the way.
contract MintReenterer {
    GlamToon immutable nft;
    uint256 other;
    bool armed;

    constructor(GlamToon n) {
        nft = n;
    }

    function attackBlue(uint256 imageId, uint256 price, uint256 otherId) external payable {
        armed = true;
        other = otherId;
        nft.mintBlue{value: price}(imageId, price);
    }

    function attackGreen(uint256 imageId, uint256 otherId) external {
        armed = true;
        other = otherId;
        nft.mintGreen(imageId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (armed) {
            armed = false;
            nft.mintGreen(other);
        }
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/// Re-enters through the refund, the last thing a genesis mint does.
contract RefundReenterer {
    GlamToon immutable nft;
    bool armed;

    constructor(GlamToon n) {
        nft = n;
    }

    function attack(uint256 imageId, uint256 send, uint256 maxPrice) external payable {
        armed = true;
        nft.mintBlue{value: send}(imageId, maxPrice);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            nft.withdraw();
        }
    }
}

/// Refuses ETH. Used to check that a caller who cannot take a refund gets a clean
/// revert rather than losing the difference.
contract RejectsETH {
    GlamToon immutable nft;

    constructor(GlamToon n) {
        nft = n;
    }

    function mint(uint256 imageId, uint256 send, uint256 maxPrice) external payable {
        nft.mintBlue{value: send}(imageId, maxPrice);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        revert("no thanks");
    }
}

/// Holds no receiver hook at all.
contract NotAReceiver {
    GlamToon immutable nft;

    constructor(GlamToon n) {
        nft = n;
    }

    function mint(uint256 imageId) external {
        nft.mintGreen(imageId);
    }
}
