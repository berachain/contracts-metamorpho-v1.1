// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./helpers/BaseTest.sol";
import {MetaFeePartitionerDeployer} from "../../src/utils/MetaFeePartitionerDeployer.sol";
import {MetaFeePartitioner} from "../../src/MetaFeePartitioner.sol";

uint256 constant ONE_HUNDRED_PERCENT = 10000; // 100% in basis points

contract FeePartitionerTest is BaseTest {
    using Math for uint256;
    using MathLib for uint256;
    using MarketParamsLib for MarketParams;

    MetaFeePartitioner internal feePartitioner;

    address internal MOCK_VAULT = makeAddr("MockVault");

    function setUp() public override {
        super.setUp();

        MetaFeePartitionerDeployer feePartitionerDeployer = new MetaFeePartitionerDeployer(GOVERNANCE, 0);
        feePartitioner = feePartitionerDeployer.feePartitioner();
    }

    function testSetPercentage(uint256 fee) public {
        fee = bound(fee, 0, ONE_HUNDRED_PERCENT);

        vm.prank(GOVERNANCE);
        vm.expectEmit();
        emit EventsLib.FeePercentageSet(MOCK_VAULT, fee);
        feePartitioner.setFeePercentage(MOCK_VAULT, fee);

        uint256 contractValue = feePartitioner.getPlatformPercentage(MOCK_VAULT);
        assertEq(contractValue, fee, "feePercentage");
    }

    function testSetDefaultPlatformFeePercentage(uint256 fee) public {
        fee = bound(fee, 0, ONE_HUNDRED_PERCENT);
        uint256 initFee = feePartitioner.INIT_FEE_PERCENTAGE();
        vm.assume(fee != initFee);

        vm.prank(GOVERNANCE);
        vm.expectEmit();
        emit EventsLib.DefaultPlatformFeePercentageSet(initFee, fee);
        feePartitioner.setDefaultPlatformFeePercentage(fee);

        assertEq(feePartitioner.defaultPlatformFeePercentage(), fee, "defaultPlatformFeePercentage");
    }

    function testSetDefaultPlatformFeePercentageAlreadySet(uint256 fee) public {
        fee = bound(fee, 1, ONE_HUNDRED_PERCENT);

        uint256 initFee = feePartitioner.INIT_FEE_PERCENTAGE();

        vm.prank(GOVERNANCE);
        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        feePartitioner.setDefaultPlatformFeePercentage(initFee);

        vm.prank(GOVERNANCE);
        feePartitioner.setDefaultPlatformFeePercentage(fee);

        vm.prank(GOVERNANCE);
        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        feePartitioner.setDefaultPlatformFeePercentage(fee);
    }

    function testSetDefaultPlatformFeePercentageOutOfBounds(uint256 fee) public {
        fee = bound(fee, ONE_HUNDRED_PERCENT + 1, type(uint256).max);

        vm.prank(GOVERNANCE);
        vm.expectRevert();
        feePartitioner.setDefaultPlatformFeePercentage(fee);
    }

    function testGetPlatformPercentage() public {
        // Test default value:
        uint256 initFee = feePartitioner.INIT_FEE_PERCENTAGE();
        assertEq(feePartitioner.defaultPlatformFeePercentage(), initFee, "defaultPlatformFeePercentage");
        uint256 fee = feePartitioner.getPlatformPercentage(MOCK_VAULT);
        assertEq(fee, initFee, "getPlatformPercentage default");

        // Test set value:
        uint256 newFee = 2 * initFee;
        vm.prank(GOVERNANCE);
        feePartitioner.setFeePercentage(MOCK_VAULT, newFee);
        fee = feePartitioner.getPlatformPercentage(MOCK_VAULT);
        assertEq(fee, newFee, "getPlatformPercentage set");
    }

    function testGetShares() public {
        // Test 100% Platform and 0% Vault:
        vm.prank(GOVERNANCE);
        feePartitioner.setFeePercentage(MOCK_VAULT, 10000);
        (uint256 platformShare, uint256 recipientShare) = feePartitioner.getShares(MOCK_VAULT, 100e18);
        assertEq(platformShare, 100e18, "getShares 100/0");
        assertEq(recipientShare, 0, "getShares 100/0");

        // Test 80% Platform and 20% Vault:
        vm.prank(GOVERNANCE);
        feePartitioner.setFeePercentage(MOCK_VAULT, 8000);
        (platformShare, recipientShare) = feePartitioner.getShares(MOCK_VAULT, 100e18);
        assertEq(platformShare, 80e18, "getShares 80/20");
        assertEq(recipientShare, 20e18, "getShares 80/20");

        // Test 50% Platform and 50% Vault:
        vm.prank(GOVERNANCE);
        feePartitioner.setFeePercentage(MOCK_VAULT, 5000);
        (platformShare, recipientShare) = feePartitioner.getShares(MOCK_VAULT, 100e18);
        assertEq(platformShare, 50e18, "getShares 50/50");
        assertEq(recipientShare, 50e18, "getShares 50/50");

        // Test 0% Platform and 100% Vault:
        vm.prank(GOVERNANCE);
        feePartitioner.setFeePercentage(MOCK_VAULT, 0);
        (platformShare, recipientShare) = feePartitioner.getShares(MOCK_VAULT, 100e18);
        assertEq(platformShare, 0, "getShares 0/100");
        assertEq(recipientShare, 100e18, "getShares 0/100");
    }
}
