// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, func-name-mixedcase
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AeroCLStrat} from "../../src/contracts/strategies/AeroCLStrat.sol";
import {IUniswapV3Pool} from "../../src/interfaces/integrations/uniswap/IUniswapV3Pool.sol";

import {AeroCLStratLegacy} from "./legacy/AeroCLStratLegacy.sol";
import {AeroCLStratForkTest} from "./AeroCLStratFork.t.sol";

/// @dev Differential check of the library split (run via script/ci/run-aero-split-differential.sh,
///      which extracts the pre-split contract from git): runs one scenario against the pre-refactor
///      AeroCLStrat and the library-split AeroCLStrat at the same address on the same fork state,
///      and requires byte-identical observable state after every step.
contract AeroCLStratDifferentialTest is AeroCLStratForkTest {
    uint256 internal constant MAX_TRACE = 512;

    struct Trace {
        uint256[MAX_TRACE] values;
        uint256 length;
    }

    function test_Differential_LegacyVsLibrarySplit() public onlyFork {
        uint256 snapshot = vm.snapshotState();
        Trace memory legacyTrace = _runScenario(true);
        vm.revertToState(snapshot);
        Trace memory splitTrace = _runScenario(false);

        assertEq(legacyTrace.length, splitTrace.length, "trace length");
        for (uint256 i; i < legacyTrace.length; ++i) {
            assertEq(splitTrace.values[i], legacyTrace.values[i], string.concat("trace[", vm.toString(i), "]"));
        }
        emit log_named_uint("compared values", legacyTrace.length);
    }

    function _runScenario(bool _legacy) internal returns (Trace memory t) {
        address deployed = _legacy
            ? address(new AeroCLStratLegacy(_deploymentConfig(AERO_WETH_USDT_POOL)))
            : address(new AeroCLStrat(_deploymentConfig(AERO_WETH_USDT_POOL)));
        _record(t, uint256(uint160(deployed)));
        strategy = AeroCLStrat(payable(deployed));
        vm.prank(strategyManager);
        converter.grantCallerRole(deployed);
        vm.prank(admin);
        strategy.setSwapSlippageBps(strategy.MAX_SWAP_SLIPPAGE_BPS());

        // 1. first deposit (places main + alt)
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);
        _snapshotStrategy(t);

        // 2. in-range volume, then sync pokes fees
        (int256 amount0, int256 amount1) = _swapExactIn(!wethIsToken0, FEE_SWAP_USDT_AMOUNT);
        _swapExactIn(wethIsToken0, uint256(-(wethIsToken0 ? amount0 : amount1)));
        vm.prank(strategyManager);
        strategy.sync();
        _snapshotStrategy(t);

        // 3. partial withdraw (partial-burn path)
        vm.prank(strategyManager);
        _record(t, strategy.withdraw(receiver, PARTIAL_WITHDRAW_AMOUNT));
        _snapshotStrategy(t);

        // 4. settle performance fee
        vm.prank(strategyManager);
        _record(t, strategy.settlePerformanceFee(1_000));
        _snapshotStrategy(t);

        // 5. drift + rebalance (full unwind, re-center, ratio swap, alt)
        _movePoolTickBy(-REBALANCE_TICK_OFFSET);
        _alignPoolToTickBoundaryAndSettle();
        _record(t, strategy.isHealthy() ? 1 : 0);
        vm.prank(strategyManager);
        strategy.rebalance();
        _snapshotStrategy(t);

        // 6. incremental deposit on top of existing positions
        _deposit(0.3 ether);
        _snapshotStrategy(t);

        // 7. withdraw while the pool is not calm (unwind not gated, re-add skipped)
        _movePoolTickBy(NOT_CALM_TICK_OFFSET);
        _record(t, strategy.maxDeposit());
        vm.prank(strategyManager);
        _record(t, strategy.withdraw(receiver, 0.1 ether));
        _snapshotStrategy(t);
        _alignPoolToTickBoundaryAndSettle();

        // 8. admin invests a donation
        vm.deal(address(strategy), address(strategy).balance + 0.05 ether);
        vm.prank(admin);
        _record(t, strategy.investIdleETH());
        _snapshotStrategy(t);

        // 9. near-full withdraw (full unwind without route probe)
        uint256 nav = strategy.navInETH();
        vm.prank(strategyManager);
        _record(t, strategy.withdraw(receiver, nav * 99 / 100));
        _snapshotStrategy(t);

        // 10. deposit, pause (best-effort unwind), emergency exit
        _deposit(0.2 ether);
        vm.prank(security);
        strategy.pause();
        _snapshotStrategy(t);
        vm.prank(security);
        strategy.emergencyExit();
        _snapshotStrategy(t);
        _record(t, strategyManager.balance);
        _record(t, IERC20(USDT).balanceOf(strategyManager));
    }

    function _snapshotStrategy(Trace memory t) internal view {
        (int24 mainLower, int24 mainUpper) = strategy.positionMain();
        (int24 altLower, int24 altUpper) = strategy.positionAlt();
        _recordPosition(t, mainLower, mainUpper);
        _recordPosition(t, altLower, altUpper);
        _record(t, strategy.initTicks() ? 1 : 0);
        _record(t, address(strategy).balance);
        _record(t, IERC20(WETH).balanceOf(address(strategy)));
        _record(t, IERC20(USDT).balanceOf(address(strategy)));
        _record(t, receiver.balance);
        _record(t, strategy.totalDeposited());
        _record(t, strategy.totalWithdrawn());
        _record(t, uint256(_currentSqrtPrice()));
        if (!strategy.paused()) {
            _record(t, strategy.navInETH());
            _record(t, strategy.pendingPerformanceFeeInETH(1_000));
            _record(t, strategy.isHealthy() ? 1 : 0);
        }
    }

    function _recordPosition(Trace memory t, int24 _lower, int24 _upper) internal view {
        _record(t, uint256(int256(_lower)));
        _record(t, uint256(int256(_upper)));
        bytes32 key = keccak256(abi.encodePacked(address(strategy), _lower, _upper));
        (uint128 liquidity,,, uint128 owed0, uint128 owed1) = IUniswapV3Pool(AERO_WETH_USDT_POOL).positions(key);
        _record(t, liquidity);
        _record(t, owed0);
        _record(t, owed1);
    }

    function _record(Trace memory t, uint256 _value) internal pure {
        t.values[t.length++] = _value;
    }
}
