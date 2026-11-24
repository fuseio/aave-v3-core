// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.10;

import {Script, console2} from 'forge-std/Script.sol';
import {IPoolAddressesProvider} from '../contracts/interfaces/IPoolAddressesProvider.sol';
import {AaveManualOracle} from '../contracts/misc/AaveManualOracle.sol';

/**
 * @notice Deploys AaveManualOracle for the Fuse market (step 3 of the handover plan).
 * The oracle is deployed with NO prices and owned by the Admin Safe. Prices are written and the
 * oracle is connected inside the single Admin Safe MultiSend (step 5):
 *   AaveManualOracle.setAssetPrices([USDC.e, WETH, WFUSE, soUSD], [...])
 *   PoolAddressesProvider.setPriceOracle(AaveManualOracle)
 * Until then nothing reads it, and connecting it before prices are set makes price reads revert.
 *
 * forge script script-foundry/DeployAaveManualOracle.s.sol:DeployAaveManualOracle \
 *   --rpc-url fuse --broadcast --account <keystore> \
 *   --verify --verifier blockscout --verifier-url https://explorer.fuse.io/api/
 */
contract DeployAaveManualOracle is Script {
  address internal constant POOL_ADDRESSES_PROVIDER = 0x72749C8543dD9Ad0A3f7661d09bc40b0315016a2;
  address internal constant ADMIN_SAFE = 0x03709784c96aeaAa9Dd38Df14A23e996681b2C66;

  function run() external returns (AaveManualOracle oracle) {
    require(block.chainid == 122, 'not Fuse');

    vm.startBroadcast();
    oracle = new AaveManualOracle(IPoolAddressesProvider(POOL_ADDRESSES_PROVIDER), ADMIN_SAFE);
    vm.stopBroadcast();

    require(oracle.owner() == ADMIN_SAFE, 'owner');
    require(address(oracle.ADDRESSES_PROVIDER()) == POOL_ADDRESSES_PROVIDER, 'provider');
    require(oracle.BASE_CURRENCY_UNIT() == 1e8, 'unit');

    console2.log('AaveManualOracle:', address(oracle));
    console2.log('owner (Admin Safe):', oracle.owner());
  }
}
