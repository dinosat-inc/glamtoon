// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BaseTest} from "../Base.t.sol";
import {IERC721Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {TraitSchema} from "../../src/gen/TraitSchema.sol";

/// The on chain JSON is the only description of a Glamtoon that outlives the
/// team, and nothing can edit it afterwards. TokenURI.t.sol covers the shapes it
/// takes; this covers what it does not. The field set itself, the data URI read
/// back the way a marketplace reads it, the attribute count on a character with
/// no hair, the generation label reached by minting rather than by arithmetic,
/// the four art URLs against the four public getters, and a few whole documents
/// written out byte for byte.
contract MetadataJsonTest is BaseTest {
    string constant PREFIX = "data:application/json;base64,";
    string constant SITE = "https://glamtoon.com/token/";
    string constant CSV = "test/fixtures/traits.csv";

    /// The sentence on every token, and the paragraph on the collection page,
    /// written out here so the byte for byte documents below owe nothing to the
    /// contract's own constants.
    string constant DESCRIPTION = "A Glamtoon character. 10,000 portraits, ages 18 to 70, in two inks.";
    string constant PARAGRAPH = "Ten thousand characters, each one drawn once and issued in two editions. "
        "The blue edition is the genesis: one per character, ten thousand in all, and no more ever. "
        "The green edition is free and open, and every mint of a character takes the next generation of it.";

    /// The category names come out of the pipeline's own CSV header, so the
    /// expectation is never the contract restating itself.
    string[4] internal category;

    function setUp() public override {
        super.setUp();
        string[5] memory header = _openCsv();
        for (uint256 c = 0; c < 4; ++c) {
            category[c] = header[c + 1];
        }
        vm.closeFile(CSV);
    }

    /*//////////////////////////////////////////////////////////////
                               STRUCTURE
    //////////////////////////////////////////////////////////////*/

    /// A marketplace reads this document by field name. One renamed, dropped or
    /// added is a silent change to how all twenty thousand tokens display, with
    /// no setter to put it back.
    function test_theTopLevelFieldsAreExactlyTheSix(uint256 tokenId) public view {
        string memory j = _json(tokenId);

        string[] memory keys = vm.parseJsonKeys(j, "$");
        assertEq(keys.length, 6, "top level field count");
        assertEq(keys[0], "name", "first");
        assertEq(keys[1], "description", "second");
        assertEq(keys[2], "image", "third");
        assertEq(keys[3], "external_url", "fourth");
        assertEq(keys[4], "glamtoon", "fifth");
        assertEq(keys[5], "attributes", "sixth");

        string[] memory inner = vm.parseJsonKeys(j, ".glamtoon");
        assertEq(inner.length, 5, "glamtoon field count");
        assertEq(inner[0], "optimized", "first");
        assertEq(inner[1], "arweave", "second");
        assertEq(inner[2], "arweave_optimized", "third");
        assertEq(inner[3], "image_id", "fourth");
        assertEq(inner[4], "generation", "fifth");
    }

    /// Every field of a whole document, for both editions, at both ends of the
    /// table and either side of the chunk seam, built from the identifiers
    /// rather than from the contract's own concatenation.
    function test_everyFieldOfASpreadOfTokens() public view {
        uint256[6] memory ids = [uint256(0), 1, 4999, 5000, 9999, 7412];
        uint256[4] memory gens = [uint256(0), 1, 8, 9];
        for (uint256 i = 0; i < ids.length; ++i) {
            for (uint256 g = 0; g < gens.length; ++g) {
                _assertDocument(ids[i], gens[g]);
            }
        }
    }

    /// A blue with hair, byte for byte. Every other test here reads the document
    /// through a parser, which forgives a stray space, a trailing newline and a
    /// number written as a string. This one does not: no whitespace anywhere,
    /// every attribute value a string, the two numbers bare, and the keys in the
    /// order written. The traits come off the sheet's row for character 0.
    function test_theRawDocumentOfABlueIsExactlyTheWrittenOutBytes() public {
        string[5] memory row = _sheetRow(0);
        assertFalse(_eq(row[4], "None"), "character 0 has hair on the sheet");

        string memory want = string.concat(
            '{"name":"Glamtoon #0","description":"',
            DESCRIPTION,
            '","image":"ipfs://',
            nft.ipfsRoot(),
            '/blue/0.png","external_url":"https://glamtoon.com/token/0","glamtoon":{"optimized":"ipfs://',
            nft.ipfsRoot(),
            '/blue/0.webp","arweave":"ar://',
            nft.arweaveManifest(),
            '/blue/0.png","arweave_optimized":"ar://',
            nft.arweaveManifest(),
            '/blue/0.webp","image_id":0,"generation":0},"attributes":['
        );
        want = string.concat(
            want,
            '{"trait_type":"Edition","value":"Genesis Blue"},',
            string.concat('{"trait_type":"Dress Code","value":"', row[1], '"},'),
            string.concat('{"trait_type":"Age","value":"', row[2], '"},'),
            string.concat('{"trait_type":"Hair Cut","value":"', row[3], '"},'),
            string.concat('{"trait_type":"Hair Colour","value":"', row[4], '"},'),
            '{"trait_type":"Generation","value":"0"}]}'
        );
        assertEq(nft.tokenJSON(0), want, "blue document");
    }

    /// A green past the grouping threshold, byte for byte. The name and the page
    /// carry the true generation, the two numbers carry it bare, and only the
    /// Generation attribute collapses to the grouped label.
    function test_theRawDocumentOfAGreenPastTheThresholdIsExactlyTheWrittenOutBytes() public {
        string[5] memory row = _sheetRow(7412);
        assertFalse(_eq(row[4], "None"), "character 7412 has hair on the sheet");

        string memory want = string.concat(
            '{"name":"Glamtoon #7412 Gen 12","description":"',
            DESCRIPTION,
            '","image":"ipfs://',
            nft.ipfsRoot(),
            '/green/7412.png","external_url":"https://glamtoon.com/token/127412","glamtoon":{"optimized":"ipfs://',
            nft.ipfsRoot(),
            '/green/7412.webp","arweave":"ar://',
            nft.arweaveManifest(),
            '/green/7412.png","arweave_optimized":"ar://',
            nft.arweaveManifest(),
            '/green/7412.webp","image_id":7412,"generation":12},"attributes":['
        );
        want = string.concat(
            want,
            '{"trait_type":"Edition","value":"Generation Green"},',
            string.concat('{"trait_type":"Dress Code","value":"', row[1], '"},'),
            string.concat('{"trait_type":"Age","value":"', row[2], '"},'),
            string.concat('{"trait_type":"Hair Cut","value":"', row[3], '"},'),
            string.concat('{"trait_type":"Hair Colour","value":"', row[4], '"},'),
            '{"trait_type":"Generation","value":"9+"}]}'
        );
        assertEq(nft.tokenJSON(nft.tokenIdFor(7412, 12)), want, "green document");
    }

    /// A character with no hair, byte for byte, as a green below the threshold.
    /// The hair cut is followed directly by the generation, with no Hair Colour
    /// element, no empty one and no stray comma where it would have been.
    function test_theRawDocumentOfABaldCharacterIsExactlyTheWrittenOutBytes() public {
        string[5] memory row = _sheetRow(65);
        assertEq(row[4], "None", "character 65 has no hair on the sheet");

        string memory want = string.concat(
            '{"name":"Glamtoon #65 Gen 3","description":"',
            DESCRIPTION,
            '","image":"ipfs://',
            nft.ipfsRoot(),
            '/green/65.png","external_url":"https://glamtoon.com/token/30065","glamtoon":{"optimized":"ipfs://',
            nft.ipfsRoot(),
            '/green/65.webp","arweave":"ar://',
            nft.arweaveManifest(),
            '/green/65.png","arweave_optimized":"ar://',
            nft.arweaveManifest(),
            '/green/65.webp","image_id":65,"generation":3},"attributes":['
        );
        want = string.concat(
            want,
            '{"trait_type":"Edition","value":"Generation Green"},',
            string.concat('{"trait_type":"Dress Code","value":"', row[1], '"},'),
            string.concat('{"trait_type":"Age","value":"', row[2], '"},'),
            string.concat('{"trait_type":"Hair Cut","value":"', row[3], '"},'),
            '{"trait_type":"Generation","value":"3"}]}'
        );
        assertEq(nft.tokenJSON(nft.tokenIdFor(65, 3)), want, "bald document");
    }

    /// The pair that decides the edition everywhere else in the contract. Token
    /// 9999 is the last blue and 10000 is the first green, so the flip has to
    /// land between them and nowhere else.
    function test_theEditionFlipsExactlyAtTheEndOfTheBlueRange() public view {
        assertTrue(nft.isBlue(9999), "9999 is blue");
        assertFalse(nft.isBlue(10_000), "10000 is not");
        assertEq(_attrs(_json(9999))[0].value, "Genesis Blue", "last blue");
        assertEq(_attrs(_json(10_000))[0].value, "Generation Green", "first green");
        assertEq(vm.parseJsonString(_json(9999), ".name"), "Glamtoon #9999", "no generation on a blue");
        assertEq(vm.parseJsonString(_json(10_000), ".name"), "Glamtoon #0 Gen 1", "character 0, generation 1");
    }

    /// decode() is what groups a character's generations together on a
    /// marketplace. The two numeric fields are the only place it is published,
    /// and they go out as bare JSON numbers. The parser reads a quoted "7412"
    /// back as 7412 just the same, so the bytes are checked as well.
    function test_theNumericFieldsCarryTheDecodedToken(uint256 tokenId) public view {
        string memory j = _json(tokenId);
        assertEq(vm.parseJsonUint(j, ".glamtoon.image_id"), tokenId % 10_000, "image_id");
        assertEq(vm.parseJsonUint(j, ".glamtoon.generation"), tokenId / 10_000, "generation");
        assertEq(vm.parseJsonUint(j, ".glamtoon.image_id"), nft.imageIdOf(tokenId), "image_id against the getter");
        assertEq(vm.parseJsonUint(j, ".glamtoon.generation"), nft.generationOf(tokenId), "generation against it");

        string memory bare = string.concat(
            '"image_id":', vm.toString(tokenId % 10_000), ',"generation":', vm.toString(tokenId / 10_000), "},"
        );
        assertTrue(vm.contains(j, bare), "image_id and generation are not bare numbers");
    }

    /// The sentence a buyer reads on every listing. It is fixed at deployment,
    /// so this is the last chance to notice a typo in it.
    function test_theDescriptionIsOneFixedSentenceOnEveryToken() public view {
        string memory want = "A Glamtoon character. 10,000 portraits, ages 18 to 70, in two inks.";
        assertEq(vm.parseJsonString(_json(0), ".description"), want, "blue");
        assertEq(vm.parseJsonString(_json(nft.tokenIdFor(0, 1)), ".description"), want, "green");
        assertEq(vm.parseJsonString(_json(9999), ".description"), want, "last character");
        assertEq(vm.parseJsonString(_json(type(uint256).max), ".description"), want, "and a token that cannot exist");
    }

    /// Structural proof separate from the parser: a document that parsed but
    /// carried an empty element would mean a concatenation dropped its content
    /// rather than its comma.
    function test_theDocumentHasNoEmptyElements(uint256 tokenId) public view {
        bytes memory j = bytes(_json(tokenId));
        assertFalse(_contains(j, bytes(",,")), "empty element");
        assertFalse(_contains(j, bytes(",}")), "trailing comma in an object");
        assertFalse(_contains(j, bytes(",]")), "trailing comma in an array");
        assertFalse(_contains(j, bytes("{,")), "leading comma in an object");
        assertFalse(_contains(j, bytes("[,")), "leading comma in an array");
        assertFalse(_contains(j, bytes(':""')), "an empty string value");
        assertFalse(_contains(j, bytes("}{")), "two objects with nothing between them");
    }

    /*//////////////////////////////////////////////////////////////
                                DATA URI
    //////////////////////////////////////////////////////////////*/

    /// A marketplace does not re-encode, it decodes. So decode it, the way the
    /// marketplace will, and read the JSON back out the far side.
    function test_theTokenUriDecodesBackToTheTokenJson() public {
        _buy(alice, 1);
        uint256 green = _green(bob, 1);

        uint256[2] memory minted = [uint256(1), green];
        for (uint256 i = 0; i < minted.length; ++i) {
            string memory uri = nft.tokenURI(minted[i]);
            string memory payload = _afterPrefix(uri, PREFIX);
            assertEq(string(B64.decode(payload)), nft.tokenJSON(minted[i]), "decoded body is not the json");
        }
    }

    /// Standard alphabet, padded, and on one line. A wrapped or url-safe
    /// encoding still decodes in some tools and shows nothing in others, and the
    /// prefix has to be the media type a wallet dispatches on.
    function test_theDataUriIsASingleLineOfStandardBase64() public {
        _buy(alice, 2);
        string memory uri = nft.tokenURI(2);
        assertTrue(_startsWith(bytes(uri), bytes(PREFIX)), "prefix");
        assertEq(_countOf(bytes(uri), ","), 1, "the prefix comma must be the only one");

        bytes memory payload = bytes(_afterPrefix(uri, PREFIX));
        assertEq(payload.length % 4, 0, "base64 is quantised to four characters");
        for (uint256 i = 0; i < payload.length; ++i) {
            bytes1 c = payload[i];
            bool ok = (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "+" || c == "/"
                || (c == "=" && i >= payload.length - 2);
            assertTrue(ok, "a character outside padded standard base64");
        }
    }

    /// The collection document is what sets the name, the royalty banner and the
    /// thumbnail on the collection page, and it is read once and cached.
    function test_theContractUriDecodesBackToTheCollectionJson() public view {
        string memory payload = _afterPrefix(nft.contractURI(), PREFIX);
        assertEq(string(B64.decode(payload)), nft.collectionJSON(), "decoded body is not the collection json");

        string memory j = nft.collectionJSON();
        string[] memory keys = vm.parseJsonKeys(j, "$");
        assertEq(keys.length, 4, "collection field count");
        assertEq(keys[0], "name", "first");
        assertEq(keys[1], "description", "second");
        assertEq(keys[2], "image", "third");
        assertEq(keys[3], "external_link", "fourth");
    }

    /// The paragraph a marketplace shows on the collection page, word for word,
    /// from the plain document and from the data URI a marketplace decodes. The
    /// source joins it from five pieces, and a space lost between two of them
    /// would read wrong for good.
    function test_theCollectionDescriptionIsTheFixedParagraph() public view {
        assertEq(vm.parseJsonString(nft.collectionJSON(), ".description"), PARAGRAPH, "collectionJSON");

        string memory decoded = string(B64.decode(_afterPrefix(nft.contractURI(), PREFIX)));
        assertEq(vm.parseJsonString(decoded, ".description"), PARAGRAPH, "contractURI");
    }

    /// The whole collection document byte for byte, for the same reason as the
    /// token documents: a parser forgives whitespace a strict reader may not.
    function test_theRawCollectionDocumentIsExactlyTheWrittenOutBytes() public view {
        string memory want = string.concat(
            '{"name":"Glamtoon","description":"',
            PARAGRAPH,
            '","image":"ipfs://',
            nft.ipfsRoot(),
            '/blue/0.webp","external_link":"https://glamtoon.com"}'
        );
        assertEq(nft.collectionJSON(), want, "collection document");
    }

    /// The collection thumbnail is the lighter blue copy of character zero. A
    /// full png here is a several megabyte download on a listing page, and a
    /// green file would put the free edition on the front of the paid one.
    function test_theCollectionImageIsTheBlueWebp() public view {
        string memory image = vm.parseJsonString(nft.collectionJSON(), ".image");
        assertEq(image, _wantUri("ipfs://", nft.ipfsRoot(), true, 0, ".webp"), "collection image");
        assertEq(image, nft.optimizedURI(0, true), "and the getter for the same file");
        assertTrue(_contains(bytes(image), bytes("/blue/")), "blue edition");
        assertFalse(_contains(bytes(image), bytes("/green/")), "not the green one");
        assertTrue(_endsWith(bytes(image), bytes(".webp")), "the lighter copy");
    }

    /*//////////////////////////////////////////////////////////////
                               ATTRIBUTES
    //////////////////////////////////////////////////////////////*/

    /// Edition first and Generation last is the order the filter row is built
    /// in. The traits between them are the character's own.
    function test_editionOpensTheArrayAndGenerationClosesIt() public {
        _buy(alice, 0);
        uint256 green = _green(alice, 0);

        Attr[] memory blue = _attrs(nft.tokenJSON(0));
        assertEq(blue[0].trait_type, "Edition", "first on a blue");
        assertEq(blue[0].value, "Genesis Blue", "blue edition");
        assertEq(blue[blue.length - 1].trait_type, "Generation", "last on a blue");

        Attr[] memory g = _attrs(nft.tokenJSON(green));
        assertEq(g[0].trait_type, "Edition", "first on a green");
        assertEq(g[0].value, "Generation Green", "green edition");
        assertEq(g[g.length - 1].trait_type, "Generation", "last on a green");
        assertEq(g[g.length - 1].value, "1", "the generation that was actually minted");
    }

    /// A character with no hair must carry no hair colour at all. An attribute
    /// reading None would give the collection a None trait to filter on and rank
    /// by, which is the opposite of what an absent trait means.
    function test_aCharacterWithNoHairColourCarriesFiveAttributes() public {
        uint256 imageId = _firstCsvIdWithColour("None");

        Attr[] memory a = _attrs(_json(imageId));
        assertEq(a.length, 5, "five attributes, not six");
        assertEq(a[0].trait_type, "Edition", "first");
        assertEq(a[1].trait_type, category[0], "dress code");
        assertEq(a[2].trait_type, category[1], "age");
        assertEq(a[3].trait_type, category[2], "hair cut");
        assertEq(a[4].trait_type, "Generation", "last, with no hair colour before it");

        bytes memory j = bytes(_json(imageId));
        assertFalse(_contains(j, bytes(category[3])), "the hair colour attribute survived");
        assertFalse(_contains(j, bytes("None")), "the word None reached the document");
    }

    /// The other side of the same branch. Dropping a trait that exists would be
    /// just as permanent as keeping one that does not.
    function test_aCharacterWithHairCarriesSixAttributes() public {
        (uint256 imageId, string[5] memory row) = _firstCsvRowWithHair();

        Attr[] memory a = _attrs(_json(imageId));
        assertEq(a.length, 6, "six attributes");
        assertEq(a[4].trait_type, category[3], "hair colour is present");
        assertEq(a[4].value, row[4], "and reads what the art pipeline recorded");
        assertEq(a[5].trait_type, "Generation", "generation still closes the array");
    }

    /// Both branches over every one of the 395 characters the pipeline gave no
    /// hair, plus the first hundred characters of the half that have some. One
    /// document per external call so each is freed with its frame, and split
    /// across the two trait chunks because the whole table in one test exceeds
    /// the per test gas budget.
    function test_everyBaldCharacterInChunkZeroDropsItsHairColour() public {
        _skipUnderCoverage();
        (uint256 bald, uint256 haired) = _sweepBaldness(0, TraitSchema.IMAGES_PER_CHUNK - 1);
        assertEq(bald, 199, "the pipeline's count of bald characters in chunk zero moved");
        assertEq(haired, 100, "no haired characters were checked");
    }

    function test_everyBaldCharacterInChunkOneDropsItsHairColour() public {
        _skipUnderCoverage();
        (uint256 bald, uint256 haired) = _sweepBaldness(TraitSchema.IMAGES_PER_CHUNK, 9999);
        assertEq(bald, 196, "the pipeline's count of bald characters in chunk one moved");
        assertEq(haired, 100, "no haired characters were checked");
    }

    /// The attribute values against the art pipeline's own CSV, not against the
    /// contract's tables. This is what catches a category reading through the
    /// wrong value base, which would give every character somebody else's age.
    /// Every 97th row, a prime so the sample does not line up with a chunk seam.
    function test_theAttributeValuesMatchTheArtPipeline() public {
        _openCsv();
        uint256 checked;
        while (true) {
            (bool ok, uint256 imageId, string[5] memory row) = _nextRow();
            if (!ok) break;
            if (imageId % 97 != 0) continue;
            ++checked;

            Attr[] memory a = _attrs(_json(imageId));
            uint256 at = 1;
            for (uint256 c = 0; c < 4; ++c) {
                if (_eq(row[c + 1], "None")) continue;
                assertEq(a[at].trait_type, category[c], "category out of order");
                assertEq(a[at].value, row[c + 1], "value differs from the art metadata");
                ++at;
            }
            assertEq(a.length, at + 1, "an attribute the pipeline did not record");
        }
        vm.closeFile(CSV);
        assertEq(checked, 104, "the sample did not run");
    }

    /// Nothing may reach a listing as an empty string or as one of the padding
    /// slots the name table carries so that no record index is unnamed.
    function test_noAttributeIsEmptyOrPadding() public view {
        uint256[8] memory ids = [uint256(0), 65, 1, 2500, 4999, 5000, 9999, 7412];
        for (uint256 i = 0; i < ids.length; ++i) {
            for (uint256 g = 0; g < 3; ++g) {
                Attr[] memory a = _attrs(_json(nft.tokenIdFor(ids[i], g)));
                assertTrue(a.length == 5 || a.length == 6, "attribute count");
                for (uint256 k = 0; k < a.length; ++k) {
                    assertGt(bytes(a[k].trait_type).length, 0, "an attribute has no name");
                    assertGt(bytes(a[k].value).length, 0, "an attribute has no value");
                    assertFalse(_eq(a[k].value, "-"), "a padding slot reached a listing");
                    assertFalse(_eq(a[k].value, "None"), "a None reached a listing");
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            GENERATION LABEL
    //////////////////////////////////////////////////////////////*/

    /// The label from the only direction that proves it: nine different people
    /// each taking their one generation of the same character, read back through
    /// tokenURI on tokens that actually exist. The ninth is the one that groups.
    function test_aCharacterMintedUpToGenerationNineShowsThePlusLabel() public {
        uint256 imageId = 4242;
        for (uint256 g = 1; g <= 9; ++g) {
            address minter = vm.addr(uint256(keccak256(abi.encodePacked("gen", g))));
            vm.prank(minter);
            nft.mintGreen(imageId);

            uint256 tokenId = nft.tokenIdFor(imageId, g);
            assertEq(nft.ownerOf(tokenId), minter, "generation went to the wrong minter");

            string memory j = string(B64.decode(_afterPrefix(nft.tokenURI(tokenId), PREFIX)));
            Attr[] memory a = _attrs(j);
            string memory want = g < 9 ? vm.toString(g) : "9+";
            assertEq(a[a.length - 1].value, want, "generation label");
            assertEq(vm.parseJsonUint(j, ".glamtoon.generation"), g, "the true generation is still published");
        }
        assertEq(nft.greenCount(imageId), 9, "nine generations exist");
    }

    /// The boundary itself, taken from the constant so the two cannot drift: the
    /// generation below it shows its own number and the threshold does not.
    function test_theLabelGroupsFromTheThresholdUp() public view {
        uint256 shown = nft.GENERATION_SHOWN();
        assertEq(_label(1, shown - 1), vm.toString(shown - 1), "one below the threshold is exact");
        assertEq(_label(1, shown), string.concat(vm.toString(shown), "+"), "the threshold groups");

        uint256[3] memory far = [uint256(10), 99, 1_000_000];
        for (uint256 i = 0; i < far.length; ++i) {
            assertEq(_label(1, far[i]), _label(1, shown), "a far generation made its own row");
        }
    }

    /// Every generation below the threshold is its own plain number, with no
    /// padding and no plus. A leading zero would sort right and read wrong.
    function test_everyGenerationBelowTheThresholdShowsItsOwnNumber() public view {
        for (uint256 g = 0; g < nft.GENERATION_SHOWN(); ++g) {
            assertEq(_label(7412, g), vm.toString(g), "exact label");
        }
    }

    /// No generation, however large, may escape the grouped row and add a value
    /// to the filter.
    function test_noGenerationEscapesTheGroupedRow(uint256 generation) public view {
        generation = bound(generation, nft.GENERATION_SHOWN(), type(uint256).max / 10_000 - 1);
        assertEq(_label(1, generation), "9+", "a generation made its own row");
    }

    /*//////////////////////////////////////////////////////////////
                                ART URLS
    //////////////////////////////////////////////////////////////*/

    /// The four URLs in the document are the four the getters answer with. A
    /// site that reads a getter and a marketplace that reads the document have
    /// to land on the same file.
    function test_theFourUrlsMatchTheFourGetters(uint256 seed) public view {
        uint256 imageId = bound(seed, 0, 9999);
        uint256 generation = bound(uint256(keccak256(abi.encodePacked(seed))), 0, 50);
        bool blue = generation == 0;

        string memory j = _json(nft.tokenIdFor(imageId, generation));
        assertEq(vm.parseJsonString(j, ".image"), nft.imageURI(imageId, blue), "image");
        assertEq(vm.parseJsonString(j, ".glamtoon.optimized"), nft.optimizedURI(imageId, blue), "optimized");
        assertEq(vm.parseJsonString(j, ".glamtoon.arweave"), nft.arweaveURI(imageId, blue), "arweave");
        assertEq(
            vm.parseJsonString(j, ".glamtoon.arweave_optimized"),
            nft.arweaveOptimizedURI(imageId, blue),
            "arweave optimized"
        );
    }

    /// Directory and extension, asserted both ways round. The green file of a
    /// blue token is a different picture, and a png where a webp was promised is
    /// a several megabyte thumbnail.
    function test_theEditionDecidesTheDirectoryAndTheExtension(uint256 seed) public view {
        uint256 imageId = bound(seed, 0, 9999);
        uint256 generation = bound(uint256(keccak256(abi.encodePacked(seed, uint256(1)))), 0, 9);
        bool blue = generation == 0;
        string memory here = blue ? "/blue/" : "/green/";
        string memory there = blue ? "/green/" : "/blue/";

        string memory j = _json(nft.tokenIdFor(imageId, generation));
        string[4] memory url = [
            vm.parseJsonString(j, ".image"),
            vm.parseJsonString(j, ".glamtoon.optimized"),
            vm.parseJsonString(j, ".glamtoon.arweave"),
            vm.parseJsonString(j, ".glamtoon.arweave_optimized")
        ];
        string[4] memory ext = [".png", ".webp", ".png", ".webp"];
        string[4] memory scheme = ["ipfs://", "ipfs://", "ar://", "ar://"];
        string[4] memory root = [nft.ipfsRoot(), nft.ipfsRoot(), nft.arweaveManifest(), nft.arweaveManifest()];

        for (uint256 i = 0; i < 4; ++i) {
            assertEq(url[i], _wantUri(scheme[i], root[i], blue, imageId, ext[i]), "url");
            assertTrue(_contains(bytes(url[i]), bytes(here)), "wrong edition directory");
            assertFalse(_contains(bytes(url[i]), bytes(there)), "the other edition's directory");
            assertTrue(_endsWith(bytes(url[i]), bytes(ext[i])), "wrong extension");
            assertTrue(_startsWith(bytes(url[i]), bytes(scheme[i])), "wrong scheme");
        }
    }

    /// The two editions of a character are the same file name in two folders.
    /// This is the whole premise of the collection, so it is asserted as a
    /// substitution rather than as two separate strings.
    function test_theTwoEditionsDifferOnlyInTheFolder() public view {
        uint256[4] memory ids = [uint256(0), 4999, 5000, 9999];
        for (uint256 i = 0; i < ids.length; ++i) {
            string memory blue = vm.parseJsonString(_json(ids[i]), ".image");
            string memory green = vm.parseJsonString(_json(nft.tokenIdFor(ids[i], 1)), ".image");
            assertEq(_replace(blue, "/blue/", "/green/"), green, "the editions differ by more than the folder");
        }
    }

    /// external_url points at a token's page, and a character has as many pages
    /// as it has generations. The character number here would send every
    /// generation of a character to the same page and lose the token.
    function test_theExternalUrlCarriesTheTokenIdNotTheCharacter(uint256 tokenId) public view {
        string memory url = vm.parseJsonString(_json(tokenId), ".external_url");
        assertEq(url, string.concat(SITE, vm.toString(tokenId)), "external url");
        assertEq(nft.tokenBase(), SITE, "the base moved");

        uint256 suffix = _toUint(bytes(_afterPrefix(url, SITE)));
        assertEq(suffix, tokenId, "the url does not name the token");
    }

    /// Made explicit for a green, because it is the case where the two numbers
    /// differ and where the mistake would be invisible on a blue.
    function test_aGreenPageIsNotTheCharacterPage() public view {
        string memory url = vm.parseJsonString(_json(nft.tokenIdFor(7412, 3)), ".external_url");
        assertEq(url, "https://glamtoon.com/token/37412", "green page");
        assertFalse(_endsWith(bytes(url), bytes("/7412")), "the green fell back to the character page");
    }

    /*//////////////////////////////////////////////////////////////
                               EXISTENCE
    //////////////////////////////////////////////////////////////*/

    /// tokenURI follows the standard and refuses an id nobody owns, while
    /// tokenJSON is the preview and answers for anything. Both doors, both
    /// editions, so neither drifts into the other's behaviour.
    function test_tokenUriRefusesAnUnmintedIdWhileTokenJsonAnswers() public {
        uint256 green = nft.tokenIdFor(5, 1);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(5)));
        nft.tokenURI(5);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, green));
        nft.tokenURI(green);

        assertGt(bytes(nft.tokenJSON(5)).length, 200, "the blue preview went missing");
        assertGt(bytes(nft.tokenJSON(green)).length, 200, "the green preview went missing");
    }

    /// The preview a buyer reads before paying has to be the document they own
    /// afterwards, or the sale was made on different terms than it settled on.
    function test_thePreviewIsTheDocumentTheBuyerEndsUpWith() public {
        string memory previewBlue = nft.tokenJSON(3);
        string memory previewGreen = nft.tokenJSON(nft.tokenIdFor(3, 1));

        _buy(alice, 3);
        uint256 green = _green(bob, 3);

        assertEq(nft.tokenJSON(3), previewBlue, "the blue changed on being bought");
        assertEq(nft.tokenJSON(green), previewGreen, "the green changed on being minted");
        assertEq(string(B64.decode(_afterPrefix(nft.tokenURI(3), PREFIX))), previewBlue, "blue uri against the preview");
        assertEq(
            string(B64.decode(_afterPrefix(nft.tokenURI(green), PREFIX))), previewGreen, "green uri against the preview"
        );
    }

    /// Ownership is not part of the document, so transferring a token must not
    /// change a byte of it.
    function test_theDocumentDoesNotFollowTheOwner() public {
        _buy(alice, 6);
        string memory before = nft.tokenURI(6);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 6);
        assertEq(nft.tokenURI(6), before, "the document followed the owner");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// Every bald character in a range, and the first hundred haired ones, read
    /// one document at a time.
    function _sweepBaldness(uint256 from, uint256 to) internal returns (uint256 bald, uint256 haired) {
        _openCsv();
        while (true) {
            (bool ok, uint256 imageId, string[5] memory row) = _nextRow();
            if (!ok) break;
            if (imageId < from || imageId > to) continue;

            bool isBald = _eq(row[4], "None");
            if (!isBald && haired >= 100) continue;

            (bool carries, bool mentionsNone) = this.hairColourIn(imageId);
            if (isBald) {
                ++bald;
                assertFalse(carries, "a character with no hair carries a hair colour");
                assertFalse(mentionsNone, "the word None reached a document");
            } else {
                ++haired;
                assertTrue(carries, "a character with hair lost its hair colour");
            }
        }
        vm.closeFile(CSV);
    }

    /// Behind an external call so each document is freed with its own frame.
    function hairColourIn(uint256 imageId) external view returns (bool carries, bool mentionsNone) {
        bytes memory j = bytes(nft.tokenJSON(imageId));
        carries = _contains(j, bytes(category[3]));
        mentionsNone = _contains(j, bytes("None"));
    }

    function _json(uint256 tokenId) internal view returns (string memory) {
        return nft.tokenJSON(tokenId);
    }

    function _attrs(string memory j) internal view returns (Attr[] memory) {
        return abi.decode(vm.parseJson(j, ".attributes"), (Attr[]));
    }

    function _label(uint256 imageId, uint256 generation) internal view returns (string memory) {
        Attr[] memory a = _attrs(_json(nft.tokenIdFor(imageId, generation)));
        return a[a.length - 1].value;
    }

    function _wantUri(string memory scheme, string memory root, bool blue, uint256 imageId, string memory ext)
        internal
        view
        returns (string memory)
    {
        return string.concat(scheme, root, blue ? "/blue/" : "/green/", vm.toString(imageId), ext);
    }

    function _assertDocument(uint256 imageId, uint256 generation) internal view {
        uint256 tokenId = nft.tokenIdFor(imageId, generation);
        bool blue = generation == 0;
        string memory j = _json(tokenId);
        string memory id = vm.toString(imageId);

        assertEq(
            vm.parseJsonString(j, ".name"),
            blue ? string.concat("Glamtoon #", id) : string.concat("Glamtoon #", id, " Gen ", vm.toString(generation)),
            "name"
        );
        assertEq(vm.parseJsonString(j, ".image"), _wantUri("ipfs://", nft.ipfsRoot(), blue, imageId, ".png"), "image");
        assertEq(vm.parseJsonString(j, ".external_url"), string.concat(SITE, vm.toString(tokenId)), "external_url");
        assertEq(
            vm.parseJsonString(j, ".glamtoon.optimized"),
            _wantUri("ipfs://", nft.ipfsRoot(), blue, imageId, ".webp"),
            "optimized"
        );
        assertEq(
            vm.parseJsonString(j, ".glamtoon.arweave"),
            _wantUri("ar://", nft.arweaveManifest(), blue, imageId, ".png"),
            "arweave"
        );
        assertEq(
            vm.parseJsonString(j, ".glamtoon.arweave_optimized"),
            _wantUri("ar://", nft.arweaveManifest(), blue, imageId, ".webp"),
            "arweave_optimized"
        );
        assertEq(vm.parseJsonUint(j, ".glamtoon.image_id"), imageId, "image_id");
        assertEq(vm.parseJsonUint(j, ".glamtoon.generation"), generation, "generation");

        Attr[] memory a = _attrs(j);
        assertEq(a[0].value, blue ? "Genesis Blue" : "Generation Green", "edition");
        assertEq(a[a.length - 1].trait_type, "Generation", "generation attribute");
    }

    /*//////////////////////////////////////////////////////////////
                             THE ART CSV
    //////////////////////////////////////////////////////////////*/

    /// Open the pipeline's trait table and hand back its header row.
    function _openCsv() internal returns (string[5] memory header) {
        vm.closeFile(CSV);
        header = _fields(bytes(vm.readLine(CSV)));
    }

    function _nextRow() internal returns (bool ok, uint256 imageId, string[5] memory row) {
        bytes memory line = bytes(vm.readLine(CSV));
        if (line.length == 0) return (false, 0, row);
        row = _fields(line);
        return (true, _toUint(bytes(row[0])), row);
    }

    /// One character's row. The sheet is in character order, so the lines before
    /// it are skipped unparsed and only the row itself is split and checked.
    function _sheetRow(uint256 imageId) internal returns (string[5] memory row) {
        _openCsv();
        for (uint256 i = 0; i < imageId; ++i) {
            vm.readLine(CSV);
        }
        row = _fields(bytes(vm.readLine(CSV)));
        vm.closeFile(CSV);
        assertEq(_toUint(bytes(row[0])), imageId, "the sheet is not in character order");
    }

    function _firstCsvIdWithColour(string memory colour) internal returns (uint256) {
        _openCsv();
        while (true) {
            (bool ok, uint256 imageId, string[5] memory row) = _nextRow();
            if (!ok) break;
            if (_eq(row[4], colour)) {
                vm.closeFile(CSV);
                return imageId;
            }
        }
        vm.closeFile(CSV);
        revert("no character carries that hair colour");
    }

    function _firstCsvRowWithHair() internal returns (uint256, string[5] memory) {
        _openCsv();
        while (true) {
            (bool ok, uint256 imageId, string[5] memory row) = _nextRow();
            if (!ok) break;
            if (!_eq(row[4], "None")) {
                vm.closeFile(CSV);
                return (imageId, row);
            }
        }
        vm.closeFile(CSV);
        revert("every character is bald");
    }

    function _fields(bytes memory line) internal pure returns (string[5] memory out) {
        uint256 end = line.length;
        if (end > 0 && line[end - 1] == 0x0d) --end;

        uint256 start;
        uint256 f;
        for (uint256 i = 0; i <= end; ++i) {
            if (i != end && line[i] != ",") continue;
            require(f < 5, "csv row has more than five fields");
            bytes memory piece = new bytes(i - start);
            for (uint256 k = 0; k < piece.length; ++k) {
                piece[k] = line[start + k];
            }
            out[f++] = string(piece);
            start = i + 1;
        }
        require(f == 5, "csv row is short");
    }

    /*//////////////////////////////////////////////////////////////
                                STRINGS
    //////////////////////////////////////////////////////////////*/

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _startsWith(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (haystack.length < needle.length) return false;
        for (uint256 i = 0; i < needle.length; ++i) {
            if (haystack[i] != needle[i]) return false;
        }
        return true;
    }

    function _endsWith(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (haystack.length < needle.length) return false;
        uint256 offset = haystack.length - needle.length;
        for (uint256 i = 0; i < needle.length; ++i) {
            if (haystack[offset + i] != needle[i]) return false;
        }
        return true;
    }

    function _indexOf(bytes memory haystack, bytes memory needle) internal pure returns (bool found, uint256 at) {
        if (needle.length == 0 || haystack.length < needle.length) return (false, 0);
        for (uint256 i = 0; i <= haystack.length - needle.length; ++i) {
            bool hit = true;
            for (uint256 k = 0; k < needle.length; ++k) {
                if (haystack[i + k] == needle[k]) continue;
                hit = false;
                break;
            }
            if (hit) return (true, i);
        }
        return (false, 0);
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool found) {
        (found,) = _indexOf(haystack, needle);
    }

    function _countOf(bytes memory haystack, bytes1 c) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < haystack.length; ++i) {
            if (haystack[i] == c) ++n;
        }
    }

    function _afterPrefix(string memory s, string memory prefix) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory p = bytes(prefix);
        require(_startsWith(b, p), "string does not start with the prefix");
        bytes memory out = new bytes(b.length - p.length);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = b[p.length + i];
        }
        return string(out);
    }

    function _replace(string memory s, string memory from, string memory to) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory f = bytes(from);
        (bool found, uint256 cut) = _indexOf(b, f);
        require(found, "substring not found");

        bytes memory head = new bytes(cut);
        for (uint256 i = 0; i < cut; ++i) {
            head[i] = b[i];
        }
        bytes memory tail = new bytes(b.length - cut - f.length);
        for (uint256 i = 0; i < tail.length; ++i) {
            tail[i] = b[cut + f.length + i];
        }
        return string.concat(string(head), to, string(tail));
    }

    function _toUint(bytes memory b) internal pure returns (uint256 n) {
        require(b.length > 0, "empty number");
        for (uint256 i = 0; i < b.length; ++i) {
            require(b[i] >= "0" && b[i] <= "9", "not a decimal number");
            n = n * 10 + (uint8(b[i]) - 48);
        }
    }
}

