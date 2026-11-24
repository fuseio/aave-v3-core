// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.10;

import {Test, console2} from 'forge-std/Test.sol';
import {IERC20} from '../contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {AaveManualOracle} from '../contracts/misc/AaveManualOracle.sol';
import {FuseSafeBatches} from '../script-foundry/FuseSafeBatches.sol';

interface IOwnable {
  function owner() external view returns (address);
}

/**
 * @notice Runs the handover plan's Admin Safe batches against a fork of Fuse with AaveManualOracle,
 * using the same builder the export scripts use, so what is tested is what the Safe signs.
 *
 * Prices default to the plan's 18 Nov figures; override at signing time:
 *   PRICE_WETH=175500000000 PRICE_WFUSE=530000 PRICE_SOUSD=108970000 FORK_BLOCK=<n>
 *
 * forge test --match-path test-foundry/AaveManualOracle.fork.t.sol -vv
 */
contract AaveManualOracleForkTest is Test, FuseSafeBatches {
  AaveManualOracle internal oracle;

  function setUp() public {
    uint256 forkBlock = vm.envOr('FORK_BLOCK', uint256(0));
    if (forkBlock == 0) vm.createSelectFork(vm.rpcUrl('fuse_archive'));
    else vm.createSelectFork(vm.rpcUrl('fuse_archive'), forkBlock);

    oracle = new AaveManualOracle(PROVIDER, SAFE);
  }

  function _prices() internal view returns (Prices memory) {
    return
      Prices(
        vm.envOr('PRICE_WETH', uint256(1755e8)),
        vm.envOr('PRICE_WFUSE', uint256(530000)), // $0.0053
        vm.envOr('PRICE_SOUSD', uint256(108970000)) // accountant getRate() (6 dp) * 100
      );
  }

  function _runFix(bool includeWfuse) internal returns (FixPlan memory plan, uint256 wethGained) {
    plan = _buildFixBatch(address(oracle), _prices(), includeWfuse, 100);
    _fundSafe(plan, true);
    uint256 wethBefore = IERC20(WETH).balanceOf(SAFE);
    _execAll(plan.calls);
    wethGained = IERC20(WETH).balanceOf(SAFE) - wethBefore;
  }

  function test_fork_preconditions() public {
    assertEq(PROVIDER.getPriceOracle(), OLD_ORACLE, 'old oracle not connected anymore');
    assertEq(IOwnable(address(PROVIDER)).owner(), SAFE, 'provider owner');
    address[] memory r = _reserves();
    for (uint256 i = 0; i < r.length; i++)
      assertTrue(DATA_PROVIDER.getPaused(r[i]), 'reserve not paused');
  }

  function test_fork_connectingBeforePricesRevertsInsteadOfUsingZero() public {
    vm.prank(SAFE);
    PROVIDER.setPriceOracle(address(oracle));
    vm.expectRevert();
    POOL.getUserAccountData(ATTACKER_1BD2);
  }

  function test_fork_buildingLeavesStateUntouched() public {
    _buildFixBatch(address(oracle), _prices(), false, 100);
    assertEq(PROVIDER.getPriceOracle(), OLD_ORACLE);
    assertGt(_totalDebt(SOUSD, ATTACKER_1BD2), 0);
    assertEq(IERC20(SOUSD).allowance(SAFE, address(POOL)), 0);
  }

  /// Whole fix batch without the optional WFUSE part (decision 2 = no).
  function test_fork_fixBatch() public {
    (FixPlan memory plan, uint256 wethGained) = _runFix(false);
    _checkFixOutcome(address(oracle));

    // the batch starts by freezing and ends by pausing again
    assertEq(plan.calls[0].to, address(CONFIGURATOR));
    assertEq(plan.calls[plan.calls.length - 1].to, address(CONFIGURATOR));
    assertGt(wethGained, 1.5e18, 'WETH received');

    console2.log('calls in batch', plan.calls.length);
    console2.log('soUSD needed', plan.soUSDNeeded);
    console2.log('USDC.e needed', plan.usdcNeeded);
    console2.log('WETH received', wethGained);
  }

  /// Whole fix batch including the WFUSE liquidations (decision 2 = yes).
  function test_fork_fixBatch_withWfuse() public {
    (FixPlan memory plan, uint256 wethGained) = _runFix(true);
    _checkFixOutcome(address(oracle));
    assertGt(plan.wfuseNeeded, 0, 'no WFUSE liquidation in batch');
    assertGt(wethGained, 3e18, 'WETH received');
    console2.log('WFUSE needed', plan.wfuseNeeded);
    console2.log('WETH received', wethGained);
  }

  /// While paused after the fix, nothing moves; the later reopen batch makes the pool exit-only.
  function test_fork_reopenAfterFix() public {
    _runFix(false);

    vm.prank(SAFE);
    vm.expectRevert();
    POOL.supply(SOUSD, 1e6, SAFE, 0);

    vm.warp(block.timestamp + 7 days);
    Prices memory p = _prices();
    Call[] memory calls = _buildPriceUpdateBatch(address(oracle), p, true);
    _execAll(calls);
    _checkPriceUpdateOutcome(address(oracle), p, true);

    // frozen: no new deposits even though unpaused
    deal(SOUSD, address(this), 1e6);
    IERC20(SOUSD).approve(address(POOL), 1e6);
    vm.expectRevert();
    POOL.supply(SOUSD, 1e6, address(this), 0);
  }

  function test_fork_priceUpdateRequiresConnectedOracle() public {
    vm.expectRevert(bytes('AaveManualOracle is not the connected oracle'));
    this.externalBuildPriceUpdate();
  }

  function externalBuildPriceUpdate() external view {
    _buildPriceUpdateBatch(address(oracle), _prices(), true);
  }
}
