// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, func-name-mixedcase
pragma solidity ^0.8.30;

import {AeroCLStrat} from "../../src/contracts/strategies/AeroCLStrat.sol";
import {UniCLStrat} from "../../src/contracts/strategies/UniCLStrat.sol";
import {IUniCLStrat} from "../../src/interfaces/strategies/IUniCLStrat.sol";
import {MockUniCLPool} from "../mocks/UniCLStratMocks.sol";
import {MockAeroCLPool, MockAeroCLFactory} from "../mocks/AeroCLStratMocks.sol";
import {UniCLStratFuzzTest} from "./UniCLStratFuzz.t.sol";

/// @notice Runs the `UniCLStrat` fuzz suite against `AeroCLStrat` (see `AeroCLStratParityTest`).
contract AeroCLStratParityFuzzTest is UniCLStratFuzzTest {
    function setUp() public override {
        super.setUp();

        MockAeroCLPool aeroPool = new MockAeroCLPool(address(weth), address(pairedToken), TICK_SPACING, INITIAL_TICK);
        MockAeroCLFactory aeroFactory = new MockAeroCLFactory();
        aeroFactory.setPool(address(weth), address(pairedToken), TICK_SPACING, address(aeroPool));

        pool = MockUniCLPool(address(aeroPool));
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.addresses.factory = address(aeroFactory);
        strategy = UniCLStrat(payable(address(new AeroCLStrat(config))));
    }
}
