// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.10;

import {Test} from 'forge-std/Test.sol';
import {IPoolAddressesProvider} from '../contracts/interfaces/IPoolAddressesProvider.sol';
import {IAaveManualOracle} from '../contracts/interfaces/IAaveManualOracle.sol';
import {AaveManualOracle} from '../contracts/misc/AaveManualOracle.sol';

contract AaveManualOracleTest is Test {
  event AssetPriceUpdated(
    address indexed asset,
    uint256 oldPrice,
    uint256 newPrice,
    uint256 timestamp
  );

  address internal constant PROVIDER = address(0xA11CE);
  address internal constant SAFE = address(0x5AFE);
  address internal constant WETH = address(0xE7);
  address internal constant SOUSD = address(0x50);

  AaveManualOracle internal oracle;

  function setUp() public {
    oracle = new AaveManualOracle(IPoolAddressesProvider(PROVIDER), SAFE);
  }

  function _set(address asset, uint256 price) internal {
    address[] memory assets = new address[](1);
    uint256[] memory prices = new uint256[](1);
    assets[0] = asset;
    prices[0] = price;
    vm.prank(SAFE);
    oracle.setAssetPrices(assets, prices);
  }

  function test_constructor() public {
    assertEq(oracle.owner(), SAFE);
    assertEq(address(oracle.ADDRESSES_PROVIDER()), PROVIDER);
    assertEq(oracle.BASE_CURRENCY(), address(0));
    assertEq(oracle.BASE_CURRENCY_UNIT(), 1e8);
    assertEq(oracle.getFallbackOracle(), address(0));
  }

  function test_constructor_revertsOnZeroAddress() public {
    vm.expectRevert(IAaveManualOracle.ZeroAddress.selector);
    new AaveManualOracle(IPoolAddressesProvider(address(0)), SAFE);
    vm.expectRevert(IAaveManualOracle.ZeroAddress.selector);
    new AaveManualOracle(IPoolAddressesProvider(PROVIDER), address(0));
  }

  function test_setAssetPrices() public {
    vm.warp(1_800_000_000);
    vm.expectEmit(true, false, false, true, address(oracle));
    emit AssetPriceUpdated(WETH, 0, 1755e8, 1_800_000_000);
    _set(WETH, 1755e8);

    assertEq(oracle.getAssetPrice(WETH), 1755e8);
    (uint256 price, uint256 updatedAt) = oracle.getPriceData(WETH);
    assertEq(price, 1755e8);
    assertEq(updatedAt, 1_800_000_000);
    assertEq(oracle.getSourceOfAsset(WETH), address(oracle));
  }

  function test_setAssetPrices_batch() public {
    address[] memory assets = new address[](2);
    uint256[] memory prices = new uint256[](2);
    assets[0] = WETH;
    assets[1] = SOUSD;
    prices[0] = 1755e8;
    prices[1] = 108970000;
    vm.prank(SAFE);
    oracle.setAssetPrices(assets, prices);

    uint256[] memory read = oracle.getAssetsPrices(assets);
    assertEq(read[0], 1755e8);
    assertEq(read[1], 108970000);
  }

  function test_setAssetPrices_onlyOwner(address caller) public {
    vm.assume(caller != SAFE);
    address[] memory assets = new address[](1);
    uint256[] memory prices = new uint256[](1);
    assets[0] = WETH;
    prices[0] = 1755e8;
    vm.prank(caller);
    vm.expectRevert(IAaveManualOracle.NotOwner.selector);
    oracle.setAssetPrices(assets, prices);
  }

  function test_setAssetPrices_rejectsBadInput() public {
    address[] memory assets = new address[](1);
    uint256[] memory prices = new uint256[](2);
    vm.prank(SAFE);
    vm.expectRevert(IAaveManualOracle.InconsistentParamsLength.selector);
    oracle.setAssetPrices(assets, prices);

    prices = new uint256[](1);
    assets[0] = WETH;
    prices[0] = 0;
    vm.prank(SAFE);
    vm.expectRevert(abi.encodeWithSelector(IAaveManualOracle.InvalidPrice.selector, WETH, 0));
    oracle.setAssetPrices(assets, prices);

    // ETH price typed with 18 decimals instead of 8
    prices[0] = 1755e18;
    vm.prank(SAFE);
    vm.expectRevert(abi.encodeWithSelector(IAaveManualOracle.InvalidPrice.selector, WETH, 1755e18));
    oracle.setAssetPrices(assets, prices);

    assets[0] = address(0);
    prices[0] = 1e8;
    vm.prank(SAFE);
    vm.expectRevert(IAaveManualOracle.ZeroAddress.selector);
    oracle.setAssetPrices(assets, prices);
  }

  function test_getAssetPrice_revertsWhenUnset() public {
    vm.expectRevert(abi.encodeWithSelector(IAaveManualOracle.PriceNotSet.selector, WETH));
    oracle.getAssetPrice(WETH);
    assertEq(oracle.getSourceOfAsset(WETH), address(0));
  }

  function test_getAssetPrice_baseCurrency() public {
    assertEq(oracle.getAssetPrice(address(0)), 1e8);
  }

  function test_ownership_twoStep() public {
    address newOwner = address(0xB0B);

    vm.prank(address(0xBAD));
    vm.expectRevert(IAaveManualOracle.NotOwner.selector);
    oracle.transferOwnership(newOwner);

    vm.prank(SAFE);
    oracle.transferOwnership(newOwner);
    assertEq(oracle.owner(), SAFE);
    assertEq(oracle.pendingOwner(), newOwner);

    vm.prank(address(0xBAD));
    vm.expectRevert(IAaveManualOracle.NotPendingOwner.selector);
    oracle.acceptOwnership();

    vm.prank(newOwner);
    oracle.acceptOwnership();
    assertEq(oracle.owner(), newOwner);
    assertEq(oracle.pendingOwner(), address(0));

    // old owner lost write access
    address[] memory assets = new address[](1);
    uint256[] memory prices = new uint256[](1);
    assets[0] = WETH;
    prices[0] = 1755e8;
    vm.prank(SAFE);
    vm.expectRevert(IAaveManualOracle.NotOwner.selector);
    oracle.setAssetPrices(assets, prices);
  }
}
