// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {ERC2981} from "openzeppelin/token/common/ERC2981.sol";
import {ReentrancyGuardTransient} from "openzeppelin/utils/ReentrancyGuardTransient.sol";
import {Base64} from "openzeppelin/utils/Base64.sol";
import {Address} from "openzeppelin/utils/Address.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {TraitSchema} from "./gen/TraitSchema.sol";

string constant IPFS_ROOT = "bafybeide2rqgoymdal3bhump5imrmladdo73umdro4ezbswmvnuprvqdeu";
string constant ARWEAVE = "h9hcgqPaUnpUDbwyXkdoRE_mFuRUN_jFNBPd2Kz4jBM";
string constant TOKEN_BASE = "https://glamtoon.com/token/";

/**
 * @title ITraitData
 * @notice One chunk of packed trait records.
 */
interface ITraitData {
    function record(uint256 imageId) external pure returns (uint40);
    function data() external pure returns (bytes memory);
    function dataHash() external pure returns (bytes32);
}

/**
 * @title IOwned
 * @notice Anything with an owner, here the treasury.
 */
interface IOwned {
    function owner() external view returns (address);
}

/**
 * @title ITraitNames
 * @notice The category and trait value names.
 */
interface ITraitNames {
    function namesAt(uint256[] calldata slots) external pure returns (string[] memory);
    function data() external pure returns (bytes memory);
    function namesHash() external pure returns (bytes32);
}

/**
 * @title GlamToon
 * @notice Ten thousand characters, each with one paid blue edition and free
 *         green generations. This software is provided as is, without warranty.
 *         Use at your own risk.
 * @dev No proxy, no pause, no setters, no owner key and no burn.
 */
