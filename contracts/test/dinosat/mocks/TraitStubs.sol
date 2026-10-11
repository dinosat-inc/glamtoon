// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/// Stand ins for the trait data contracts, for proving what the token's
/// constructor refuses. Each reports whatever hash it was built with. They
/// match the ITraitData and ITraitNames selectors without inheriting them,
/// because those declare their functions pure and a stored hash is not.
/// The hash is kept in storage rather than as an immutable so the symbolic
/// engine never has to run code with a symbolic constant spliced into it.

/// A chunk that reports a chosen hash. Its records read as zero, or revert.
contract ChunkStub {
    error Unreadable();

    bytes32 internal hash;
    bool internal readable;

    constructor(bytes32 reported, bool answersRecords) {
        hash = reported;
        readable = answersRecords;
    }

    function record(uint256) external view returns (uint40) {
        if (!readable) revert Unreadable();
        return 0;
    }

    function data() external pure returns (bytes memory) {
        return "";
    }

    function dataHash() external view returns (bytes32) {
        return hash;
    }
}

/// A name table that reports a chosen hash.
contract NamesStub {
    bytes32 internal hash;

    constructor(bytes32 reported) {
        hash = reported;
    }

    function namesAt(uint256[] calldata slots) external pure returns (string[] memory) {
        return new string[](slots.length);
    }

    function data() external pure returns (bytes memory) {
        return "";
    }

    function namesHash() external view returns (bytes32) {
        return hash;
    }
}
