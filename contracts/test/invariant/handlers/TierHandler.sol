// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";
import {GlamToon} from "../../../src/GlamToon.sol";
import {Treasury} from "../../../src/Treasury.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {LifecycleHandler} from "./LifecycleHandler.sol";

/// The lifecycle handler with the rest of the world let in. Sales come in bulk
/// as well as one at a time, so a run that starts just below a tier edge gets
/// well past it. The treasury's keys are used: its owner offers it on, takes
/// an offer back and points the money somewhere else, and whoever was offered
/// it takes it. Royalties arrive in ether and in a token and are swept by
/// anyone, and holders hand whole collections to operators and take them back.
///
/// The books follow the treasury as it moves. The handler knows the owner, the
/// pending owner and the beneficiary of the moment from the calls it made, and
/// credits every sweep, ether or token, to whoever it was meant for when it
/// happened, so a sweep that reached last week's beneficiary shows.
contract TierHandler is LifecycleHandler {
    /// Stands in for wrapped ether, the way marketplaces pay royalties on offers.
    MockERC20 public royaltyToken;

    /// Who may be offered the treasury, the deployment's owner first. None of
    /// them is an actor, so an actor poking at the treasury is always a stranger.
    address[] public owners;
    /// Where the money may be pointed, the deployment's beneficiary first. None
    /// of them receives ether or tokens by any other route.
    address[] public payees;

    /// Who holds the treasury, and who has been offered it, as this handler
    /// understands it from the calls it made.
    address public treasuryOwnerGhost;
    address public pendingOwnerGhost;

    /// Ether royalties paid straight to the treasury.
    uint256 public etherRoyalties;
    /// Royalty tokens paid to the treasury, and swept on from it.
    uint256 public tokenPaidIn;
    uint256 public tokenSwept;
    /// What each address was sent by token sweeps while it was the beneficiary.
    mapping(address payee => uint256) public tokenSweptTo;

    /// Whether this handler believes a holder has handed an operator its tokens.
    mapping(address holder => mapping(address operator => bool)) public operatorGhost;

    /// Batches priced on both sides of a tier edge.
    uint256 public straddles;
    /// Times the treasury went to somebody other than the owner of the moment.
    uint256 public handovers;
    uint256 public repoints;
    uint256 public tokenSweepCount;
    uint256 public operatorMoves;

    /// Somebody moved a token its holder never let it touch.
    bool public movedWithoutPermission;
    /// The chain named some other set of operators than the holders did.
    bool public operatorsDrifted;

    /// Brings the sale to startAt blues before the campaign begins, bought one at a
    /// time through the same books as every later sale so the handler starts
    /// out knowing every token. The characters step through the collection by
    /// a stride that shares no factor with ten thousand, so the ones left for
    /// sale are scattered over every word of the bitmap rather than bunched at
    /// the end of it.
    constructor(GlamToon n, Treasury t, uint256 startAt) LifecycleHandler(n, t) {
        royaltyToken = new MockERC20();

        treasuryOwnerGhost = t.owner();
        owners.push(t.owner());
        payees.push(t.beneficiary());
        for (uint256 i = 0; i < 2; ++i) {
            owners.push(address(uint160(uint256(keccak256(abi.encode("tier owner", i))))));
            payees.push(address(uint160(uint256(keccak256(abi.encode("tier payee", i))))));
        }

        for (uint256 i = 0; i < startAt; ++i) {
            address buyer = actors[i % 5];
            require(_buy(buyer, buyer, (i * 7919) % IMAGE_COUNT, 0, false), "the sale stalled before the campaign");
        }
        supplyHighWater = n.totalSupply();
    }

    /*//////////////////////////////////////////////////////////////
                                THE SALE
    //////////////////////////////////////////////////////////////*/

    /// Many sales in one call, alternating the two doors and each priced from
    /// the count at the moment it is made, so one call can straddle a tier edge.
    /// The fuzzer asks for up to forty. A batch that would stop on a tier edge,
    /// or less than forty short of it, runs on to the first sale past it
    /// instead, because single sales left to finish the approach would land a
    /// run on its edge often enough that some runs would never see a batch
    /// cross it. Payer and recipient never have code, so every sale has to go
    /// through.
    function buyBatch(uint256 payerSeed, uint256 count, uint256 imageSeed, uint256 extra) external tracked {
        uint256 p = bound(payerSeed, 0, 4);
        address payer = actors[p];
        address friend = actors[(p + 1) % 5];
        count = bound(count, 1, 40);
        extra = bound(extra, 0, 2 ether);
        uint256 next = bound(imageSeed, 0, IMAGE_COUNT - 1);

        uint256 first = bluesSold;
        uint256 edge = (first / TIER_SIZE + 1) * TIER_SIZE;
        if (edge < BLUE_SUPPLY && first + count <= edge && edge - (first + count) < 40) count = edge - first + 1;

        for (uint256 i = 0; i < count; ++i) {
            (uint256 imageId, bool open) = _unsold(next);
            if (!open) {
                _probeSoldOut(payer, friend, imageId);
                break;
            }
            if (payer.balance < _price() + extra) break;

            bool gift = i % 2 == 1;
            if (!_buy(payer, gift ? friend : payer, imageId, extra, gift)) {
                unexpectedRevert = true;
                break;
            }
            next = (imageId + 7919) % IMAGE_COUNT;
        }

        // The first sale of the batch in one tier and the last in the next.
        if (bluesSold > first && (bluesSold - 1) / TIER_SIZE != first / TIER_SIZE) straddles += 1;
    }

    /// A green taken by the receiver that tries to mint again from inside its
    /// own mint. Once the blues are gone this is the only mint that hands it a
    /// token, and so the only way the guard is still tried from a green hook.
    function reentererTakesAGreen(uint256 imageId) external tracked {
        _mintGreen(address(reenterer), bound(imageId, 0, IMAGE_COUNT - 1));
    }

    /*//////////////////////////////////////////////////////////////
                              THE TREASURY
    //////////////////////////////////////////////////////////////*/

    /// The owner offers the treasury to one of the candidates, or withdraws an
    /// offer by naming nobody.
    function offerTheTreasury(uint256 toSeed) external tracked {
        uint256 i = bound(toSeed, 0, owners.length);
        address to = i == owners.length ? address(0) : owners[i];

        vm.prank(treasuryOwnerGhost);
        try treasury.transferOwnership(to) {
            pendingOwnerGhost = to;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// Whoever holds the offer takes the treasury. With no offer standing the
    /// owner makes one first, to somebody else, so a run cannot end without
    /// the treasury changing hands.
    function acceptTheTreasury(uint256 toSeed) external tracked {
        if (pendingOwnerGhost == address(0)) {
            uint256 i = bound(toSeed, 0, owners.length - 1);
            address to = owners[i];
            if (to == treasuryOwnerGhost) to = owners[(i + 1) % owners.length];
            vm.prank(treasuryOwnerGhost);
            try treasury.transferOwnership(to) {
                pendingOwnerGhost = to;
            } catch {
                unexpectedRevert = true;
                return;
            }
        }

        address taker = pendingOwnerGhost;
        address previous = treasuryOwnerGhost;
        vm.prank(taker);
        try treasury.acceptOwnership() {
            treasuryOwnerGhost = taker;
            pendingOwnerGhost = address(0);
            if (taker != previous) handovers += 1;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// The owner of the moment points the money somewhere else.
    function repointTheBeneficiary(uint256 toSeed) external tracked {
        uint256 i = bound(toSeed, 0, payees.length - 1);
        address to = payees[i];
        if (to == beneficiaryGhost) to = payees[(i + 1) % payees.length];

        vm.prank(treasuryOwnerGhost);
        try treasury.setBeneficiary(to) {
            beneficiaryGhost = to;
            repoints += 1;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// A candidate who does not hold the treasury right now tries to act as its
    /// owner. It may have held it once, or be holding an offer it has not taken
    /// up, and either way it has no more power than a stranger.
    function pokeAsAnOwnerOfAnotherMoment(uint256 whoSeed, uint256 which) external tracked {
        address who = owners[bound(whoSeed, 0, owners.length - 1)];
        if (who == treasuryOwnerGhost) return;
        bytes memory refusal = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who);
        bool repoint = bound(which, 0, 1) == 0;

        vm.prank(who);
        if (repoint) {
            try treasury.setBeneficiary(who) {}
            catch (bytes memory reason) {
                _refusedAs(reason, refusal);
            }
        } else {
            try treasury.transferOwnership(who) {}
            catch (bytes memory reason) {
                _refusedAs(reason, refusal);
            }
        }
    }

    /// A royalty lands in the treasury, in ether through its receive or in the
    /// token a marketplace settles offers in.
    function payRoyalty(uint256 actorSeed, uint256 amount, bool inEther) external tracked {
        amount = bound(amount, 1, 5 ether);

        if (!inEther) {
            royaltyToken.mint(address(treasury), amount);
            tokenPaidIn += amount;
            return;
        }

        vm.prank(actors[bound(actorSeed, 0, 4)]);
        (bool ok,) = address(treasury).call{value: amount}("");
        if (ok) etherRoyalties += amount;
        else unexpectedRevert = true;
    }

    /// Anyone may push the token balance on, and it has to land with the
    /// beneficiary of the moment. With nothing held a royalty arrives first, so
    /// a run cannot end without a token sweep.
    function sweepTreasuryToken(uint256 actorSeed, uint256 amount) external tracked {
        uint256 held = tokenPaidIn - tokenSwept;
        if (held == 0) {
            held = bound(amount, 1, 5 ether);
            royaltyToken.mint(address(treasury), held);
            tokenPaidIn += held;
        }

        vm.prank(_actor(actorSeed));
        try treasury.sweepToken(royaltyToken) {
            tokenSwept += held;
            tokenSweptTo[beneficiaryGhost] += held;
            tokenSweepCount += 1;
        } catch {
            unexpectedRevert = true;
        }
    }

    /*//////////////////////////////////////////////////////////////
                               OPERATORS
    //////////////////////////////////////////////////////////////*/

    /// A holder hands everything it holds to an operator, or takes it back.
    function setOperator(uint256 holderSeed, uint256 operatorSeed, bool approved) external tracked {
        address holder = _actor(holderSeed);
        address operator = _actor(operatorSeed);
        if (holder == operator) return;

        vm.prank(holder);
        try nft.setApprovalForAll(operator, approved) {
            operatorGhost[holder][operator] = approved;
            _checkOperators();
        } catch {
            unexpectedRevert = true;
        }
    }

    /// An operator moves a token it does not hold. A holder that has not handed
    /// it over yet does so first, so every call ends in a move by an operator.
    function transferByOperator(uint256 tokenSeed, uint256 operatorSeed, uint256 toSeed) external tracked {
        if (tokenIds.length == 0) return;
        uint256 tokenId = tokenIds[bound(tokenSeed, 0, tokenIds.length - 1)];
        address from = ownerGhost[tokenId];
        address operator = _actor(operatorSeed);
        address to = _actor(toSeed);
        if (operator == from) return;

        if (!operatorGhost[from][operator]) {
            vm.prank(from);
            try nft.setApprovalForAll(operator, true) {
                operatorGhost[from][operator] = true;
                _checkOperators();
            } catch {
                unexpectedRevert = true;
                return;
            }
        }

        vm.prank(operator);
        try nft.transferFrom(from, to, tokenId) {
            _moved(tokenId, to);
            _countContractLanding(to);
            operatorMoves += 1;
        } catch {
            unexpectedRevert = true;
        }
    }

    /// Somebody the holder never handed its tokens to, or has since cut off,
    /// tries to move one. It has to be refused, and refused as unapproved.
    function transferWithoutPermission(uint256 tokenSeed, uint256 strangerSeed, uint256 toSeed) external tracked {
        if (tokenIds.length == 0) return;
        uint256 tokenId = tokenIds[bound(tokenSeed, 0, tokenIds.length - 1)];
        address from = ownerGhost[tokenId];
        address stranger = _actor(strangerSeed);
        address to = _actor(toSeed);
        if (stranger == from || operatorGhost[from][stranger]) return;
        // An approval of this one token is a permission of its own, and another
        // door spends those.
        if (nft.getApproved(tokenId) == stranger) return;

        vm.prank(stranger);
        try nft.transferFrom(from, to, tokenId) {
            movedWithoutPermission = true;
            _moved(tokenId, to);
        } catch (bytes memory reason) {
            _refusedAs(
                reason, abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, stranger, tokenId)
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 READBACK
    //////////////////////////////////////////////////////////////*/

    function payeeCount() external view returns (uint256) {
        return payees.length;
    }

    /// Whether every holder and operator pair on chain is the one the holders
    /// named, asked in one call so the books can ask after every step.
    function operatorsAgree() public view returns (bool) {
        for (uint256 h = 0; h < actors.length; ++h) {
            for (uint256 o = 0; o < actors.length; ++o) {
                if (nft.isApprovedForAll(actors[h], actors[o]) != operatorGhost[actors[h]][actors[o]]) return false;
            }
        }
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// Asked the moment a holder names or drops an operator, so a pair the
    /// chain got wrong only until the next call shows as well.
    function _checkOperators() internal {
        if (!operatorsAgree()) operatorsDrifted = true;
    }
}
