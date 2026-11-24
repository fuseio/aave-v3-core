// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.10;

import {CommonBase} from 'forge-std/Base.sol';
import {StdCheats} from 'forge-std/StdCheats.sol';
import {console2} from 'forge-std/console2.sol';
import {IERC20} from '../contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {IPool} from '../contracts/interfaces/IPool.sol';
import {IPoolAddressesProvider} from '../contracts/interfaces/IPoolAddressesProvider.sol';
import {IPoolConfigurator} from '../contracts/interfaces/IPoolConfigurator.sol';
import {IPoolDataProvider} from '../contracts/interfaces/IPoolDataProvider.sol';
import {IAaveManualOracle} from '../contracts/interfaces/IAaveManualOracle.sol';

/**
 * @notice Builds, simulates and exports the Admin Safe batches for the Fuse lending pool fix.
 * Every batch is one Safe transaction (Transaction Builder JSON -> MultiSend), so nobody can act
 * between its calls. Each call is simulated with the Admin Safe as msg.sender, which is what the
 * Safe's MultiSend does on chain.
 *
 * Fix batch, in order:
 *   1. freeze the 4 reserves (exit-only)
 *   2. write prices on AaveManualOracle, connect it on the PoolAddressesProvider
 *   3. unpause the 4 reserves
 *   4. approve the Pool
 *   5. liquidate the attacker accounts (WETH collateral, receiveAToken = false)
 *   6. repay the attackers' leftover soUSD / USDC.e debt on their behalf
 *   7. reset approvals to 0
 *   8. pause the 4 reserves again
 *
 * Price update batch (later): write prices; with unpause = true also re-freeze and unpause.
 */
