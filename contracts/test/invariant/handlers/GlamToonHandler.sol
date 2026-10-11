// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {GlamToon} from "../../../src/GlamToon.sol";

/// Drives the collection the way the world would: a handful of actors buying,
/// taking green generations, moving tokens around and sweeping the money, with
/// the amounts and the characters chosen by the fuzzer.
///
/// Keeps its own books alongside, so the invariants can compare what the contract
/// says against what actually went in and out rather than against itself.
///
/// Every actor is an address with no code and every door is one the handler has
/// already checked should open. A door that refuses anyway raises a flag the
/// invariants read. Nothing else here is caught, the reads that decide whether
/// a door should open included, so a revert in any of them fails the campaign
/// rather than being discarded.
contract GlamToonHandler is CommonBase, StdCheats, StdUtils {
    GlamToon public immutable nft;

    address[] public actors;
    uint256[] public minted;

    uint256 public totalPaid;
    uint256 public totalRefunded;
    uint256 public totalWithdrawn;
    uint256 public totalForceFed;
    uint256 public greensTakenCount;
    uint256 public bluesTakenCount;
    uint256 public giftsCount;

    /// A call this handler had every reason to expect to go through reverted.
    bool public unexpectedRevert;

    /// Highest generation this handler has taken for a character, so a test can
    /// check the chain agrees without walking every token.
    mapping(uint256 imageId => uint256) public highestGeneration;

    constructor(GlamToon n) {
        nft = n;
        for (uint256 i = 0; i < 5; ++i) {
            address a = address(uint160(uint256(keccak256(abi.encode("actor", i)))));
            actors.push(a);
            vm.deal(a, 100_000 ether);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function mintBlue(uint256 actorSeed, uint256 imageId, uint256 extra) external {
        address who = _actor(actorSeed);
        imageId = bound(imageId, 0, 9999);
        extra = bound(extra, 0, 2 ether);

        if (nft.blueMinted() >= 10_000) return;
        if (nft.blueTaken(imageId)) return;

        uint256 price = nft.currentPrice();
        uint256 sent = price + extra;
        if (who.balance < sent) return;

        uint256 balanceBefore = who.balance;
        vm.prank(who);
        try nft.mintBlue{value: sent}(imageId, price) {
            uint256 spent = balanceBefore - who.balance;
            totalPaid += sent;
            totalRefunded += sent - spent;
            bluesTakenCount += 1;
            minted.push(imageId);
        } catch {
            unexpectedRevert = true;
        }
    }

    /// The same sale, bought by one actor for another. The counters do not care
    /// which, which is the point: a gift is a sale like any other and must not
    /// let the supply, the refunds or the bitmap drift.
    function mintBlueFor(uint256 payerSeed, uint256 toSeed, uint256 imageId, uint256 extra) external {
        address payer = _actor(payerSeed);
        address to = _actor(toSeed);
        imageId = bound(imageId, 0, 9999);
        extra = bound(extra, 0, 2 ether);

        if (nft.blueMinted() >= 10_000) return;
        if (nft.blueTaken(imageId)) return;

        uint256 price = nft.currentPrice();
        uint256 sent = price + extra;
        if (payer.balance < sent) return;

        uint256 balanceBefore = payer.balance;
        vm.prank(payer);
        try nft.mintBlueFor{value: sent}(to, imageId, price) {
            uint256 spent = balanceBefore - payer.balance;
            totalPaid += sent;
            totalRefunded += sent - spent;
            bluesTakenCount += 1;
            giftsCount += 1;
            minted.push(imageId);
        } catch {
            unexpectedRevert = true;
        }
    }

    function mintGreen(uint256 actorSeed, uint256 imageId) external {
        address who = _actor(actorSeed);
        imageId = bound(imageId, 0, 9999);
        if (nft.greenTaken(imageId, who)) return;

        vm.prank(who);
        try nft.mintGreen(imageId) {
            greensTakenCount += 1;
            highestGeneration[imageId] += 1;
            minted.push(nft.tokenIdFor(imageId, highestGeneration[imageId]));
        } catch {
            unexpectedRevert = true;
        }
    }

    function transfer(uint256 actorSeed, uint256 tokenSeed) external {
        if (minted.length == 0) return;
        uint256 tokenId = minted[bound(tokenSeed, 0, minted.length - 1)];
        address from = nft.ownerOf(tokenId);
        address to = _actor(actorSeed);
        if (from == to) return;

        vm.prank(from);
        try nft.transferFrom(from, to, tokenId) {}
        catch {
            unexpectedRevert = true;
        }
    }

    function withdraw(uint256) external {
        uint256 amount = address(nft).balance;
        if (amount == 0) return;
        try nft.withdraw() {
            totalWithdrawn += amount;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// Ether arriving by no route the contract offers. Withdrawing the balance
    /// rather than a running total is what keeps this recoverable.
    function forceFeed(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);
        totalForceFed += amount;
        vm.deal(address(nft), address(nft).balance + amount);
    }

    function mintedCount() external view returns (uint256) {
        return minted.length;
    }

    function mintedAt(uint256 i) external view returns (uint256) {
        return minted[i];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
