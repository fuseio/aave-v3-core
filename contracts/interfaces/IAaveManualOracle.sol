// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IPriceOracleGetter} from './IPriceOracleGetter.sol';
import {IPoolAddressesProvider} from './IPoolAddressesProvider.sol';

/**
 * @title IAaveManualOracle
 * @notice Price oracle whose prices are written directly by a single owner (a multisig).
 * @dev Exposes the read side of IAaveOracle (getAssetPrice, getAssetsPrices, getSourceOfAsset,
 * getFallbackOracle, BASE_CURRENCY, BASE_CURRENCY_UNIT, ADDRESSES_PROVIDER) so the Pool,
 * UiPoolDataProviderV3 and the interface keep working when it is set on the PoolAddressesProvider.
 */
interface IAaveManualOracle is IPriceOracleGetter {
  error NotOwner();
  error NotPendingOwner();
  error ZeroAddress();
  error InconsistentParamsLength();
  error InvalidPrice(address asset, uint256 price);
  error PriceNotSet(address asset);

  event BaseCurrencySet(address indexed baseCurrency, uint256 baseCurrencyUnit);
  event AssetPriceUpdated(
    address indexed asset,
    uint256 oldPrice,
    uint256 newPrice,
    uint256 timestamp
  );
  event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

  /// @notice The PoolAddressesProvider of the market this oracle serves
  function ADDRESSES_PROVIDER() external view returns (IPoolAddressesProvider);

  /// @notice Largest accepted price (base currency units). Guards against entering a price with the wrong decimals.
  function MAX_PRICE() external view returns (uint256);

  /// @notice The only address allowed to write prices
  function owner() external view returns (address);

  /// @notice Address that can accept ownership, set by transferOwnership
  function pendingOwner() external view returns (address);

  /**
   * @notice Writes prices for a list of assets
   * @param assets The asset addresses
   * @param prices The prices in base currency units (USD with 8 decimals): 1 USD = 1e8
   */
  function setAssetPrices(address[] calldata assets, uint256[] calldata prices) external;

  /// @notice Starts a two-step ownership transfer; `newOwner` must call acceptOwnership
  function transferOwnership(address newOwner) external;

  /// @notice Completes a two-step ownership transfer
  function acceptOwnership() external;

  /// @notice Returns the prices of a list of assets; reverts if any is not set
  function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory);

  /// @notice Returns the stored price and the timestamp it was written (both 0 if never set)
  function getPriceData(address asset) external view returns (uint256 price, uint256 updatedAt);

  /// @notice Returns this oracle's address if the asset has a price, else address(0)
  function getSourceOfAsset(address asset) external view returns (address);

  /// @notice Always address(0): there is no fallback oracle
  function getFallbackOracle() external view returns (address);
}
