// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "../Base.t.sol";
import {Treasury} from "../../src/Treasury.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

/// The logs are the only record of a sale that survives outside the chain's
/// state: an indexer, a tax return and the collection page all read them rather
/// than replaying storage. Nothing asserted them, so a wrong address or a wrong
/// amount in any of these would have shipped unnoticed.
///
/// The events are redeclared here because expectEmit needs one to compare
/// against. A signature that drifts from the contract stops matching and the
/// test fails, which is the point.
contract EventsTest is BaseTest {
    event BlueMinted(address indexed to, address indexed payer, uint256 indexed imageId, uint256 price);
    event GreenMinted(address indexed minter, uint256 indexed imageId, uint256 generation);
    event Withdrawn(uint256 amount);

    event BeneficiarySet(address indexed previous, address indexed current);
    event Swept(address indexed to, uint256 amount);
    event SweptToken(address indexed token, address indexed to, uint256 amount);
    event Received(address indexed from, uint256 amount);

    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    function test_buyingLogsTheBuyerTheCharacterAndThePrice() public {
        uint256 price = _price();

        vm.expectEmit(true, true, true, true, address(nft));
        emit BlueMinted(alice, alice, 7412, price);

        vm.prank(alice);
        nft.mintBlue{value: price}(7412, price);
    }

    /// A gift separates the two addresses, which is the only reason the payer is
    /// in the log at all.
    function test_aGiftLogsTheRecipientAndThePayer() public {
        uint256 price = _price();

        vm.expectEmit(true, true, true, true, address(nft));
        emit BlueMinted(bob, alice, 512, price);

        vm.prank(alice);
        nft.mintBlueFor{value: price}(bob, 512, price);
    }

    /// The price in the log is what was charged, not what was sent. Overpaying
    /// is refunded, and a log that carried msg.value would overstate the sale.
    function test_theLoggedPriceIsWhatWasCharged() public {
        uint256 price = _price();

        vm.expectEmit(true, true, true, true, address(nft));
        emit BlueMinted(bob, bob, 88, price);

        vm.prank(bob);
        nft.mintBlue{value: price + 3 ether}(88, price + 3 ether);
    }

    /// The price in the log is the one the sale charged at every tier, not the
    /// opening price carried forward. Both edges of each tier are bought
    /// through the gift door with money on top, so the logged figure is neither
    /// the value sent nor the price of a neighbouring sale, and the payer's
    /// wallet is held to it.
    function test_theLoggedPriceStepsWithTheTier() public {
        // Metering off: with each call its own transaction, as in a gas report,
        // this walk comes close to the per test gas limit. Nothing here asserts
        // on gas.
        vm.pauseGasMetering();

        uint256[8] memory edge = [uint256(0), 2499, 2500, 4999, 5000, 7499, 7500, 9999];
        uint256[8] memory charged =
            [uint256(0.01 ether), 0.01 ether, 0.02 ether, 0.02 ether, 0.03 ether, 0.03 ether, 0.04 ether, 0.04 ether];

        uint256 k;
        for (uint256 id = 0; id < BLUE_SUPPLY; ++id) {
            if (k < edge.length && id == edge[k]) {
                uint256 before = bob.balance;

                vm.expectEmit(true, true, true, true, address(nft));
                emit BlueMinted(carol, bob, id, charged[k]);

                vm.prank(bob);
                nft.mintBlueFor{value: charged[k] + 1 ether}(carol, id, type(uint256).max);
                assertEq(before - bob.balance, charged[k], "the payer lost exactly what the log says");
                ++k;
            } else {
                _buy(alice, id);
            }
        }

        assertEq(k, edge.length, "every edge was logged");
    }

    /// The sale is logged before the token moves, through either door, so an
    /// indexer reading the receipt meets the payer and the price ahead of the
    /// Transfer. That Transfer is the plain ERC721 one from address zero to
    /// whoever received the token, and nothing else is logged.
    function test_aSaleIsLoggedJustBeforeTheStandardTransferFromZero() public {
        uint256 price = _price();
        vm.recordLogs();
        vm.prank(alice);
        nft.mintBlue{value: price}(7412, price);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 2, "the sale and the transfer, nothing else");
        _assertLog(logs[0], BlueMinted.selector, alice, alice, 7412, abi.encode(price));
        _assertLog(logs[1], TRANSFER, address(0), alice, 7412, "");

        price = _price();
        vm.recordLogs();
        vm.prank(alice);
        nft.mintBlueFor{value: price + 1 ether}(bob, 512, price);
        logs = vm.getRecordedLogs();

        assertEq(logs.length, 2, "a gift logs the same two, and the refund logs nothing");
        _assertLog(logs[0], BlueMinted.selector, bob, alice, 512, abi.encode(price));
        _assertLog(logs[1], TRANSFER, address(0), bob, 512, "");
    }

    function test_greenLogsTheMinterTheCharacterAndTheGeneration() public {
        _green(alice, 4711);

        vm.expectEmit(true, true, false, true, address(nft));
        emit GreenMinted(bob, 4711, 2);

        vm.prank(bob);
        nft.mintGreen(4711);
    }

    /// The logged generation is the character's own count. The collection's
    /// running total of greens agrees with it only while a single character
    /// has been minted, so this reads the log after others have greens too.
    function test_theLoggedGenerationIsTheCharactersOwnNotTheCollectionTotal() public {
        _green(alice, 1);
        _green(alice, 2);
        _green(bob, 2);

        vm.expectEmit(true, true, false, true, address(nft));
        emit GreenMinted(carol, 3, 1);
        vm.prank(carol);
        nft.mintGreen(3);

        vm.expectEmit(true, true, false, true, address(nft));
        emit GreenMinted(carol, 1, 2);
        vm.prank(carol);
        nft.mintGreen(1);
    }

    /// The same order for the free edition: the generation first, then the
    /// plain Transfer from address zero to the minter, whose token id carries
    /// that generation.
    function test_aGreenIsLoggedJustBeforeTheStandardTransferFromZero() public {
        _green(alice, 7412);

        vm.recordLogs();
        vm.prank(carol);
        nft.mintGreen(7412);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 2, "the generation and the transfer, nothing else");
        assertEq(logs[0].emitter, address(nft), "logged by the collection");
        assertEq(logs[0].topics.length, 3, "two indexed fields");
        assertEq(logs[0].topics[0], GreenMinted.selector, "the generation comes first");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(carol))), "the minter");
        assertEq(logs[0].topics[2], bytes32(uint256(7412)), "the character");
        assertEq(logs[0].data, abi.encode(uint256(2)), "the second generation");
        _assertLog(logs[1], TRANSFER, address(0), carol, 27_412, "");
    }

    function test_withdrawLogsWhatItSent() public {
        uint256 paid = _buy(alice, 12);

        vm.expectEmit(false, false, false, true, address(nft));
        emit Withdrawn(paid);

        nft.withdraw();
    }

    /// The payee's own log of the same money. Both sides of the hop are
    /// asserted, because an indexer reading only one of them would be wrong
    /// about where the sale proceeds went.
    function test_theTreasuryLogsWhatArrives() public {
        uint256 paid = _buy(alice, 13);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit Received(address(nft), paid);

        nft.withdraw();
    }

    function test_sweepLogsTheDestinationAndTheAmount() public {
        vm.deal(address(treasury), 5 ether);

        vm.expectEmit(true, false, false, true, address(treasury));
        emit Swept(beneficiary, 5 ether);

        treasury.sweep();
    }

    function test_sweepTokenLogsTheTokenTheDestinationAndTheAmount() public {
        MockERC20 weth = new MockERC20();
        weth.mint(address(treasury), 3 ether);

        vm.expectEmit(true, true, false, true, address(treasury));
        emit SweptToken(address(weth), beneficiary, 3 ether);

        treasury.sweepToken(IERC20(address(weth)));
    }

    function test_repointingLogsBothAddresses() public {
        vm.expectEmit(true, true, false, false, address(treasury));
        emit BeneficiarySet(beneficiary, carol);

        vm.prank(treasuryOwner);
        treasury.setBeneficiary(carol);
    }

    /// The first beneficiary is announced by the constructor, so an indexer
    /// watching only BeneficiarySet still learns where the money starts.
    function test_deploymentAnnouncesTheFirstBeneficiary() public {
        vm.recordLogs();
        new Treasury(treasuryOwner, beneficiary);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 wanted = keccak256("BeneficiarySet(address,address)");
        uint256 found = 0;

        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != wanted) continue;
            found += 1;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(0), "no previous beneficiary");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), beneficiary, "the first one");
        }

        assertEq(found, 1, "announced once");
    }

    /// One log from the collection with three indexed fields: two addresses and
    /// a number, then the unindexed data.
    function _assertLog(
        Vm.Log memory log,
        bytes32 topic,
        address first,
        address second,
        uint256 third,
        bytes memory data
    ) internal view {
        assertEq(log.emitter, address(nft), "logged by the collection");
        assertEq(log.topics.length, 4, "three indexed fields");
        assertEq(log.topics[0], topic, "the event logged in this position");
        assertEq(log.topics[1], bytes32(uint256(uint160(first))), "first address");
        assertEq(log.topics[2], bytes32(uint256(uint160(second))), "second address");
        assertEq(log.topics[3], bytes32(third), "the id");
        assertEq(log.data, data, "the data");
    }
}