contract GlamToon is ERC721, ERC2981, ReentrancyGuardTransient {
    using Strings for uint256;

    error SoldOut();
    error NotStarted();
    error BadTraitData();
    error PriceTooHigh();
    error InvalidChunk();
    error InvalidPayout();
    error BadTraitNames();
    error InvalidImageId();
    error InvalidCategory();
    error SaleStartTooFar();
    error BlueAlreadyTaken();
    error InvalidWordRange();
    error GreenAlreadyTaken();
    error NothingToWithdraw();
    error InsufficientPayment();

    /**
     * @notice A blue was sold. The payer and the recipient can differ.
     */
    event BlueMinted(address indexed to, address indexed payer, uint256 indexed imageId, uint256 price);

    /**
     * @notice A green generation was minted.
     */
    event GreenMinted(address indexed minter, uint256 indexed imageId, uint256 generation);

    /**
     * @notice The balance was sent to the treasury.
     */
    event Withdrawn(uint256 amount);

    /**
     * @notice Characters in the collection, numbered 0 to 9999.
     */
    uint256 public constant IMAGE_COUNT = 10_000;

    /**
     * @notice The most blue tokens there can ever be, one per character.
     */
    uint256 public constant BLUE_SUPPLY = IMAGE_COUNT;

    /**
     * @notice Blue sales between price steps.
     */
    uint256 public constant TIER_SIZE = 2500;

    /**
     * @notice The opening price and the size of each step.
     */
    uint256 public constant PRICE_STEP = 0.01 ether;

    /**
     * @notice Royalty on secondary sales in basis points, two percent.
     */
    uint96 public constant ROYALTY_BPS = 200;

    uint256 constant BITMAP_WORDS = (IMAGE_COUNT >> 8) + 1;

    /**
     * @notice Generations from this one up share one Generation trait value.
     */
    uint256 public constant GENERATION_SHOWN = 9;

    string constant DESCRIPTION = "A Glamtoon character. 10,000 portraits, ages 18 to 70, in two inks.";
    string constant IPFS_SCHEME = "ipfs://";
    string constant AR_SCHEME = "ar://";
    string constant BLUE_DIR = "/blue/";
    string constant GREEN_DIR = "/green/";
    string constant FULL_EXT = ".png";
    string constant LITE_EXT = ".webp";

    /**
     * @notice Where the sale's takings and royalties go.
     */
    address public immutable PAYOUT;

    /**
     * @notice When minting opens for both editions, in unix seconds.
     */
    uint64 public immutable SALE_START;

    /**
     * @notice Trait records for characters 0 to 4999.
     */
    ITraitData public immutable CHUNK0;

    /**
     * @notice Trait records for characters 5000 to 9999.
     */
    ITraitData public immutable CHUNK1;

    /**
     * @notice The category and trait value names.
     */
    ITraitNames public immutable NAMES;

    /**
     * @notice Blue tokens sold so far, which also sets the price.
     */
    uint256 public blueMinted;

    /**
     * @notice Green tokens minted so far.
     */
    uint256 public greenMinted;

    /**
     * @notice Green generations minted of each character.
     */
    mapping(uint256 imageId => uint256 count) public greenCount;

    /**
     * @notice Whether an address has ever minted a green of a character.
     */
    mapping(uint256 imageId => mapping(address minter => bool)) public greenTaken;

    mapping(uint256 word => uint256 bits) private _blueBits;

    /**
     * @notice Deploy the collection and lock in its trait data.
     * @dev Checks the hash each data contract reports, then reads the first and
     *      last record of each chunk. Payable so the deploy can prove the
     *      treasury takes ether.
     * @param c0 Trait records for characters 0 to 4999
     * @param c1 Trait records for characters 5000 to 9999
     * @param n The category and trait value names
     * @param treasury Where the sale's takings and royalties go
     * @param start When minting opens, at most 90 days out
     */
    constructor(ITraitData c0, ITraitData c1, ITraitNames n, address treasury, uint64 start)
        payable
        ERC721("Glamtoon", "GLAMTOON")
    {
        if (treasury == address(0) || treasury == address(this)) revert InvalidPayout();
        if (start > block.timestamp + 90 days) revert SaleStartTooFar();
        if (IMAGE_COUNT != TraitSchema.IMAGE_COUNT) revert BadTraitData();

        if (c0.dataHash() != TraitSchema.DATA_HASH_0) revert BadTraitData();
        if (c1.dataHash() != TraitSchema.DATA_HASH_1) revert BadTraitData();
        if (n.namesHash() != TraitSchema.NAMES_HASH) revert BadTraitNames();

        CHUNK0 = c0;
        CHUNK1 = c1;
        NAMES = n;

        PAYOUT = treasury;
        SALE_START = start;

        _setDefaultRoyalty(treasury, ROYALTY_BPS);

        uint256 per = TraitSchema.IMAGES_PER_CHUNK;
        _record(0);
        _record(per - 1);
        _record(per);
        _record(IMAGE_COUNT - 1);

        if (msg.value > 0) Address.sendValue(payable(treasury), msg.value);
    }

    /**
     * @notice Buy the blue edition of a character.
     * @param imageId Which character, from 0 to 9999
     * @param maxPrice The most the caller is willing to pay
     */
    function mintBlue(uint256 imageId, uint256 maxPrice) external payable nonReentrant {
        _mintBlue(msg.sender, imageId, maxPrice);
    }

    /**
     * @notice Buy the blue edition of a character for somebody else.
     * @dev The change goes back to the payer.
     * @param to Who receives the token
     * @param imageId Which character, from 0 to 9999
     * @param maxPrice The most the caller is willing to pay
     */
    function mintBlueFor(address to, uint256 imageId, uint256 maxPrice) external payable nonReentrant {
        _mintBlue(to, imageId, maxPrice);
    }

    /**
     * @notice The blue sale, shared by mintBlue and mintBlueFor.
     * @dev Every storage write comes before the onERC721Received call in
     *      _safeMint and before the refund, the two calls into untrusted code.
     * @param to Who receives the token
     * @param imageId Which character, from 0 to 9999
     * @param maxPrice The most the caller is willing to pay
     */
    function _mintBlue(address to, uint256 imageId, uint256 maxPrice) private {
        if (block.timestamp < SALE_START) revert NotStarted();
        if (imageId >= IMAGE_COUNT) revert InvalidImageId();

        uint256 sold = blueMinted;
        if (sold >= BLUE_SUPPLY) revert SoldOut();
        if (_ownerOf(imageId) != address(0)) revert BlueAlreadyTaken();

        uint256 price = priceAt(sold);
        if (price > maxPrice) revert PriceTooHigh();
        if (msg.value < price) revert InsufficientPayment();

        blueMinted = sold + 1;
        _blueBits[imageId >> 8] |= uint256(1) << (imageId & 0xff);

        emit BlueMinted(to, msg.sender, imageId, price);
        _safeMint(to, imageId);

        if (msg.value > price) {
            Address.sendValue(payable(msg.sender), msg.value - price);
        }
    }

    /**
     * @notice Mint the next green generation of a character. It costs only gas.
     * @dev Each address may mint one green of each character, ever. A minter
     *      with code must implement onERC721Received.
     * @param imageId Which character, from 0 to 9999
     */
    function mintGreen(uint256 imageId) external nonReentrant {
        if (block.timestamp < SALE_START) revert NotStarted();
        if (imageId >= IMAGE_COUNT) revert InvalidImageId();
        if (greenTaken[imageId][msg.sender]) revert GreenAlreadyTaken();

        greenTaken[imageId][msg.sender] = true;
        uint256 generation = greenCount[imageId] + 1;
        greenCount[imageId] = generation;
        greenMinted += 1;

        emit GreenMinted(msg.sender, imageId, generation);
        _safeMint(msg.sender, tokenIdFor(imageId, generation));
    }

    /**
     * @notice Send the whole balance to the treasury. Anyone may call it.
     */
    function withdraw() external nonReentrant {
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToWithdraw();
        emit Withdrawn(amount);
        Address.sendValue(payable(PAYOUT), amount);
    }

    /**
     * @notice The treasury's owner, so marketplaces know who may edit the
     *         collection page.
     * @dev Grants nothing in this contract. Returns the zero address when the
     *      treasury reverts or does not answer with a single address.
     * @return The treasury's owner, or the zero address
     */
    function owner() external view returns (address) {
        (bool ok, bytes memory answer) = PAYOUT.staticcall(abi.encodeCall(IOwned.owner, ()));
        if (!ok || answer.length != 32) return address(0);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 word = uint256(bytes32(answer));
        if (word > type(uint160).max) return address(0);

        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(word));
    }

    /**
     * @notice What the next blue costs. Reverts once sold out.
     * @return Price in wei
     */
    function currentPrice() external view returns (uint256) {
        return priceAt(blueMinted);
    }

    /**
     * @notice What a blue costs after a given number of sales. Reverts when
     *         sold is BLUE_SUPPLY or more.
     * @param sold Blue tokens already sold
     * @return Price in wei
     */
    function priceAt(uint256 sold) public pure returns (uint256) {
        if (sold >= BLUE_SUPPLY) revert SoldOut();
        return PRICE_STEP * (1 + sold / TIER_SIZE);
    }

    /**
     * @notice The token id of one generation of one character.
     * @dev Checked arithmetic, so an overflow reverts instead of colliding.
     * @param imageId Which character, from 0 to 9999
     * @param generation Which generation, zero being blue
     * @return The token id
     */
    function tokenIdFor(uint256 imageId, uint256 generation) public pure returns (uint256) {
        if (imageId >= IMAGE_COUNT) revert InvalidImageId();
        return generation * IMAGE_COUNT + imageId;
    }

    /**
     * @notice The character and generation of any token id.
     * @param tokenId The token to decode
     * @return imageId Which character, from 0 to 9999
     * @return generation Which generation, zero being blue
     */
    function decode(uint256 tokenId) public pure returns (uint256 imageId, uint256 generation) {
        imageId = tokenId % IMAGE_COUNT;
        generation = tokenId / IMAGE_COUNT;
    }

    /**
     * @notice The character a token depicts.
     * @param tokenId The token to decode
     * @return imageId Which character, from 0 to 9999
     */
    function imageIdOf(uint256 tokenId) public pure returns (uint256 imageId) {
        (imageId,) = decode(tokenId);
    }

    /**
     * @notice Which generation of its character a token is. Zero is blue.
     * @param tokenId The token to decode
     * @return generation Which generation
     */
    function generationOf(uint256 tokenId) public pure returns (uint256 generation) {
        (, generation) = decode(tokenId);
    }

    /**
     * @notice Whether an id is in the blue range, minted or not.
     * @param tokenId The token to check
     * @return True when the id is a blue one
     */
    function isBlue(uint256 tokenId) public pure returns (bool) {
        return tokenId < IMAGE_COUNT;
    }

    /**
     * @notice The metadata of one token, as a base64 data URI.
     * @param tokenId The token to describe
     * @return The metadata as a data URI
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string.concat("data:application/json;base64,", Base64.encode(bytes(tokenJSON(tokenId))));
    }

    /**
     * @notice The same metadata as plain JSON, for any id, minted or not.
     * @param tokenId The token to describe
     * @return The metadata as JSON
     */
    function tokenJSON(uint256 tokenId) public view returns (string memory) {
        (uint256 imageId, uint256 generation) = decode(tokenId);
        bool blue = generation == 0;
        string memory id = imageId.toString();

        return string.concat(
            '{"name":"Glamtoon #',
            id,
            blue ? '"' : string.concat(" Gen ", generation.toString(), '"'),
            ',"description":"',
            DESCRIPTION,
            '","image":"',
            _uri(IPFS_SCHEME, IPFS_ROOT, blue, id, FULL_EXT),
            '","external_url":"',
            TOKEN_BASE,
            tokenId.toString(),
            '","glamtoon":{"optimized":"',
            _uri(IPFS_SCHEME, IPFS_ROOT, blue, id, LITE_EXT),
            '","arweave":"',
            _uri(AR_SCHEME, ARWEAVE, blue, id, FULL_EXT),
            '","arweave_optimized":"',
            _uri(AR_SCHEME, ARWEAVE, blue, id, LITE_EXT),
            '","image_id":',
            id,
            ',"generation":',
            generation.toString(),
            '},"attributes":',
            _attributes(imageId, generation, blue),
            "}"
        );
    }

    /**
     * @notice Collection level metadata, as a data URI.
     * @return The collection metadata as a data URI
     */
    function contractURI() external pure returns (string memory) {
        return string.concat("data:application/json;base64,", Base64.encode(bytes(collectionJSON())));
    }

    /**
     * @notice Collection level metadata, as plain JSON.
     * @return The collection metadata as JSON
     */
    function collectionJSON() public pure returns (string memory) {
        return string.concat(
            '{"name":"Glamtoon","description":"Ten thousand characters, each one ',
            "drawn once and issued in two editions. The blue edition is the genesis: one per ",
            "character, ten thousand in all, and no more ever. The green edition is ",
            "free and open, and every mint of a character takes the next generation ",
            'of it.","image":"',
            _uri(IPFS_SCHEME, IPFS_ROOT, true, "0", LITE_EXT),
            '","external_link":"https://glamtoon.com"}'
        );
    }

    /**
     * @notice True for ERC165, ERC721, ERC721 metadata and ERC2981.
     * @param interfaceId The interface to check
     * @return True when the interface is supported
     */
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @notice Full resolution art for one edition of one character.
     * @param imageId Which character, from 0 to 9999
     * @param blue True for the Genesis Blue edition
     * @return An IPFS URL
     */
    function imageURI(uint256 imageId, bool blue) external pure returns (string memory) {
        return _uri(IPFS_SCHEME, IPFS_ROOT, blue, _checked(imageId), FULL_EXT);
    }

    /**
     * @notice The lighter copy of the art.
     * @param imageId Which character, from 0 to 9999
     * @param blue True for the Genesis Blue edition
     * @return An IPFS URL
     */
    function optimizedURI(uint256 imageId, bool blue) external pure returns (string memory) {
        return _uri(IPFS_SCHEME, IPFS_ROOT, blue, _checked(imageId), LITE_EXT);
    }

    /**
     * @notice The full resolution art on Arweave.
     * @param imageId Which character, from 0 to 9999
     * @param blue True for the Genesis Blue edition
     * @return An Arweave URL
     */
    function arweaveURI(uint256 imageId, bool blue) external pure returns (string memory) {
        return _uri(AR_SCHEME, ARWEAVE, blue, _checked(imageId), FULL_EXT);
    }

    /**
     * @notice The lighter art on Arweave.
     * @param imageId Which character, from 0 to 9999
     * @param blue True for the Genesis Blue edition
     * @return An Arweave URL
     */
    function arweaveOptimizedURI(uint256 imageId, bool blue) external pure returns (string memory) {
        return _uri(AR_SCHEME, ARWEAVE, blue, _checked(imageId), LITE_EXT);
    }

    /**
     * @notice The IPFS root holding all the art.
     * @return The CID
     */
    function ipfsRoot() external pure returns (string memory) {
        return IPFS_ROOT;
    }

    /**
     * @notice The Arweave manifest covering all the art.
     * @return The manifest transaction id
     */
    function arweaveManifest() external pure returns (string memory) {
        return ARWEAVE;
    }

    /**
     * @notice The base of each token's web page. The token id follows it.
     * @return The base URL
     */
    function tokenBase() external pure returns (string memory) {
        return TOKEN_BASE;
    }

    /**
     * @notice The trait value index of every category for one character. The
     *         same for every generation.
     * @param imageId Which character, from 0 to 9999
     * @return values One value index per category, in record order
     */
    function traitsOf(uint256 imageId) public view returns (uint8[4] memory values) {
        uint40 packed = _record(imageId);
        uint8[4] memory shift = TraitSchema.shifts();
        uint40[4] memory mask = TraitSchema.masks();
        for (uint256 c = 0; c < TraitSchema.CATEGORY_COUNT; ++c) {
            values[c] = uint8((packed >> shift[c]) & mask[c]);
        }
    }

    /**
     * @notice Traits for several characters in one call.
     * @param imageIds The characters to read
     * @return out One set of value indices per character
     */
    function traitsBatch(uint256[] calldata imageIds) external view returns (uint8[4][] memory out) {
        out = new uint8[4][](imageIds.length);
        for (uint256 i = 0; i < imageIds.length; ++i) {
            out[i] = traitsOf(imageIds[i]);
        }
    }

    /**
     * @notice The packed record for one character, undecoded.
     * @param imageId Which character, from 0 to 9999
     * @return The packed record
     */
    function recordOf(uint256 imageId) external view returns (uint40) {
        return _record(imageId);
    }

    /**
     * @notice One chunk of the trait table, raw.
     * @param index Which chunk, 0 or 1
     * @return The chunk's bytes
     */
    function traitChunk(uint256 index) external view returns (bytes memory) {
        if (index >= TraitSchema.CHUNK_COUNT) revert InvalidChunk();
        return _chunk(index).data();
    }

    /**
     * @notice The whole trait table in one call.
     * @return Every record, in character order
     */
    function allTraits() external view returns (bytes memory) {
        return bytes.concat(CHUNK0.data(), CHUNK1.data());
    }

    /**
     * @notice The raw name table.
     * @return Every name, in fixed width slots
     */
    function traitNames() external view returns (bytes memory) {
        return NAMES.data();
    }

    /**
     * @notice The name of every category, in record order.
     * @return The category names
     */
    function categoryNames() external view returns (string[] memory) {
        uint256[] memory slots = new uint256[](TraitSchema.CATEGORY_COUNT);
        for (uint256 c = 0; c < TraitSchema.CATEGORY_COUNT; ++c) {
            slots[c] = c;
        }
        return NAMES.namesAt(slots);
    }

    /**
     * @notice Every value name of one category, padded to the full range of
     *         its bits. Unused slots read as a dash.
     * @param category Which category, from 0 to 3
     * @return The value names
     */
    function valueNames(uint256 category) external view returns (string[] memory) {
        if (category >= TraitSchema.CATEGORY_COUNT) revert InvalidCategory();
        uint40[4] memory mask = TraitSchema.masks();
        uint16[4] memory base = TraitSchema.valueBase();
        uint256 count = uint256(mask[category]) + 1;
        uint256[] memory slots = new uint256[](count);
        for (uint256 v = 0; v < count; ++v) {
            slots[v] = base[category] + v;
        }
        return NAMES.namesAt(slots);
    }

    /**
     * @notice How many tokens exist, both editions.
     * @return The total supply
     */
    function totalSupply() external view returns (uint256) {
        return blueMinted + greenMinted;
    }

    /**
     * @notice Whether a character's blue has been sold.
     * @param imageId Which character, from 0 to 9999
     * @return True when the blue edition is taken
     */
    function blueTaken(uint256 imageId) external view returns (bool) {
        if (imageId >= IMAGE_COUNT) revert InvalidImageId();
        return _ownerOf(imageId) != address(0);
    }

    /**
     * @notice Which blues are sold, as a bitmap with 256 characters to a word.
     * @param startWord First word to read
     * @param words How many words to read
     * @return taken The bitmap words
     */
    function blueTakenBits(uint256 startWord, uint256 words) external view returns (uint256[] memory taken) {
        if (words > BITMAP_WORDS || startWord > BITMAP_WORDS - words) revert InvalidWordRange();
        taken = new uint256[](words);
        for (uint256 i = 0; i < words; ++i) {
            taken[i] = _blueBits[startWord + i];
        }
    }

    /**
     * @notice How many words the blue bitmap holds.
     * @return The word count
     */
    function blueBitmapWords() external pure returns (uint256) {
        return BITMAP_WORDS;
    }

    /**
     * @notice Whether one address has minted a green of several characters.
     *         Ids out of range answer false.
     * @param imageIds The characters to read
     * @param who The address to ask about
     * @return taken One answer per character, in the order asked
     */
    function greenTakenBatch(uint256[] calldata imageIds, address who) external view returns (bool[] memory taken) {
        taken = new bool[](imageIds.length);
        for (uint256 i = 0; i < imageIds.length; ++i) {
            taken[i] = greenTaken[imageIds[i]][who];
        }
    }

    /**
     * @notice Green generation counts for several characters at once.
     *         Ids out of range answer zero.
     * @param imageIds The characters to read
     * @return counts One count per character
     */
    function greenCountBatch(uint256[] calldata imageIds) external view returns (uint256[] memory counts) {
        counts = new uint256[](imageIds.length);
        for (uint256 i = 0; i < imageIds.length; ++i) {
            counts[i] = greenCount[imageIds[i]];
        }
    }

    function _isNone(string memory value) private pure returns (bool) {
        return keccak256(bytes(value)) == keccak256(bytes("None"));
    }

    /**
     * @notice Build the attributes array for one token.
     * @dev Every value is a string, and a value of None is left out.
     * @param imageId Which character
     * @param generation Which generation
     * @param blue True for the Genesis Blue edition
     * @return The attributes array as JSON
     */
    function _attributes(uint256 imageId, uint256 generation, bool blue) private view returns (string memory) {
        uint8[4] memory values = traitsOf(imageId);
        uint16[4] memory base = TraitSchema.valueBase();

        uint256[] memory slots = new uint256[](TraitSchema.CATEGORY_COUNT * 2);
        for (uint256 c = 0; c < TraitSchema.CATEGORY_COUNT; ++c) {
            slots[c * 2] = c;
            slots[c * 2 + 1] = uint256(base[c]) + values[c];
        }
        string[] memory name = NAMES.namesAt(slots);

        string memory out =
            string.concat('[{"trait_type":"Edition","value":"', blue ? "Genesis Blue" : "Generation Green", '"}');
        for (uint256 c = 0; c < TraitSchema.CATEGORY_COUNT; ++c) {
            if (_isNone(name[c * 2 + 1])) continue;
            out = string.concat(out, ',{"trait_type":"', name[c * 2], '","value":"', name[c * 2 + 1], '"}');
        }
        return string.concat(out, ',{"trait_type":"Generation","value":"', _generationLabel(generation), '"}]');
    }

    /**
     * @notice The Generation trait value, grouped from GENERATION_SHOWN up.
     * @param generation Which generation
     * @return The trait value
     */
    function _generationLabel(uint256 generation) private pure returns (string memory) {
        if (generation >= GENERATION_SHOWN) {
            return string.concat(GENERATION_SHOWN.toString(), "+");
        }
        return generation.toString();
    }

    /**
     * @notice Build one art URL.
     * @param scheme The IPFS or Arweave scheme
     * @param root The CID or manifest id
     * @param blue True for the Genesis Blue edition
     * @param id The character number as a string
     * @param ext The file extension
     * @return The URL
     */
    function _uri(string memory scheme, string memory root, bool blue, string memory id, string memory ext)
        private
        pure
        returns (string memory)
    {
        return string.concat(scheme, root, blue ? BLUE_DIR : GREEN_DIR, id, ext);
    }

    /**
     * @notice Check a character number and render it as a string.
     * @param imageId Which character, from 0 to 9999
     * @return The character number as a string
     */
    function _checked(uint256 imageId) private pure returns (string memory) {
        if (imageId >= IMAGE_COUNT) revert InvalidImageId();
        return imageId.toString();
    }

    /**
     * @notice Read the packed trait record for one character.
     * @param imageId Which character, from 0 to 9999
     * @return The packed record
     */
    function _record(uint256 imageId) private view returns (uint40) {
        if (imageId >= IMAGE_COUNT) revert InvalidImageId();
        return _chunk(imageId / TraitSchema.IMAGES_PER_CHUNK).record(imageId);
    }

    /**
     * @notice The data contract holding a given chunk.
     * @param index Which chunk, 0 or 1
     * @return The data contract
     */
    function _chunk(uint256 index) private view returns (ITraitData) {
        if (index == 0) return CHUNK0;
        return CHUNK1;
    }
}
