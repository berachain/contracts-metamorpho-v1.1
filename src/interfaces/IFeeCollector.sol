// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

interface IFeeCollector {

    struct FeePercentage {
        uint256 foundationPercentage; // Share for the foundation
        bool isSet; // Indicates if the fee percentage is set
    }

    /// @notice The percentage of fees collected by the foundation for a specific vault.
    /// @param vault The address of the vault.
    /// @return The fee percentage in basis points (10000 = 100%).
    function feePercentage(address vault) external view returns (uint256);

    /// @notice Claims shares from a MetaMorpho vault and transfers them to the caller.
    /// @param vault The address of the MetaMorpho vault.
    function claimShares(address vault) external;
}