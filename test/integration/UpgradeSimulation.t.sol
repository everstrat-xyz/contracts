// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StrategyManager} from "../../src/contracts/StrategyManager.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";
import {Registry} from "registry/Registry.sol";
import {Auth} from "../../src/libraries/Auth.sol";

/**
 * @title Upgrade Simulation Tests
 * @notice Comprehensive tests for contract upgrade scenarios
 */
contract UpgradeSimulationTest is ProtocolTestBase {
    StrategyManager public implementation;
    StrategyManager public strategyManager;
    Registry public registry;

    address public owner;
    address public admin;
    address public controllerAddr;
    address public strategy1;
    address public strategy2;

    uint256 public constant ETH_PRICE = 4000e8;
    uint256 public constant STALENESS_INTERVAL = 3600;

    function setUp() public {
        owner = address(this);
        admin = address(0x1);

        ProtocolContracts memory contracts = _deployProtocol(owner, 5e17);
        registry = contracts.registry;
        strategyManager = contracts.strategyManager;
        controllerAddr = address(contracts.controller);
        implementation = new StrategyManager();

        MockPriceFeed ethPriceFeed = new MockPriceFeed(8, int256(ETH_PRICE));
        contracts.oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);

        strategy1 = address(new MockStrategy("Strategy 1", controllerAddr, address(strategyManager)));
        strategy2 = address(new MockStrategy("Strategy 2", controllerAddr, address(strategyManager)));
    }

    function test_UpgradePreservesState() public {
        vm.startPrank(owner);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        assertTrue(strategyManager.isStrategyRegistered(strategy1));
        assertTrue(strategyManager.isStrategyRegistered(strategy2));
        assertEq(strategyManager.strategyCount(), 2);

        StrategyManager newImplementation = new StrategyManager();

        vm.prank(owner);
        strategyManager.upgradeToAndCall(address(newImplementation), "");

        assertTrue(strategyManager.isStrategyRegistered(strategy1));
        assertTrue(strategyManager.isStrategyRegistered(strategy2));
        assertEq(strategyManager.strategyCount(), 2);
    }

    function test_UpgradePreservesRoles() public {
        address newAdmin = address(0x99);

        vm.prank(owner);
        registry.grantRole(Auth.ADMIN_ROLE, newAdmin);

        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, owner));
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, newAdmin));
        assertEq(registry.getContractByKey(Auth.CONTROLLER), controllerAddr);

        StrategyManager newImplementation = new StrategyManager();
        vm.prank(owner);
        strategyManager.upgradeToAndCall(address(newImplementation), "");

        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, owner));
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, newAdmin));
        assertEq(registry.getContractByKey(Auth.CONTROLLER), controllerAddr);
    }

    function test_UpgradePreservesPauseState() public {
        vm.prank(owner);
        strategyManager.pause();
        assertTrue(strategyManager.paused());

        StrategyManager newImplementation = new StrategyManager();
        vm.prank(owner);
        strategyManager.upgradeToAndCall(address(newImplementation), "");

        assertTrue(strategyManager.paused());
    }
}
