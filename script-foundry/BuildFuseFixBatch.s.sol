// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.10;

import {Script, console2} from 'forge-std/Script.sol';
import {IERC20} from '../contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {FuseSafeBatches} from './FuseSafeBatches.sol';

/**
 * @notice Builds the single Admin Safe batch for the Fuse fix (handover plan step 5), simulates it
 * on live Fuse state as the Safe, checks the result, and writes it out for the Safe Transaction Builder.
 * Never broadcasts: the Safe signers execute the exported batch.
 *
 * ORACLE=<AaveManualOracle> PRICE_WETH=175500000000 PRICE_WFUSE=530000 PRICE_SOUSD=108970000 \
 * forge script script-foundry/BuildFuseFixBatch.s.sol:BuildFuseFixBatch --rpc-url fuse
 *
 * Optional env:
 *   INCLUDE_WFUSE=true   also liquidate the attackers' WFUSE debt (decision 2)
 *   BUFFER_BPS=100       extra on approvals and repay amounts for interest accrued until execution
 *   ALLOW_DEAL=true      dry run before the Safe is funded: mints missing tokens in the simulation
 *   OUT=safe-batches/fuse-fix   output path without extension (.json + .txt)
 */
contract BuildFuseFixBatch is Script, FuseSafeBatches {
  function run() external {
    require(block.chainid == 122, 'not Fuse');
    address oracle = vm.envAddress('ORACLE');
    Prices memory p = Prices(
      vm.envUint('PRICE_WETH'),
      vm.envUint('PRICE_WFUSE'),
      vm.envUint('PRICE_SOUSD')
    );
    bool includeWfuse = vm.envOr('INCLUDE_WFUSE', false);
    uint256 bufferBps = vm.envOr('BUFFER_BPS', uint256(100));
    bool allowDeal = vm.envOr('ALLOW_DEAL', false);
    string memory out = vm.envOr('OUT', string('safe-batches/fuse-fix'));

    FixPlan memory plan = _buildFixBatch(oracle, p, includeWfuse, bufferBps);
    console2.log('Admin Safe must hold soUSD (6 dp):', plan.soUSDNeeded);
    console2.log('Admin Safe must hold USDC.e (6 dp):', plan.usdcNeeded);
    console2.log('Admin Safe must hold WFUSE (18 dp):', plan.wfuseNeeded);

    _fundSafe(plan, allowDeal);
    uint256 wethBefore = IERC20(WETH).balanceOf(SAFE);
    _execAll(plan.calls);
    _checkFixOutcome(oracle);
    console2.log(
      'Simulation OK. WETH received by the Safe (18 dp):',
      IERC20(WETH).balanceOf(SAFE) - wethBefore
    );

    _writeSafeBatch(
      out,
      'Fuse lending pool fix',
      'Freeze, switch to AaveManualOracle, unpause, liquidate attackers, repay leftover debt, reset approvals, pause again',
      plan.calls
    );
    if (allowDeal)
      console2.log('WARNING: ALLOW_DEAL was on. Re-run without it once the Safe is funded.');
  }
}
