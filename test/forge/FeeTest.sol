// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./helpers/IntegrationTest.sol";
import {IMetaFeePartitioner} from "../../src/interfaces/IMetaFeePartitioner.sol";
import {GasGuzzlingFeePartitionerMock} from "../../src/mocks/GasGuzzlingFeePartitionerMock.sol";

uint256 constant FEE = 0.2 ether; // 20%

/// @dev Mirrors `MetaMorphoV1_1.MAX_GAS_FOR_FEE_PARTITIONER`, which is private.
uint256 constant MAX_GAS_FOR_FEE_PARTITIONER = 50_000;

/// @dev Deposit and elapsed-block floors high enough that the accrued fee never rounds down to zero shares, so the
/// fee partitioner tests can assert on the fee instead of rejecting the runs that accrue none.
uint256 constant MIN_FEE_ACCRUING_ASSETS = 1e12;
uint256 constant MIN_FEE_ACCRUING_BLOCKS = 10_000;

contract FeeTest is IntegrationTest {
    using Math for uint256;
    using MathLib for uint256;
    using MarketParamsLib for MarketParams;

    function setUp() public override {
        super.setUp();

        _setFee(FEE);
        vm.prank(GOVERNANCE);
        feePartitioner.setDefaultPlatformFeePercentage(5000); // 50%

        for (uint256 i; i < NB_MARKETS; ++i) {
            MarketParams memory marketParams = allMarkets[i];

            // Create some debt on the market to accrue interest.

            loanToken.setBalance(SUPPLIER, MAX_TEST_ASSETS);

            vm.prank(SUPPLIER);
            morpho.supply(marketParams, MAX_TEST_ASSETS, 0, ONBEHALF, hex"");

            uint256 collateral = uint256(MAX_TEST_ASSETS).wDivUp(marketParams.lltv);
            collateralToken.setBalance(BORROWER, collateral);

            vm.startPrank(BORROWER);
            morpho.supplyCollateral(marketParams, collateral, BORROWER, hex"");
            morpho.borrow(marketParams, MAX_TEST_ASSETS, 0, BORROWER, BORROWER);
            vm.stopPrank();
        }

        _setCap(allMarkets[0], CAP);
        _sortSupplyQueueIdleLast();
    }

    function testSetFee(uint256 fee) public {
        fee = bound(fee, 0, ConstantsLib.MAX_FEE);
        vm.assume(fee != vault.fee());

        vm.expectEmit(address(vault));
        emit EventsLib.SetFee(OWNER, fee);
        vm.prank(OWNER);
        vault.setFee(fee);

        assertEq(vault.fee(), fee, "fee");
    }

    function _feeShares() internal view returns (uint256) {
        uint256 totalAssetsAfter = vault.totalAssets();
        uint256 interest = totalAssetsAfter - vault.lastTotalAssets();
        uint256 feeAssets = interest.mulDiv(FEE, WAD);

        return feeAssets.mulDiv(vault.totalSupply() + 1, totalAssetsAfter - feeAssets + 1, Math.Rounding.Floor);
    }

    function testAccrueFeeWithinABlock(uint256 deposited, uint256 withdrawn) public {
        deposited = bound(deposited, MIN_TEST_ASSETS + 1, MAX_TEST_ASSETS);
        // The deposited amount is rounded down on Morpho and thus cannot be withdrawn in a block in most cases.
        withdrawn = bound(withdrawn, MIN_TEST_ASSETS, deposited - 1);

        loanToken.setBalance(SUPPLIER, deposited);

        vm.prank(SUPPLIER);
        vault.deposit(deposited, ONBEHALF);

        assertApproxEqAbs(vault.lastTotalAssets(), vault.totalAssets(), 1, "lastTotalAssets1");

        vm.prank(ONBEHALF);
        vault.withdraw(withdrawn, RECEIVER, ONBEHALF);

        assertApproxEqAbs(vault.lastTotalAssets(), vault.totalAssets(), 1, "lastTotalAssets2");
        assertApproxEqAbs(vault.balanceOf(FEE_RECIPIENT), 0, 1, "vault.balanceOf(FEE_RECIPIENT)");
        assertApproxEqAbs(vault.balanceOf(MORPHO_FEE_RECIPIENT), 0, 1, "vault.balanceOf(MORPHO_FEE_RECIPIENT)");
    }

    function testDepositAccrueFee(uint256 deposited, uint256 newDeposit, uint256 blocks) public {
        deposited = bound(deposited, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        newDeposit = bound(newDeposit, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        blocks = _boundBlocks(blocks);

        loanToken.setBalance(SUPPLIER, deposited);

        vm.prank(SUPPLIER);
        vault.deposit(deposited, ONBEHALF);

        assertApproxEqAbs(vault.lastTotalAssets(), vault.totalAssets(), 1, "lastTotalAssets1");

        _forward(blocks);

        uint256 feeShares = _feeShares();
        vm.assume(feeShares != 0);

        loanToken.setBalance(SUPPLIER, newDeposit);

        vm.expectEmit(address(vault));
        emit EventsLib.AccrueInterest(vault.totalAssets(), feeShares);

        vm.prank(SUPPLIER);
        vault.deposit(newDeposit, ONBEHALF);

        assertApproxEqAbs(vault.lastTotalAssets(), vault.totalAssets(), 1, "lastTotalAssets2");
        uint256 platformFee = feeShares / 2;
        assertEq(vault.balanceOf(MORPHO_FEE_RECIPIENT), platformFee, "vault.balanceOf(MORPHO_FEE_RECIPIENT)");
        assertEq(vault.balanceOf(FEE_RECIPIENT), feeShares - platformFee, "vault.balanceOf(FEE_RECIPIENT)");
    }

    function testMintAccrueFee(uint256 deposited, uint256 newDeposit, uint256 blocks) public {
        deposited = bound(deposited, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        newDeposit = bound(newDeposit, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        blocks = _boundBlocks(blocks);

        loanToken.setBalance(SUPPLIER, deposited);

        vm.prank(SUPPLIER);
        vault.deposit(deposited, ONBEHALF);

        assertApproxEqAbs(vault.lastTotalAssets(), vault.totalAssets(), 1, "lastTotalAssets1");

        _forward(blocks);

        uint256 feeShares = _feeShares();
        vm.assume(feeShares != 0);

        uint256 shares = vault.convertToShares(newDeposit);

        loanToken.setBalance(SUPPLIER, newDeposit);

        vm.expectEmit(address(vault));
        emit EventsLib.AccrueInterest(vault.totalAssets(), feeShares);

        vm.prank(SUPPLIER);
        vault.mint(shares, ONBEHALF);

        assertApproxEqAbs(vault.lastTotalAssets(), vault.totalAssets(), 1, "lastTotalAssets2");
        uint256 platformFee = feeShares / 2;
        assertEq(vault.balanceOf(MORPHO_FEE_RECIPIENT), platformFee, "vault.balanceOf(MORPHO_FEE_RECIPIENT)");
        assertEq(vault.balanceOf(FEE_RECIPIENT), feeShares - platformFee, "vault.balanceOf(FEE_RECIPIENT)");
    }

    function testRedeemAccrueFee(uint256 deposited, uint256 withdrawn, uint256 blocks) public {
        deposited = bound(deposited, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        withdrawn = bound(withdrawn, MIN_TEST_ASSETS, deposited);
        blocks = _boundBlocks(blocks);

        loanToken.setBalance(SUPPLIER, deposited);

        vm.prank(SUPPLIER);
        vault.deposit(deposited, ONBEHALF);

        assertApproxEqAbs(vault.lastTotalAssets(), vault.totalAssets(), 1, "lastTotalAssets1");

        _forward(blocks);

        uint256 feeShares = _feeShares();
        vm.assume(feeShares != 0);

        uint256 shares = vault.convertToShares(withdrawn);

        vm.expectEmit(address(vault));
        emit EventsLib.AccrueInterest(vault.totalAssets(), feeShares);

        vm.prank(ONBEHALF);
        vault.redeem(shares, RECEIVER, ONBEHALF);

        assertApproxEqAbs(vault.lastTotalAssets(), vault.totalAssets(), 1, "lastTotalAssets2");
        uint256 platformFee = feeShares / 2;
        assertEq(vault.balanceOf(MORPHO_FEE_RECIPIENT), platformFee, "vault.balanceOf(MORPHO_FEE_RECIPIENT)");
        assertEq(vault.balanceOf(FEE_RECIPIENT), feeShares - platformFee, "vault.balanceOf(FEE_RECIPIENT)");
    }

    function testWithdrawAccrueFee(uint256 deposited, uint256 withdrawn, uint256 blocks) public {
        deposited = bound(deposited, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        withdrawn = bound(withdrawn, MIN_TEST_ASSETS, deposited);
        blocks = _boundBlocks(blocks);

        loanToken.setBalance(SUPPLIER, deposited);

        vm.prank(SUPPLIER);
        vault.deposit(deposited, ONBEHALF);

        assertApproxEqAbs(vault.lastTotalAssets(), vault.totalAssets(), 1, "lastTotalAssets1");

        _forward(blocks);

        uint256 feeShares = _feeShares();
        vm.assume(feeShares != 0);

        vm.expectEmit(address(vault));
        emit EventsLib.AccrueInterest(vault.totalAssets(), feeShares);

        vm.prank(ONBEHALF);
        vault.withdraw(withdrawn, RECEIVER, ONBEHALF);

        assertApproxEqAbs(vault.lastTotalAssets(), vault.totalAssets(), 1, "lastTotalAssets2");
        uint256 platformFee = feeShares / 2;
        assertEq(vault.balanceOf(MORPHO_FEE_RECIPIENT), platformFee, "vault.balanceOf(MORPHO_FEE_RECIPIENT)");
        assertEq(vault.balanceOf(FEE_RECIPIENT), feeShares - platformFee, "vault.balanceOf(FEE_RECIPIENT)");
    }

    function testSetFeeAccrueFee(uint256 deposited, uint256 fee, uint256 blocks) public {
        deposited = bound(deposited, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        fee = bound(fee, 0, FEE - 1);
        blocks = _boundBlocks(blocks);

        loanToken.setBalance(SUPPLIER, deposited);

        vm.prank(SUPPLIER);
        vault.deposit(deposited, ONBEHALF);

        assertApproxEqAbs(vault.lastTotalAssets(), vault.totalAssets(), 1, "lastTotalAssets1");

        _forward(blocks);

        uint256 feeShares = _feeShares();
        vm.assume(feeShares != 0);

        vm.expectEmit(address(vault));
        emit EventsLib.AccrueInterest(vault.totalAssets(), feeShares);

        _setFee(fee);

        assertApproxEqAbs(vault.lastTotalAssets(), vault.totalAssets(), 1, "lastTotalAssets2");
        uint256 platformFee = feeShares / 2;
        assertEq(vault.balanceOf(MORPHO_FEE_RECIPIENT), platformFee, "vault.balanceOf(MORPHO_FEE_RECIPIENT)");
        assertEq(vault.balanceOf(FEE_RECIPIENT), feeShares - platformFee, "vault.balanceOf(FEE_RECIPIENT)");
    }

    function testSetSplittedFeeWithAccrueFee(uint256 deposited, uint256 blocks) public {
        deposited = bound(deposited, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        blocks = _boundBlocks(blocks);

        loanToken.setBalance(SUPPLIER, deposited);

        vm.prank(SUPPLIER);
        vault.deposit(deposited, ONBEHALF);

        assertApproxEqAbs(vault.lastTotalAssets(), vault.totalAssets(), 1, "lastTotalAssets1");

        _forward(blocks);

        uint256 feeShares = _feeShares();
        vm.assume(feeShares != 0);

        vm.expectEmit(address(vault));
        emit EventsLib.AccrueInterest(vault.totalAssets(), feeShares);
        emit EventsLib.UpdateLastTotalAssets(vault.totalAssets());
        emit EventsLib.SetFeeRecipient(address(1));

        vm.prank(OWNER);
        vault.setFeeRecipient(address(1));

        assertApproxEqAbs(vault.lastTotalAssets(), vault.totalAssets(), 1, "lastTotalAssets2");
        assertEq(vault.balanceOf(FEE_RECIPIENT), feeShares - (feeShares / 2), "vault.balanceOf(FEE_RECIPIENT)");
        assertEq(vault.balanceOf(address(1)), 0, "vault.balanceOf(address(1))");
    }

    /// @dev Deposits, lets interest accrue and deposits again, so that a first fee is split by the healthy
    /// partitioner. Both fee recipients are left holding shares, and their balances are returned.
    function _accrueFeeWithHealthyPartitioner(uint256 deposited, uint256 blocks)
        internal
        returns (uint256 platformBalance, uint256 recipientBalance)
    {
        loanToken.setBalance(SUPPLIER, deposited);

        vm.prank(SUPPLIER);
        vault.deposit(deposited, ONBEHALF);

        _forward(blocks);

        loanToken.setBalance(SUPPLIER, deposited);

        vm.prank(SUPPLIER);
        vault.deposit(deposited, ONBEHALF);

        platformBalance = vault.balanceOf(MORPHO_FEE_RECIPIENT);
        recipientBalance = vault.balanceOf(FEE_RECIPIENT);

        assertGt(platformBalance, 0, "platformBalance");
        assertGt(recipientBalance, 0, "recipientBalance");
    }

    function testDepositAccrueFeeGasGuzzlingFeePartitioner(uint256 deposited, uint256 newDeposit, uint256 blocks)
        public
    {
        deposited = bound(deposited, MIN_FEE_ACCRUING_ASSETS, MAX_TEST_ASSETS);
        newDeposit = bound(newDeposit, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        blocks = bound(blocks, MIN_FEE_ACCRUING_BLOCKS, type(uint24).max);

        (uint256 platformBalanceBefore, uint256 recipientBalanceBefore) =
            _accrueFeeWithHealthyPartitioner(deposited, blocks);

        _forward(blocks);

        uint256 feeShares = _feeShares();
        assertGt(feeShares, 0, "feeShares");

        // The vault's fee partitioner is immutable, so the guzzling code is put at the partitioner's address.
        vm.etch(address(feePartitioner), address(new GasGuzzlingFeePartitionerMock()).code);

        // Sanity check: the mock cannot return within the vault's gas budget, and would give everything to the
        // platform if it could, so the assertions below can only hold if the vault took the fallback path.
        (bool success, bytes memory returnData) = address(feePartitioner).staticcall{
            gas: MAX_GAS_FOR_FEE_PARTITIONER
        }(abi.encodeCall(IMetaFeePartitioner.getShares, (address(vault), feeShares)));
        assertFalse(success, "partitioner returned within the gas budget");
        assertEq(returnData.length, 0, "returnData");

        loanToken.setBalance(SUPPLIER, newDeposit);

        vm.expectEmit(address(vault));
        emit EventsLib.AccrueInterest(vault.totalAssets(), feeShares);

        // The failing partitioner must not make interest accrual, and hence the deposit, revert.
        vm.prank(SUPPLIER);
        vault.deposit(newDeposit, ONBEHALF);

        // The platform keeps the shares it already held, but is minted none of the new fee.
        assertEq(vault.balanceOf(MORPHO_FEE_RECIPIENT), platformBalanceBefore, "vault.balanceOf(MORPHO_FEE_RECIPIENT)");
        assertEq(vault.balanceOf(FEE_RECIPIENT), recipientBalanceBefore + feeShares, "vault.balanceOf(FEE_RECIPIENT)");
    }

    function testDepositAccrueFeeInconsistentFeePartitioning(
        uint256 deposited,
        uint256 newDeposit,
        uint256 blocks,
        uint256 platformShare,
        uint256 recipientShare
    ) public {
        deposited = bound(deposited, MIN_FEE_ACCRUING_ASSETS, MAX_TEST_ASSETS);
        newDeposit = bound(newDeposit, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        blocks = bound(blocks, MIN_FEE_ACCRUING_BLOCKS, type(uint24).max);

        (uint256 platformBalanceBefore, uint256 recipientBalanceBefore) =
            _accrueFeeWithHealthyPartitioner(deposited, blocks);

        _forward(blocks);

        uint256 feeShares = _feeShares();
        assertGt(feeShares, 0, "feeShares");

        // Ensure that the recipient share does not match the expected valid split, making the partitioner return an inconsistent split.
        vm.assume(feeShares < type(uint256).max);
        recipientShare = bound(recipientShare, 0, feeShares);
        platformShare = bound(platformShare, feeShares, type(uint256).max - recipientShare);
        if (recipientShare + platformShare == feeShares) ++recipientShare;

        // Make the fee partitioner return shares that do not sum up to the total fee shares. The whole uint256 range
        // is fuzzed on purpose: shares large enough to overflow their sum must fall back like any other bad split.
        vm.mockCall(
            address(feePartitioner),
            abi.encodeWithSelector(IMetaFeePartitioner.getShares.selector),
            abi.encode(platformShare, recipientShare)
        );

        loanToken.setBalance(SUPPLIER, newDeposit);

        // An inconsistent split does not revert: the whole fee is minted to the vault's fee recipient, and the platform
        // keeps the already existing owned shares.
        vm.expectEmit(address(vault));
        emit EventsLib.AccrueInterest(vault.totalAssets(), feeShares);

        vm.prank(SUPPLIER);
        vault.deposit(newDeposit, ONBEHALF);

        assertEq(vault.balanceOf(MORPHO_FEE_RECIPIENT), platformBalanceBefore, "vault.balanceOf(MORPHO_FEE_RECIPIENT)");
        assertEq(vault.balanceOf(FEE_RECIPIENT), recipientBalanceBefore + feeShares, "vault.balanceOf(FEE_RECIPIENT)");
    }

    /// @dev The `fee`/`feeRecipient` slot is packed as `fee` (bytes 0-11) then `feeRecipient` (bytes 12-31).
    function _setVaultFeeRecipientStorage(address newFeeRecipient) internal {
        bytes32 slot = vm.load(address(vault), bytes32(uint256(18)));
        uint256 feeBits = uint256(slot) & type(uint96).max;
        vm.store(address(vault), bytes32(uint256(18)), bytes32((uint256(uint160(newFeeRecipient)) << 96) | feeBits));
    }

    function testDepositAccrueFeeZeroPlatformFeeRecipient(uint256 deposited, uint256 newDeposit, uint256 blocks)
        public
    {
        deposited = bound(deposited, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        newDeposit = bound(newDeposit, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        blocks = _boundBlocks(blocks);

        vm.prank(MORPHO_OWNER);
        morpho.setFeeRecipient(address(0));

        loanToken.setBalance(SUPPLIER, deposited);

        vm.prank(SUPPLIER);
        vault.deposit(deposited, ONBEHALF);

        _forward(blocks);

        uint256 feeShares = _feeShares();
        vm.assume(feeShares != 0);

        loanToken.setBalance(SUPPLIER, newDeposit);

        vm.expectEmit(address(vault));
        emit EventsLib.AccrueInterest(vault.totalAssets(), feeShares);

        vm.prank(SUPPLIER);
        vault.deposit(newDeposit, ONBEHALF);

        assertEq(vault.balanceOf(MORPHO_FEE_RECIPIENT), 0, "vault.balanceOf(MORPHO_FEE_RECIPIENT)");
        assertEq(vault.balanceOf(FEE_RECIPIENT), feeShares, "vault.balanceOf(FEE_RECIPIENT)");
    }

    function testDepositAccrueFeeZeroVaultFeeRecipient(uint256 deposited, uint256 newDeposit, uint256 blocks)
        public
    {
        deposited = bound(deposited, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        newDeposit = bound(newDeposit, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        blocks = _boundBlocks(blocks);

        _setVaultFeeRecipientStorage(address(0));

        loanToken.setBalance(SUPPLIER, deposited);

        vm.prank(SUPPLIER);
        vault.deposit(deposited, ONBEHALF);

        _forward(blocks);

        uint256 feeShares = _feeShares();
        vm.assume(feeShares != 0);

        loanToken.setBalance(SUPPLIER, newDeposit);

        vm.expectEmit(address(vault));
        emit EventsLib.AccrueInterest(vault.totalAssets(), feeShares);

        vm.prank(SUPPLIER);
        vault.deposit(newDeposit, ONBEHALF);

        assertEq(vault.balanceOf(MORPHO_FEE_RECIPIENT), feeShares, "vault.balanceOf(MORPHO_FEE_RECIPIENT)");
        assertEq(vault.balanceOf(FEE_RECIPIENT), 0, "vault.balanceOf(FEE_RECIPIENT)");
    }

    function testDepositAccrueFeeZeroBothFeeRecipients(uint256 deposited, uint256 newDeposit, uint256 blocks)
        public
    {
        deposited = bound(deposited, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        newDeposit = bound(newDeposit, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        blocks = _boundBlocks(blocks);

        vm.prank(MORPHO_OWNER);
        morpho.setFeeRecipient(address(0));
        _setVaultFeeRecipientStorage(address(0));

        loanToken.setBalance(SUPPLIER, deposited);

        vm.prank(SUPPLIER);
        vault.deposit(deposited, ONBEHALF);

        _forward(blocks);

        uint256 feeShares = _feeShares();
        vm.assume(feeShares != 0);

        uint256 totalSupplyBefore = vault.totalSupply();

        loanToken.setBalance(SUPPLIER, newDeposit);

        vm.expectEmit(address(vault));
        emit EventsLib.AccrueInterest(vault.totalAssets(), feeShares);

        vm.prank(SUPPLIER);
        uint256 mintedShares = vault.deposit(newDeposit, ONBEHALF);

        assertEq(vault.balanceOf(MORPHO_FEE_RECIPIENT), 0, "vault.balanceOf(MORPHO_FEE_RECIPIENT)");
        assertEq(vault.balanceOf(FEE_RECIPIENT), 0, "vault.balanceOf(FEE_RECIPIENT)");
        assertEq(vault.totalSupply(), totalSupplyBefore + mintedShares, "vault.totalSupply()");
    }

    function testSetFeeNotOwner(uint256 fee) public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        vault.setFee(fee);
    }

    function testSetFeeMaxFeeExceeded(uint256 fee) public {
        fee = bound(fee, ConstantsLib.MAX_FEE + 1, type(uint256).max);

        vm.prank(OWNER);
        vm.expectRevert(ErrorsLib.MaxFeeExceeded.selector);
        vault.setFee(fee);
    }

    function testSetFeeAlreadySet() public {
        vm.prank(OWNER);
        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        vault.setFee(FEE);
    }

    function testSetFeeZeroFeeRecipient(uint256 fee) public {
        fee = bound(fee, 1, ConstantsLib.MAX_FEE);

        vm.startPrank(OWNER);

        vault.setFee(0);
        vault.setFeeRecipient(address(0));

        vm.expectRevert(ErrorsLib.ZeroFeeRecipient.selector);
        vault.setFee(fee);

        vm.stopPrank();
    }

    function testSetFeeRecipientAlreadySet() public {
        vm.prank(OWNER);
        vm.expectRevert(ErrorsLib.AlreadySet.selector);
        vault.setFeeRecipient(FEE_RECIPIENT);
    }

    function testSetZeroFeeRecipientWithFee() public {
        vm.prank(OWNER);
        vm.expectRevert(ErrorsLib.ZeroFeeRecipient.selector);
        vault.setFeeRecipient(address(0));
    }

    function testConvertToAssetsWithFeeAndInterest(uint256 deposited, uint256 assets, uint256 blocks) public {
        deposited = bound(deposited, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        assets = bound(assets, 1, MAX_TEST_ASSETS);
        blocks = _boundBlocks(blocks);

        loanToken.setBalance(SUPPLIER, deposited);

        vm.prank(SUPPLIER);
        vault.deposit(deposited, ONBEHALF);

        uint256 sharesBefore = vault.convertToShares(assets);

        _forward(blocks);

        uint256 feeShares = _feeShares();
        uint256 expectedShares =
            assets.mulDiv(vault.totalSupply() + feeShares + 1, vault.totalAssets() + 1, Math.Rounding.Floor);
        uint256 shares = vault.convertToShares(assets);

        assertEq(shares, expectedShares, "shares");
        assertLt(shares, sharesBefore, "shares decreased");
    }

    function testConvertToSharesWithFeeAndInterest(uint256 deposited, uint256 shares, uint256 blocks) public {
        deposited = bound(deposited, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        shares = bound(shares, 1, MAX_TEST_ASSETS);
        blocks = _boundBlocks(blocks);

        loanToken.setBalance(SUPPLIER, deposited);

        vm.prank(SUPPLIER);
        vault.deposit(deposited, ONBEHALF);

        uint256 assetsBefore = vault.convertToAssets(shares);

        _forward(blocks);

        uint256 feeShares = _feeShares();
        uint256 expectedAssets =
            shares.mulDiv(vault.totalAssets() + 1, vault.totalSupply() + feeShares + 1, Math.Rounding.Floor);
        uint256 assets = vault.convertToAssets(shares);

        assertEq(assets, expectedAssets, "assets");
        assertGe(assets, assetsBefore, "assets increased");
    }
}
