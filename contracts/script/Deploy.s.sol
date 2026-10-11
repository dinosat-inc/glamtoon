// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import {Script} from "forge-std/Script.sol";
import {GlamToon, ITraitData, ITraitNames, IPFS_ROOT, ARWEAVE, TOKEN_BASE} from "../src/GlamToon.sol";
import {Treasury} from "../src/Treasury.sol";
import {TraitSchema} from "../src/gen/TraitSchema.sol";
import {TraitData0} from "../src/gen/TraitData0.sol";
import {TraitData1} from "../src/gen/TraitData1.sol";
import {TraitNames} from "../src/gen/TraitNames.sol";

/**
 * @title Deploy
 * @notice Deploys the collection in the only safe order, hashing every piece of
 *         data before anything is pinned to it, and refusing a broadcast on any
 *         chain but anvil while the art identifiers are still placeholders.
 * @dev The token is ownerless and the only owner anywhere is the treasury's,
 *      TREASURY_OWNER. The signer creates every contract here, so block
 *      explorers name it as their creator for good, and it holds the treasury
 *      too whenever TREASURY_OWNER is the signer's own address.
 *
 *      Reads TREASURY_OWNER, BENEFICIARY and SALE_START from the environment.
 *      On any chain but anvil it also reads ALLOW_EOA_TREASURY_OWNER when the
 *      treasury owner has no code, and ALLOW_EOA_BENEFICIARY when the
 *      beneficiary has no code and is not the signer. A treasury owner with no
 *      code has to be the signer, whatever the environment says.
 *
 *      forge script script/Deploy.s.sol --rpc-url $OP_RPC --broadcast --verify
 *        --slow --account glamtoon-deployer --sender $DEPLOYER
 */
