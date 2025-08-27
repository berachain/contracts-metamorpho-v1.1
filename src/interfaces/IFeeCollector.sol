// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

interface IFeeCollector {

    struct FeePercentage {
        uint256 foundationPercentage; // Share for the foundation
        bool isSet; // Indicates if the fee percentage is set
    }

    /// @notice Berachain foundation address that receives a percentage of the fees collected..
    function foundation() external view returns (address);

    /// @notice The percentage of fees collected by the foundation for a specific vault.
    /// @param vault The address of the vault.
    /// @return The fee percentage in basis points (10000 = 100%).
    function getFoundationFeePercentage(address vault) external view returns (uint256);

    /// @notice Transfer shares to the foundation and the vault's fee recipient.
    /// @param vault The address of the MetaMorpho vault.
    function claimShares(address vault) external;
}
