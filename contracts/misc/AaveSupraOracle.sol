// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {AggregatorInterface} from '../dependencies/chainlink/AggregatorInterface.sol';
import {Errors} from '../protocol/libraries/helpers/Errors.sol';
import {IACLManager} from '../interfaces/IACLManager.sol';
import {IPoolAddressesProvider} from '../interfaces/IPoolAddressesProvider.sol';
import {IPriceOracleGetter} from '../interfaces/IPriceOracleGetter.sol';
import {IAaveSupraOracle} from '../interfaces/IAaveSupraOracle.sol';
import {ISupraSValueFeed} from '../interfaces/ISupraSValueFeed.sol';

/**
 * @title AaveSupraOracle
 * @author Aave
 * @notice Contract to get asset prices, manage price sources and update the fallback oracle
 * - Use of Supra SValue Feed as first source of price
 * - If the returned price by a Supra SValue Feed is <= 0, the call is forwarded to a fallback oracle
 * - Owned by the Aave governance
 */
contract AaveSupraOracle is IAaveSupraOracle {
  IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;
  ISupraSValueFeed public immutable SUPRA_SVALUE_FEED;

  // Map of asset price sources (asset => pair index)
  mapping(address => uint256) private assetIndices;

  IPriceOracleGetter private _fallbackOracle;
  address public immutable override BASE_CURRENCY;
  uint256 public immutable override BASE_CURRENCY_UNIT;

  /**
   * @dev Only asset listing or pool admin can call functions marked by this modifier.
   */
  modifier onlyAssetListingOrPoolAdmins() {
    _onlyAssetListingOrPoolAdmins();
    _;
  }

  /**
   * @notice Constructor
   * @param provider The address of the new PoolAddressesProvider
   * @param supraSValueFeed The address of the Supra SValue Feed
   * @param assets The addresses of the assets
   * @param pairIndexes The pair indexes of the assets
   * @param fallbackOracle The address of the fallback oracle to use if the data of an
   *        aggregator is not consistent
   * @param baseCurrency The base currency used for the price quotes. If USD is used, base currency is 0x0
   * @param baseCurrencyUnit The unit of the base currency
   */
  constructor(
    IPoolAddressesProvider provider,
    ISupraSValueFeed supraSValueFeed,
    address[] memory assets,
    uint256[] memory pairIndexes,
    address fallbackOracle,
    address baseCurrency,
    uint256 baseCurrencyUnit
  ) {
    ADDRESSES_PROVIDER = provider;
    SUPRA_SVALUE_FEED = supraSValueFeed;
    _setFallbackOracle(fallbackOracle);
    _setAssetsSources(assets, pairIndexes);
    BASE_CURRENCY = baseCurrency;
    BASE_CURRENCY_UNIT = baseCurrencyUnit;
    emit BaseCurrencySet(baseCurrency, baseCurrencyUnit);
  }

  /// @inheritdoc IAaveSupraOracle
  function setAssetSources(
    address[] calldata assets,
    uint256[] calldata pairIndexes
  ) external override onlyAssetListingOrPoolAdmins {
    _setAssetsSources(assets, pairIndexes);
  }

  /// @inheritdoc IAaveSupraOracle
  function setFallbackOracle(
    address fallbackOracle
  ) external override onlyAssetListingOrPoolAdmins {
    _setFallbackOracle(fallbackOracle);
  }

  /**
   * @notice Internal function to set the sources for each asset
   * @param assets The addresses of the assets
   * @param pairIndexes The pair indexes of the assets
   */
  function _setAssetsSources(address[] memory assets, uint256[] memory pairIndexes) internal {
    require(assets.length == pairIndexes.length, Errors.INCONSISTENT_PARAMS_LENGTH);
    for (uint256 i = 0; i < assets.length; i++) {
      assetIndices[assets[i]] = pairIndexes[i];
      emit AssetSourceUpdated(assets[i], address(SUPRA_SVALUE_FEED));
    }
  }

  /**
   * @notice Internal function to set the fallback oracle
   * @param fallbackOracle The address of the fallback oracle
   */
  function _setFallbackOracle(address fallbackOracle) internal {
    _fallbackOracle = IPriceOracleGetter(fallbackOracle);
    emit FallbackOracleUpdated(fallbackOracle);
  }

  /// @inheritdoc IPriceOracleGetter
  function getAssetPrice(address asset) public view override returns (uint256) {
    uint256 pairIndex = assetIndices[asset];

    if (asset == BASE_CURRENCY) {
      return BASE_CURRENCY_UNIT;
    } else {
      ISupraSValueFeed.priceFeed memory priceFeed = SUPRA_SVALUE_FEED.getSvalue(pairIndex);
      // convert price from decimals to BASE_CURRENCY_UNIT
      uint256 price = uint256(priceFeed.price);
      uint256 decimals = uint256(priceFeed.decimals);
      uint256 priceInBaseCurrency;
      if (decimals > 8) {
        priceInBaseCurrency = price / (10 ** (decimals - 8));
      } else {
        priceInBaseCurrency = price * (10 ** (8 - decimals));
      }
      if (priceFeed.price > 0) {
        return priceInBaseCurrency;
      } else {
        return _fallbackOracle.getAssetPrice(asset);
      }
    }
  }

  /// @inheritdoc IAaveSupraOracle
  function getAssetsPrices(
    address[] calldata assets
  ) external view override returns (uint256[] memory) {
    uint256[] memory prices = new uint256[](assets.length);
    for (uint256 i = 0; i < assets.length; i++) {
      prices[i] = getAssetPrice(assets[i]);
    }
    return prices;
  }

  /// @inheritdoc IAaveSupraOracle
  function getSourceOfAsset() external view override returns (address) {
    return address(SUPRA_SVALUE_FEED);
  }

  /// @inheritdoc IAaveSupraOracle
  function getFallbackOracle() external view returns (address) {
    return address(_fallbackOracle);
  }

  function _onlyAssetListingOrPoolAdmins() internal view {
    IACLManager aclManager = IACLManager(ADDRESSES_PROVIDER.getACLManager());
    require(
      aclManager.isAssetListingAdmin(msg.sender) || aclManager.isPoolAdmin(msg.sender),
      Errors.CALLER_NOT_ASSET_LISTING_OR_POOL_ADMIN
    );
  }
}
