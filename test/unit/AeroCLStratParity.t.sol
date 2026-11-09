// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, func-name-mixedcase
pragma solidity ^0.8.30;

import {AeroCLStrat} from "../../src/contracts/strategies/AeroCLStrat.sol";
import {UniCLStrat} from "../../src/contracts/strategies/UniCLStrat.sol";
import {IUniCLStrat} from "../../src/interfaces/strategies/IUniCLStrat.sol";
import {MockUniCLPool} from "../mocks/UniCLStratMocks.sol";
import {MockAeroCLPool, MockAeroCLFactory} from "../mocks/AeroCLStratMocks.sol";
import {UniCLStratTest} from "./UniCLStrat.t.sol";

/**
 * @title AeroCLStratParityTest
 * @notice Runs the whole `UniCLStrat` unit suite against `AeroCLStrat` on a Slipstream-layout pool.
 * @dev `AeroCLStrat` exposes the same `IStrategy` / `IUniCLStrat` ABI as `UniCLStrat`, and
 *      `MockAeroCLPool` exposes the same test setters as `MockUniCLPool` (only `slot0` differs: 6
 *      fields). So `strategy` and `pool` are re-pointed at the Aero contracts and every inherited
 *      test exercises AeroCLStrat / AeroCLRangeLib / AeroCLPositionLib instead.
 *
 *      This is the parity guard that replaced the textual drift check: a behaviour change to
 *      UniCLStrat that comes with a new or changed test in `UniCLStrat.t.sol` also runs here, so a
 *      fix that is not ported to the Aero libraries fails CI.
 *
 *      Tests that only make sense for the Uniswap venue (UniCLStrat constructor / provenance,
 *      metadata, the 7-field `slot0`) are overridden with a skip; their Aero counterparts live in
 *      `AeroCLStrat.t.sol`.
 */
contract AeroCLStratParityTest is UniCLStratTest {
    MockAeroCLFactory internal aeroFactory;

    function setUp() public override {
        super.setUp();

        MockAeroCLPool aeroPool = new MockAeroCLPool(address(weth), address(pairedToken), TICK_SPACING, INITIAL_TICK);
        aeroFactory = new MockAeroCLFactory();
        aeroFactory.setPool(address(weth), address(pairedToken), TICK_SPACING, address(aeroPool));

        pool = MockUniCLPool(address(aeroPool));
        strategy = UniCLStrat(payable(address(new AeroCLStrat(_aeroConfig()))));
    }

    /// @dev Slipstream keys pools by tick spacing, so the rebind goes through the Aero factory.
    function test_Constructor_RevertsWhenFactoryReturnsDifferentPool() public override {
        MockAeroCLPool otherPool = new MockAeroCLPool(address(weth), address(pairedToken), TICK_SPACING, INITIAL_TICK);
        aeroFactory.setPool(address(weth), address(pairedToken), TICK_SPACING, address(otherPool));

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidPool.selector);
        _newStrategy(_aeroConfig());
    }

    // ============ Venue hooks ============

    /// @dev Inherited tests build configs from `_defaultConfig()`, which names the Uniswap
    ///      factory; swap in the Aero factory unless a test deliberately set something else.
    function _newStrategy(IUniCLStrat.DeploymentConfig memory _config) internal override returns (address) {
        if (_config.addresses.factory == address(factory)) _config.addresses.factory = address(aeroFactory);
        return address(new AeroCLStrat(_config));
    }

    function _expectedName() internal pure override returns (string memory) {
        return "Aero Concentrated Liquidity Strategy";
    }

    function _expectedVersion() internal pure override returns (string memory) {
        return "1.0.0";
    }

    function _expectedFactory() internal view override returns (address) {
        return address(aeroFactory);
    }

    function _aeroConfig() internal view returns (IUniCLStrat.DeploymentConfig memory config) {
        config = _defaultConfig();
        config.addresses.pool = address(pool);
        config.addresses.factory = address(aeroFactory);
    }
}
