// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IMetaFeePartitioner} from "../interfaces/IMetaFeePartitioner.sol";

/// @dev Fee partitioner burning far more gas than the vault's partitioner budget, so that the vault's gas-capped
/// staticcall runs out of gas instead of returning a split.
contract GasGuzzlingFeePartitionerMock is IMetaFeePartitioner {
    /// @dev Returns the whole fee to the platform, but only if it is ever given enough gas to reach the return.
    function getShares(address, uint256 fee) external pure returns (uint256 platformShare, uint256 recipientShare) {
        uint256 acc;
        for (uint256 i; i < 1000; ++i) {
            acc = uint256(keccak256(abi.encode(acc, i)));
        }

        // `acc` is read so that the loop above cannot be optimized away.
        return acc != 0 ? (fee, uint256(0)) : (uint256(0), fee);
    }
}