contract Deploy is Script {
    uint256 constant OPTIMISM = 10;
    uint256 constant ANVIL = 31_337;

    /**
     * @notice The collection this build is meant to be.
     * @dev A stale build fails against these rather than being broadcast
     *      immutably.
     */
    uint256 constant EXPECTED_IMAGES = 10_000;
    uint96 constant EXPECTED_ROYALTY_BPS = 200;
    uint256 constant EXPECTED_TIER_SIZE = 2500;
    uint256 constant EXPECTED_FIRST_PRICE = 0.01 ether;
    uint256 constant EXPECTED_LAST_PRICE = 0.04 ether;

    /**
     * @notice The least time between the deployment and the opening of the sale
     *         on any chain but anvil.
     * @dev Room to verify the source, read the metadata back and hand the
     *      treasury on while every mint still reverts NotStarted.
     */
    uint256 constant SALE_LEAD = 1 hours;

    /**
     * @notice Everything the script puts on chain.
     */
    struct Deployed {
        TraitData0 chunk0;
        TraitData1 chunk1;
        TraitNames names;
        Treasury treasury;
        GlamToon nft;
    }

    /**
     * @notice Deploy the data, the treasury and the token, then check the wiring.
     * @dev OP Mainnet, and so a fork of it, runs the art guards, so a rehearsal
     *      exercises them. The balance floor catches an unfunded signer and
     *      nothing else; the deployment itself costs a tiny fraction of it.
     *
     *      OP Mainnet also wants the sale to open at least SALE_LEAD after the
     *      deployment, so the checks that follow it happen while nobody can
     *      mint. Anvil may open at once for local work on the site.
     *
     *      An address with no code is refused unless something shows it is
     *      meant. A treasury owner with no code has to be the signer, the one
     *      plain wallet whose key this run proves is held, because a wrong
     *      owner can never be corrected. Another wallet can still take the
     *      treasury afterwards through the two step handover, which completes
     *      only when that wallet signs. A beneficiary with no code has to be
     *      the signer or be allowed by name, which is the case of a Safe
     *      copied from another chain that was never deployed on OP.
     *
     *      The constructor's wei proves the treasury takes ether; the sweep
     *      proves the beneficiary does, which is the hop nobody checks. Sweep is
     *      open to all, so a mistyped beneficiary cannot be quietly corrected
     *      later. An emptied treasury is the assertion, because a splitter
     *      forwards what it receives and would otherwise look like a payee that
     *      cannot take delivery.
     * @return d The deployed contracts
     */
    function run() external returns (Deployed memory d) {
        require(
            block.chainid == OPTIMISM || block.chainid == ANVIL, "wrong chain, this collection deploys to OP Mainnet"
        );

        (address treasuryOwner, address beneficiary, uint256 saleStartSeconds) = _inputs();
        require(saleStartSeconds <= type(uint64).max, "SALE_START is not a unix timestamp in seconds");
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 saleStart = uint64(saleStartSeconds);

        require(treasuryOwner != address(0), "TREASURY_OWNER unset");
        require(beneficiary != address(0), "BENEFICIARY unset");
        require(saleStart >= block.timestamp, "SALE_START is in the past");

        if (block.chainid != ANVIL) {
            require(saleStart >= block.timestamp + SALE_LEAD, "SALE_START is less than an hour away");
            require(_signer().balance > 0.01 ether, "deployer underfunded");

            _assertArt(IPFS_ROOT, ARWEAVE, TraitSchema.REAL_ROWS, TOKEN_BASE);

            require(
                treasuryOwner.code.length > 0 || _allowEoaTreasuryOwner(),
                "TREASURY_OWNER is not a contract, use a Safe or set ALLOW_EOA_TREASURY_OWNER=true"
            );
            require(
                treasuryOwner.code.length > 0 || treasuryOwner == _signer(),
                "TREASURY_OWNER is a plain wallet other than the signer, deploy to the signer and hand it on"
            );
            require(
                beneficiary.code.length > 0 || beneficiary == _signer() || _allowEoaBeneficiary(),
                "BENEFICIARY is a plain wallet other than the signer, check it and set ALLOW_EOA_BENEFICIARY=true"
            );
        }

        vm.startBroadcast();

        d.chunk0 = new TraitData0();
        d.chunk1 = new TraitData1();
        d.names = new TraitNames();

        d.treasury = new Treasury(treasuryOwner, beneficiary);

        d.nft = new GlamToon{value: 1 wei}(
            ITraitData(address(d.chunk0)),
            ITraitData(address(d.chunk1)),
            ITraitNames(address(d.names)),
            address(d.treasury),
            saleStart
        );

        d.treasury.sweep();

        vm.stopBroadcast();

        require(address(d.treasury).balance == 0, "the beneficiary cannot receive ether");
        _assertWiring(d, treasuryOwner, beneficiary, saleStart);
    }

    /**
     * @notice Refuse art, trait data or a token base that is not ready for a
     *         real chain.
     * @dev REAL_ROWS is the only guard that catches filler traits: the chunk
     *      hashes are computed from the table they check, so filler hashes
     *      perfectly. TOKEN_BASE gets the same treatment as the art because it
     *      is immutable too.
     *
     *      Virtual so a test can see what run() hands it and when.
     * @param ipfsRoot The IPFS root the art is served from
     * @param arweave The Arweave manifest id the art is served from
     * @param realRows How many rows of the trait table are real
     * @param tokenBase The https base each token's page address is built on
     */
    function _assertArt(string memory ipfsRoot, string memory arweave, uint256 realRows, string memory tokenBase)
        internal
        pure
        virtual
    {
        require(!_hasPlaceholder(ipfsRoot), "IPFS_ROOT is still a placeholder");
        require(!_hasPlaceholder(arweave), "ARWEAVE is still a placeholder");

        require(_looksLikeCid(ipfsRoot), "IPFS_ROOT is not a base32 CIDv1");
        require(_looksLikeArweaveId(arweave), "ARWEAVE is not a transaction id");

        require(realRows == EXPECTED_IMAGES, "trait table is still fixture filler");

        require(!_hasPlaceholder(tokenBase), "TOKEN_BASE is still a placeholder");
        require(_looksLikeHttpsBase(tokenBase), "TOKEN_BASE is not an https base path");
    }

    /**
     * @notice Check the wiring the constructor cannot see.
     * @dev Runs inside the simulation, so a failure stops the broadcast rather
     *      than reporting on one that already happened.
     * @param d The deployed contracts
     * @param treasuryOwner Who may change the beneficiary
     * @param beneficiary Where sweeps go
     * @param saleStart When minting opens
     */
    function _assertWiring(Deployed memory d, address treasuryOwner, address beneficiary, uint64 saleStart)
        internal
        view
    {
        require(d.chunk0.dataHash() == TraitSchema.DATA_HASH_0, "chunk 0 data");
        require(d.chunk1.dataHash() == TraitSchema.DATA_HASH_1, "chunk 1 data");
        require(d.names.namesHash() == TraitSchema.NAMES_HASH, "name table");

        require(address(d.nft.CHUNK0()) == address(d.chunk0), "chunk 0 not wired");
        require(address(d.nft.CHUNK1()) == address(d.chunk1), "chunk 1 not wired");
        require(address(d.nft.NAMES()) == address(d.names), "name table not wired");

        require(d.nft.PAYOUT() == address(d.treasury), "payee not wired");
        require(d.nft.SALE_START() == saleStart, "sale start");
        require(d.nft.owner() == treasuryOwner, "collection label does not follow the treasury");
        require(d.nft.BLUE_SUPPLY() == EXPECTED_IMAGES, "wrong supply");
        require(d.nft.priceAt(0) == EXPECTED_FIRST_PRICE, "wrong opening price");
        require(d.nft.priceAt(EXPECTED_IMAGES - 1) == EXPECTED_LAST_PRICE, "wrong closing price");
        require(d.nft.TIER_SIZE() == EXPECTED_TIER_SIZE, "wrong tier size");
        require(TraitSchema.IMAGE_COUNT == EXPECTED_IMAGES, "wrong schema");
        require(d.nft.IMAGE_COUNT() == EXPECTED_IMAGES, "wrong character count");
        require(keccak256(bytes(d.nft.name())) == keccak256("Glamtoon"), "wrong name");
        require(keccak256(bytes(d.nft.symbol())) == keccak256("GLAMTOON"), "wrong symbol");

        (address receiver, uint256 amount) = d.nft.royaltyInfo(1, 1 ether);
        require(receiver == address(d.treasury), "royalty receiver");
        require(amount == uint256(EXPECTED_ROYALTY_BPS) * 1 ether / 10_000, "royalty rate");

        require(d.treasury.owner() == treasuryOwner, "treasury owner");
        require(d.treasury.beneficiary() == beneficiary, "beneficiary");

        require(
            keccak256(bytes(d.nft.ipfsRoot())) == keccak256(bytes(IPFS_ROOT)),
            "deployed art root is not the compiled one"
        );

        require(
            keccak256(bytes(d.nft.tokenBase())) == keccak256(bytes(TOKEN_BASE)),
            "deployed token base is not the compiled one"
        );

        require(bytes(d.nft.tokenJSON(0)).length > 200, "first character has no metadata");
        require(bytes(d.nft.tokenJSON(EXPECTED_IMAGES - 1)).length > 200, "last character has no metadata");
    }

    /**
     * @notice The three values a human types for the deployment.
     * @dev Virtual so a test can supply them without writing the process
     *      environment, which every test here shares.
     * @return treasuryOwner TREASURY_OWNER, who may change the beneficiary
     * @return beneficiary BENEFICIARY, where sweeps go
     * @return saleStartSeconds SALE_START, before it is checked to fit a uint64
     */
    function _inputs()
        internal
        view
        virtual
        returns (address treasuryOwner, address beneficiary, uint256 saleStartSeconds)
    {
        treasuryOwner = vm.envAddress("TREASURY_OWNER");
        beneficiary = vm.envAddress("BENEFICIARY");
        saleStartSeconds = vm.envUint("SALE_START");
    }

    /**
     * @notice Whether a plain wallet may own the treasury.
     * @dev Virtual so a test can allow it without writing the process
     *      environment, which every test here shares.
     * @return True when ALLOW_EOA_TREASURY_OWNER is set
     */
    function _allowEoaTreasuryOwner() internal view virtual returns (bool) {
        return vm.envOr("ALLOW_EOA_TREASURY_OWNER", false);
    }

    /**
     * @notice Whether a plain wallet other than the signer may be the beneficiary.
     * @dev Virtual so a test can allow it without writing the process
     *      environment, which every test here shares.
     * @return True when ALLOW_EOA_BENEFICIARY is set
     */
    function _allowEoaBeneficiary() internal view virtual returns (bool) {
        return vm.envOr("ALLOW_EOA_BENEFICIARY", false);
    }

    /**
     * @notice The account that signs the deployment.
     * @dev forge calls run() from the account it broadcasts from, the key's own
     *      address or --sender. Virtual so a test can stand a plain wallet in,
     *      since forge refuses to broadcast inside a pranked call.
     * @return The signing account
     */
    function _signer() internal view virtual returns (address) {
        return msg.sender;
    }

    /**
     * @notice True if the word placeholder appears anywhere in the string.
     * @dev Case insensitive, because a placeholder may be written in any case.
     * @param value The string to search
     * @return True when a placeholder is still in place
     */
    function _hasPlaceholder(string memory value) internal pure returns (bool) {
        bytes memory v = _lower(value);
        bytes memory needle = "placeholder";
        if (v.length < needle.length) return false;
        for (uint256 i = 0; i + needle.length <= v.length; ++i) {
            bool hit = true;
            for (uint256 j = 0; j < needle.length; ++j) {
                if (v[i + j] != needle[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    /**
     * @notice Lowercase a string, ASCII only.
     * @param value The string to fold
     * @return The folded bytes
     */
    function _lower(string memory value) internal pure returns (bytes memory) {
        bytes memory v = bytes(value);
        bytes memory out = new bytes(v.length);
        for (uint256 i = 0; i < v.length; ++i) {
            bytes1 c = v[i];
            out[i] = (c >= 0x41 && c <= 0x5a) ? bytes1(uint8(c) + 32) : c;
        }
        return out;
    }

    /**
     * @notice Whether a string is an https base path a token id can be appended to.
     * @dev Catches an http scheme, a missing trailing slash and a leftover
     *      localhost or example host. Whether the page answers is the runbook's
     *      job.
     * @param value The string to check
     * @return True when the shape is right
     */
    function _looksLikeHttpsBase(string memory value) internal pure returns (bool) {
        bytes memory v = bytes(value);
        if (v.length < 12) return false;
        if (v[v.length - 1] != "/") return false;

        bytes memory scheme = "https://";
        for (uint256 i = 0; i < scheme.length; ++i) {
            if (v[i] != scheme[i]) return false;
        }

        bytes memory lower = _lower(value);
        return !_contains(lower, "localhost") && !_contains(lower, "example.");
    }

    /**
     * @notice Whether a byte string contains another.
     * @param haystack The bytes to search
     * @param needle The bytes to find
     * @return True when found
     */
    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (haystack.length < needle.length) return false;
        for (uint256 i = 0; i + needle.length <= haystack.length; ++i) {
            bool hit = true;
            for (uint256 j = 0; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    /**
     * @notice Whether a string has the shape of a base32 CIDv1.
     * @dev Catches a pasted ipfs:// prefix, a trailing newline, a CIDv0 starting
     *      Qm, and anything with a character base32 cannot hold. It cannot tell
     *      whether the CID resolves, which is what scripts/verify-pin.mjs is
     *      for.
     * @param value The string to check
     * @return True when the shape is right
     */
    function _looksLikeCid(string memory value) internal pure returns (bool) {
        bytes memory v = bytes(value);
        if (v.length < 55 || v.length > 64) return false;
        if (v[0] != "b" || v[1] != "a" || v[2] != "f") return false;
        for (uint256 i = 0; i < v.length; ++i) {
            bytes1 c = v[i];
            if (!((c >= "a" && c <= "z") || (c >= "2" && c <= "7"))) return false;
        }
        return true;
    }

    /**
     * @notice Whether a string has the shape of an Arweave transaction id.
     * @param value The string to check
     * @return True when the shape is right
     */
    function _looksLikeArweaveId(string memory value) internal pure returns (bool) {
        bytes memory v = bytes(value);
        if (v.length != 43) return false;
        for (uint256 i = 0; i < v.length; ++i) {
            bytes1 c = v[i];
            bool ok = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-" || c == "_";
            if (!ok) return false;
        }
        return true;
    }
}