abstract contract FuseSafeBatches is CommonBase, StdCheats {
  IPoolAddressesProvider internal constant PROVIDER =
    IPoolAddressesProvider(0x72749C8543dD9Ad0A3f7661d09bc40b0315016a2);
  IPool internal constant POOL = IPool(0xe3eda4b12ae4ACC031E4CF9Eae08ACe6250CED3E);
  IPoolConfigurator internal constant CONFIGURATOR =
    IPoolConfigurator(0x6CB77Aa6Ef154480bFe9670F22BF1BBc9FBe7715);
  IPoolDataProvider internal constant DATA_PROVIDER =
    IPoolDataProvider(0x87cB512CFB0f18F4Dd9652a186922cf6A4e63213);
  address internal constant OLD_ORACLE = 0xcdeFAe251B4401EDAb328F475f5a6d0C9E7c7C1B;
  address internal constant SAFE = 0x03709784c96aeaAa9Dd38Df14A23e996681b2C66;

  address internal constant USDC_E = 0xc6Bc407706B7140EE8Eef2f86F9504651b63e7f9;
  address internal constant WETH = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;
  address internal constant WFUSE = 0x0BE9e53fd7EDaC9F859882AfdDa116645287C629;
  address internal constant SOUSD = 0x75333830E7014e909535389a6E5b0C02aA62ca27;

  address internal constant ATTACKER_19AF = 0x19af8eC924B078C4988760cB09a2b99Ec567500B;
  address internal constant ATTACKER_0AE6 = 0x0AE6588174E63E1252ed86999d86a3ba0381096D;
  address internal constant ATTACKER_1BD2 = 0x1BD216e459396D82e66bb5400ae3a6294E1eE26F;
  address internal constant ATTACKER_0769 = 0x07692D7b9A5855F3794453c55A8CED0d7698ddCc;

  struct Call {
    address to;
    bytes data;
    string label;
  }

  /// USD prices with 8 decimals. USDC.e is always 1e8.
  struct Prices {
    uint256 weth;
    uint256 wfuse;
    uint256 soUSD; // soUSD accountant getRate() (6 decimals) * 100
  }

  struct FixPlan {
    Call[] calls;
    uint256 soUSDNeeded;
    uint256 usdcNeeded;
    uint256 wfuseNeeded;
  }

  struct Measured {
    Call[] liquidations;
    Call[] repays;
    uint256 soUSDLiquidation;
    uint256 usdcLiquidation;
    uint256 wfuseLiquidation;
    uint256 soUSDRepay;
    uint256 usdcRepay;
  }

  // ---------------------------------------------------------------------------------------------
  // Fix batch
  // ---------------------------------------------------------------------------------------------

  /**
   * @notice Builds the fix batch. Amounts are measured with a dry run on a state snapshot that is
   * rolled back afterwards, so the caller's state is unchanged. Repay amounts carry `bufferBps`
   * extra for interest accrued before execution; the Pool only pulls the actual debt.
   */
  function _buildFixBatch(
    address oracle,
    Prices memory p,
    bool includeWfuse,
    uint256 bufferBps
  ) internal returns (FixPlan memory plan) {
    _checkPrices(p);
    require(IAaveManualOracle(oracle).owner() == SAFE, 'oracle owner is not the Admin Safe');
    require(
      address(IAaveManualOracle(oracle).ADDRESSES_PROVIDER()) == address(PROVIDER),
      'oracle provider'
    );
    require(
      PROVIDER.getPriceOracle() == OLD_ORACLE,
      'price oracle already replaced: fix already done?'
    );

    uint256 snapshot = vm.snapshotState();
    Measured memory m = _measure(oracle, p, includeWfuse, bufferBps);
    vm.revertToState(snapshot);

    plan.soUSDNeeded = _withBuffer(m.soUSDLiquidation, bufferBps) + m.soUSDRepay;
    plan.usdcNeeded = _withBuffer(m.usdcLiquidation, bufferBps) + m.usdcRepay;
    plan.wfuseNeeded = _withBuffer(m.wfuseLiquidation, bufferBps);

    Call[] memory buf = new Call[](64);
    uint256 n = _openCalls(buf, 0, oracle, p);
    n = _approveCalls(buf, n, plan.soUSDNeeded, plan.usdcNeeded, plan.wfuseNeeded);
    n = _append(buf, n, m.liquidations);
    n = _append(buf, n, m.repays);
    n = _resetApprovalCalls(buf, n, plan);
    n = _pauseCalls(buf, n, true);
    plan.calls = _trim(buf, n);
  }

  /// @notice Requires the post-fix state: new oracle live, reserves paused + frozen, attacker debt cleared.
  function _checkFixOutcome(address oracle) internal view {
    require(PROVIDER.getPriceOracle() == oracle, 'oracle not connected');
    _checkReserves(true);
    address[4] memory attackers = _attackers();
    for (uint256 i = 0; i < attackers.length; i++) {
      require(_totalDebt(SOUSD, attackers[i]) == 0, 'attacker soUSD debt left');
      require(_totalDebt(USDC_E, attackers[i]) == 0, 'attacker USDC.e debt left');
    }
    require(IERC20(SOUSD).allowance(SAFE, address(POOL)) == 0, 'soUSD allowance left');
    require(IERC20(USDC_E).allowance(SAFE, address(POOL)) == 0, 'USDC.e allowance left');
    require(IERC20(WFUSE).allowance(SAFE, address(POOL)) == 0, 'WFUSE allowance left');
  }

  /// @notice Makes sure the Safe holds what the fix batch pulls. `allowDeal` mints it (simulation only).
  function _fundSafe(FixPlan memory plan, bool allowDeal) internal {
    _ensureBalance(SOUSD, plan.soUSDNeeded, allowDeal);
    _ensureBalance(USDC_E, plan.usdcNeeded, allowDeal);
    _ensureBalance(WFUSE, plan.wfuseNeeded, allowDeal);
  }

  // ---------------------------------------------------------------------------------------------
  // Price update / reopen batch
  // ---------------------------------------------------------------------------------------------

  /**
   * @notice Writes fresh prices. With `unpause`, also re-freezes and unpauses the 4 reserves so
   * users can repay and withdraw (exit-only). Prices and unpause are always in the same batch.
   */
  function _buildPriceUpdateBatch(
    address oracle,
    Prices memory p,
    bool unpause
  ) internal view returns (Call[] memory) {
    _checkPrices(p);
    require(PROVIDER.getPriceOracle() == oracle, 'AaveManualOracle is not the connected oracle');
    require(IAaveManualOracle(oracle).owner() == SAFE, 'oracle owner is not the Admin Safe');

    Call[] memory buf = new Call[](16);
    uint256 n = _setPricesCall(buf, 0, oracle, p);
    if (unpause) {
      n = _freezeCalls(buf, n);
      n = _pauseCalls(buf, n, false);
    }
    return _trim(buf, n);
  }

  function _checkPriceUpdateOutcome(address oracle, Prices memory p, bool unpause) internal view {
    IAaveManualOracle o = IAaveManualOracle(oracle);
    require(o.getAssetPrice(USDC_E) == 1e8, 'USDC.e price');
    require(o.getAssetPrice(WETH) == p.weth, 'WETH price');
    require(o.getAssetPrice(WFUSE) == p.wfuse, 'WFUSE price');
    require(o.getAssetPrice(SOUSD) == p.soUSD, 'soUSD price');
    if (unpause) _checkReserves(false);
  }

  // ---------------------------------------------------------------------------------------------
  // Execution and export
  // ---------------------------------------------------------------------------------------------

  /// @notice Executes every call with the Admin Safe as msg.sender, reverting with the failing call's label.
  function _execAll(Call[] memory calls) internal {
    for (uint256 i = 0; i < calls.length; i++) _exec(calls[i]);
  }

  /**
   * @notice Writes `<basePath>.json` (import into Safe{Wallet} > Transaction Builder) and
   * `<basePath>.txt` (the same calls, numbered and labelled, for signers to check).
   */
  function _writeSafeBatch(
    string memory basePath,
    string memory name,
    string memory description,
    Call[] memory calls
  ) internal {
    string memory txs;
    string memory summary = string(
      abi.encodePacked(
        name,
        '\n',
        description,
        '\nSafe: ',
        vm.toString(SAFE),
        ' (Fuse, chain 122)\n\n'
      )
    );
    for (uint256 i = 0; i < calls.length; i++) {
      txs = string(
        abi.encodePacked(
          txs,
          i == 0 ? '' : ',',
          '{"to":"',
          vm.toString(calls[i].to),
          '","value":"0","data":"',
          vm.toString(calls[i].data),
          '","contractMethod":null,"contractInputsValues":null}'
        )
      );
      summary = string(
        abi.encodePacked(
          summary,
          vm.toString(i + 1),
          '. ',
          calls[i].label,
          '\n   to ',
          vm.toString(calls[i].to),
          '\n'
        )
      );
    }
    string memory json = string(
      abi.encodePacked(
        '{"version":"1.0","chainId":"122","createdAt":',
        vm.toString(block.timestamp * 1000),
        ',"meta":{"name":"',
        name,
        '","description":"',
        description,
        '","txBuilderVersion":"1.16.5","createdFromSafeAddress":"',
        vm.toString(SAFE),
        '","createdFromOwnerAddress":""},"transactions":[',
        txs,
        ']}'
      )
    );
    vm.writeFile(string(abi.encodePacked(basePath, '.json')), json);
    vm.writeFile(string(abi.encodePacked(basePath, '.txt')), summary);
    console2.log(summary);
  }

  // ---------------------------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------------------------

  function _measure(
    address oracle,
    Prices memory p,
    bool includeWfuse,
    uint256 bufferBps
  ) private returns (Measured memory m) {
    deal(SOUSD, SAFE, 1_000_000e6);
    deal(USDC_E, SAFE, 1_000_000e6);
    if (includeWfuse) deal(WFUSE, SAFE, 100_000_000e18);

    Call[] memory open = new Call[](16);
    _execAll(_trim(open, _openCalls(open, 0, oracle, p)));

    vm.startPrank(SAFE);
    IERC20(SOUSD).approve(address(POOL), type(uint256).max);
    IERC20(USDC_E).approve(address(POOL), type(uint256).max);
    IERC20(WFUSE).approve(address(POOL), type(uint256).max);
    vm.stopPrank();

    uint256 soUSD0 = IERC20(SOUSD).balanceOf(SAFE);
    uint256 usdc0 = IERC20(USDC_E).balanceOf(SAFE);
    uint256 wfuse0 = IERC20(WFUSE).balanceOf(SAFE);
    m.liquidations = _liquidate(includeWfuse);
    m.soUSDLiquidation = soUSD0 - IERC20(SOUSD).balanceOf(SAFE);
    m.usdcLiquidation = usdc0 - IERC20(USDC_E).balanceOf(SAFE);
    m.wfuseLiquidation = wfuse0 - IERC20(WFUSE).balanceOf(SAFE);

    (m.repays, m.soUSDRepay, m.usdcRepay) = _repayCalls(bufferBps);
  }

  /// Liquidates, in plan order, every (account, debt) pair that has both debt and WETH collateral left.
  function _liquidate(bool includeWfuse) private returns (Call[] memory) {
    address[3] memory accounts = [ATTACKER_1BD2, ATTACKER_0769, ATTACKER_0AE6];
    address[3] memory debts = [SOUSD, USDC_E, WFUSE];
    Call[] memory buf = new Call[](9);
    uint256 n;
    for (uint256 a = 0; a < accounts.length; a++) {
      for (uint256 d = 0; d < debts.length; d++) {
        if (debts[d] == WFUSE && !includeWfuse) continue;
        if (_totalDebt(debts[d], accounts[a]) == 0 || _aBalance(WETH, accounts[a]) == 0) continue;
        Call memory c = Call(
          address(POOL),
          abi.encodeWithSelector(
            IPool.liquidationCall.selector,
            WETH,
            debts[d],
            accounts[a],
            type(uint256).max,
            false
          ),
          string(
            abi.encodePacked(
              'Pool.liquidationCall(WETH, ',
              _sym(debts[d]),
              ', ',
              vm.toString(accounts[a]),
              ', max, false)'
            )
          )
        );
        _exec(c);
        buf[n++] = c;
      }
    }
    return _trim(buf, n);
  }

  /// Repay-on-behalf calls for every attacker's remaining soUSD / USDC.e debt (stable and variable).
  function _repayCalls(
    uint256 bufferBps
  ) private view returns (Call[] memory, uint256 soUSDTotal, uint256 usdcTotal) {
    address[4] memory attackers = _attackers();
    address[2] memory assets = [SOUSD, USDC_E];
    Call[] memory buf = new Call[](16);
    uint256 n;
    uint256 added;
    for (uint256 i = 0; i < attackers.length; i++) {
      for (uint256 j = 0; j < assets.length; j++) {
        (n, added) = _addRepays(buf, n, assets[j], attackers[i], bufferBps);
        if (assets[j] == SOUSD) soUSDTotal += added;
        else usdcTotal += added;
      }
    }
    return (_trim(buf, n), soUSDTotal, usdcTotal);
  }

  function _addRepays(
    Call[] memory buf,
    uint256 n,
    address asset,
    address user,
    uint256 bufferBps
  ) private view returns (uint256, uint256 total) {
    (uint256 stableDebt, uint256 variableDebt) = _debts(asset, user);
    if (stableDebt > 0) {
      uint256 amount = _withBuffer(stableDebt, bufferBps);
      total += amount;
      buf[n++] = _repayCall(asset, amount, 1, user);
    }
    if (variableDebt > 0) {
      uint256 amount = _withBuffer(variableDebt, bufferBps);
      total += amount;
      buf[n++] = _repayCall(asset, amount, 2, user);
    }
    return (n, total);
  }

  function _repayCall(
    address asset,
    uint256 amount,
    uint256 mode,
    address user
  ) private pure returns (Call memory) {
    return
      Call(
        address(POOL),
        abi.encodeWithSelector(IPool.repay.selector, asset, amount, mode, user),
        string(
          abi.encodePacked(
            'Pool.repay(',
            _sym(asset),
            ', ',
            vm.toString(amount),
            ', ',
            vm.toString(mode),
            ', ',
            vm.toString(user),
            ')'
          )
        )
      );
  }

  function _openCalls(
    Call[] memory buf,
    uint256 n,
    address oracle,
    Prices memory p
  ) private pure returns (uint256) {
    n = _freezeCalls(buf, n);
    n = _setPricesCall(buf, n, oracle, p);
    buf[n++] = Call(
      address(PROVIDER),
      abi.encodeWithSelector(IPoolAddressesProvider.setPriceOracle.selector, oracle),
      'PoolAddressesProvider.setPriceOracle(AaveManualOracle)'
    );
    return _pauseCalls(buf, n, false);
  }

  function _setPricesCall(
    Call[] memory buf,
    uint256 n,
    address oracle,
    Prices memory p
  ) private pure returns (uint256) {
    uint256[] memory prices = new uint256[](4);
    prices[0] = 1e8;
    prices[1] = p.weth;
    prices[2] = p.wfuse;
    prices[3] = p.soUSD;
    buf[n++] = Call(
      oracle,
      abi.encodeWithSelector(IAaveManualOracle.setAssetPrices.selector, _reserves(), prices),
      'AaveManualOracle.setAssetPrices([USDC.e, WETH, WFUSE, soUSD], prices)'
    );
    return n;
  }

  function _freezeCalls(Call[] memory buf, uint256 n) private pure returns (uint256) {
    address[] memory r = _reserves();
    for (uint256 i = 0; i < r.length; i++) {
      buf[n++] = Call(
        address(CONFIGURATOR),
        abi.encodeWithSelector(IPoolConfigurator.setReserveFreeze.selector, r[i], true),
        string(abi.encodePacked('PoolConfigurator.setReserveFreeze(', _sym(r[i]), ', true)'))
      );
    }
    return n;
  }

  function _pauseCalls(Call[] memory buf, uint256 n, bool paused) private pure returns (uint256) {
    address[] memory r = _reserves();
    for (uint256 i = 0; i < r.length; i++) {
      buf[n++] = Call(
        address(CONFIGURATOR),
        abi.encodeWithSelector(IPoolConfigurator.setReservePause.selector, r[i], paused),
        string(
          abi.encodePacked(
            'PoolConfigurator.setReservePause(',
            _sym(r[i]),
            paused ? ', true)' : ', false)'
          )
        )
      );
    }
    return n;
  }

  function _approveCalls(
    Call[] memory buf,
    uint256 n,
    uint256 soUSDAmount,
    uint256 usdcAmount,
    uint256 wfuseAmount
  ) private pure returns (uint256) {
    if (soUSDAmount > 0) n = _approve(buf, n, SOUSD, soUSDAmount);
    if (usdcAmount > 0) n = _approve(buf, n, USDC_E, usdcAmount);
    if (wfuseAmount > 0) n = _approve(buf, n, WFUSE, wfuseAmount);
    return n;
  }

  function _resetApprovalCalls(
    Call[] memory buf,
    uint256 n,
    FixPlan memory plan
  ) private pure returns (uint256) {
    if (plan.soUSDNeeded > 0) n = _approve(buf, n, SOUSD, 0);
    if (plan.usdcNeeded > 0) n = _approve(buf, n, USDC_E, 0);
    if (plan.wfuseNeeded > 0) n = _approve(buf, n, WFUSE, 0);
    return n;
  }

  function _approve(
    Call[] memory buf,
    uint256 n,
    address token,
    uint256 amount
  ) private pure returns (uint256) {
    buf[n++] = Call(
      token,
      abi.encodeWithSelector(IERC20.approve.selector, address(POOL), amount),
      string(abi.encodePacked(_sym(token), '.approve(Pool, ', vm.toString(amount), ')'))
    );
    return n;
  }

  function _exec(Call memory c) internal {
    vm.prank(SAFE);
    (bool ok, bytes memory ret) = c.to.call(c.data);
    if (!ok) {
      console2.log('Safe batch call failed:', c.label);
      assembly {
        revert(add(ret, 32), mload(ret))
      }
    }
  }

  function _ensureBalance(address token, uint256 needed, bool allowDeal) private {
    uint256 balance = IERC20(token).balanceOf(SAFE);
    if (balance >= needed) return;
    if (allowDeal) {
      console2.log('SIMULATION ONLY: minting to the Safe', _sym(token), needed - balance);
      deal(token, SAFE, needed);
      return;
    }
    revert(
      string(
        abi.encodePacked(
          'Admin Safe is short of ',
          _sym(token),
          ': needs ',
          vm.toString(needed),
          ', has ',
          vm.toString(balance)
        )
      )
    );
  }

  function _checkReserves(bool paused) private view {
    address[] memory r = _reserves();
    for (uint256 i = 0; i < r.length; i++) {
      (, , , , , , , , bool isActive, bool isFrozen) = DATA_PROVIDER.getReserveConfigurationData(
        r[i]
      );
      require(isActive && isFrozen, 'reserve not active + frozen');
      require(
        DATA_PROVIDER.getPaused(r[i]) == paused,
        paused ? 'reserve not paused' : 'reserve still paused'
      );
    }
  }

  function _checkPrices(Prices memory p) internal pure {
    require(p.weth >= 500e8 && p.weth <= 20_000e8, 'PRICE_WETH out of range: USD with 8 decimals');
    require(p.wfuse >= 1e4 && p.wfuse <= 1e8, 'PRICE_WFUSE out of range: USD with 8 decimals');
    require(
      p.soUSD >= 1e8 && p.soUSD <= 150_000_000,
      'PRICE_SOUSD out of range: accountant getRate() * 100'
    );
  }

  function _debts(
    address asset,
    address user
  ) internal view returns (uint256 stableDebt, uint256 variableDebt) {
    (, stableDebt, variableDebt, , , , , , ) = DATA_PROVIDER.getUserReserveData(asset, user);
  }

  function _totalDebt(address asset, address user) internal view returns (uint256) {
    (uint256 s, uint256 v) = _debts(asset, user);
    return s + v;
  }

  function _aBalance(address asset, address user) internal view returns (uint256 balance) {
    (balance, , , , , , , , ) = DATA_PROVIDER.getUserReserveData(asset, user);
  }

  function _reserves() internal pure returns (address[] memory r) {
    r = new address[](4);
    r[0] = USDC_E;
    r[1] = WETH;
    r[2] = WFUSE;
    r[3] = SOUSD;
  }

  function _attackers() internal pure returns (address[4] memory) {
    return [ATTACKER_19AF, ATTACKER_0AE6, ATTACKER_1BD2, ATTACKER_0769];
  }

  function _sym(address token) internal pure returns (string memory) {
    if (token == USDC_E) return 'USDC.e';
    if (token == WETH) return 'WETH';
    if (token == WFUSE) return 'WFUSE';
    if (token == SOUSD) return 'soUSD';
    return '?';
  }

  function _withBuffer(uint256 amount, uint256 bufferBps) private pure returns (uint256) {
    return amount == 0 ? 0 : amount + (amount * bufferBps) / 10_000 + 1;
  }

  function _append(
    Call[] memory buf,
    uint256 n,
    Call[] memory more
  ) private pure returns (uint256) {
    for (uint256 i = 0; i < more.length; i++) buf[n++] = more[i];
    return n;
  }

  function _trim(Call[] memory buf, uint256 n) private pure returns (Call[] memory) {
    assembly {
      mstore(buf, n)
    }
    return buf;
  }
}
