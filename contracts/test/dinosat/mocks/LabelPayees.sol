// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

/// Payees that answer owner() in every way a contract might, well behaved or
/// not. GlamToon.owner() reads its payee's owner with a staticcall and has to
/// turn anything but one clean address into the zero address.

/// Answers with whatever word it was last given, a clean address or not.
contract WordPayee {
    uint256 internal word;

    function set(uint256 to) external {
        word = to;
    }

    function owner() external view returns (uint256) {
        return word;
    }

    receive() external payable {}
}

/// Reverts when asked.
contract RevertingPayee {
    error NotToday();

    function owner() external pure returns (address) {
        revert NotToday();
    }

    receive() external payable {}
}

/// Answers every call with thirty one bytes, one short of a word.
contract ShortPayee {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0x00, 0x01)
            return(0x00, 31)
        }
    }
}

/// Answers every call with two words, the first of them a clean address.
contract LongPayee {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0x00, 0x1234)
            mstore(0x20, 0x5678)
            return(0x00, 64)
        }
    }
}

/// Accepts every call and answers with nothing at all.
contract SilentPayee {
    fallback() external {}
}
