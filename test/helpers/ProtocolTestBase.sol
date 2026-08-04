// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Registry} from "registry/Registry.sol";
import {Converter} from "../../src/contracts/Converter.sol";
import {Controller} from "../../src/contracts/Controller.sol";
import {EVE} from "../../src/contracts/EVE.sol";
import {AMM} from "../../src/contracts/AMM.sol";
import {StrategyManager} from "../../src/contracts/StrategyManager.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {ExitQueue} from "../../src/contracts/ExitQueue.sol";
import {Whitelist} from "../../src/contracts/Whitelist.sol";

import {Auth} from "../../src/libraries/Auth.sol";
import {IRegistry} from "interfaces/IRegistry.sol";
import {IStrategyManager} from "../../src/interfaces/IStrategyManager.sol";

import {MockWETH} from "../mocks/UniCLStratMocks.sol";

/**
 * @title ProtocolTestBase
 * @notice Shared deployment helper matching the Registry-centric protocol wiring.
 */
abstract contract ProtocolTestBase is Test {
    uint256 internal constant DEFAULT_CONNECTOR_WEIGHT = 5e17;
    /// @dev Non-zero DAO treasury used in test deploys; performance fees disabled via 0 bps.
    address internal constant TEST_DAO_TREASURY = address(0xdead);

    struct ProtocolContracts {
        Registry registry;
        EVE token;
        Controller controller;
        StrategyManager strategyManager;
        Oracle oracle;
        ExitQueue exitQueue;
        AMM amm;
        Converter converter;
        MockWETH weth;
        Whitelist whitelist;
    }

    function _deployRegistry(address _admin) internal returns (Registry registry) {
        if (_admin == address(this)) {
            // The Registry constructor rejects `_admin == msg.sender` (the deployer never
            // becomes the designated admin). Deploy through a dedicated bootstrap key and
            // renounce its temporary ADMIN_ROLE so `_admin` ends as the sole admin, exactly
            // as before and mirroring the production finalize step.
            address bootstrapDeployer = makeAddr("registryBootstrapDeployer");
            vm.prank(bootstrapDeployer);
            registry = new Registry(_admin);
            vm.prank(bootstrapDeployer);
            registry.renounceRole(Auth.ADMIN_ROLE, bootstrapDeployer);
        } else {
            registry = new Registry(_admin);
        }
    }

    function _deployProtocolInstances(address _admin, uint256 _connectorWeight)
        internal
        returns (ProtocolContracts memory contracts)
    {
        contracts.registry = _deployRegistry(_admin);
        _deployProtocolInstancesOnRegistry(contracts, _connectorWeight);
    }

    function _deployProtocolInstancesOnRegistry(ProtocolContracts memory contracts, uint256 _connectorWeight)
        internal
    {
        contracts.token = new EVE(address(contracts.registry));
        contracts.exitQueue = _deployExitQueue(contracts.registry);

        Controller controllerImpl = new Controller();
        contracts.controller = Controller(
            payable(
                new ERC1967Proxy(
                    address(controllerImpl),
                    abi.encodeWithSelector(Controller.initialize.selector, address(contracts.registry))
                )
            )
        );

        Oracle oracleImpl = new Oracle();
        contracts.oracle = Oracle(
            address(
                new ERC1967Proxy(
                    address(oracleImpl), abi.encodeWithSelector(Oracle.initialize.selector, address(contracts.registry))
                )
            )
        );

        StrategyManager strategyManagerImpl = new StrategyManager();
        IStrategyManager.FeeConfig memory feeConfig =
            IStrategyManager.FeeConfig({daoTreasury: TEST_DAO_TREASURY, performanceFeeBps: 0});
        contracts.strategyManager = StrategyManager(
            payable(
                new ERC1967Proxy(
                    address(strategyManagerImpl),
                    abi.encodeWithSelector(StrategyManager.initialize.selector, address(contracts.registry), feeConfig)
                )
            )
        );

        contracts.weth = new MockWETH();

        Converter converterImpl = new Converter();
        contracts.converter = Converter(
            payable(
                new ERC1967Proxy(
                    address(converterImpl),
                    abi.encodeWithSelector(
                        Converter.initialize.selector, address(contracts.registry), address(contracts.weth)
                    )
                )
            )
        );

        contracts.whitelist = new Whitelist(address(contracts.registry));

        contracts.amm = new AMM(address(contracts.registry), _connectorWeight);
    }

    function _deployProtocol(address _admin, uint256 _connectorWeight)
        internal
        returns (ProtocolContracts memory contracts)
    {
        contracts = _deployProtocolInstances(_admin, _connectorWeight);
        _registerProtocolContracts(contracts.registry, contracts, _admin, true);
        _grantProtocolRoles(contracts.registry, contracts, _admin, _admin);
        _disableWhitelistByDefault(contracts, _admin);
    }

    function _deployProtocolWithoutAmm(address _admin, uint256 _connectorWeight)
        internal
        returns (ProtocolContracts memory contracts)
    {
        contracts = _deployProtocolInstances(_admin, _connectorWeight);
        _registerProtocolContracts(contracts.registry, contracts, _admin, false);
        _grantProtocolRoles(contracts.registry, contracts, _admin, _admin);
        _disableWhitelistByDefault(contracts, _admin);
    }

    /// @dev Most unit/integration tests exercise enter()/exit() flows that predate the
    ///      Whitelist gate and don't care about invite mechanics. Disabling the gate here
    ///      keeps every existing `_deployProtocol`/`_deployProtocolWithoutAmm` caller working
    ///      unchanged; tests that specifically exercise gating deploy their own Whitelist
    ///      (or re-enable via a fresh instance) instead of relying on this helper.
    function _disableWhitelistByDefault(ProtocolContracts memory _contracts, address _admin) internal {
        vm.prank(_admin);
        _contracts.whitelist.disable();
    }

    function _registerProtocolContracts(
        Registry _registry,
        ProtocolContracts memory _contracts,
        address _admin,
        bool _registerAmm
    ) internal {
        uint256 count = _registerAmm ? 8 : 7;
        bytes32[] memory keys = new bytes32[](count);
        address[] memory addresses = new address[](count);

        keys[0] = Auth.CONTROLLER;
        addresses[0] = address(_contracts.controller);
        uint256 idx = 1;
        if (_registerAmm) {
            keys[idx] = Auth.AMM;
            addresses[idx] = address(_contracts.amm);
            idx++;
        }
        keys[idx] = Auth.STRATEGY_MANAGER;
        addresses[idx] = address(_contracts.strategyManager);
        idx++;
        keys[idx] = Auth.EXIT_QUEUE;
        addresses[idx] = address(_contracts.exitQueue);
        idx++;
        keys[idx] = Auth.ORACLE;
        addresses[idx] = address(_contracts.oracle);
        idx++;
        keys[idx] = Auth.EVE;
        addresses[idx] = address(_contracts.token);
        idx++;
        keys[idx] = Auth.CONVERTER;
        addresses[idx] = address(_contracts.converter);
        idx++;
        keys[idx] = Auth.WHITELIST;
        addresses[idx] = address(_contracts.whitelist);

        vm.startPrank(_admin);
        _registry.registerContracts(keys, addresses);
        vm.stopPrank();
    }

    function _grantProtocolRoles(
        Registry _registry,
        ProtocolContracts memory _contracts,
        address _admin,
        address _keeper
    ) internal {
        // CONVERTER_CALLER_MANAGER_ROLE is granted to the Converter so that grantCallerRole /
        // revokeCallerRole (called by the registered StrategyManager contract) can
        // administer CONVERTER_CALLER_ROLE on the Registry on behalf of individual strategies.
        bytes32[] memory rolesBatch1 = new bytes32[](5);
        address[] memory accountsBatch1 = new address[](5);

        rolesBatch1[0] = Auth.ADMIN_ROLE;
        accountsBatch1[0] = _admin;
        rolesBatch1[1] = Auth.KEEPER_ROLE;
        accountsBatch1[1] = _keeper;
        rolesBatch1[2] = Auth.MINTER_ROLE;
        accountsBatch1[2] = address(_contracts.amm);
        rolesBatch1[3] = Auth.CONVERTER_CALLER_MANAGER_ROLE;
        accountsBatch1[3] = address(_contracts.converter);
        rolesBatch1[4] = Auth.MINTER_ROLE;
        accountsBatch1[4] = address(_contracts.strategyManager);

        vm.startPrank(_admin);
        _registry.grantRoles(rolesBatch1, accountsBatch1);
        vm.stopPrank();
    }

    function _registryHasRole(IRegistry _registry, bytes32 _role, address _account) internal view returns (bool) {
        return _registry.hasRole(_role, _account);
    }

    function _deployExitQueue(Registry _registry) internal returns (ExitQueue exitQueue) {
        ExitQueue exitQueueImpl = new ExitQueue();
        exitQueue = ExitQueue(
            address(
                new ERC1967Proxy(
                    address(exitQueueImpl), abi.encodeWithSelector(ExitQueue.initialize.selector, address(_registry))
                )
            )
        );
    }

    function _registerExitQueuePeers(Registry _registry, address _amm, address _controller, address _admin) internal {
        bytes32[] memory keys = new bytes32[](2);
        address[] memory addresses = new address[](2);
        keys[0] = Auth.AMM;
        addresses[0] = _amm;
        keys[1] = Auth.CONTROLLER;
        addresses[1] = _controller;

        vm.startPrank(_admin);
        _registry.registerContracts(keys, addresses);
        if (!_registry.hasRole(Auth.ADMIN_ROLE, _admin)) {
            _registry.grantRole(Auth.ADMIN_ROLE, _admin);
        }
        vm.stopPrank();
    }

    /**
     * @dev Mirrors ProtocolDeployBase._finalizeDeployerTieredAccess for script deployment tests:
     *      under PL-003 the deployer ALWAYS renounces its bootstrap Registry ADMIN_ROLE so the
     *      role ends held only by the admin TimelockController.
     */
    function _finalizeDeployerTieredAccess(Registry _registry, address _deployer) internal {
        if (_registry.hasRole(Auth.ADMIN_ROLE, _deployer)) {
            vm.prank(_deployer);
            _registry.renounceRole(Auth.ADMIN_ROLE, _deployer);
        }
    }

    function _deployRegistryAs(address _deployer, address _admin) internal returns (Registry registry) {
        vm.prank(_deployer);
        registry = new Registry(_admin);
    }
}
