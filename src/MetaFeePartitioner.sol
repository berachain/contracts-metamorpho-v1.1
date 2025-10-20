// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {OwnableUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IMetaFeePartitioner} from "./interfaces/IMetaFeePartitioner.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";

/// @title MetaFeePartitioner
/// @author Berachain Team
/// @notice An utility contract the signals to each vault how to partition the fee between its recipient and the morpho
/// one.
/// @dev The morpho fee recipient is named as "platform fee recipient" in order to avoid confusion.
contract MetaFeePartitioner is IMetaFeePartitioner, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    struct FeePercentage {
        // Share for the platform in basis points:
        uint256 platformPercentage;
        // Whether the fee percentage has been set:
        bool isSet;
    }

    uint256 private constant ONE_HUNDRED_PERCENT = 10000; // 100% in basis points

    /// @notice The init fee percentage value.
    uint256 public constant INIT_FEE_PERCENTAGE = 1500; // 15% in basis points

    /// @notice The default platform fee percentage each vault has if no specific fee is set.
    uint256 public defaultPlatformFeePercentage;

    /// @notice Percentage of fees collected by the platform.
    /// @dev The percentage is represented as a value between 0 and ONE_HUNDRED_PERCENT
    /// @dev The remaining percentage (ONE_HUNDRED_PERCENT - platformPercentage) is collected by the vault
    /// feeRecipient.
    mapping(address => FeePercentage) internal _vaultFeePercentages;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract.
    /// @param governance The address of the governance.
    function initialize(address governance) external initializer {
        __Ownable_init(governance);
        __UUPSUpgradeable_init();

        defaultPlatformFeePercentage = INIT_FEE_PERCENTAGE;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Sets the fee percentage for a vault that is taken by the platform.
    /// @param vault The address of the vault.
    /// @param newFee The fee percentage to set, represented in basis points
    function setFeePercentage(address vault, uint256 newFee) external onlyOwner {
        if (newFee > ONE_HUNDRED_PERCENT) revert ErrorsLib.MaxFeeExceeded();
        FeePercentage storage fee = _vaultFeePercentages[vault];

        if (fee.isSet && fee.platformPercentage == newFee) revert ErrorsLib.AlreadySet();

        fee.platformPercentage = newFee;
        fee.isSet = true;

        emit EventsLib.FeePercentageSet(vault, newFee);
    }

    /// @notice Sets the default platform fee percentage.
    /// @param newFee The new default fee percentage
    function setDefaultPlatformFeePercentage(uint256 newFee) external onlyOwner {
        if (newFee > ONE_HUNDRED_PERCENT) revert ErrorsLib.MaxFeeExceeded();
        if (defaultPlatformFeePercentage == newFee) revert ErrorsLib.AlreadySet();

        uint256 old = defaultPlatformFeePercentage;
        defaultPlatformFeePercentage = newFee;

        emit EventsLib.DefaultPlatformFeePercentageSet(old, newFee);
    }

    /// @inheritdoc IMetaFeePartitioner
    function getShares(address vault, uint256 fee)
        external
        view
        returns (uint256 platformShare, uint256 recipientShare)
    {
        uint256 platformPercentage = getPlatformPercentage(vault);

        platformShare = (fee * platformPercentage) / ONE_HUNDRED_PERCENT;
        recipientShare = fee - platformShare;
    }

    /// @notice The percentage of fees collected by the platform for a specific vault.
    /// @param vault The address of the vault.
    /// @return percentage The fee percentage in basis points (10000 = 100%).
    function getPlatformPercentage(address vault) public view returns (uint256 percentage) {
        FeePercentage memory fee = _vaultFeePercentages[vault];
        if (fee.isSet) {
            percentage = fee.platformPercentage;
        } else {
            percentage = defaultPlatformFeePercentage;
        }
    }
}
