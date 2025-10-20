// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface IMetaFeePartitioner {
    /// @notice Get the vault fee splitted between the platform and the vault recipient.
    /// @param vault The address of the vault.
    /// @param fee The fee amount.
    /// @return platformShare The fee amount for the platform.
    /// @return recipientShare The fee amount for the vault recipient.
    function getShares(address vault, uint256 fee)
        external
        view
        returns (uint256 platformShare, uint256 recipientShare);
}
