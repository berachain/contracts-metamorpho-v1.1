// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { OwnableUpgradeable } from "../lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import { Initializable } from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { SafeERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IFeeCollector } from "./interfaces/IFeeCollector.sol";
import { IMetaMorphoV1_1 } from "./interfaces/IMetaMorphoV1_1.sol";
import { IMetaMorphoV1_1Factory } from "./interfaces/IMetaMorphoV1_1Factory.sol";
import { ErrorsLib } from "./libraries/ErrorsLib.sol";
import { EventsLib } from "./libraries/EventsLib.sol";

contract FeeCollector is IFeeCollector, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    
    uint256 private constant ONE_HUNDRED_PERCENT = 10000; // 100% in basis points

    /// @notice The init fee percentage value.
    uint256 public constant INIT_FEE_PERCENTAGE = 1500; // 15% in basis points 

    /// @notice The default foundation fee percentage each vault has if no specific fee is set.
    uint256 public defaultFoundationFeePercentage;

    /// @inheritdoc IFeeCollector
    address public foundation;

    /// @notice The MetaMorphoV1_1 factory contract.
    IMetaMorphoV1_1Factory public metamorphoFactory;

    /// @notice Percentage of fees collected by the foundation.
    /// @dev The percentage is represented as a value between 0 and ONE_HUNDRED_PERCENT
    /// @dev The remaining percentage (ONE_HUNDRED_PERCENT - foundationPercentage) is collected by the vault feeRecipient.
    mapping(address => FeePercentage) public _vaultFeePercentages;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract.
    /// @param _foundation The address of the Berachain foundation.
    function initialize(address governance, address _foundation, address _metamorphoFactory) external initializer {
        if (_foundation == address(0)) revert ErrorsLib.ZeroAddress();
        __Ownable_init(governance);
        __UUPSUpgradeable_init();

        foundation = _foundation;
        metamorphoFactory = IMetaMorphoV1_1Factory(_metamorphoFactory);
        defaultFoundationFeePercentage = INIT_FEE_PERCENTAGE;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Sets the fee percentage for a vault that is taken by the foundation.
    /// @param vault The address of the vault.
    /// @param _feePercentage The fee percentage to set, represented in basis points
    function setFeePercentage(address vault, uint256 _feePercentage) external onlyOwner {
        if (vault == address(0)) revert ErrorsLib.ZeroAddress();
        if (_feePercentage > ONE_HUNDRED_PERCENT) revert ErrorsLib.MaxFeeExceeded();
        if (!metamorphoFactory.isMetaMorpho(vault)) revert ErrorsLib.InvalidMetaMorpho();
        FeePercentage storage fee = _vaultFeePercentages[vault];

        if (fee.isSet && fee.foundationPercentage == _feePercentage) revert ErrorsLib.AlreadySet();

        // Claim with old fee percentage
        claimShares(vault);
    
        fee.foundationPercentage = _feePercentage;
        fee.isSet = true;

        emit EventsLib.FeePercentageSet(vault, _feePercentage);
    }

    /// @notice Sets the foundation address who takes the fees.
    /// @param _foundation The foundation address
    function setFoundation(address _foundation) external onlyOwner {
        if (_foundation == address(0)) revert ErrorsLib.ZeroAddress();
        if (_foundation == foundation) revert ErrorsLib.AlreadySet();

        foundation = _foundation;

        emit EventsLib.FoundationAddressSet(_foundation);
    }

    /// @notice Sets the default foundation fee percentage.
    /// @param _defaultFee The default fee percentage
    function setDefaultFoundationFeePercentage(uint256 _defaultFee) external onlyOwner {
        if (_defaultFee > ONE_HUNDRED_PERCENT) revert ErrorsLib.MaxFeeExceeded();
        if (defaultFoundationFeePercentage == _defaultFee) revert ErrorsLib.AlreadySet();

        uint256 old = defaultFoundationFeePercentage;
        defaultFoundationFeePercentage = _defaultFee;

        emit EventsLib.DefaultFoundationFeePercentageSet(old, _defaultFee);
    }

    /// @inheritdoc IFeeCollector
    function getFoundationFeePercentage(address vault) external override view returns (uint256) {
        if (!metamorphoFactory.isMetaMorpho(vault)) revert ErrorsLib.InvalidMetaMorpho();

        return _getFoundationPercentage(vault);
    } 

    /// @inheritdoc IFeeCollector
    function claimShares(address vault) public {
        if (!metamorphoFactory.isMetaMorpho(vault)) revert ErrorsLib.InvalidMetaMorpho();
        if (vault == address(0)) revert ErrorsLib.ZeroAddress();

        IERC20 vaultShare = IERC20(vault);
        uint256 shares = vaultShare.balanceOf(address(this));

        if (shares == 0) return;

        uint256 foundationPercentage = _getFoundationPercentage(vault);

        uint256 foundationShare = (shares * foundationPercentage) / ONE_HUNDRED_PERCENT;
        uint256 remainingShare = shares - foundationShare;


        if (foundationShare > 0) {
            // Transfer the foundation's share to the foundation address
            vaultShare.safeTransfer(foundation, foundationShare);
        }

        if (remainingShare > 0) {
            // Here the assumption the vault has a feeRecipient set
            // because, otherwise, fee from vault will not be collected
            // because of this, we do not check if feeRecipient is the zero address
            address vaultFeeRecipient = IMetaMorphoV1_1(vault).feeRecipient();

            // Transfer the remaining shares to the vault's fee recipient
            vaultShare.safeTransfer(vaultFeeRecipient, remainingShare);
        }

        emit EventsLib.SharesClaimed(vault, foundationShare, remainingShare);
    }

    /// @dev Retrieves the foundation percentage for a vault.
    /// @param vault The address of the vault.
    /// @return The foundation percentage for the vault.
    function _getFoundationPercentage(address vault) internal view returns (uint256) {
        FeePercentage memory fee = _vaultFeePercentages[vault];
        if (!fee.isSet) {
            return defaultFoundationFeePercentage;
        }
        return fee.foundationPercentage;
    }
}