/// One attribute, in the order forge hands the fields back.
struct Attr {
    // forge-lint: disable-next-line(mixed-case-variable)
    string trait_type;
    string value;
}

/// The decoding half of the data URI, written here so the test reads the
/// document the way a marketplace does rather than by encoding the answer it
/// expects and comparing that. Standard alphabet, padded, no line breaks.
library B64 {
    function decode(string memory s) internal pure returns (bytes memory out) {
        bytes memory d = bytes(s);
        require(d.length % 4 == 0, "base64 length is not a multiple of four");
        if (d.length == 0) return out;

        uint256 pad;
        if (d[d.length - 1] == "=") ++pad;
        if (d[d.length - 2] == "=") ++pad;

        out = new bytes(d.length / 4 * 3 - pad);
        uint256 o;
        for (uint256 i = 0; i < d.length; i += 4) {
            uint256 n = (_sextet(d[i]) << 18) | (_sextet(d[i + 1]) << 12) | (_sextet(d[i + 2]) << 6) | _sextet(d[i + 3]);
            out[o++] = _byte(n, 16);
            if (o < out.length) out[o++] = _byte(n, 8);
            if (o < out.length) out[o++] = _byte(n, 0);
        }
    }

    /// One byte out of a decoded quantum. The mask is what makes the cast safe.
    function _byte(uint256 n, uint256 shift) private pure returns (bytes1) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes1(uint8((n >> shift) & 0xff));
    }

    function _sextet(bytes1 c) private pure returns (uint256) {
        if (c >= "A" && c <= "Z") return uint8(c) - 65;
        if (c >= "a" && c <= "z") return uint8(c) - 71;
        if (c >= "0" && c <= "9") return uint8(c) + 4;
        if (c == "+") return 62;
        if (c == "/") return 63;
        if (c == "=") return 0;
        revert("character outside standard base64");
    }
}
