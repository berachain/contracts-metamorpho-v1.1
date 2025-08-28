// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Create2Deployer} from "./Create2Deployer.sol";
import {MetaFeePartitioner} from "../MetaFeePartitioner.sol";

contract MetaFeePartitionerDeployer is Create2Deployer {
    /// @notice The MetaFeePartitioner contract.
    // solhint-disable-next-line immutable-vars-naming
    MetaFeePartitioner public feePartitioner;

    constructor(address governance, uint256 salt) {
        // deploy the MetaFeePartitioner implementation
        address feePartitionerImpl = deployWithCreate2(salt, type(MetaFeePartitioner).creationCode);
        // deploy the MetaFeePartitioner proxy
        feePartitioner = MetaFeePartitioner(deployProxyWithCreate2(feePartitionerImpl, salt));

        // initialize the contract
        feePartitioner.initialize(governance);
    }
}
