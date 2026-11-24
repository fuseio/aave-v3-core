// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.10;

import {Script} from 'forge-std/Script.sol';
import {FuseSafeBatches} from './FuseSafeBatches.sol';

/**
 * @notice Builds an Admin Safe batch that writes fresh prices on AaveManualOracle, and with
 * UNPAUSE=true also reopens the pool in exit-only mode (re-freeze + unpause the 4 reserves) in the
 * same batch. Use after the fix batch has executed. Never broadcasts.
 *
 * Reopen for repay/withdraw:
 *   ORACLE=<AaveManualOracle> PRICE_WETH=... PRICE_WFUSE=... PRICE_SOUSD=... UNPAUSE=true \
 *   forge script script-foundry/BuildFusePriceUpdateBatch.s.sol:BuildFusePriceUpdateBatch --rpc-url fuse
 *
 * Weekly price refresh while the pool is open: same command without UNPAUSE.
 * OUT overrides the output path (default safe-batches/fuse-reopen or safe-batches/fuse-prices).
 */
contract BuildFusePriceUpdateBatch is Script, FuseSafeBatches {
  function run() external {
    require(block.chainid == 122, 'not Fuse');
    address oracle = vm.envAddress('ORACLE');
    Prices memory p = Prices(
      vm.envUint('PRICE_WETH'),
      vm.envUint('PRICE_WFUSE'),
      vm.envUint('PRICE_SOUSD')
    );
    bool unpause = vm.envOr('UNPAUSE', false);
    string memory out = vm.envOr(
      'OUT',
      string(unpause ? 'safe-batches/fuse-reopen' : 'safe-batches/fuse-prices')
    );

    Call[] memory calls = _buildPriceUpdateBatch(oracle, p, unpause);
    _execAll(calls);
    _checkPriceUpdateOutcome(oracle, p, unpause);

    _writeSafeBatch(
      out,
      unpause ? 'Fuse lending pool reopen (exit-only)' : 'Fuse lending pool price update',
      unpause
        ? 'Write fresh prices, keep reserves frozen, unpause'
        : 'Write fresh prices on AaveManualOracle',
      calls
    );
  }
}
