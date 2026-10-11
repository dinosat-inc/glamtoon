// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";
import {ReentrancyGuardTransient} from "openzeppelin/utils/ReentrancyGuardTransient.sol";
import {GlamToon} from "../../../src/GlamToon.sol";
import {Treasury} from "../../../src/Treasury.sol";

/// Drives a whole collection lifecycle: buying, gifting, taking green
/// generations, moving tokens by every door the token offers, emptying the
/// contract into the treasury and on to the beneficiary, and letting time run.
///
/// Three of the eight actors are contracts, because a recipient with code is the
/// case a codeless fuzzer never reaches, and all three act when the collection
/// calls into them rather than when they call it. One forwards whatever lands on
/// it, one refuses tokens outright, and one reads the collection's books and
/// tries to mint again, both from inside the mint handing it a token.
///
/// The books here are kept independently of the contract. The price is worked
/// out from this handler's own sales count rather than read back from
/// currentPrice, token ids are computed rather than queried, and the holder of
/// every token is modelled rather than looked up, so an implementation that
/// drifted could not talk the invariants into agreeing with it.
contract LifecycleHandler is CommonBase, StdCheats, StdUtils {
    /// Marks this as test code, so forge build --sizes leaves it out of the
    /// check that only deployable contracts have to pass. This handler and the
    /// tier handler built on it are larger than a contract on chain may be.
    bool public constant IS_TEST = true;

    uint256 internal constant IMAGE_COUNT = 10_000;
    uint256 internal constant BLUE_SUPPLY = 10_000;
    uint256 internal constant TIER_SIZE = 2500;
    uint256 internal constant PRICE_STEP = 0.01 ether;

    /// Words in the blue bitmap. The last one covers only the final sixteen
    /// characters.
    uint256 internal constant BITMAP_WORDS = 40;

    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    GlamToon public immutable nft;
    Treasury public immutable treasury;

    /// The receiver that passes tokens straight on, and where it passes them.
    ForwardingReceiver public immutable forwarder;
    address public immutable forwardTo;

    /// The receiver that refuses the safe transfer hook.
    RejectingReceiver public immutable rejecter;

    /// The receiver that tries to mint again from inside the mint handing it a
    /// token, which the guard on the outer door has to stop.
    ReenteringReceiver public immutable reenterer;

    address[] public actors;

    /*//////////////////////////////////////////////////////////////
                                  GHOSTS
    //////////////////////////////////////////////////////////////*/

    /// Ether handed to the token contract by a mint, before any change came back.
    uint256 public etherIn;
    /// Change the sale handed back to whoever overpaid.
    uint256 public etherRefunded;
    /// Ether the contract sent on to its payee.
    uint256 public etherWithdrawn;
    /// Ether pushed in by no route the contract offers.
    uint256 public etherForced;
    /// Ether the treasury sent on to the beneficiary.
    uint256 public swept;
    /// What each address was sent by sweeps while it was the beneficiary.
    mapping(address payee => uint256) public sweptTo;
    /// Where this handler believes a sweep goes right now.
    address public beneficiaryGhost;
    /// What the sale should have taken, priced by this handler's own count.
    uint256 public expectedRevenue;

    uint256 public bluesSold;
    uint256 public greensTaken;
    uint256 public giftCount;
    uint256 public withdrawCount;
    uint256 public sweepCount;
    uint256 public transfersToContracts;
    /// Greens taken once every blue had sold.
    uint256 public greensAfterSellOut;
    /// Buyers the sold out sale turned away with SoldOut, counting both doors.
    uint256 public soldOutRefusals;

    /// Green generations this handler believes a character has.
    mapping(uint256 imageId => uint256) public greensOfCharacter;
    /// Green tokens this handler believes an actor took, across all characters.
    mapping(address actor => uint256) public greensOfActor;
    /// Whether this handler believes an actor has used up its slot on a character.
    mapping(uint256 imageId => mapping(address actor => bool)) public tookGreen;

    /// Every token id this handler believes exists, and who should be holding it.
    uint256[] public tokenIds;
    mapping(uint256 tokenId => bool) public exists;
    mapping(uint256 tokenId => address) public ownerGhost;
    /// How many tokens this handler believes each address holds.
    mapping(address holder => uint256) public heldBy;
    /// How many times a token has changed hands. A token can leave and come
    /// back, so its holder is not enough to tell whether it moved.
    mapping(uint256 tokenId => uint256) public moveCount;

    /// Blue ids only, so the bitmap check does not walk the greens.
    uint256[] public blueIds;
    /// The blue bitmap as this handler would draw it from the sales it saw.
    mapping(uint256 word => uint256) public soldBits;

    /// Characters a green was ever taken of.
    uint256[] internal touched;
    mapping(uint256 imageId => bool) internal isTouched;

    /// The highest supply ever seen. Nothing may take supply below it.
    uint256 public supplyHighWater;

    /// A mint handed out a token id that was already live.
    bool public doubleMinted;
    /// A mint logged some other id than the one worked out here, or logged
    /// none, or logged more than one.
    bool public mintedTheWrongId;
    /// A token was not with the holder a mint or a move had just handed it to.
    bool public misplaced;
    /// A call this handler had every reason to expect to go through reverted.
    bool public unexpectedRevert;
    /// An approval went missing while its token sat still.
    bool public approvalLost;

    /// Doors the sale is meant to hold shut. Each flag goes up the moment a mint
    /// that should have been refused went through, and stays up.
    bool public soldATakenBlue;
    bool public ignoredThePriceCeiling;
    bool public acceptedShortPayment;
    bool public mintedOffTheEndOfTheCollection;
    bool public gaveTheSameAddressASecondGreen;
    bool public mintedBeforeTheSaleOpened;
    bool public soldPastTheEnd;
    /// A door that had to shut did, but with some other error than the one
    /// that says why.
    bool public refusedForTheWrongReason;

    uint256 internal approvedToken;
    address internal approvedSpender;
    uint256 internal approvedAtMove;
    bool internal hasApproval;

    constructor(GlamToon n, Treasury t) {
        // The schedule is kept here as its own literals so the model can
        // disagree with the contract, but both have to start from the same
        // published numbers or every price after the first edge is a false alarm.
        require(
            n.TIER_SIZE() == TIER_SIZE && n.PRICE_STEP() == PRICE_STEP && n.BLUE_SUPPLY() == BLUE_SUPPLY
                && n.IMAGE_COUNT() == IMAGE_COUNT,
            "the handler prices a different schedule from the contract"
        );

        nft = n;
        treasury = t;
        beneficiaryGhost = t.beneficiary();

        for (uint256 i = 0; i < 5; ++i) {
            address a = address(uint160(uint256(keccak256(abi.encode("lifecycle actor", i)))));
            actors.push(a);
            vm.deal(a, 50_000 ether);
        }

        forwardTo = actors[0];
        forwarder = new ForwardingReceiver(n, actors[0]);
        rejecter = new RejectingReceiver();
        reenterer = new ReenteringReceiver(n);

        actors.push(address(forwarder));
        actors.push(address(rejecter));
        actors.push(address(reenterer));
        vm.deal(address(forwarder), 50_000 ether);
        vm.deal(address(rejecter), 50_000 ether);
        vm.deal(address(reenterer), 50_000 ether);
    }

    /// Puts the clock back inside the sale's opening hours before every action,
    /// because the refused mint probe winds it back and a cheatcode warp is not
    /// undone by the revert that may follow it. Supply is read afterwards rather
    /// than only after a mint, so a token that went missing during a transfer is
    /// caught as well.
    modifier tracked() {
        if (block.timestamp < nft.SALE_START()) vm.warp(nft.SALE_START());
        _;
        uint256 supply = nft.totalSupply();
        if (supply > supplyHighWater) supplyHighWater = supply;
    }

    /*//////////////////////////////////////////////////////////////
                                THE SALE
    //////////////////////////////////////////////////////////////*/

    /// The fuzzer's character is moved on to the next one still for sale, so the
    /// door keeps selling however much of the collection is gone. Once nothing
    /// is left it asks anyway, and has to be told the sale is over.
    function mintBlue(uint256 actorSeed, uint256 imageId, uint256 extra) external tracked {
        address who = _actor(actorSeed);
        extra = bound(extra, 0, 2 ether);
        bool open;
        (imageId, open) = _unsold(imageId);

        if (!open) {
            _probeSoldOut(who, who, imageId);
            return;
        }
        if (who.balance < _price() + extra) return;

        // Only a recipient that refuses the hook has any right to fail here.
        if (!_buy(who, who, imageId, extra, false) && who != address(rejecter)) unexpectedRevert = true;
    }

    /// The same sale, paid for by one actor and delivered to another. The token
    /// has to land on the recipient and the change has to go back to the payer,
    /// and those are two different addresses precisely so a mix up shows.
    function mintBlueFor(uint256 payerSeed, uint256 toSeed, uint256 imageId, uint256 extra) external tracked {
        address payer = _actor(payerSeed);
        address to = _actor(toSeed);
        extra = bound(extra, 0, 2 ether);
        bool open;
        (imageId, open) = _unsold(imageId);

        if (!open) {
            _probeSoldOut(payer, to, imageId);
            return;
        }
        if (payer.balance < _price() + extra) return;

        if (!_buy(payer, to, imageId, extra, true)) {
            bool refundRefused = extra > 0 && payer == address(rejecter);
            if (to != address(rejecter) && !refundRefused) unexpectedRevert = true;
        }
    }

    /// A gift that always completes, because both parties are picked rather than
    /// fuzzed. The door above lets the fuzzer aim one at a contract that refuses
    /// it, which is worth exploring but fails by design, so without this a run
    /// could end having completed no gift at all and still claim the path was
    /// covered. Half of them land on the re-entering receiver for the same
    /// reason: that probe is worth nothing if the campaign never triggers it.
    function giftBlue(uint256 payerSeed, uint256 imageId, uint256 extra) external tracked {
        uint256 i = bound(payerSeed, 0, 9);
        address payer = actors[i % 5];
        address to = i < 5 ? actors[(i + 1) % 5] : address(reenterer);
        extra = bound(extra, 0, 2 ether);
        bool open;
        (imageId, open) = _unsold(imageId);

        if (!open) {
            _probeSoldOut(payer, to, imageId);
            return;
        }
        if (payer.balance < _price() + extra) return;

        if (!_buy(payer, to, imageId, extra, true)) unexpectedRevert = true;
    }

    function mintGreen(uint256 actorSeed, uint256 imageId) external tracked {
        _mintGreen(_actor(actorSeed), bound(imageId, 0, IMAGE_COUNT - 1));
    }

    /// Mints that have to be refused, tried against whatever state the campaign
    /// has reached rather than against a fixture. A guard that only ever sees a
    /// fresh contract is a guard nobody has really pushed on. Each has to be
    /// refused with the error that names its reason, so a door that shut for
    /// some other cause does not pass for one that works.
    function refusedMint(uint256 actorSeed, uint256 which, uint256 seed) external tracked {
        address who = _actor(actorSeed);
        uint256 price = _price();
        if (who.balance < price) return;
        which = bound(which, 0, 5);

        if (which == 0) {
            // A character whose blue is already sold, bought again. Once the
            // sale is over that check comes first.
            if (blueIds.length == 0) return;
            uint256 imageId = blueIds[bound(seed, 0, blueIds.length - 1)];
            bytes4 why = bluesSold < BLUE_SUPPLY ? GlamToon.BlueAlreadyTaken.selector : GlamToon.SoldOut.selector;
            vm.prank(who);
            try nft.mintBlue{value: price}(imageId, price) {
                soldATakenBlue = true;
            } catch (bytes memory reason) {
                _refusedAs(reason, abi.encodeWithSelector(why));
            }
        } else if (which == 1) {
            // A ceiling below the asking price.
            (uint256 imageId, bool open) = _unsold(seed);
            if (!open) return;
            vm.prank(who);
            try nft.mintBlue{value: price}(imageId, price - 1) {
                ignoredThePriceCeiling = true;
            } catch (bytes memory reason) {
                _refusedAs(reason, abi.encodeWithSelector(GlamToon.PriceTooHigh.selector));
            }
        } else if (which == 2) {
            // Short payment, with a ceiling that would otherwise allow the sale.
            (uint256 imageId, bool open) = _unsold(seed);
            if (!open) return;
            vm.prank(who);
            try nft.mintBlue{value: price - 1}(imageId, price) {
                acceptedShortPayment = true;
            } catch (bytes memory reason) {
                _refusedAs(reason, abi.encodeWithSelector(GlamToon.InsufficientPayment.selector));
            }
        } else if (which == 3) {
            // A character number past the end of the collection.
            uint256 imageId = bound(seed, IMAGE_COUNT, type(uint64).max);
            vm.prank(who);
            try nft.mintBlue{value: price}(imageId, price) {
                mintedOffTheEndOfTheCollection = true;
            } catch (bytes memory reason) {
                _refusedAs(reason, abi.encodeWithSelector(GlamToon.InvalidImageId.selector));
            }
        } else if (which == 4) {
            // A second green of a character by an address that already took one.
            if (touched.length == 0) return;
            uint256 imageId = touched[bound(seed, 0, touched.length - 1)];
            for (uint256 i = 0; i < actors.length; ++i) {
                if (!tookGreen[imageId][actors[i]]) continue;
                vm.prank(actors[i]);
                try nft.mintGreen(imageId) {
                    gaveTheSameAddressASecondGreen = true;
                } catch (bytes memory reason) {
                    _refusedAs(reason, abi.encodeWithSelector(GlamToon.GreenAlreadyTaken.selector));
                }
                return;
            }
        } else {
            // Both doors, from before the sale opened. The clock goes back only
            // for the length of this call, so the campaign still runs forward.
            (uint256 imageId, bool open) = _unsold(seed);
            if (!open) return;
            uint256 resume = block.timestamp;
            vm.warp(uint256(nft.SALE_START()) - 1);

            vm.prank(who);
            try nft.mintBlue{value: price}(imageId, price) {
                mintedBeforeTheSaleOpened = true;
            } catch (bytes memory reason) {
                _refusedAs(reason, abi.encodeWithSelector(GlamToon.NotStarted.selector));
            }

            vm.prank(who);
            try nft.mintGreen(imageId) {
                mintedBeforeTheSaleOpened = true;
            } catch (bytes memory reason) {
                _refusedAs(reason, abi.encodeWithSelector(GlamToon.NotStarted.selector));
            }

            vm.warp(resume);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              MOVING TOKENS
    //////////////////////////////////////////////////////////////*/

    /// The plain door. No hook fires, so even the receiver that refuses tokens
    /// ends up holding one, which is a state worth having in the space.
    function transferFrom(uint256 tokenSeed, uint256 toSeed) external tracked {
        if (tokenIds.length == 0) return;
        uint256 tokenId = tokenIds[bound(tokenSeed, 0, tokenIds.length - 1)];
        address from = ownerGhost[tokenId];
        address to = _actor(toSeed);

        vm.prank(from);
        try nft.transferFrom(from, to, tokenId) {
            _moved(tokenId, to);
            _countContractLanding(to);
        } catch {
            unexpectedRevert = true;
        }
    }

    /// The safe door, which hands control to the recipient. The forwarder moves
    /// the token on again before this call has returned.
    function safeTransferFrom(uint256 tokenSeed, uint256 toSeed) external tracked {
        if (tokenIds.length == 0) return;
        uint256 tokenId = tokenIds[bound(tokenSeed, 0, tokenIds.length - 1)];
        address from = ownerGhost[tokenId];
        address to = _actor(toSeed);

        vm.prank(from);
        try nft.safeTransferFrom(from, to, tokenId) {
            _moved(tokenId, _settle(to));
            _countContractLanding(to);
        } catch {
            if (to != address(rejecter)) unexpectedRevert = true;
        }
    }

    /// Aimed squarely at the receiver that acts from inside the hook, so the
    /// campaign cannot finish having never handed a token to a contract that
    /// calls straight back into the collection.
    function safeTransferToForwarder(uint256 tokenSeed) external tracked {
        if (tokenIds.length == 0) return;
        uint256 tokenId = tokenIds[bound(tokenSeed, 0, tokenIds.length - 1)];
        address from = ownerGhost[tokenId];

        vm.prank(from);
        try nft.safeTransferFrom(from, address(forwarder), tokenId) {
            _moved(tokenId, forwardTo);
            _countContractLanding(address(forwarder));
        } catch {
            unexpectedRevert = true;
        }
    }

    function approveToken(uint256 tokenSeed, uint256 spenderSeed) external tracked {
        if (tokenIds.length == 0) return;
        uint256 tokenId = tokenIds[bound(tokenSeed, 0, tokenIds.length - 1)];
        address holder = ownerGhost[tokenId];
        address spender = _actor(spenderSeed);
        if (spender == holder) return;

        vm.prank(holder);
        try nft.approve(spender, tokenId) {
            if (nft.getApproved(tokenId) != spender) approvalLost = true;
            approvedToken = tokenId;
            approvedSpender = spender;
            approvedAtMove = moveCount[tokenId];
            hasApproval = true;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// Spends an approval granted by some earlier call in the sequence. It is the
    /// only way to reach a mover that is neither the owner nor an operator, with
    /// whatever else the fuzzer did in between still having to leave it standing.
    function transferByApproved(uint256 toSeed) external tracked {
        if (!hasApproval) return;
        uint256 tokenId = approvedToken;
        address spender = approvedSpender;
        address from = ownerGhost[tokenId];
        hasApproval = false;

        // A transfer in between clears the approval by design, and a token can
        // leave and come back, so the move count rather than the holder is what
        // says whether the approval had any right to survive.
        if (moveCount[tokenId] != approvedAtMove) return;
        if (nft.getApproved(tokenId) != spender) {
            approvalLost = true;
            return;
        }

        address to = _actor(toSeed);
        vm.prank(spender);
        try nft.transferFrom(from, to, tokenId) {
            _moved(tokenId, to);
            _countContractLanding(to);
        } catch {
            unexpectedRevert = true;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  MONEY
    //////////////////////////////////////////////////////////////*/

    function withdraw(uint256) external tracked {
        uint256 amount = address(nft).balance;
        if (amount == 0) return;

        try nft.withdraw() {
            etherWithdrawn += amount;
            withdrawCount += 1;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// Anyone may push the money the whole way out, so the fuzzer does it from
    /// whichever actor it feels like, contracts included. It pulls the takings
    /// through first when the treasury is empty, because a sweep of nothing
    /// tests nothing and the campaign would too often end never having swept.
    function sweepTreasury(uint256 actorSeed) external tracked {
        if (address(treasury).balance == 0) {
            uint256 held = address(nft).balance;
            if (held == 0) return;
            try nft.withdraw() {
                etherWithdrawn += held;
                withdrawCount += 1;
            } catch {
                unexpectedRevert = true;
                return;
            }
        }

        uint256 amount = address(treasury).balance;
        vm.prank(_actor(actorSeed));
        try treasury.sweep() {
            swept += amount;
            sweptTo[beneficiaryGhost] += amount;
            sweepCount += 1;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// The one key in the whole system, pushed on from outside and, for the
    /// refusal to renounce, from inside. None of these may go through, and the
    /// fixtures invariant is what says none did.
    function pokeTheTreasury(uint256 actorSeed, uint256 which) external tracked {
        address who = _actor(actorSeed);
        which = bound(which, 0, 3);
        bytes memory stranger = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who);

        if (which == 0) {
            vm.prank(who);
            try treasury.setBeneficiary(who) {}
            catch (bytes memory reason) {
                _refusedAs(reason, stranger);
            }
        } else if (which == 1) {
            vm.prank(who);
            try treasury.transferOwnership(who) {}
            catch (bytes memory reason) {
                _refusedAs(reason, stranger);
            }
        } else if (which == 2) {
            vm.prank(who);
            try treasury.acceptOwnership() {}
            catch (bytes memory reason) {
                _refusedAs(reason, stranger);
            }
        } else {
            vm.prank(treasury.owner());
            try treasury.renounceOwnership() {}
            catch (bytes memory reason) {
                _refusedAs(reason, abi.encodeWithSelector(Treasury.CannotRenounce.selector));
            }
        }
    }

    /// Ether that arrived by a route the contract does not offer. It has to stay
    /// reachable, because withdraw sends the balance rather than a tally.
    function forceFeed(uint256 amount) external tracked {
        amount = bound(amount, 1, 5 ether);
        etherForced += amount;
        vm.deal(address(nft), address(nft).balance + amount);
    }

    /// Nothing about the sale is meant to move with the clock once it has opened.
    /// Running time on is how a hidden deadline would show itself.
    function warpAhead(uint256 secs) external tracked {
        secs = bound(secs, 1 hours, 45 days);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1 + secs / 12);
    }

    /*//////////////////////////////////////////////////////////////
                                 READBACK
    //////////////////////////////////////////////////////////////*/

    /// Every actor in one call, so a check that walks them all does not pay for
    /// a call per actor after every step of the campaign.
    function actorList() external view returns (address[] memory) {
        return actors;
    }

    function tokenCount() external view returns (uint256) {
        return tokenIds.length;
    }

    function blueCount() external view returns (uint256) {
        return blueIds.length;
    }

    function blueAt(uint256 i) external view returns (uint256) {
        return blueIds[i];
    }

    /// The newest tokens, up to n of them, and who this handler believes holds each.
    function newestTokens(uint256 n) external view returns (uint256[] memory ids, address[] memory holders) {
        uint256 total = tokenIds.length;
        if (n > total) n = total;
        ids = new uint256[](n);
        holders = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            ids[i] = tokenIds[total - n + i];
            holders[i] = ownerGhost[ids[i]];
        }
    }

    /// The whole bitmap this handler drew, in the shape blueTakenBits returns.
    function soldWords() external view returns (uint256[] memory words) {
        words = new uint256[](BITMAP_WORDS);
        for (uint256 i = 0; i < BITMAP_WORDS; ++i) {
            words[i] = soldBits[i];
        }
    }

    /// Every character a green was taken of, oldest first. A campaign at the
    /// default depth touches a few dozen, and the per actor count needs them all.
    function charactersTouched() external view returns (uint256[] memory) {
        return touched;
    }

    /// Whether this handler believes an actor took a green of each character,
    /// in the shape greenTakenBatch returns.
    function tookGreenBatch(uint256[] calldata ids, address actor) external view returns (bool[] memory took) {
        took = new bool[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            took[i] = tookGreen[ids[i]][actor];
        }
    }

    /// The green generations this handler believes each character has, in the
    /// shape greenCountBatch returns.
    function greensOfCharacterBatch(uint256[] calldata ids) external view returns (uint256[] memory counts) {
        counts = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            counts[i] = greensOfCharacter[ids[i]];
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    /// The tier price from this handler's own sales count, never from the
    /// contract, so the sale cannot quote itself into agreement.
    function _price() internal view returns (uint256) {
        return PRICE_STEP * (1 + bluesSold / TIER_SIZE);
    }

    /// One sale on either door, booked only if it went through. The ceiling is
    /// everything sent, so a sale charged off the ladder can still settle, and
    /// it is the revenue books that notice.
    function _buy(address payer, address to, uint256 imageId, uint256 extra, bool gift) internal returns (bool ok) {
        uint256 price = _price();
        uint256 sent = price + extra;
        uint256 before = payer.balance;

        vm.recordLogs();
        vm.prank(payer);
        if (gift) {
            try nft.mintBlueFor{value: sent}(to, imageId, sent) {
                ok = true;
            } catch {}
        } else {
            try nft.mintBlue{value: sent}(imageId, sent) {
                ok = true;
            } catch {}
        }
        if (!ok) return false;

        etherIn += sent;
        etherRefunded += sent - (before - payer.balance);
        expectedRevenue += price;
        if (gift) giftCount += 1;
        _recordMint(imageId, to, true);
    }

    /// The next green of a character, taken by who if its slot is still free.
    function _mintGreen(address who, uint256 imageId) internal {
        if (tookGreen[imageId][who]) return;

        // Worked out here, so a contract that numbered the token differently
        // would leave this handler holding an id that does not exist.
        uint256 generation = greensOfCharacter[imageId] + 1;
        uint256 tokenId = generation * IMAGE_COUNT + imageId;

        vm.recordLogs();
        vm.prank(who);
        try nft.mintGreen(imageId) {
            tookGreen[imageId][who] = true;
            greensOfCharacter[imageId] = generation;
            greensOfActor[who] += 1;
            greensTaken += 1;
            if (bluesSold == BLUE_SUPPLY) greensAfterSellOut += 1;
            _touch(imageId);
            _recordMint(tokenId, who, false);
        } catch {
            if (who != address(rejecter)) unexpectedRevert = true;
        }
    }

    /// Once the last blue has sold, both doors have to turn a buyer away for
    /// exactly that reason, even one paying the top price with no ceiling.
    function _probeSoldOut(address payer, address to, uint256 imageId) internal {
        uint256 offer = 4 * PRICE_STEP;
        if (payer.balance < offer) return;
        bytes memory soldOut = abi.encodeWithSelector(GlamToon.SoldOut.selector);

        vm.prank(payer);
        try nft.mintBlue{value: offer}(imageId, type(uint256).max) {
            soldPastTheEnd = true;
        } catch (bytes memory reason) {
            if (_refusedAs(reason, soldOut)) soldOutRefusals += 1;
        }

        vm.prank(payer);
        try nft.mintBlueFor{value: offer}(to, imageId, type(uint256).max) {
            soldPastTheEnd = true;
        } catch (bytes memory reason) {
            if (_refusedAs(reason, soldOut)) soldOutRefusals += 1;
        }
    }

    /// The seed's character if its blue is still for sale, or else the first
    /// free one in the next word along that has any, read off this handler's
    /// own bitmap. Answers false with the seed's character once nothing is left.
    function _unsold(uint256 seed) internal view returns (uint256 imageId, bool open) {
        imageId = bound(seed, 0, IMAGE_COUNT - 1);
        if ((soldBits[imageId >> 8] >> (imageId & 0xff)) & 1 == 0) return (imageId, true);

        for (uint256 i = 1; i <= BITMAP_WORDS; ++i) {
            uint256 word = ((imageId >> 8) + i) % BITMAP_WORDS;
            uint256 free = ~soldBits[word];
            if (word == BITMAP_WORDS - 1) free &= (uint256(1) << (IMAGE_COUNT & 0xff)) - 1;
            if (free != 0) return (word * 256 + _lowestBit(free), true);
        }
    }

    /// The position of the lowest set bit of a word that is not zero.
    function _lowestBit(uint256 x) internal pure returns (uint256 n) {
        unchecked {
            x &= ~x + 1;
        }
        for (uint256 step = 128; step > 0; step >>= 1) {
            if (x >> step != 0) {
                x >>= step;
                n += step;
            }
        }
    }

    /// True when a refusal carried exactly the expected error. Anything else
    /// is a door that shut for the wrong reason.
    function _refusedAs(bytes memory reason, bytes memory expected) internal returns (bool) {
        if (keccak256(reason) == keccak256(expected)) return true;
        refusedForTheWrongReason = true;
        return false;
    }

    /// Where a token really comes to rest when the receive hook fires: the
    /// forwarder never keeps anything handed to it that way.
    function _settle(address to) internal view returns (address) {
        return to == address(forwarder) ? forwardTo : to;
    }

    function _countContractLanding(address to) internal {
        if (to.code.length > 0) transfersToContracts += 1;
    }

    function _moved(uint256 tokenId, address to) internal {
        heldBy[ownerGhost[tokenId]] -= 1;
        heldBy[to] += 1;
        ownerGhost[tokenId] = to;
        moveCount[tokenId] += 1;
        _checkHolder(tokenId);
    }

    /// Asked the moment a token lands, so a move that went astray is caught
    /// whichever token it was, not only when it happens to be a recent mint.
    function _checkHolder(uint256 tokenId) internal {
        try nft.ownerOf(tokenId) returns (address holder) {
            if (holder != ownerGhost[tokenId]) misplaced = true;
        } catch {
            misplaced = true;
        }
    }

    /// Reads the id the mint really handed out off the Transfer it logged. There
    /// has to be exactly one, it has to be the id worked out here, and it must
    /// not be a token that was already live.
    function _checkMintedId(uint256 expected) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 mints;
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(nft) || entry.topics.length != 4) continue;
            if (entry.topics[0] != TRANSFER || entry.topics[1] != bytes32(0)) continue;

            uint256 id = uint256(entry.topics[3]);
            if (exists[id]) doubleMinted = true;
            if (id != expected) mintedTheWrongId = true;
            mints += 1;
        }
        if (mints != 1) mintedTheWrongId = true;
    }

    function _recordMint(uint256 tokenId, address to, bool blue) internal {
        _checkMintedId(tokenId);
        if (exists[tokenId]) {
            doubleMinted = true;
            return;
        }
        exists[tokenId] = true;
        tokenIds.push(tokenId);
        address holder = _settle(to);
        ownerGhost[tokenId] = holder;
        heldBy[holder] += 1;
        if (blue) {
            bluesSold += 1;
            blueIds.push(tokenId);
            soldBits[tokenId >> 8] |= uint256(1) << (tokenId & 0xff);
        }
        _countContractLanding(to);
        _checkHolder(tokenId);
    }

    function _touch(uint256 imageId) internal {
        if (isTouched[imageId]) return;
        isTouched[imageId] = true;
        touched.push(imageId);
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
                           CONTRACT ACTORS
//////////////////////////////////////////////////////////////*/

/// A receiver that sends on whatever it is handed, the way a router or a vault
/// wrapper does. It acts from inside onERC721Received, so the collection is
/// re-entered by a party it called into rather than by one that called it.
contract ForwardingReceiver {
    GlamToon internal immutable nft;
    address internal immutable target;

    uint256 public forwarded;

    constructor(GlamToon n, address to) {
        nft = n;
        target = to;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (msg.sender == address(nft)) {
            forwarded += 1;
            nft.transferFrom(address(this), target, tokenId);
        }
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/// A receiver that refuses both tokens and ether. It is still reachable by plain
/// transferFrom, which fires no hook, so it can be left holding a token it would
/// never have accepted.
contract RejectingReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }

    receive() external payable {
        revert("no ether");
    }
}

/// A receiver that looks around and then tries to mint again, both from inside
/// the mint that is handing it a token. It fires only on a mint, because a
/// transfer carries no guard and minting from inside one is allowed and would
/// say nothing.
///
/// The look around is the half that cannot be done from outside: the sale is
/// meant to have written everything down before it hands control over, and this
/// is the only moment at which that claim can be checked.
///
/// The second mint is always of a character whose green slot this receiver has
/// not used. Retrying the character a green hook has just handed over would be
/// refused by the one per address rule whether the guard worked or not, so only
/// a free slot leaves the guard as the one thing in the way.
contract ReenteringReceiver {
    uint256 internal constant IMAGE_COUNT = 10_000;

    GlamToon internal immutable nft;

    /// Attempts that only the guard could have stopped.
    uint256 public attempts;
    bool public gotBackIn;
    bool public sawStaleState;
    /// An attempt was turned away with some other error than the guard's.
    bool public stoppedByAnythingButTheGuard;

    /// Up while an attempt is under way, so a broken guard lets one mint back in
    /// rather than recursing until the call runs out of gas.
    bool internal inside;

    constructor(GlamToon n) {
        nft = n;
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (msg.sender == address(nft) && from == address(0) && !inside) {
            _lookAround(tokenId);

            uint256 imageId = tokenId % IMAGE_COUNT;
            for (uint256 i = 0; i < 16 && nft.greenTaken(imageId, address(this)); ++i) {
                imageId = (imageId + 1) % IMAGE_COUNT;
            }

            if (!nft.greenTaken(imageId, address(this))) {
                attempts += 1;
                inside = true;
                try nft.mintGreen(imageId) {
                    gotBackIn = true;
                } catch (bytes memory reason) {
                    bytes memory guard =
                        abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
                    if (keccak256(reason) != keccak256(guard)) stoppedByAnythingButTheGuard = true;
                }
                inside = false;
            }
        }
        return this.onERC721Received.selector;
    }

    function _lookAround(uint256 tokenId) private {
        if (tokenId < IMAGE_COUNT) {
            uint256[] memory word = nft.blueTakenBits(tokenId >> 8, 1);
            if ((word[0] >> (tokenId & 0xff)) & 1 == 0) sawStaleState = true;
        } else {
            uint256 imageId = tokenId % IMAGE_COUNT;
            if (nft.greenCount(imageId) < tokenId / IMAGE_COUNT) sawStaleState = true;
        }
    }

    receive() external payable {}
}
