// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/// The one halmos cheatcode these proofs use, declared here rather than pulled
/// in as a library. halmos answers it at the address below. forge never calls
/// it, because forge never runs a check_ function.
interface ISvm {
    /// Symbolic calldata for the named contract. halmos forks one path per
    /// state changing function in its ABI, each with symbolic arguments, plus
    /// one with empty calldata and one with a selector the contract does not
    /// have, so receive and fallback are covered too. View and pure functions
    /// are left out.
    function createCalldata(string calldata contractName) external pure returns (bytes memory data);
}

ISvm constant SVM = ISvm(address(uint160(uint256(keccak256("svm cheat code")))));
