// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.10;

import {IPoolAddressesProvider} from '../interfaces/IPoolAddressesProvider.sol';
import {IPriceOracleGetter} from '../interfaces/IPriceOracleGetter.sol';
import {IAaveManualOracle} from '../interfaces/IAaveManualOracle.sol';

/**
 * @title AaveManualOracle
 * @notice Replacement for AaveSupraOracle on the Fuse market. Prices are written only by the owner
 * (the Admin Safe) and never by anyone else, so they cannot be steered the way the permissionless
 * Supra push feed was.
 * - Prices are USD with 8 decimals (BASE_CURRENCY = address(0), BASE_CURRENCY_UNIT = 1e8),
 *   the same units AaveSupraOracle returned, so no reserve config changes are needed.
 * - getAssetPrice reverts for an asset with no price. If the oracle is connected before prices are
 *   written, Pool actions that need a price revert instead of using 0.
 * - There is deliberately no staleness revert: in exit-only mode a revert would block withdrawals.
 *   Monitor freshness off-chain with getPriceData(asset).updatedAt.
 */
contract AaveManualOracle is IAaveManualOracle {
  struct PriceData {
    uint128 price;
    uint64 updatedAt;
  }

  /// @inheritdoc IAaveManualOracle
  uint256 public constant override MAX_PRICE = 1e17; // $1,000,000,000 at 8 decimals

  address public constant override BASE_CURRENCY = address(0);
  uint256 public constant override BASE_CURRENCY_UNIT = 1e8;

  /// @inheritdoc IAaveManualOracle
  IPoolAddressesProvider public immutable override ADDRESSES_PROVIDER;

  /// @inheritdoc IAaveManualOracle
  address public override owner;

  /// @inheritdoc IAaveManualOracle
  address public override pendingOwner;

  mapping(address => PriceData) private _prices;

  modifier onlyOwner() {
    if (msg.sender != owner) revert NotOwner();
    _;
  }

  /**
   * @param provider The market's PoolAddressesProvider
   * @param initialOwner The address allowed to write prices (the Admin Safe)
   */
  constructor(IPoolAddressesProvider provider, address initialOwner) {
    if (address(provider) == address(0) || initialOwner == address(0)) revert ZeroAddress();
    ADDRESSES_PROVIDER = provider;
    owner = initialOwner;
    emit OwnershipTransferred(address(0), initialOwner);
    emit BaseCurrencySet(BASE_CURRENCY, BASE_CURRENCY_UNIT);
  }

  /// @inheritdoc IAaveManualOracle
  function setAssetPrices(
    address[] calldata assets,
    uint256[] calldata prices
  ) external override onlyOwner {
    if (assets.length != prices.length) revert InconsistentParamsLength();
    for (uint256 i = 0; i < assets.length; i++) {
      address asset = assets[i];
      uint256 price = prices[i];
      if (asset == BASE_CURRENCY) revert ZeroAddress();
      if (price == 0 || price > MAX_PRICE) revert InvalidPrice(asset, price);

      uint256 oldPrice = _prices[asset].price;
      _prices[asset] = PriceData({price: uint128(price), updatedAt: uint64(block.timestamp)});
      emit AssetPriceUpdated(asset, oldPrice, price, block.timestamp);
    }
  }

  /// @inheritdoc IAaveManualOracle
  function transferOwnership(address newOwner) external override onlyOwner {
    if (newOwner == address(0)) revert ZeroAddress();
    pendingOwner = newOwner;
    emit OwnershipTransferStarted(owner, newOwner);
  }

  /// @inheritdoc IAaveManualOracle
  function acceptOwnership() external override {
    if (msg.sender != pendingOwner) revert NotPendingOwner();
    emit OwnershipTransferred(owner, msg.sender);
    owner = msg.sender;
    pendingOwner = address(0);
  }

  /// @inheritdoc IPriceOracleGetter
  function getAssetPrice(address asset) public view override returns (uint256) {
    if (asset == BASE_CURRENCY) return BASE_CURRENCY_UNIT;
    uint256 price = _prices[asset].price;
    if (price == 0) revert PriceNotSet(asset);
    return price;
  }

  /// @inheritdoc IAaveManualOracle
  function getAssetsPrices(
    address[] calldata assets
  ) external view override returns (uint256[] memory) {
    uint256[] memory prices = new uint256[](assets.length);
    for (uint256 i = 0; i < assets.length; i++) {
      prices[i] = getAssetPrice(assets[i]);
    }
    return prices;
  }

  /// @inheritdoc IAaveManualOracle
  function getPriceData(
    address asset
  ) external view override returns (uint256 price, uint256 updatedAt) {
    PriceData memory data = _prices[asset];
    return (data.price, data.updatedAt);
  }

  /// @inheritdoc IAaveManualOracle
  function getSourceOfAsset(address asset) external view override returns (address) {
    return _prices[asset].price == 0 ? address(0) : address(this);
  }

  /// @inheritdoc IAaveManualOracle
  function getFallbackOracle() external pure override returns (address) {
    return address(0);
  }
}
