// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {StrategyManager} from "contracts/StrategyManager.sol";
import {IStrategyManager} from "interfaces/IStrategyManager.sol";
import {IStrategy} from "interfaces/IStrategy.sol";
import {Oracle} from "contracts/Oracle.sol";
import {Controller} from "contracts/Controller.sol";
import {EVE} from "contracts/EVE.sol";
import {ExitQueue} from "contracts/ExitQueue.sol";
import {IExitQueue} from "interfaces/IExitQueue.sol";
import {MockStrategy} from "test/mocks/MockStrategy.sol";
import {MockFeeTakingStrategy} from "test/mocks/MockFeeTakingStrategy.sol";
import {MockPriceFeed} from "test/mocks/MockPriceFeed.sol";
import {MockAMMStub} from "test/mocks/MockAMMStub.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {ProtocolTestBase} from "test/helpers/ProtocolTestBase.sol";
import {Registry} from "registry/Registry.sol";
import {AMM} from "contracts/AMM.sol";
import {Auth} from "libraries/Auth.sol";
import {IRegistry} from "interfaces/IRegistry.sol";
import {IRegistryClient} from "interfaces/IRegistryClient.sol";

/**
 * @title StrategyManager Test
 * @notice Comprehensive test suite for StrategyManager contract
 */
contract StrategyManagerTest is ProtocolTestBase {
    StrategyManager public implementation;
    StrategyManager public strategyManager;
    ERC1967Proxy public proxy;
    Oracle public oracle;
    Controller public controllerContract;
    Registry public registry;
    AMM public amm;
    ExitQueue public exitQueue;
    EVE public token;
    MockStrategy public mockStrategy1;
    MockStrategy public mockStrategy2;
    MockStrategy public mockStrategy3;
    MockAMMStub public ammMock;

    // Supported-ERC-20 fixture (see _setUpSupportedERC20Fixture)
    MockERC20 public usdc;
    MockPriceFeed public ethPriceFeed;
    MockPriceFeed public usdcFeed;

    // CONVERTER_CALLER_ROLE = keccak256("CONVERTER_CALLER_ROLE")
    bytes32 public constant CONVERTER_CALLER_ROLE = keccak256("CONVERTER_CALLER_ROLE");

    address public admin;
    address public controller;
    address public user1;
    address public strategy1;
    address public strategy2;
    address public strategy3;

    // Strategy NAV is always reported in ETH; USD values below use ETH_PRICE via the Oracle.
    uint256 public constant INITIAL_NAV_1 = 25e18; // 25 ETH (~$100K at ETH_PRICE)
    uint256 public constant INITIAL_NAV_2 = 50e18; // 50 ETH (~$200K at ETH_PRICE)
    uint256 public constant INITIAL_NAV_3 = 12.5e18; // 12.5 ETH (~$50K at ETH_PRICE)
    uint256 public constant ETH_PRICE = 4000e8; // $4000 with 8 decimals
    uint256 public constant STALENESS_INTERVAL = 3600;
    uint256 public constant ALLOWED_NAV_RESIDUE = 10 wei;
    uint256 public constant EXCESS_NAV_RESIDUE = ALLOWED_NAV_RESIDUE + 1 wei;
    uint256 public constant WITHDRAWAL_FEE_BPS = 1000; // 10%
    uint256 public constant GROSS_WITHDRAW_AMOUNT = 5 ether;
    uint256 public constant PERFORMANCE_FEE_BPS = 2000; // 20%
    uint256 public constant STRATEGY_DEPOSIT_COOLDOWN = 1 hours;
    address public constant DAO_TREASURY = address(0xdead);
    uint256 public constant LP_FEE_BASE_1 = 12.5e18;
    uint256 public constant LP_FEE_BASE_2 = 25e18;
    uint256 public constant LP_FEE_BASE_3 = 6.25e18;
    uint256 public constant STRANDED_TOKEN_AMOUNT = 500e6; // $500 USDC stranded by emergencyExit()
    uint256 public constant USDC_PRICE = 1e8; // $1 with 8 decimals
    /// @dev ETH value of STRANDED_TOKEN_AMOUNT: $500 / $4000 per ETH = 0.125 ETH
    uint256 public constant STRANDED_TOKEN_VALUE_ETH = 0.125 ether;

    /// @dev `amm.enter` in setUp bootstraps the AMM and forwards this ETH to the Controller,
    ///      which `totalNAVInETH()` always counts as in-flight protocol NAV.
    uint256 internal constant BOOTSTRAP_CONTROLLER_ETH = 1 ether;
    uint256 internal constant PRICED_QUEUE_EXIT_ETH = 0.5 ether;
    uint256 internal constant UNPRICED_QUEUE_EXIT_ETH = 0.1 ether;
    uint256 internal constant SECOND_USER_DEPOSIT = 1 ether;
    uint256 internal constant LATE_ENTER_ETH = 0.1 ether;
    uint256 internal constant LEFTOVER_EXIT_ETH = 0.01 ether;

    event StrategyAdded(address indexed strategy);

    /// @dev Expected protocol NAV in ETH when only strategy NAVs contribute beyond the bootstrap deposit.
    function _expectedTotalNAVInETH(uint256 _strategyNavSum) internal pure returns (uint256) {
        return _strategyNavSum + BOOTSTRAP_CONTROLLER_ETH;
    }

    function _queueExitAs(address _user, uint256 _requestedETH) internal returns (uint256 batchId) {
        uint256 bal = token.balanceOf(_user);
        vm.startPrank(_user);
        token.approve(address(amm), bal);
        batchId = amm.exit(_requestedETH, bal, 0);
        vm.stopPrank();
        assertGt(batchId, 0);
    }

    /// @dev Converts an ETH-denominated strategy NAV to normalized USD (18 decimals).
    function _ethNavToUsd(uint256 _navInETH) internal view returns (uint256) {
        return oracle.convertTokenToUSD(address(0), _navInETH, 18);
    }

    /// @dev Pending performance fee in ETH for an uncharged LP-fee base.
    function _expectedPendingFeeEth(uint256 _unchargedLpFeesInETH, uint256 _feeBps) internal pure returns (uint256) {
        return _unchargedLpFeesInETH * _feeBps / 10_000;
    }

    /// @dev Enables performance fee rate; treasury is set at deploy. Grants StrategyManager MINTER_ROLE.
    function _configurePerformanceFees() internal {
        vm.prank(admin);
        strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);
        registry.grantRole(Auth.MINTER_ROLE, address(strategyManager));
    }

    function _harvestFeeFromStrategy(address _strategy) internal {
        vm.prank(controller);
        strategyManager.harvestPerformanceFeeFromStrategy(_strategy);
    }

    function _harvestAllFeesFromStrategies() internal {
        vm.prank(controller);
        strategyManager.harvestPerformanceFeeFromStrategies();
    }

    function _harvestFeesFromStrategies(uint256 _startIndex, uint256 _endIndex) internal {
        vm.prank(controller);
        strategyManager.harvestPerformanceFeeFromStrategies(_startIndex, _endIndex);
    }

    /// @dev EVE minted for a performance fee of `_feeETH` at the current protocol NAV and supply.
    function _expectedEvesToMint(uint256 _feeETH) internal view returns (uint256) {
        uint256 supply = token.totalSupply();
        uint256 totalNAV = strategyManager.totalNAVInETH();
        return (_feeETH * supply) / (totalNAV - _feeETH);
    }

    /// @dev Converts a pending USD fee to its ETH equivalent via the live Oracle feed.
    function _feeUsdToEth(uint256 _feeUsd) internal view returns (uint256) {
        return oracle.convertUsdToToken(address(0), _feeUsd, 18);
    }

    /// @dev Seeds mock strategy LP-fee base for performance-fee tests.
    function _accrueMockLpFees(MockStrategy _strategy, uint256 _unchargedBase) internal {
        _strategy.setUnchargedLpFeeBaseInETH(_unchargedBase);
    }

    /// @dev Deploys a USDC-like paired token with a $1 feed for supported-ERC-20 NAV tests.
    function _setUpSupportedERC20Fixture() internal {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdcFeed = new MockPriceFeed(8, int256(USDC_PRICE));
        oracle.updateUsdFeedInfo(address(usdc), address(usdcFeed), STALENESS_INTERVAL);
    }

    /// @dev Strands STRANDED_TOKEN_AMOUNT of USDC on the StrategyManager (as UniCLStrat's
    ///      emergencyExit() would) on top of the supported-ERC-20 fixture.
    function _strandTokensOnStrategyManager() internal {
        _setUpSupportedERC20Fixture();
        usdc.mint(address(strategyManager), STRANDED_TOKEN_AMOUNT);
    }

    function setUp() public {
        admin = address(this);
        user1 = makeAddr("user1");

        ProtocolContracts memory contracts = _deployProtocol(admin, 5e17);
        registry = contracts.registry;
        token = contracts.token;
        controllerContract = contracts.controller;
        controller = address(controllerContract);
        strategyManager = contracts.strategyManager;
        oracle = contracts.oracle;
        amm = contracts.amm;
        exitQueue = contracts.exitQueue;
        implementation = new StrategyManager();

        ethPriceFeed = new MockPriceFeed(8, int256(ETH_PRICE));
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);

        // Bootstrap AMM to establish non-zero EVE total supply (dead supply = 1e18).
        // Required for performance-fee harvesting: evesToMint = feeETH * supply / (totalNAV - feeETH).
        // Also forwards BOOTSTRAP_CONTROLLER_ETH to the Controller, counted in totalNAVInETH().
        amm.enter{value: 1 ether}(1);

        ammMock = new MockAMMStub();

        // Deploy mock strategies
        mockStrategy1 = new MockStrategy("Strategy 1", controller, address(strategyManager));
        mockStrategy2 = new MockStrategy("Strategy 2", controller, address(strategyManager));
        mockStrategy3 = new MockStrategy("Strategy 3", controller, address(strategyManager));

        strategy1 = address(mockStrategy1);
        strategy2 = address(mockStrategy2);
        strategy3 = address(mockStrategy3);

        // Set initial NAVs on mock strategies
        mockStrategy1.setNavInETH(INITIAL_NAV_1);
        mockStrategy2.setNavInETH(INITIAL_NAV_2);
        mockStrategy3.setNavInETH(INITIAL_NAV_3);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialize() public view {
        assertEq(address(strategyManager.registry()), address(registry));
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, admin));
        assertEq(registry.getContractByKey(Auth.CONTROLLER), controller);
        assertEq(registry.getContractByKey(Auth.AMM), address(amm));
        assertEq(registry.getContractByKey(Auth.ORACLE), address(oracle));
        assertEq(strategyManager.totalNAVInETH(), BOOTSTRAP_CONTROLLER_ETH);
        assertEq(strategyManager.strategyCount(), 0);
        assertEq(strategyManager.daoTreasury(), TEST_DAO_TREASURY);
        assertEq(strategyManager.performanceFeeBps(), 0);
    }

    function test_InitializeCannotBeCalledTwice() public {
        IStrategyManager.FeeConfig memory feeConfig =
            IStrategyManager.FeeConfig({daoTreasury: DAO_TREASURY, performanceFeeBps: PERFORMANCE_FEE_BPS});
        vm.expectRevert();
        strategyManager.initialize(address(registry), feeConfig);
    }

    function test_InitializeWithZeroRegistry() public {
        StrategyManager newImpl = new StrategyManager();
        IStrategyManager.FeeConfig memory feeConfig =
            IStrategyManager.FeeConfig({daoTreasury: TEST_DAO_TREASURY, performanceFeeBps: 0});
        bytes memory initData = abi.encodeWithSelector(StrategyManager.initialize.selector, address(0), feeConfig);
        vm.expectRevert(IRegistryClient.RegistryClientZeroRegistry.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialize_RevertsWhenDaoTreasuryZero() public {
        StrategyManager newImpl = new StrategyManager();
        IStrategyManager.FeeConfig memory feeConfig =
            IStrategyManager.FeeConfig({daoTreasury: address(0), performanceFeeBps: 0});
        bytes memory initData =
            abi.encodeWithSelector(StrategyManager.initialize.selector, address(registry), feeConfig);
        vm.expectRevert(IStrategyManager.StrategyManagerZeroDaoTreasury.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialize_StoresFeeConfig() public {
        StrategyManager newImpl = new StrategyManager();
        IStrategyManager.FeeConfig memory feeConfig =
            IStrategyManager.FeeConfig({daoTreasury: DAO_TREASURY, performanceFeeBps: PERFORMANCE_FEE_BPS});
        bytes memory initData =
            abi.encodeWithSelector(StrategyManager.initialize.selector, address(registry), feeConfig);
        StrategyManager freshManager = StrategyManager(payable(new ERC1967Proxy(address(newImpl), initData)));

        assertEq(freshManager.daoTreasury(), DAO_TREASURY);
        assertEq(freshManager.performanceFeeBps(), PERFORMANCE_FEE_BPS);
    }

    function test_Initialize_RevertsWhenPerformanceFeeBpsTooHigh() public {
        StrategyManager newImpl = new StrategyManager();
        IStrategyManager.FeeConfig memory feeConfig = IStrategyManager.FeeConfig({
            daoTreasury: DAO_TREASURY,
            performanceFeeBps: strategyManager.MAX_PERFORMANCE_FEE_BPS() + 1
        });
        bytes memory initData =
            abi.encodeWithSelector(StrategyManager.initialize.selector, address(registry), feeConfig);
        vm.expectRevert(IStrategyManager.StrategyManagerInvalidPerformanceFeeBps.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialize_EmitsFeeConfigEvents() public {
        StrategyManager newImpl = new StrategyManager();
        IStrategyManager.FeeConfig memory feeConfig =
            IStrategyManager.FeeConfig({daoTreasury: DAO_TREASURY, performanceFeeBps: PERFORMANCE_FEE_BPS});
        bytes memory initData =
            abi.encodeWithSelector(StrategyManager.initialize.selector, address(registry), feeConfig);

        vm.expectEmit(false, false, false, true);
        emit IStrategyManager.DaoTreasuryChanged(address(0), DAO_TREASURY);
        vm.expectEmit(false, false, false, true);
        emit IStrategyManager.PerformanceFeeBpsChanged(0, PERFORMANCE_FEE_BPS);

        new ERC1967Proxy(address(newImpl), initData);
    }

    /*//////////////////////////////////////////////////////////////
                        FEE CONFIG SETTER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetPerformanceFeeBps_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit IStrategyManager.PerformanceFeeBpsChanged(0, PERFORMANCE_FEE_BPS);

        vm.prank(admin);
        strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);
        assertEq(strategyManager.performanceFeeBps(), PERFORMANCE_FEE_BPS);
    }

    function test_SetDaoTreasury_EmitsEvent() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(false, false, false, true);
        emit IStrategyManager.DaoTreasuryChanged(TEST_DAO_TREASURY, newTreasury);

        vm.prank(admin);
        strategyManager.setDaoTreasury(newTreasury);
        assertEq(strategyManager.daoTreasury(), newTreasury);
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function testStrategy() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.DepositWeightUpdated(strategy1, 0, 80);
        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.WithdrawalWeightUpdated(strategy1, 0, 70);
        vm.expectEmit(true, false, false, false);
        emit IStrategyManager.StrategyAdded(strategy1);
        strategyManager.addStrategy(strategy1, 80, 70);

        assertTrue(strategyManager.isStrategyRegistered(strategy1));
        assertEq(strategyManager.depositWeight(strategy1), 80);
        assertEq(strategyManager.withdrawalWeight(strategy1), 70);
        assertEq(strategyManager.strategyNAVInETH(strategy1), INITIAL_NAV_1);
        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(INITIAL_NAV_1));
        assertEq(strategyManager.strategyCount(), 1);
        // Verify CONVERTER_CALLER_ROLE was granted on the Registry by the Converter
        assertTrue(registry.hasRole(CONVERTER_CALLER_ROLE, strategy1));

        address[] memory strategies = strategyManager.strategies();
        assertEq(strategies.length, 1);
        assertEq(strategies[0], strategy1);
    }

    function test_AddMultipleStrategies() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        strategyManager.addStrategy(strategy3, 40, 30);
        vm.stopPrank();

        assertEq(strategyManager.strategyCount(), 3);
        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(INITIAL_NAV_1 + INITIAL_NAV_2 + INITIAL_NAV_3));

        address[] memory strategies = strategyManager.strategies();
        assertEq(strategies.length, 3);
        assertTrue(strategyManager.isStrategyRegistered(strategy1));
        assertTrue(strategyManager.isStrategyRegistered(strategy2));
        assertTrue(strategyManager.isStrategyRegistered(strategy3));
    }

    function test_AddStrategyOnlyAdmin() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        strategyManager.addStrategy(strategy1, 80, 70);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        strategyManager.addStrategy(strategy1, 80, 70);
    }

    function test_AddStrategyZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IStrategyManager.StrategyManagerZeroAddress.selector);
        strategyManager.addStrategy(address(0), 80, 70);
    }

    function test_AddStrategyNoCode() public {
        vm.prank(admin);
        vm.expectRevert(IStrategyManager.StrategyManagerNoCode.selector);
        strategyManager.addStrategy(makeAddr("eoa"), 80, 70);
    }

    function test_AddStrategyAlreadyRegistered() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.expectRevert(IStrategyManager.StrategyManagerStrategyAlreadyRegistered.selector);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();
    }

    function test_AddStrategyWhenPaused() public {
        vm.startPrank(admin);
        strategyManager.pause();
        vm.expectRevert();
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();
    }

    function test_RemoveStrategy() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);

        // CONVERTER_CALLER_ROLE should be granted after addStrategy
        assertTrue(registry.hasRole(CONVERTER_CALLER_ROLE, strategy1));

        mockStrategy1.setNavInETH(0);

        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.StrategyRemoved(strategy1);
        strategyManager.removeStrategy(strategy1);
        vm.stopPrank();

        assertFalse(strategyManager.isStrategyRegistered(strategy1));
        assertTrue(strategyManager.isStrategyRegistered(strategy2));
        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(INITIAL_NAV_2));
        assertEq(strategyManager.strategyCount(), 1);

        // CONVERTER_CALLER_ROLE should be revoked after removeStrategy
        assertFalse(registry.hasRole(CONVERTER_CALLER_ROLE, strategy1));
    }

    function test_RemoveStrategyOnlyAdmin() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        vm.prank(user1);
        vm.expectRevert();
        strategyManager.removeStrategy(strategy1);

        vm.prank(controller);
        vm.expectRevert();
        strategyManager.removeStrategy(strategy1);
    }

    function test_RemoveStrategyNotRegistered() public {
        vm.prank(admin);
        vm.expectRevert(IStrategyManager.StrategyManagerStrategyNotRegistered.selector);
        strategyManager.removeStrategy(strategy1);
    }

    function test_RemoveStrategy_AllowsNAVResidue() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setNavInETH(ALLOWED_NAV_RESIDUE);

        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.StrategyRemoved(strategy1);
        strategyManager.removeStrategy(strategy1);
        vm.stopPrank();

        assertFalse(strategyManager.isStrategyRegistered(strategy1));
        assertEq(strategyManager.strategyCount(), 0);
    }

    function test_RemoveStrategy_RevertsWhenStrategyNAVResidueTooHigh() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setNavInETH(EXCESS_NAV_RESIDUE);

        vm.expectRevert(
            abi.encodeWithSelector(IStrategyManager.StrategyManagerStrategyNAVResidueTooHigh.selector, strategy1)
        );
        strategyManager.removeStrategy(strategy1);
        vm.stopPrank();
    }

    function test_RemoveStrategyWhenPaused() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setNavInETH(0);
        strategyManager.pause();

        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.StrategyRemoved(strategy1);
        strategyManager.removeStrategy(strategy1);
        vm.stopPrank();

        assertFalse(strategyManager.isStrategyRegistered(strategy1));
        assertTrue(strategyManager.paused());
    }

    function test_RemoveStrategy_RevertsWhenNavReverts() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setRevertNavInETH(true);

        vm.expectRevert(MockStrategy.MockStrategyNavReverted.selector);
        strategyManager.removeStrategy(strategy1);
        vm.stopPrank();

        assertTrue(strategyManager.isStrategyRegistered(strategy1));
    }

    /*//////////////////////////////////////////////////////////////
                    FORCE REMOVE STRATEGY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ForceRemoveStrategy_RemovesOverReportingStrategy() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);

        assertTrue(registry.hasRole(CONVERTER_CALLER_ROLE, strategy1));

        // Over-reporting strategy: NAV far above MAX_NAV_RESIDUE can never pass removeStrategy
        assertGt(mockStrategy1.navInETH(), ALLOWED_NAV_RESIDUE);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyManager.StrategyManagerStrategyNAVResidueTooHigh.selector, strategy1)
        );
        strategyManager.removeStrategy(strategy1);

        // forceRemoveStrategy is the escape hatch: skips the residue check, reports the NAV dropped
        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.StrategyForceRemoved(strategy1, INITIAL_NAV_1, false);
        strategyManager.forceRemoveStrategy(strategy1);
        vm.stopPrank();

        assertFalse(strategyManager.isStrategyRegistered(strategy1));
        assertTrue(strategyManager.isStrategyRegistered(strategy2));
        assertEq(strategyManager.strategyCount(), 1);

        // Over-reported NAV no longer summed into protocol NAV
        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(INITIAL_NAV_2));

        // CONVERTER_CALLER_ROLE revoked, same as removeStrategy
        assertFalse(registry.hasRole(CONVERTER_CALLER_ROLE, strategy1));
    }

    function test_ForceRemoveStrategy_AccessControl() public {
        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        vm.prank(user1);
        vm.expectRevert();
        strategyManager.forceRemoveStrategy(strategy1);

        vm.prank(controller);
        vm.expectRevert();
        strategyManager.forceRemoveStrategy(strategy1);

        assertTrue(strategyManager.isStrategyRegistered(strategy1));
    }

    function test_ForceRemoveStrategy_NotRegistered() public {
        vm.prank(admin);
        vm.expectRevert(IStrategyManager.StrategyManagerStrategyNotRegistered.selector);
        strategyManager.forceRemoveStrategy(strategy1);
    }

    function test_ForceRemoveStrategy_SucceedsWhenNavReverts() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setRevertNavInETH(true);

        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.StrategyForceRemoved(strategy1, 0, true);
        strategyManager.forceRemoveStrategy(strategy1);
        vm.stopPrank();

        assertFalse(strategyManager.isStrategyRegistered(strategy1));
        assertEq(strategyManager.strategyCount(), 0);
    }

    function test_ForceRemoveStrategy_WhenPaused() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.pause();

        // Escape hatch works while the StrategyManager is paused, even for an over-reporting
        // strategy that is itself not paused.
        assertFalse(mockStrategy1.paused());
        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.StrategyForceRemoved(strategy1, INITIAL_NAV_1, false);
        strategyManager.forceRemoveStrategy(strategy1);
        vm.stopPrank();

        assertFalse(strategyManager.isStrategyRegistered(strategy1));
        assertTrue(strategyManager.paused());
    }

    function test_ForceRemoveStrategy_NoPhantomFeeOnReAdd() public {
        _configurePerformanceFees();

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        // Force-remove with full NAV still reported, then re-add. In the strategy-local LP-fee
        // model there is no SM-side HWM to clear: fee accounting lives on the strategy, so a
        // strategy that never accrued LP fees reports zero pending fees after re-registration
        // and harvesting mints nothing.
        vm.prank(admin);
        strategyManager.forceRemoveStrategy(strategy1);

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        uint256 treasuryBefore = token.balanceOf(DAO_TREASURY);
        _harvestFeeFromStrategy(strategy1);
        assertEq(token.balanceOf(DAO_TREASURY), treasuryBefore);
    }

    /*//////////////////////////////////////////////////////////////
                        NAV FAIL-CLOSED TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TotalNAVInETH_RevertsWhenStrategyNavReverts() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        mockStrategy2.setRevertNavInETH(true);

        vm.expectRevert(MockStrategy.MockStrategyNavReverted.selector);
        strategyManager.totalNAVInETH();
    }

    function test_TotalNAVInETH_RevertsWhenOneOfMultipleStrategiesNavReverts() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        strategyManager.addStrategy(strategy3, 40, 30);
        vm.stopPrank();

        mockStrategy2.setRevertNavInETH(true);

        vm.expectRevert(MockStrategy.MockStrategyNavReverted.selector);
        strategyManager.totalNAVInETH();
    }

    function test_TotalNAVInUSD_RevertsWhenStrategyNavReverts() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        mockStrategy2.setRevertNavInETH(true);

        vm.expectRevert(MockStrategy.MockStrategyNavReverted.selector);
        strategyManager.totalNAVInUSD();
    }

    function test_TotalNAVInETH_RecoversWhenForceRemovingStrategyWhileNavStillReverts() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        mockStrategy2.setRevertNavInETH(true);

        vm.expectRevert(MockStrategy.MockStrategyNavReverted.selector);
        strategyManager.totalNAVInETH();

        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.StrategyForceRemoved(strategy2, 0, true);
        strategyManager.forceRemoveStrategy(strategy2);
        vm.stopPrank();

        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(INITIAL_NAV_1));
        assertEq(strategyManager.strategyCount(), 1);
        assertFalse(strategyManager.isStrategyRegistered(strategy2));
    }

    /*//////////////////////////////////////////////////////////////
                    ORPHANED STRATEGY RECOVERY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ForceRemoveStrategy_OrphanedFundsRecoveredViaEmergencyExit() public {
        uint256 orphanedEth = 10 ether;

        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        vm.deal(strategy1, orphanedEth);
        mockStrategy1.setRevertNavInETH(true);

        vm.expectRevert(MockStrategy.MockStrategyNavReverted.selector);
        strategyManager.totalNAVInETH();

        vm.prank(admin);
        strategyManager.forceRemoveStrategy(strategy1);

        uint256 navBeforeRecovery = strategyManager.totalNAVInETH();
        assertEq(navBeforeRecovery, _expectedTotalNAVInETH(INITIAL_NAV_2));
        assertEq(address(strategy1).balance, orphanedEth);

        mockStrategy1.setPaused(true);
        vm.expectEmit(false, false, false, true, strategy1);
        emit IStrategy.EmergencyExited(orphanedEth);
        mockStrategy1.emergencyExit();

        assertEq(address(strategy1).balance, 0);
        assertEq(address(strategyManager).balance, orphanedEth);
        assertEq(strategyManager.totalNAVInETH(), navBeforeRecovery + orphanedEth);
    }

    /*//////////////////////////////////////////////////////////////
                        NAV MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_StrategyNAVInETH_ReadsFromStrategy() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        // NAV is read directly from strategy (ETH denomination); USD view uses Oracle.
        uint256 nav = strategyManager.strategyNAVInETH(strategy1);
        assertEq(nav, INITIAL_NAV_1);
        assertEq(strategyManager.strategyNAVInUSD(strategy1), _ethNavToUsd(INITIAL_NAV_1));
    }

    function test_StrategyNAVInETH_NotRegistered() public {
        vm.expectRevert(IStrategyManager.StrategyManagerStrategyNotRegistered.selector);
        strategyManager.strategyNAVInETH(strategy1);
    }

    function test_StrategyNAVInETH_UpdatesWhenStrategyUpdates() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        // Update strategy NAV directly
        uint256 newNAV = 150000e18;
        mockStrategy1.setNavInETH(newNAV);

        // StrategyManager should read updated NAV
        assertEq(strategyManager.strategyNAVInETH(strategy1), newNAV);
    }

    function test_TotalNAVInETH_IncludesAllStrategies() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        strategyManager.addStrategy(strategy3, 40, 30);
        vm.stopPrank();

        uint256 totalNAV = strategyManager.totalNAVInETH();
        assertEq(totalNAV, _expectedTotalNAVInETH(INITIAL_NAV_1 + INITIAL_NAV_2 + INITIAL_NAV_3));
    }

    function test_TotalNAVInETH_IncludesControllerBalance() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        vm.deal(controller, 1 ether);

        uint256 totalNAV = strategyManager.totalNAVInETH();
        assertEq(totalNAV, INITIAL_NAV_1 + 1 ether);
    }

    function test_TotalNAVInETH_IncludesStrategyManagerBalance() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        // Isolate the StrategyManager's own balance contribution
        vm.deal(controller, 0);
        vm.deal(address(strategyManager), 3 ether);

        uint256 totalNAV = strategyManager.totalNAVInETH();
        assertEq(totalNAV, INITIAL_NAV_1 + 3 ether);
    }

    function test_TotalNAVInETH_IncludesAllInFlightBalances() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        // ETH simultaneously sitting on Controller and StrategyManager simulates
        // a mid-distribution snapshot of the system.
        vm.deal(controller, 1 ether);
        vm.deal(address(strategyManager), 4 ether);

        uint256 totalNAV = strategyManager.totalNAVInETH();
        assertEq(totalNAV, INITIAL_NAV_1 + INITIAL_NAV_2 + 1 ether + 4 ether);
    }

    function test_TotalNAVInETH_IncludesAMMFreeBalance() public {
        vm.deal(address(amm), 5 ether);

        assertEq(strategyManager.totalNAVInETH(), 5 ether + BOOTSTRAP_CONTROLLER_ETH);
        assertEq(amm.freeBalance(), 5 ether);
    }

    function test_TotalNAVInETH_ExcludesLockedClaims() public {
        MockAMMStub stub = new MockAMMStub();
        vm.deal(address(stub), 5 ether);
        stub.setLockedForClaims(3 ether);

        vm.prank(admin);
        registry.registerContract(Auth.AMM, address(stub));

        assertEq(stub.freeBalance(), 2 ether);
        assertEq(strategyManager.totalNAVInETH(), 2 ether + BOOTSTRAP_CONTROLLER_ETH);
    }

    function test_TotalNAVInETH_IsConservedAcrossDistributeCycle() public {
        // NAV must be equal before and after a distribution — ETH simply moves
        // from Controller → StrategyManager → Strategy, all of which are counted.
        // We start with navInETH = 0 on the strategy so ETH movements are tracked
        // cleanly, then simulate a real strategy by updating navInETH after deposit.
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        mockStrategy1.setNavInETH(0);
        mockStrategy1.setMaxDeposit(10 ether);
        mockStrategy1.setIsHealthy(true);

        vm.deal(controller, 10 ether);

        uint256 navBefore = strategyManager.totalNAVInETH(); // 0 + 10 ETH = 10 ETH

        controllerContract.depositToStrategies(10 ether);

        // Real strategy implementations must update navInETH() inside deposit();
        // mock requires manual update here.
        mockStrategy1.setNavInETH(10 ether);

        uint256 navAfter = strategyManager.totalNAVInETH(); // 10 ETH + 0 + 0 = 10 ETH
        assertEq(navAfter, navBefore);
        assertEq(address(strategyManager).balance, 0);
    }

    function test_TotalNAVInETH_IsConservedWhenRemainderReturnedToController() public {
        // When maxDeposit caps the distribution, the remainder returns to Controller.
        // NAV must still be conserved: strategy got some, Controller got the rest.
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        mockStrategy1.setNavInETH(0);
        mockStrategy1.setMaxDeposit(3 ether);
        mockStrategy1.setIsHealthy(true);

        vm.deal(controller, 10 ether);

        uint256 navBefore = strategyManager.totalNAVInETH(); // 0 + 10 ETH = 10 ETH

        controllerContract.depositToStrategies(10 ether);

        // Strategy received 3 ETH; Controller got the 7 ETH remainder back.
        // Real strategy implementations must update navInETH() inside deposit();
        // mock requires manual update here.
        mockStrategy1.setNavInETH(3 ether);

        uint256 navAfter = strategyManager.totalNAVInETH(); // 3 + 7 (controller) + 0 = 10 ETH
        assertEq(navAfter, navBefore);
        assertEq(address(mockStrategy1).balance, 3 ether);
        assertEq(address(controllerContract).balance, 7 ether);
        assertEq(address(strategyManager).balance, 0);
    }

    function test_TotalNAVInETH_PreExistingSMBalanceAbsorbedByDistribute() public {
        // If the StrategyManager holds ETH before a distribute call (e.g. from
        // a selfdestruct force-send), _validateDeposit checks only the deficit
        // (distributeAmount - SM.balance), and _fundStrategyManagerIfNeeded sends
        // only that deficit.  SM ends up with exactly _amount, deploys it all to
        // strategies, and returns to zero — the pre-existing ETH is not stuck.
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        mockStrategy1.setNavInETH(0);
        uint256 preExisting = 2 ether;
        uint256 distributeAmount = 10 ether;
        uint256 deficit = distributeAmount - preExisting;

        mockStrategy1.setMaxDeposit(distributeAmount);
        mockStrategy1.setIsHealthy(true);

        // SM has pre-existing ETH; Controller only needs the deficit.
        vm.deal(address(strategyManager), preExisting);
        vm.deal(controller, deficit);

        // NAV before = 0 (strategy) + deficit (controller) + preExisting (SM) = 10 ETH
        uint256 navBefore = strategyManager.totalNAVInETH();

        controllerContract.depositToStrategies(distributeAmount);

        // Strategy got all 10 ETH; Controller and SM are empty.
        // Real strategy implementations must update navInETH() inside deposit();
        // mock requires manual update here.
        mockStrategy1.setNavInETH(distributeAmount);

        uint256 navAfter = strategyManager.totalNAVInETH();

        assertEq(navAfter, navBefore);
        assertEq(address(strategyManager).balance, 0);
        assertEq(address(mockStrategy1).balance, distributeAmount);
        assertEq(address(controllerContract).balance, 0);
    }

    function test_TotalNAVInETH_ExcessSMBalanceStaysUntilNextDistribute() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        mockStrategy1.setNavInETH(0);
        mockStrategy1.setMaxDeposit(10 ether);
        mockStrategy1.setIsHealthy(true);

        vm.deal(address(strategyManager), 15 ether);
        vm.deal(controller, 0);

        uint256 navBefore = strategyManager.totalNAVInETH();

        controllerContract.depositToStrategies(10 ether);
        // Real strategy implementations must update navInETH() inside deposit();
        // mock requires manual update here.
        mockStrategy1.setNavInETH(10 ether);

        assertEq(strategyManager.totalNAVInETH(), navBefore);
        assertEq(address(strategyManager).balance, 5 ether);
        assertEq(address(mockStrategy1).balance, 10 ether);
        assertEq(address(controllerContract).balance, 0);

        mockStrategy1.setMaxDeposit(5 ether);
        controllerContract.depositToStrategies(5 ether);
        // Real strategy implementations must update navInETH() inside deposit();
        // mock requires manual update here.
        mockStrategy1.setNavInETH(15 ether);

        assertEq(strategyManager.totalNAVInETH(), navBefore);
        assertEq(address(strategyManager).balance, 0);
        assertEq(address(mockStrategy1).balance, 15 ether);
        assertEq(address(controllerContract).balance, 0);
    }

    function test_TotalNAVInETH_SMBalanceZeroAfterSuccessfulDistribute() public {
        // Steady-state invariant: after a full successful distribute,
        // StrategyManager holds no ETH.
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        mockStrategy1.setMaxDeposit(10 ether);
        mockStrategy2.setMaxDeposit(10 ether);
        mockStrategy1.setIsHealthy(true);
        mockStrategy2.setIsHealthy(true);

        vm.deal(controller, 14 ether);
        controllerContract.depositToStrategies(14 ether);

        assertEq(address(strategyManager).balance, 0);
    }

    function test_TotalNAVInETH_WhenAMMNotSet_Reverts() public {
        ProtocolContracts memory contracts = _deployProtocolWithoutAmm(admin, 5e17);

        vm.expectRevert(abi.encodeWithSelector(IRegistry.RegistryContractNotRegistered.selector, Auth.AMM));
        contracts.strategyManager.totalNAVInETH();
    }

    function test_TotalNAVInETH_IncludesAMMBalance() public {
        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        vm.deal(address(amm), 2 ether);

        uint256 totalNAV = strategyManager.totalNAVInETH();
        assertEq(totalNAV, INITIAL_NAV_1 + 2 ether + BOOTSTRAP_CONTROLLER_ETH);
    }

    function test_TotalNAVInETH_DoesNotDeductUnpricedQueue() public {
        uint256 navBefore = strategyManager.totalNAVInETH();
        _queueExitAs(address(this), PRICED_QUEUE_EXIT_ETH);

        (uint256 liability, uint256 escrowed) = exitQueue.liveRedemptionOffsets();
        assertEq(liability, 0);
        assertEq(escrowed, 0);
        assertEq(strategyManager.totalNAVInETH(), navBefore);
    }

    function test_TotalNAVInETH_DeductsPricedQueueLiability() public {
        uint256 navBefore = strategyManager.totalNAVInETH();
        _queueExitAs(address(this), PRICED_QUEUE_EXIT_ETH);
        controllerContract.priceBatch();

        (uint256 liability, uint256 escrowed) = exitQueue.liveRedemptionOffsets();
        assertGt(liability, 0);
        assertGt(escrowed, 0);
        assertEq(strategyManager.totalNAVInETH(), navBefore - liability);
    }

    function test_TotalNAVInETH_PricedQueueLiabilityLapsesAfterExpiry() public {
        uint256 navBefore = strategyManager.totalNAVInETH();
        _queueExitAs(address(this), PRICED_QUEUE_EXIT_ETH);
        controllerContract.priceBatch();

        (uint256 liability,) = exitQueue.liveRedemptionOffsets();
        assertEq(strategyManager.totalNAVInETH(), navBefore - liability);

        vm.warp(block.timestamp + exitQueue.MAX_BATCH_PROCESSING_TIME() + 1);

        (uint256 liabilityAfter, uint256 escrowedAfter) = exitQueue.liveRedemptionOffsets();
        assertEq(liabilityAfter, 0);
        assertEq(escrowedAfter, 0);
        assertEq(strategyManager.totalNAVInETH(), navBefore);
    }

    function test_TotalNAVInETH_RevertsWhenQueuedLiabilityExceedsNAV() public {
        uint256 grossNav = strategyManager.totalNAVInETH();
        vm.mockCall(
            address(exitQueue),
            abi.encodeWithSelector(IExitQueue.liveRedemptionOffsets.selector),
            abi.encode(grossNav + 1, uint256(0))
        );

        vm.expectRevert(IStrategyManager.StrategyManagerQueuedLiabilityExceedsNAV.selector);
        strategyManager.totalNAVInETH();
    }

    function test_TotalNAVInETH_QueuedLiabilityFreeze_BlastRadiusAndEscapeHatch() public {
        vm.deal(user1, SECOND_USER_DEPOSIT);
        vm.prank(user1);
        amm.enter{value: SECOND_USER_DEPOSIT}(1);

        uint256 pricedBatchId = _queueExitAs(address(this), PRICED_QUEUE_EXIT_ETH);
        controllerContract.priceBatch();
        uint256 unpricedBatchId = _queueExitAs(user1, UNPRICED_QUEUE_EXIT_ETH);
        assertGt(unpricedBatchId, pricedBatchId);

        // Simulate a post-price NAV drop (IL / market move): wipe in-flight ETH so
        // gross NAV < locked-in liability. Documented freeze — FREEZE_RUNBOOK scenario 10.
        vm.deal(controller, 0);
        vm.deal(address(strategyManager), 0);
        vm.deal(address(amm), 0);

        vm.expectRevert(IStrategyManager.StrategyManagerQueuedLiabilityExceedsNAV.selector);
        strategyManager.totalNAVInETH();
        vm.expectRevert(IStrategyManager.StrategyManagerQueuedLiabilityExceedsNAV.selector);
        strategyManager.totalNAVInUSD();
        vm.expectRevert(IStrategyManager.StrategyManagerQueuedLiabilityExceedsNAV.selector);
        amm.eveBasePriceInETH();
        vm.expectRevert(IStrategyManager.StrategyManagerQueuedLiabilityExceedsNAV.selector);
        amm.evePremiumPriceInETH();
        vm.expectRevert(IStrategyManager.StrategyManagerQueuedLiabilityExceedsNAV.selector);
        amm.eveBasePriceInUSD();
        vm.expectRevert(IStrategyManager.StrategyManagerQueuedLiabilityExceedsNAV.selector);
        amm.evePremiumPriceInUSD();

        address lateEntrant = makeAddr("lateEntrant");
        vm.deal(lateEntrant, LATE_ENTER_ETH);
        vm.prank(lateEntrant);
        vm.expectRevert(IStrategyManager.StrategyManagerQueuedLiabilityExceedsNAV.selector);
        amm.enter{value: LATE_ENTER_ETH}(1);

        uint256 leftover = token.balanceOf(address(this));
        token.approve(address(amm), leftover);
        vm.expectRevert(IStrategyManager.StrategyManagerQueuedLiabilityExceedsNAV.selector);
        amm.exit(LEFTOVER_EXIT_ETH, leftover, 0);

        vm.expectRevert(IStrategyManager.StrategyManagerQueuedLiabilityExceedsNAV.selector);
        controllerContract.priceBatch();

        // Unpriced requests do not read NAV — cancel still works during the freeze.
        vm.prank(user1);
        amm.cancelRedemption(unpricedBatchId);
        assertGt(token.balanceOf(user1), 0);

        // Priced in-window requests cannot close; users wait out the 3-day window.
        vm.expectRevert(IExitQueue.ExitQueueRequestCannotBeClosed.selector);
        amm.cancelRedemption(pricedBatchId);

        vm.warp(block.timestamp + exitQueue.MAX_BATCH_PROCESSING_TIME() + 1);
        (uint256 liability, uint256 escrowed) = exitQueue.liveRedemptionOffsets();
        assertEq(liability, 0);
        assertEq(escrowed, 0);
        strategyManager.totalNAVInETH();

        amm.cancelRedemption(pricedBatchId);
    }

    function test_Harvest_RevertsWhenQueuedLiabilityExceedsNAV() public {
        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        _configurePerformanceFees();
        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);

        uint256 grossNav = strategyManager.totalNAVInETH();
        vm.mockCall(
            address(exitQueue),
            abi.encodeWithSelector(IExitQueue.liveRedemptionOffsets.selector),
            abi.encode(grossNav + 1, uint256(0))
        );

        vm.prank(controller);
        vm.expectRevert(IStrategyManager.StrategyManagerQueuedLiabilityExceedsNAV.selector);
        strategyManager.harvestPerformanceFeeFromStrategy(strategy1);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetStrategiesEmpty() public view {
        address[] memory strategies = strategyManager.strategies();
        assertEq(strategies.length, 0);
    }

    function test_GetStrategiesMultiple() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        strategyManager.addStrategy(strategy3, 40, 30);
        vm.stopPrank();

        address[] memory strategies = strategyManager.strategies();
        assertEq(strategies.length, 3);

        // Check that all strategies are present
        bool found1 = false;
        bool found2 = false;
        bool found3 = false;

        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i] == strategy1) found1 = true;
            if (strategies[i] == strategy2) found2 = true;
            if (strategies[i] == strategy3) found3 = true;
        }

        assertTrue(found1);
        assertTrue(found2);
        assertTrue(found3);
    }

    function test_IsStrategyRegistered() public {
        assertFalse(strategyManager.isStrategyRegistered(strategy1));

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        assertTrue(strategyManager.isStrategyRegistered(strategy1));
    }

    /*//////////////////////////////////////////////////////////////
                        KEEPER FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositToStrategies() public {
        // Add strategies
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        // Fund strategies with ETH for maxDeposit
        mockStrategy1.setMaxDeposit(5 ether);
        mockStrategy2.setMaxDeposit(5 ether);
        mockStrategy1.setIsHealthy(true);
        mockStrategy2.setIsHealthy(true);

        uint256 amount = 10 ether;
        vm.deal(controller, amount);

        // Distribute funds
        controllerContract.depositToStrategies(amount);

        // Verify funds were distributed
        assertGt(address(mockStrategy1).balance, 0);
        assertGt(address(mockStrategy2).balance, 0);
    }

    function test_DepositToStrategies_AccessControl() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.deal(address(this), 10 ether);

        vm.prank(admin);
        vm.expectRevert();
        strategyManager.depositToStrategies(10 ether);
    }

    function test_DepositToStrategies_InvalidConditions() public {
        // No strategies
        vm.deal(controller, 10 ether);
        vm.expectRevert(IStrategyManager.StrategyManagerNoStrategiesRegistered.selector);
        controllerContract.depositToStrategies(10 ether);

        // All strategies have zero maxDeposit
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setMaxDeposit(0);
        vm.deal(controller, 10 ether);
        uint256 controllerBalanceBefore = address(controller).balance;
        controllerContract.depositToStrategies(10 ether);
        assertEq(address(controller).balance, controllerBalanceBefore);
        assertEq(address(mockStrategy1).balance, 0);
    }

    function test_DepositToStrategies_AllUnhealthy_ReturnsZero() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        mockStrategy1.setMaxDeposit(5 ether);
        mockStrategy2.setMaxDeposit(5 ether);
        mockStrategy1.setIsHealthy(false);
        mockStrategy2.setIsHealthy(false);

        vm.deal(controller, 10 ether);
        uint256 controllerBalanceBefore = address(controller).balance;
        controllerContract.depositToStrategies(10 ether);
        assertEq(address(controller).balance, controllerBalanceBefore);
        assertEq(address(mockStrategy1).balance, 0);
        assertEq(address(mockStrategy2).balance, 0);
    }

    function test_DepositToStrategies_RespectsMaxDeposit() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setMaxDeposit(2 ether);
        mockStrategy1.setIsHealthy(true);

        vm.deal(controller, 10 ether);
        controllerContract.depositToStrategies(10 ether);

        assertEq(address(mockStrategy1).balance, 2 ether);
    }

    function test_DepositToStrategies_WhenPaused() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.pause();
        vm.deal(controller, 10 ether);

        vm.expectRevert();
        controllerContract.depositToStrategies(10 ether);
    }

    function test_DepositToStrategy() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setMaxDeposit(10 ether);
        mockStrategy1.setIsHealthy(true);

        uint256 amount = 5 ether;
        vm.deal(address(controller), amount);

        Controller(payable(controller)).depositToStrategy(strategy1, 5 ether);

        assertEq(address(mockStrategy1).balance, amount);
    }

    function test_DepositToStrategy_AccessControl() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.deal(address(this), 5 ether);

        vm.prank(admin);
        vm.expectRevert();
        strategyManager.depositToStrategy(strategy1, 5 ether);
    }

    function test_DepositToStrategy_InvalidConditions() public {
        vm.deal(controller, 5 ether);

        // Not registered
        vm.expectRevert(IStrategyManager.StrategyManagerStrategyNotRegistered.selector);
        controllerContract.depositToStrategy(strategy1, 5 ether);

        // maxDeposit == 0
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setMaxDeposit(0);
        uint256 controllerBalanceBefore = address(controller).balance;
        controllerContract.depositToStrategy(strategy1, 5 ether);
        assertEq(address(controller).balance, controllerBalanceBefore);
        assertEq(address(mockStrategy1).balance, 0);
    }

    function test_DepositToStrategy_RespectsMaxDeposit() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setMaxDeposit(2 ether);
        vm.deal(controller, 5 ether);

        controllerContract.depositToStrategy(strategy1, 5 ether);

        assertEq(address(mockStrategy1).balance, 2 ether);
    }

    function test_DepositToStrategy_UnhealthyStrategy_RefundsAndDepositsNothing() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setMaxDeposit(10 ether);
        mockStrategy1.setIsHealthy(false);
        vm.deal(controller, 5 ether);
        uint256 controllerBalanceBefore = address(controller).balance;

        controllerContract.depositToStrategy(strategy1, 5 ether);

        // Unhealthy strategy receives nothing and the full amount is refunded to the controller.
        assertEq(address(mockStrategy1).balance, 0);
        assertEq(address(controller).balance, controllerBalanceBefore);
    }

    function test_WithdrawFromStrategies() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        // Fund strategies
        vm.deal(address(mockStrategy1), 5 ether);
        vm.deal(address(mockStrategy2), 5 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);
        mockStrategy2.setMaxWithdrawal(5 ether);

        uint256 amount = 10 ether;

        vm.prank(controller);
        strategyManager.withdrawFromStrategies(amount);

        // Verify Controller received funds
        assertGt(address(controllerContract).balance, 0);
    }

    function test_WithdrawFromStrategies_AccessControl() public {
        strategyManager.addStrategy(strategy1, 80, 70);

        vm.prank(admin);
        vm.expectRevert();
        strategyManager.withdrawFromStrategies(5 ether);
    }

    function test_WithdrawFromStrategies_EmptyRegistry() public {
        vm.prank(controller);
        vm.expectRevert(IStrategyManager.StrategyManagerNoStrategiesRegistered.selector);
        strategyManager.withdrawFromStrategies(5 ether);
    }

    function test_WithdrawFromStrategies_NoLiquidity() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setMaxWithdrawal(0);

        vm.prank(controller);
        uint256 withdrawn = strategyManager.withdrawFromStrategies(5 ether);
        assertEq(withdrawn, 0);
    }

    function test_WithdrawFromStrategy() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        // Fund strategy
        vm.deal(address(mockStrategy1), 5 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);

        uint256 amount = 5 ether;

        uint256 controllerBalanceBefore = controller.balance;

        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, amount);

        // Verify Controller received funds (delta excludes bootstrap ETH from setUp)
        assertEq(controller.balance - controllerBalanceBefore, amount);
    }

    function test_WithdrawFromStrategy_AccessControl() public {
        strategyManager.addStrategy(strategy1, 80, 70);

        vm.prank(admin);
        vm.expectRevert();
        strategyManager.withdrawFromStrategy(strategy1, 5 ether);
    }

    function test_WithdrawFromStrategy_InvalidConditions() public {
        // Not registered
        vm.prank(controller);
        vm.expectRevert(IStrategyManager.StrategyManagerStrategyNotRegistered.selector);
        strategyManager.withdrawFromStrategy(strategy1, 5 ether);
    }

    function test_WithdrawFromStrategy_RespectsMaxWithdrawal() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.deal(address(mockStrategy1), 5 ether);
        mockStrategy1.setMaxWithdrawal(2 ether);

        uint256 controllerBalanceBefore = controller.balance;

        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, 5 ether);

        assertEq(controller.balance - controllerBalanceBefore, 2 ether);
    }

    function test_WithdrawFromStrategy_EmitsNetAmountAfterFee() public {
        MockFeeTakingStrategy feeStrategy =
            new MockFeeTakingStrategy("Fee Strategy", controller, address(strategyManager), WITHDRAWAL_FEE_BPS);
        address feeStrategyAddr = address(feeStrategy);
        strategyManager.addStrategy(feeStrategyAddr, 80, 70);

        uint256 expectedNet = GROSS_WITHDRAW_AMOUNT - (GROSS_WITHDRAW_AMOUNT * WITHDRAWAL_FEE_BPS / 10_000);
        vm.deal(feeStrategyAddr, GROSS_WITHDRAW_AMOUNT);
        feeStrategy.setMaxWithdrawal(GROSS_WITHDRAW_AMOUNT);

        uint256 controllerBalanceBefore = controller.balance;

        vm.expectEmit(true, true, false, true);
        emit IStrategyManager.FundsWithdrawnFromStrategy(feeStrategyAddr, expectedNet);

        vm.prank(controller);
        uint256 returned = strategyManager.withdrawFromStrategy(feeStrategyAddr, GROSS_WITHDRAW_AMOUNT);

        assertEq(returned, expectedNet);
        assertEq(controller.balance - controllerBalanceBefore, expectedNet);
        assertEq(feeStrategyAddr.balance, GROSS_WITHDRAW_AMOUNT - expectedNet);
    }

    function test_WithdrawFromStrategies_EmitsNetAmountAfterFee() public {
        uint256 feeBps = 2000; // 20%
        MockFeeTakingStrategy feeStrategy =
            new MockFeeTakingStrategy("Fee Strategy", controller, address(strategyManager), feeBps);
        address feeStrategyAddr = address(feeStrategy);
        strategyManager.addStrategy(feeStrategyAddr, 80, 70);

        uint256 gross = 10 ether;
        uint256 expectedNet = gross - (gross * feeBps / 10_000);
        vm.deal(feeStrategyAddr, gross);
        feeStrategy.setMaxWithdrawal(gross);

        uint256 controllerBalanceBefore = controller.balance;

        vm.expectEmit(true, true, false, true);
        emit IStrategyManager.FundsWithdrawnFromStrategy(feeStrategyAddr, expectedNet);

        vm.prank(controller);
        uint256 returned = strategyManager.withdrawFromStrategies(gross);

        assertEq(returned, expectedNet);
        assertEq(controller.balance - controllerBalanceBefore, expectedNet);
        assertEq(feeStrategyAddr.balance, gross - expectedNet);
    }

    function test_CheckAndRebalanceStrategies() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        // Make strategies unhealthy
        mockStrategy1.setIsHealthy(false);
        mockStrategy2.setIsHealthy(false);

        // Rebalance all
        vm.prank(controller);
        strategyManager.checkAndRebalanceStrategies();

        // Strategies should be healthy after rebalance
        assertTrue(mockStrategy1.isHealthy());
        assertTrue(mockStrategy2.isHealthy());
    }

    function test_CheckAndRebalanceStrategies_AccessControl() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert();
        strategyManager.checkAndRebalanceStrategies();
    }

    function test_CheckAndRebalanceStrategy() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        // Make strategy unhealthy
        mockStrategy1.setIsHealthy(false);

        // Rebalance strategy
        vm.prank(controller);
        strategyManager.checkAndRebalanceStrategy(strategy1);

        // Strategy should be healthy
        assertTrue(mockStrategy1.isHealthy());
    }

    function test_CheckAndRebalanceStrategy_AccessControl() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert();
        strategyManager.checkAndRebalanceStrategy(strategy1);
    }

    function test_CheckAndRebalanceStrategy_NotRegistered() public {
        vm.prank(controller);
        vm.expectRevert(IStrategyManager.StrategyManagerStrategyNotRegistered.selector);
        strategyManager.checkAndRebalanceStrategy(strategy1);
    }

    function test_CheckAndRebalanceStrategyHealthyStrategy() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        // Strategy is healthy, rebalance should not do anything
        assertTrue(mockStrategy1.isHealthy());

        vm.prank(controller);
        strategyManager.checkAndRebalanceStrategy(strategy1);

        // Still healthy
        assertTrue(mockStrategy1.isHealthy());
    }

    function test_CheckAndRebalanceStrategies_WhenPaused() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.pause();
        vm.stopPrank();

        vm.prank(controller);
        vm.expectRevert();
        strategyManager.checkAndRebalanceStrategies();
    }

    function test_DepositToStrategies_PartialSuccess_WhenOneStrategyReverts() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        mockStrategy1.setMaxDeposit(5 ether);
        mockStrategy2.setMaxDeposit(5 ether);
        mockStrategy1.setIsHealthy(true);
        mockStrategy2.setIsHealthy(true);
        mockStrategy2.setRevertDeposit(true);

        uint256 amount = 10 ether;
        vm.deal(controller, amount);
        uint256 controllerBalanceBefore = address(controller).balance;

        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit IStrategyManager.StrategyDepositFailed(
            strategy2, abi.encodeWithSelector(MockStrategy.MockStrategyDepositReverted.selector)
        );

        controllerContract.depositToStrategies(amount);

        assertEq(address(mockStrategy1).balance, 5 ether);
        assertEq(address(mockStrategy2).balance, 0);
        assertEq(address(controller).balance, controllerBalanceBefore - 5 ether);
        assertEq(address(strategyManager).balance, 0);
    }

    function test_DepositToStrategy_RevertsWhenDepositFails() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setMaxDeposit(5 ether);
        mockStrategy1.setIsHealthy(true);
        mockStrategy1.setRevertDeposit(true);

        vm.deal(controller, 5 ether);

        vm.expectRevert(MockStrategy.MockStrategyDepositReverted.selector);
        controllerContract.depositToStrategy(strategy1, 5 ether);
    }

    function test_WithdrawFromStrategies_PartialSuccess_WhenOneStrategyReverts() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        vm.deal(address(mockStrategy1), 5 ether);
        vm.deal(address(mockStrategy2), 5 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);
        mockStrategy2.setMaxWithdrawal(5 ether);
        mockStrategy2.setRevertWithdraw(true);

        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit IStrategyManager.StrategyWithdrawFailed(
            strategy2, abi.encodeWithSelector(MockStrategy.MockStrategyWithdrawReverted.selector)
        );

        vm.prank(controller);
        uint256 withdrawn = strategyManager.withdrawFromStrategies(10 ether);

        assertEq(withdrawn, 5 ether);
        assertEq(address(mockStrategy1).balance, 0);
        assertEq(address(mockStrategy2).balance, 5 ether);
    }

    function test_WithdrawFromStrategy_RevertsWhenWithdrawFails() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.deal(address(mockStrategy1), 5 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);
        mockStrategy1.setRevertWithdraw(true);

        vm.prank(controller);
        vm.expectRevert(MockStrategy.MockStrategyWithdrawReverted.selector);
        strategyManager.withdrawFromStrategy(strategy1, 5 ether);
    }

    function test_CheckAndRebalanceStrategies_PartialSuccess_WhenOneStrategyReverts() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        mockStrategy1.setIsHealthy(false);
        mockStrategy2.setIsHealthy(false);
        mockStrategy1.setRevertRebalance(true);

        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit IStrategyManager.StrategyRebalanceFailed(
            strategy1, abi.encodeWithSelector(MockStrategy.MockStrategyRebalanceReverted.selector)
        );
        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit IStrategyManager.StrategyRebalanced(strategy2);

        vm.prank(controller);
        strategyManager.checkAndRebalanceStrategies();

        assertFalse(mockStrategy1.isHealthy());
        assertTrue(mockStrategy2.isHealthy());
    }

    function test_CheckAndRebalanceStrategy_RevertsWhenRebalanceFails() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setIsHealthy(false);
        mockStrategy1.setRevertRebalance(true);

        vm.prank(controller);
        vm.expectRevert(MockStrategy.MockStrategyRebalanceReverted.selector);
        strategyManager.checkAndRebalanceStrategy(strategy1);
    }

    function test_CheckAndRebalanceStrategies_SkipsPausedStrategy() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        mockStrategy1.setIsHealthy(false);
        mockStrategy2.setIsHealthy(false);
        mockStrategy1.setPaused(true);

        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit IStrategyManager.StrategyRebalanced(strategy2);

        vm.prank(controller);
        strategyManager.checkAndRebalanceStrategies();

        assertFalse(mockStrategy1.isHealthy());
        assertTrue(mockStrategy2.isHealthy());
    }

    function test_CheckAndRebalanceStrategy_SkipsWhenPaused() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        mockStrategy1.setIsHealthy(false);
        mockStrategy1.setPaused(true);

        vm.prank(controller);
        strategyManager.checkAndRebalanceStrategy(strategy1);

        assertFalse(mockStrategy1.isHealthy());
    }

    function test_SyncStrategies() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit IStrategyManager.StrategySynced(strategy1);
        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit IStrategyManager.StrategySynced(strategy2);

        vm.prank(controller);
        strategyManager.syncStrategies();
    }

    function test_SyncStrategies_AccessControl() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert();
        strategyManager.syncStrategies();
    }

    function test_SyncStrategy() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit IStrategyManager.StrategySynced(strategy1);

        vm.prank(controller);
        strategyManager.syncStrategy(strategy1);
    }

    function test_SyncStrategy_NotRegistered() public {
        vm.prank(controller);
        vm.expectRevert(IStrategyManager.StrategyManagerStrategyNotRegistered.selector);
        strategyManager.syncStrategy(strategy1);
    }

    function test_SyncStrategies_WhenPaused() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.pause();
        vm.stopPrank();

        vm.prank(controller);
        vm.expectRevert();
        strategyManager.syncStrategies();
    }

    function test_SyncStrategies_SkipsPausedStrategy() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        mockStrategy1.setPaused(true);

        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit IStrategyManager.StrategySynced(strategy2);

        vm.prank(controller);
        strategyManager.syncStrategies();
    }

    function test_SyncStrategies_PartialSuccess_WhenOneStrategyReverts() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        mockStrategy1.setRevertSync(true);

        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit IStrategyManager.StrategySyncFailed(
            strategy1, abi.encodeWithSelector(MockStrategy.MockStrategySyncReverted.selector)
        );
        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit IStrategyManager.StrategySynced(strategy2);

        vm.prank(controller);
        strategyManager.syncStrategies();
    }

    function test_SyncStrategy_RevertsWhenSyncFails() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setRevertSync(true);

        vm.prank(controller);
        vm.expectRevert(MockStrategy.MockStrategySyncReverted.selector);
        strategyManager.syncStrategy(strategy1);
    }

    function test_SyncStrategy_SkipsWhenPaused() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        mockStrategy1.setPaused(true);

        vm.prank(controller);
        strategyManager.syncStrategy(strategy1);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Controller_ResolvedViaRegistry() public view {
        assertEq(registry.getContractByKey(Auth.CONTROLLER), controller);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Pause() public {
        vm.prank(admin);
        strategyManager.pause();

        assertTrue(strategyManager.paused());
    }

    function test_Pause_AccessControl() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRegistryClient.RegistryClientCallerHasNoneOfRoles.selector, Auth.ADMIN_ROLE, Auth.SECURITY_ROLE
            )
        );
        strategyManager.pause();

        vm.prank(controller);
        vm.expectRevert();
        strategyManager.pause();
    }

    function test_Pause_SecurityCanPauseImmediately() public {
        address security = makeAddr("security");
        registry.grantRole(Auth.SECURITY_ROLE, security);

        vm.prank(security);
        strategyManager.pause();

        assertTrue(strategyManager.paused());
    }

    function test_SecurityCannotUnpause() public {
        address security = makeAddr("security");
        registry.grantRole(Auth.SECURITY_ROLE, security);

        vm.prank(security);
        strategyManager.pause();

        // Recovery stays with ADMIN_ROLE (timelocked in production)
        vm.prank(security);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        strategyManager.unpause();
    }

    function test_Unpause() public {
        strategyManager.pause();
        assertTrue(strategyManager.paused());

        strategyManager.unpause();
        assertFalse(strategyManager.paused());
    }

    function test_Unpause_AccessControl() public {
        strategyManager.pause();

        vm.prank(user1);
        vm.expectRevert();
        strategyManager.unpause();

        vm.prank(controller);
        vm.expectRevert();
        strategyManager.unpause();
    }

    function test_EmergencyWithdrawToController() public {
        uint256 idle = 5 ether;
        vm.deal(controller, 0);
        vm.deal(address(strategyManager), idle);

        vm.expectEmit(false, false, false, true, address(strategyManager));
        emit IStrategyManager.EmergencyWithdrawnToController(idle);

        vm.prank(admin);
        strategyManager.emergencyWithdrawToController();

        assertEq(address(strategyManager).balance, 0);
        assertEq(address(controllerContract).balance, idle);
    }

    function test_EmergencyWithdrawToController_SecurityCanCall() public {
        address security = makeAddr("security");
        registry.grantRole(Auth.SECURITY_ROLE, security);

        uint256 idle = 2 ether;
        vm.deal(controller, 0);
        vm.deal(address(strategyManager), idle);

        vm.prank(security);
        strategyManager.emergencyWithdrawToController();

        assertEq(address(strategyManager).balance, 0);
        assertEq(address(controllerContract).balance, idle);
    }

    function test_EmergencyWithdrawToController_AccessControl() public {
        vm.deal(address(strategyManager), 1 ether);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRegistryClient.RegistryClientCallerHasNoneOfRoles.selector, Auth.ADMIN_ROLE, Auth.SECURITY_ROLE
            )
        );
        strategyManager.emergencyWithdrawToController();

        vm.prank(controller);
        vm.expectRevert();
        strategyManager.emergencyWithdrawToController();
    }

    function test_EmergencyWithdrawToController_ZeroBalance_Reverts() public {
        vm.deal(address(strategyManager), 0);

        vm.prank(admin);
        vm.expectRevert(IStrategyManager.StrategyManagerNoBalanceToRecover.selector);
        strategyManager.emergencyWithdrawToController();
    }

    /*//////////////////////////////////////////////////////////////
                    SUPPORTED ERC20 WHITELIST TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AddSupportedERC20() public {
        _setUpSupportedERC20Fixture();

        vm.expectEmit(true, false, false, false, address(strategyManager));
        emit IStrategyManager.SupportedERC20Added(address(usdc));

        vm.prank(admin);
        strategyManager.addSupportedERC20(address(usdc));

        assertTrue(strategyManager.isSupportedERC20(address(usdc)));
        address[] memory supported = strategyManager.supportedERC20();
        assertEq(supported.length, 1);
        assertEq(supported[0], address(usdc));
    }

    function test_AddSupportedERC20_AccessControl() public {
        _setUpSupportedERC20Fixture();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        strategyManager.addSupportedERC20(address(usdc));

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        strategyManager.addSupportedERC20(address(usdc));

        // SECURITY_ROLE can remove (escape hatch) but cannot add — add stays ADMIN-only.
        address security = makeAddr("security");
        registry.grantRole(Auth.SECURITY_ROLE, security);
        vm.prank(security);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        strategyManager.addSupportedERC20(address(usdc));
    }

    function test_AddSupportedERC20_ZeroAddress_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(IStrategyManager.StrategyManagerZeroAddress.selector);
        strategyManager.addSupportedERC20(address(0));
    }

    function test_AddSupportedERC20_NoCode_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(IStrategyManager.StrategyManagerNoCode.selector);
        strategyManager.addSupportedERC20(makeAddr("eoa"));
    }

    function test_AddSupportedERC20_NotPriceable_Reverts() public {
        // Token with code but no Oracle feed: a non-zero balance would freeze NAV, so
        // whitelisting is rejected upfront.
        MockERC20 feedlessToken = new MockERC20("Feedless", "NOFEED", 18);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyManager.StrategyManagerERC20NotPriceable.selector, address(feedlessToken))
        );
        strategyManager.addSupportedERC20(address(feedlessToken));
    }

    function test_AddSupportedERC20_AlreadySupported_Reverts() public {
        _setUpSupportedERC20Fixture();

        vm.startPrank(admin);
        strategyManager.addSupportedERC20(address(usdc));
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyManager.StrategyManagerERC20AlreadySupported.selector, address(usdc))
        );
        strategyManager.addSupportedERC20(address(usdc));
        vm.stopPrank();
    }

    function test_AddSupportedERC20_WorksWhenPaused() public {
        _setUpSupportedERC20Fixture();

        vm.startPrank(admin);
        strategyManager.pause();
        strategyManager.addSupportedERC20(address(usdc));
        vm.stopPrank();

        assertTrue(strategyManager.isSupportedERC20(address(usdc)));
    }

    function test_RemoveSupportedERC20() public {
        _setUpSupportedERC20Fixture();

        vm.prank(admin);
        strategyManager.addSupportedERC20(address(usdc));

        vm.expectEmit(true, false, false, false, address(strategyManager));
        emit IStrategyManager.SupportedERC20Removed(address(usdc));

        vm.prank(admin);
        strategyManager.removeSupportedERC20(address(usdc));

        assertFalse(strategyManager.isSupportedERC20(address(usdc)));
        assertEq(strategyManager.supportedERC20().length, 0);
    }

    function test_RemoveSupportedERC20_AccessControl() public {
        _setUpSupportedERC20Fixture();

        vm.prank(admin);
        strategyManager.addSupportedERC20(address(usdc));

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRegistryClient.RegistryClientCallerHasNoneOfRoles.selector, Auth.ADMIN_ROLE, Auth.SECURITY_ROLE
            )
        );
        strategyManager.removeSupportedERC20(address(usdc));
    }

    function test_RemoveSupportedERC20_SecurityCanRemove() public {
        _setUpSupportedERC20Fixture();

        vm.prank(admin);
        strategyManager.addSupportedERC20(address(usdc));

        address security = makeAddr("security");
        registry.grantRole(Auth.SECURITY_ROLE, security);

        vm.expectEmit(true, false, false, false, address(strategyManager));
        emit IStrategyManager.SupportedERC20Removed(address(usdc));

        vm.prank(security);
        strategyManager.removeSupportedERC20(address(usdc));

        assertFalse(strategyManager.isSupportedERC20(address(usdc)));
    }

    function test_RemoveSupportedERC20_NotSupported_Reverts() public {
        _setUpSupportedERC20Fixture();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyManager.StrategyManagerERC20NotSupported.selector, address(usdc))
        );
        strategyManager.removeSupportedERC20(address(usdc));
    }

    function test_RemoveSupportedERC20_WorksWhenPaused() public {
        _setUpSupportedERC20Fixture();

        vm.startPrank(admin);
        strategyManager.addSupportedERC20(address(usdc));
        strategyManager.pause();
        strategyManager.removeSupportedERC20(address(usdc));
        vm.stopPrank();

        assertFalse(strategyManager.isSupportedERC20(address(usdc)));
    }

    function test_RemoveSupportedERC20_WithBalance_DropsValueFromNAV() public {
        _strandTokensOnStrategyManager();

        vm.prank(admin);
        strategyManager.addSupportedERC20(address(usdc));
        uint256 navWithToken = strategyManager.totalNAVInETH();

        // Removal is allowed even with a non-zero balance (escape hatch for a dead feed),
        // but the balance's value drops out of NAV immediately.
        vm.prank(admin);
        strategyManager.removeSupportedERC20(address(usdc));

        assertEq(strategyManager.totalNAVInETH(), navWithToken - STRANDED_TOKEN_VALUE_ETH);
    }

    /*//////////////////////////////////////////////////////////////
                    SUPPORTED ERC20 NAV ACCOUNTING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TotalNAVInETH_IncludesSupportedERC20Value() public {
        _strandTokensOnStrategyManager();

        uint256 navBefore = strategyManager.totalNAVInETH();

        vm.prank(admin);
        strategyManager.addSupportedERC20(address(usdc));

        // $500 of USDC at $4000/ETH = 0.125 ETH, decimals normalized 6 -> 18
        assertEq(strategyManager.totalNAVInETH(), navBefore + STRANDED_TOKEN_VALUE_ETH);
    }

    function test_TotalNAVInUSD_IncludesSupportedERC20Value() public {
        _strandTokensOnStrategyManager();

        uint256 navUsdBefore = strategyManager.totalNAVInUSD();

        vm.prank(admin);
        strategyManager.addSupportedERC20(address(usdc));

        // USD NAV converts the ETH NAV, so the supported ERC-20's USD value rides along ($500).
        assertEq(strategyManager.totalNAVInUSD(), navUsdBefore + _ethNavToUsd(STRANDED_TOKEN_VALUE_ETH));
    }

    function test_TotalNAVInETH_ExcludesNonWhitelistedToken() public {
        _strandTokensOnStrategyManager();

        uint256 navBefore = strategyManager.totalNAVInETH();

        // Stranded but not whitelisted: invisible to NAV until addSupportedERC20().
        assertEq(strategyManager.totalNAVInETH(), navBefore);
    }

    function test_TotalNAVInETH_SkipsOracleForZeroSupportedERC20Balance() public {
        _setUpSupportedERC20Fixture();

        vm.prank(admin);
        strategyManager.addSupportedERC20(address(usdc));

        // Let the USDC feed go stale (keep the ETH feed fresh). With a zero balance the
        // Oracle is never consulted for the supported ERC-20, so NAV keeps working.
        vm.warp(block.timestamp + STALENESS_INTERVAL + 1);
        ethPriceFeed.setPrice(int256(ETH_PRICE));

        uint256 nav = strategyManager.totalNAVInETH();
        assertEq(nav, _expectedTotalNAVInETH(0));
    }

    function test_TotalNAVInETH_RevertsWhenSupportedERC20FeedStale() public {
        _strandTokensOnStrategyManager();

        vm.prank(admin);
        strategyManager.addSupportedERC20(address(usdc));

        // Fail-closed: a stale feed on a non-zero supported balance freezes NAV, matching the
        // reverting-strategy-navInETH semantics. Escape hatch: removeSupportedERC20() (ADMIN or SECURITY).
        // Only the USDC feed goes stale; the ETH feed is refreshed after the warp.
        vm.warp(block.timestamp + STALENESS_INTERVAL + 1);
        ethPriceFeed.setPrice(int256(ETH_PRICE));

        vm.expectRevert();
        strategyManager.totalNAVInETH();

        vm.prank(admin);
        strategyManager.removeSupportedERC20(address(usdc));
        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(0));
    }

    function test_MockStrategyEmergencyExit_ClearsPendingLpFees() public {
        strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        assertGt(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        mockStrategy1.setPaused(true);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        mockStrategy1.emergencyExit();

        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);
    }

    /*//////////////////////////////////////////////////////////////
                INTEGRATION WITH STRATEGY MANAGER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CompleteStrategyLifecycle() public {
        // Add strategies
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        assertEq(strategyManager.strategyCount(), 2);
        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(INITIAL_NAV_1 + INITIAL_NAV_2));

        // Update NAVs directly on strategies
        mockStrategy1.setNavInETH(150000e18);
        mockStrategy2.setNavInETH(250000e18);

        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(400000e18));

        mockStrategy1.setNavInETH(0);
        // Remove one strategy
        vm.prank(admin);
        strategyManager.removeStrategy(strategy1);

        assertEq(strategyManager.strategyCount(), 1);
        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(250000e18));
        assertFalse(strategyManager.isStrategyRegistered(strategy1));
        assertTrue(strategyManager.isStrategyRegistered(strategy2));
    }

    function test_NAVCalculationsWithMultipleStrategies() public {
        // Set NAVs on strategies
        mockStrategy1.setNavInETH(100000e18);
        mockStrategy2.setNavInETH(200000e18);
        mockStrategy3.setNavInETH(300000e18);

        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        strategyManager.addStrategy(strategy3, 40, 30);
        vm.stopPrank();

        uint256 expectedTotal = 600000e18;
        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(expectedTotal));

        // Update one strategy NAV
        mockStrategy1.setNavInETH(150000e18);
        expectedTotal = 650000e18;
        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(expectedTotal));

        mockStrategy2.setNavInETH(0);
        // Remove one strategy
        vm.prank(admin);
        strategyManager.removeStrategy(strategy2);
        expectedTotal = 450000e18;
        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(expectedTotal));
    }

    /*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_AddStrategy(uint256 nav) public {
        vm.assume(nav <= type(uint128).max);
        vm.assume(nav > 0);

        // Set NAV on strategy
        mockStrategy1.setNavInETH(nav);

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        assertTrue(strategyManager.isStrategyRegistered(strategy1));
        assertEq(strategyManager.strategyNAVInETH(strategy1), nav);
        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(nav));
    }

    function testFuzz_StrategyNAVInETH_ReadsFromStrategy(uint256 nav) public {
        vm.assume(nav <= type(uint128).max);

        // Set NAV on strategy
        mockStrategy1.setNavInETH(nav);

        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        // NAV should be read from strategy
        assertEq(strategyManager.strategyNAVInETH(strategy1), nav);
    }

    function testFuzz_StrategyNAVInETH_UpdatesWhenStrategyUpdates(uint256 oldNAV, uint256 newNAV) public {
        vm.assume(oldNAV <= type(uint128).max);
        vm.assume(newNAV <= type(uint128).max);

        // Set initial NAV
        mockStrategy1.setNavInETH(oldNAV);

        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        // Update strategy NAV
        mockStrategy1.setNavInETH(newNAV);

        // StrategyManager should read updated NAV
        assertEq(strategyManager.strategyNAVInETH(strategy1), newNAV);
    }

    function testFuzz_AddMultipleStrategies(uint256 nav1, uint256 nav2, uint256 nav3) public {
        vm.assume(nav1 <= type(uint128).max);
        vm.assume(nav2 <= type(uint128).max);
        vm.assume(nav3 <= type(uint128).max);
        vm.assume(nav1 > 0);
        vm.assume(nav2 > 0);
        vm.assume(nav3 > 0);

        // Set NAVs on strategies
        mockStrategy1.setNavInETH(nav1);
        mockStrategy2.setNavInETH(nav2);
        mockStrategy3.setNavInETH(nav3);

        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        strategyManager.addStrategy(strategy3, 40, 30);
        vm.stopPrank();

        assertEq(strategyManager.strategyCount(), 3);
        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(nav1 + nav2 + nav3));
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_StrategyNAVInETH_CanBeZero() public {
        // Set strategy NAV to zero
        mockStrategy1.setNavInETH(0);

        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        assertEq(strategyManager.strategyNAVInETH(strategy1), 0);
        assertEq(strategyManager.totalNAVInETH(), BOOTSTRAP_CONTROLLER_ETH);
    }

    function test_RemoveAllStrategies() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        vm.startPrank(admin);
        mockStrategy1.setNavInETH(0);
        strategyManager.removeStrategy(strategy1);
        mockStrategy2.setNavInETH(0);
        strategyManager.removeStrategy(strategy2);
        vm.stopPrank();

        assertEq(strategyManager.strategyCount(), 0);
        assertEq(strategyManager.totalNAVInETH(), BOOTSTRAP_CONTROLLER_ETH);
        assertEq(strategyManager.strategies().length, 0);
    }

    function test_Constants() public view {
        assertEq(strategyManager.MAX_NAV_RESIDUE(), ALLOWED_NAV_RESIDUE);
    }

    /*//////////////////////////////////////////////////////////////
                        GAS BENCHMARKING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GasBenchmark_AddStrategy() public {
        uint256 gasStart = gasleft();

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        uint256 gasUsed = gasStart - gasleft();

        // Verify the operation succeeded
        assertTrue(strategyManager.isStrategyRegistered(strategy1));

        // Gas usage should be reasonable (less than 345k gas)
        assertLt(gasUsed, 345_000, "AddStrategy gas usage too high");
    }

    function test_GasBenchmark_StrategyNAVInETH() public {
        // Setup
        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        uint256 gasStart = gasleft();

        // Read NAV from strategy
        strategyManager.strategyNAVInETH(strategy1);

        uint256 gasUsed = gasStart - gasleft();

        // Verify the operation succeeded
        assertEq(strategyManager.strategyNAVInETH(strategy1), INITIAL_NAV_1);

        // Gas usage should be reasonable (less than 50k gas for view function)
        assertLt(gasUsed, 50_000, "StrategyNAVInETH gas usage too high");
    }

    function test_GasBenchmark_RemoveStrategy() public {
        // Setup
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        mockStrategy1.setNavInETH(0);

        uint256 gasStart = gasleft();

        vm.prank(admin);
        strategyManager.removeStrategy(strategy1);

        uint256 gasUsed = gasStart - gasleft();

        // Verify the operation succeeded
        assertFalse(strategyManager.isStrategyRegistered(strategy1));
        assertTrue(strategyManager.isStrategyRegistered(strategy2));

        // Gas usage should be reasonable (less than 250k gas)
        assertLt(gasUsed, 250_000, "RemoveStrategy gas usage too high");
    }

    function test_GasBenchmark_GetStrategies() public {
        // Setup multiple strategies
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        strategyManager.addStrategy(strategy3, 40, 30);
        vm.stopPrank();

        uint256 gasStart = gasleft();

        address[] memory strategies = strategyManager.strategies();

        uint256 gasUsed = gasStart - gasleft();

        assertEq(strategies.length, 3);

        assertLt(gasUsed, 50_000, "GetStrategies gas usage too high");
    }

    function test_GasBenchmark_TotalNAVInETH() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        strategyManager.addStrategy(strategy3, 40, 30);
        vm.stopPrank();

        uint256 gasStart = gasleft();

        uint256 totalNAV = strategyManager.totalNAVInETH();

        uint256 gasUsed = gasStart - gasleft();

        assertEq(totalNAV, _expectedTotalNAVInETH(INITIAL_NAV_1 + INITIAL_NAV_2 + INITIAL_NAV_3));

        assertLt(gasUsed, 100_000, "GetTotalNAVInETH gas usage too high");
    }

    function test_GasBenchmark_Pause() public {
        uint256 gasStart = gasleft();

        vm.prank(admin);
        strategyManager.pause();

        uint256 gasUsed = gasStart - gasleft();

        assertTrue(strategyManager.paused());

        assertLt(gasUsed, 100_000, "Pause gas usage too high");
    }

    function test_GasBenchmark_Unpause() public {
        // Setup - pause first
        vm.prank(admin);
        strategyManager.pause();

        uint256 gasStart = gasleft();

        vm.prank(admin);
        strategyManager.unpause();

        uint256 gasUsed = gasStart - gasleft();

        assertFalse(strategyManager.paused());

        assertLt(gasUsed, 50_000, "Unpause gas usage too high");
    }

    /*//////////////////////////////////////////////////////////////
                        ADDITIONAL EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_EdgeCase_MaxNAVValue() public {
        uint256 maxNAV = type(uint128).max;
        mockStrategy1.setNavInETH(maxNAV);

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        assertEq(strategyManager.strategyNAVInETH(strategy1), maxNAV);
        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(maxNAV));
    }

    function test_EdgeCase_ZeroNAV() public {
        mockStrategy1.setNavInETH(0);

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        assertEq(strategyManager.strategyNAVInETH(strategy1), 0);
        assertEq(strategyManager.totalNAVInETH(), BOOTSTRAP_CONTROLLER_ETH);
    }

    function test_EdgeCase_MinNAVValue() public {
        uint256 minNAV = 1;
        mockStrategy1.setNavInETH(minNAV);

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        assertEq(strategyManager.strategyNAVInETH(strategy1), minNAV);
        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(minNAV));
    }

    function test_EdgeCase_MaxStrategyCount() public {
        // Test adding many strategies to check gas limits
        // Note: In real scenario, we'd need to deploy mock strategies
        // For this test, we'll use the existing mock strategies
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        strategyManager.addStrategy(strategy3, 40, 30);
        vm.stopPrank();

        assertEq(strategyManager.strategyCount(), 3);
        assertEq(strategyManager.totalNAVInETH(), _expectedTotalNAVInETH(INITIAL_NAV_1 + INITIAL_NAV_2 + INITIAL_NAV_3));
    }

    /*//////////////////////////////////////////////////////////////
                        PAGINATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositToStrategies_WithPagination() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        strategyManager.addStrategy(strategy3, 40, 30);
        vm.stopPrank();

        mockStrategy1.setMaxDeposit(5 ether);
        mockStrategy2.setMaxDeposit(5 ether);
        mockStrategy3.setMaxDeposit(5 ether);
        mockStrategy1.setIsHealthy(true);
        mockStrategy2.setIsHealthy(true);
        mockStrategy3.setIsHealthy(true);

        uint256 amount = 10 ether;
        // Mirror Controller's flow: pre-fund the StrategyManager, then call the non-payable function
        vm.deal(address(strategyManager), amount);

        // Distribute to first two strategies only (indices 0 and 1)
        // Range [0, 2) processes indices 0 and 1
        vm.prank(controller);
        strategyManager.depositToStrategies(0, 2, amount);

        // Verify funds were distributed to first two strategies
        assertGt(address(mockStrategy1).balance, 0);
        assertGt(address(mockStrategy2).balance, 0);
        assertEq(address(mockStrategy3).balance, 0); // Third strategy should not receive funds
    }

    function test_DepositToStrategies_WithPagination_InvalidRange() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        mockStrategy1.setMaxDeposit(5 ether);
        mockStrategy1.setIsHealthy(true);
        vm.deal(controller, 10 ether);

        // Invalid range: endIndex > strategies.length (with only 1 strategy, endIndex must be <= 1)
        // endIndex = 1 is valid (processes [0, 1) = index 0), but endIndex = 2 is invalid
        vm.prank(controller);
        vm.expectRevert(IStrategyManager.StrategyManagerInvalidRange.selector);
        strategyManager.depositToStrategies(0, 2, 10 ether);

        // Invalid range: startIndex > endIndex
        vm.prank(controller);
        vm.expectRevert(IStrategyManager.StrategyManagerInvalidRange.selector);
        strategyManager.depositToStrategies(1, 0, 10 ether);
    }

    function test_DepositToStrategies_WithPagination_EmptyRegistry() public {
        vm.deal(controller, 10 ether);

        vm.prank(controller);
        vm.expectRevert(IStrategyManager.StrategyManagerNoStrategiesRegistered.selector);
        strategyManager.depositToStrategies(0, 1, 10 ether);
    }

    function test_WithdrawFromStrategies_WithPagination() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        strategyManager.addStrategy(strategy3, 40, 30);
        vm.stopPrank();

        vm.deal(address(mockStrategy1), 5 ether);
        vm.deal(address(mockStrategy2), 5 ether);
        vm.deal(address(mockStrategy3), 5 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);
        mockStrategy2.setMaxWithdrawal(5 ether);
        mockStrategy3.setMaxWithdrawal(5 ether);

        uint256 amount = 10 ether;

        // Withdraw from first two strategies only (indices 0 and 1)
        // Range [0, 2) processes indices 0 and 1
        vm.prank(controller);
        strategyManager.withdrawFromStrategies(0, 2, amount);

        // Controller should receive funds
        assertGt(address(controllerContract).balance, 0);
        // Third strategy should not be withdrawn from
        assertEq(address(mockStrategy3).balance, 5 ether);
    }

    function test_WithdrawFromStrategies_WithPagination_InvalidRange() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        vm.deal(address(mockStrategy1), 5 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);

        // Invalid range: endIndex > strategies.length (with only 1 strategy, endIndex must be <= 1)
        // endIndex = 1 is valid (processes [0, 1) = index 0), but endIndex = 2 is invalid
        vm.prank(controller);
        vm.expectRevert(IStrategyManager.StrategyManagerInvalidRange.selector);
        strategyManager.withdrawFromStrategies(0, 2, 5 ether);

        // Invalid range: startIndex > endIndex
        vm.prank(controller);
        vm.expectRevert(IStrategyManager.StrategyManagerInvalidRange.selector);
        strategyManager.withdrawFromStrategies(1, 0, 5 ether);
    }

    function test_CheckAndRebalanceStrategies_WithPagination() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        strategyManager.addStrategy(strategy3, 40, 30);
        vm.stopPrank();

        // Make strategies unhealthy
        mockStrategy1.setIsHealthy(false);
        mockStrategy2.setIsHealthy(false);
        mockStrategy3.setIsHealthy(false);

        // Rebalance only first two strategies (indices 0 and 1)
        // Range [0, 2) processes indices 0 and 1
        vm.prank(controller);
        strategyManager.checkAndRebalanceStrategies(0, 2);

        // First two strategies should be healthy after rebalance
        assertTrue(mockStrategy1.isHealthy());
        assertTrue(mockStrategy2.isHealthy());
        // Third strategy should still be unhealthy
        assertFalse(mockStrategy3.isHealthy());
    }

    function test_CheckAndRebalanceStrategies_WithPagination_InvalidRange() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        // Invalid range: endIndex > strategies.length (with only 1 strategy, endIndex must be <= 1)
        // endIndex = 1 is valid (processes [0, 1) = index 0), but endIndex = 2 is invalid
        vm.prank(controller);
        vm.expectRevert(IStrategyManager.StrategyManagerInvalidRange.selector);
        strategyManager.checkAndRebalanceStrategies(0, 2);

        // Invalid range: startIndex > endIndex
        vm.prank(controller);
        vm.expectRevert(IStrategyManager.StrategyManagerInvalidRange.selector);
        strategyManager.checkAndRebalanceStrategies(1, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT & WITHDRAWAL WEIGHT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetDepositWeight_AccessControl() public {
        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        strategyManager.setDepositWeight(strategy1, 50);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        strategyManager.setDepositWeight(strategy1, 50);
    }

    function test_SetDepositWeight_NotRegistered() public {
        vm.prank(admin);
        vm.expectRevert(IStrategyManager.StrategyManagerStrategyNotRegistered.selector);
        strategyManager.setDepositWeight(strategy1, 50);
    }

    function test_SetDepositWeight_RevertsAboveMax() public {
        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyManager.StrategyManagerInvalidDepositWeight.selector, strategy1)
        );
        strategyManager.setDepositWeight(strategy1, 101);
    }

    function test_SetDepositWeight() public {
        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.DepositWeightUpdated(strategy1, 80, 50);

        vm.prank(admin);
        strategyManager.setDepositWeight(strategy1, 50);

        assertEq(strategyManager.depositWeight(strategy1), 50);
        assertEq(strategyManager.withdrawalWeight(strategy1), 70); // unchanged
    }

    function test_SetWithdrawalWeight_AccessControl() public {
        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        strategyManager.setWithdrawalWeight(strategy1, 50);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        strategyManager.setWithdrawalWeight(strategy1, 50);
    }

    function test_SetWithdrawalWeight_NotRegistered() public {
        vm.prank(admin);
        vm.expectRevert(IStrategyManager.StrategyManagerStrategyNotRegistered.selector);
        strategyManager.setWithdrawalWeight(strategy1, 50);
    }

    function test_SetWithdrawalWeight_RevertsAboveMax() public {
        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyManager.StrategyManagerInvalidWithdrawalWeight.selector, strategy1)
        );
        strategyManager.setWithdrawalWeight(strategy1, 101);
    }

    function test_SetWithdrawalWeight() public {
        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.WithdrawalWeightUpdated(strategy1, 70, 40);

        vm.prank(admin);
        strategyManager.setWithdrawalWeight(strategy1, 40);

        assertEq(strategyManager.withdrawalWeight(strategy1), 40);
        assertEq(strategyManager.depositWeight(strategy1), 80); // unchanged
    }

    function test_AddStrategy_RevertsWithInvalidDepositWeight() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyManager.StrategyManagerInvalidDepositWeight.selector, strategy1)
        );
        strategyManager.addStrategy(strategy1, 101, 70);
    }

    function test_AddStrategy_RevertsWithInvalidWithdrawalWeight() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyManager.StrategyManagerInvalidWithdrawalWeight.selector, strategy1)
        );
        strategyManager.addStrategy(strategy1, 80, 101);
    }

    function test_AddStrategy_AllowsZeroWeights() public {
        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 0, 0);

        assertTrue(strategyManager.isStrategyRegistered(strategy1));
        assertEq(strategyManager.depositWeight(strategy1), 0);
        assertEq(strategyManager.withdrawalWeight(strategy1), 0);
    }

    function test_SetStrategyWeights_AccessControl() public {
        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        address[] memory strategies = new address[](1);
        strategies[0] = strategy1;
        uint8[] memory depositWeights = new uint8[](1);
        depositWeights[0] = 50;
        uint8[] memory withdrawalWeights = new uint8[](1);
        withdrawalWeights[0] = 50;

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        strategyManager.setStrategyWeights(strategies, depositWeights, withdrawalWeights);

        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        strategyManager.setStrategyWeights(strategies, depositWeights, withdrawalWeights);
    }

    function test_SetStrategyWeights_RevertsOnLengthMismatch() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.stopPrank();

        address[] memory strategies = new address[](1);
        strategies[0] = strategy1;
        uint8[] memory depositWeights = new uint8[](2);
        depositWeights[0] = 10;
        depositWeights[1] = 20;
        uint8[] memory withdrawalWeights = new uint8[](1);
        withdrawalWeights[0] = 30;

        vm.prank(admin);
        vm.expectRevert(IStrategyManager.StrategyManagerInvalidLength.selector);
        strategyManager.setStrategyWeights(strategies, depositWeights, withdrawalWeights);
    }

    function test_SetStrategyWeights_NotRegistered() public {
        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        // Mid-array unregistered address must revert the whole batch (no partial update).
        address[] memory strategies = new address[](2);
        strategies[0] = strategy1;
        strategies[1] = strategy2; // not registered
        uint8[] memory depositWeights = new uint8[](2);
        depositWeights[0] = 10;
        depositWeights[1] = 90;
        uint8[] memory withdrawalWeights = new uint8[](2);
        withdrawalWeights[0] = 25;
        withdrawalWeights[1] = 75;

        vm.prank(admin);
        vm.expectRevert(IStrategyManager.StrategyManagerStrategyNotRegistered.selector);
        strategyManager.setStrategyWeights(strategies, depositWeights, withdrawalWeights);

        // First strategy's weights must be unchanged after the failed batch.
        assertEq(strategyManager.depositWeight(strategy1), 80);
        assertEq(strategyManager.withdrawalWeight(strategy1), 70);
    }

    function test_SetStrategyWeights_AtomicallyUpdatesMultiple() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        address[] memory strategies = new address[](2);
        strategies[0] = strategy1;
        strategies[1] = strategy2;
        uint8[] memory depositWeights = new uint8[](2);
        depositWeights[0] = 10;
        depositWeights[1] = 90;
        uint8[] memory withdrawalWeights = new uint8[](2);
        withdrawalWeights[0] = 25;
        withdrawalWeights[1] = 75;

        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.DepositWeightUpdated(strategy1, 80, 10);
        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.WithdrawalWeightUpdated(strategy1, 70, 25);
        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.DepositWeightUpdated(strategy2, 60, 90);
        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.WithdrawalWeightUpdated(strategy2, 50, 75);

        vm.prank(admin);
        strategyManager.setStrategyWeights(strategies, depositWeights, withdrawalWeights);

        assertEq(strategyManager.depositWeight(strategy1), 10);
        assertEq(strategyManager.withdrawalWeight(strategy1), 25);
        assertEq(strategyManager.depositWeight(strategy2), 90);
        assertEq(strategyManager.withdrawalWeight(strategy2), 75);
    }

    function test_SetStrategyWeights_RevertsAboveMax() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        address[] memory strategies = new address[](2);
        strategies[0] = strategy1;
        strategies[1] = strategy2;
        uint8[] memory depositWeights = new uint8[](2);
        depositWeights[0] = 10;
        depositWeights[1] = 101; // invalid — aborts whole batch
        uint8[] memory withdrawalWeights = new uint8[](2);
        withdrawalWeights[0] = 25;
        withdrawalWeights[1] = 75;

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyManager.StrategyManagerInvalidDepositWeight.selector, strategy2)
        );
        strategyManager.setStrategyWeights(strategies, depositWeights, withdrawalWeights);

        // No partial update: strategy1 unchanged after the failed batch.
        assertEq(strategyManager.depositWeight(strategy1), 80);
        assertEq(strategyManager.withdrawalWeight(strategy1), 70);
        assertEq(strategyManager.depositWeight(strategy2), 60);
        assertEq(strategyManager.withdrawalWeight(strategy2), 50);
    }

    function test_DepositToStrategies_ZeroDepositWeightExcludesStrategy() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 0, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        mockStrategy1.setMaxDeposit(10 ether);
        mockStrategy2.setMaxDeposit(10 ether);
        mockStrategy1.setIsHealthy(true);
        mockStrategy2.setIsHealthy(true);

        uint256 amount = 6 ether;
        vm.deal(address(strategyManager), amount);

        vm.prank(controller);
        strategyManager.depositToStrategies(amount);

        assertEq(address(mockStrategy1).balance, 0);
        assertEq(address(mockStrategy2).balance, 6 ether);
    }

    function test_WithdrawFromStrategies_ZeroWithdrawalWeightExcludesStrategy() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 0);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        vm.deal(address(mockStrategy1), 10 ether);
        vm.deal(address(mockStrategy2), 10 ether);
        mockStrategy1.setMaxWithdrawal(10 ether);
        mockStrategy2.setMaxWithdrawal(10 ether);

        uint256 controllerBefore = controller.balance;

        vm.prank(controller);
        strategyManager.withdrawFromStrategies(6 ether);

        assertEq(address(mockStrategy1).balance, 10 ether); // weight 0 — untouched
        assertEq(address(mockStrategy2).balance, 4 ether); // took the full 6 ether
        assertEq(controller.balance - controllerBefore, 6 ether);
    }

    function test_RemoveStrategy_ClearsWeights() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setNavInETH(0);
        strategyManager.removeStrategy(strategy1);
        vm.stopPrank();

        assertEq(strategyManager.depositWeight(strategy1), 0);
        assertEq(strategyManager.withdrawalWeight(strategy1), 0);
    }

    function test_ForceRemoveStrategy_ClearsWeights() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.forceRemoveStrategy(strategy1);
        vm.stopPrank();

        assertFalse(strategyManager.isStrategyRegistered(strategy1));
        assertEq(strategyManager.depositWeight(strategy1), 0);
        assertEq(strategyManager.withdrawalWeight(strategy1), 0);
    }

    function test_DepositToStrategies_ProportionalByDepositWeight() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70); // depositWeight = 80
        strategyManager.addStrategy(strategy2, 60, 50); // depositWeight = 60
        vm.stopPrank();

        mockStrategy1.setMaxDeposit(10 ether);
        mockStrategy2.setMaxDeposit(10 ether);
        mockStrategy1.setIsHealthy(true);
        mockStrategy2.setIsHealthy(true);

        uint256 amount = 14 ether; // 80 + 60 = 140 total deposit weight
        // Mirror Controller's flow: pre-fund StrategyManager directly since it's no longer payable
        vm.deal(address(strategyManager), amount);

        vm.prank(controller);
        strategyManager.depositToStrategies(amount);

        // Strategy1 should get: 14 * 80 / 140 = 8 ether
        // Strategy2 should get: 14 * 60 / 140 = 6 ether
        // Allow for rounding differences
        assertGe(address(mockStrategy1).balance, 7 ether);
        assertLe(address(mockStrategy1).balance, 8 ether);
        assertGe(address(mockStrategy2).balance, 5 ether);
        assertLe(address(mockStrategy2).balance, 6 ether);
    }

    function test_WithdrawFromStrategies_ProportionalByWithdrawalWeight() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70); // withdrawalWeight = 70
        strategyManager.addStrategy(strategy2, 60, 50); // withdrawalWeight = 50
        vm.stopPrank();

        vm.deal(address(mockStrategy1), 10 ether);
        vm.deal(address(mockStrategy2), 10 ether);
        mockStrategy1.setMaxWithdrawal(10 ether);
        mockStrategy2.setMaxWithdrawal(10 ether);

        uint256 amount = 12 ether; // 70 + 50 = 120 total withdrawal weight

        uint256 controllerBalanceBefore = controller.balance;

        vm.prank(controller);
        strategyManager.withdrawFromStrategies(amount);

        // Strategy1 should withdraw: 12 * 70 / 120 = 7 ether
        // Strategy2 should withdraw: 12 * 50 / 120 = 5 ether
        uint256 withdrawn = controller.balance - controllerBalanceBefore;
        assertGe(withdrawn, 11 ether);
        assertLe(withdrawn, 12 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    PERFORMANCE FEE HARVESTING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HarvestPerformanceFee_MintsEVEToTreasury() public {
        vm.prank(admin);
        strategyManager.setDaoTreasury(DAO_TREASURY);
        vm.prank(admin);
        strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        registry.grantRole(Auth.MINTER_ROLE, address(strategyManager));

        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);

        assertEq(
            strategyManager.pendingPerformanceFeeInETH(strategy1),
            _expectedPendingFeeEth(LP_FEE_BASE_1, PERFORMANCE_FEE_BPS)
        );

        uint256 treasuryEveBefore = token.balanceOf(DAO_TREASURY);
        uint256 totalPaidBefore = strategyManager.totalPerformanceFeesPaidEVE();

        _harvestFeeFromStrategy(strategy1);

        uint256 evesMinted = token.balanceOf(DAO_TREASURY) - treasuryEveBefore;
        assertGt(evesMinted, 0);
        assertEq(strategyManager.totalPerformanceFeesPaidEVE(), totalPaidBefore + evesMinted);

        uint256 treasuryEveAfterSecond = token.balanceOf(DAO_TREASURY);
        _harvestFeeFromStrategy(strategy1);
        assertEq(token.balanceOf(DAO_TREASURY), treasuryEveAfterSecond);
    }

    function test_HarvestPerformanceFee_NoFeeWhenNothingPending() public {
        vm.prank(admin);
        strategyManager.setDaoTreasury(DAO_TREASURY);
        vm.prank(admin);
        strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        registry.grantRole(Auth.MINTER_ROLE, address(strategyManager));

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        _harvestFeeFromStrategy(strategy1);

        uint256 treasuryEveBefore = token.balanceOf(DAO_TREASURY);
        _harvestFeeFromStrategy(strategy1);
        assertEq(token.balanceOf(DAO_TREASURY), treasuryEveBefore);
    }

    /// @dev L-4 via MockStrategy: dust that rounds feeETH to 0 must not advance charged counters.
    ///      At PERFORMANCE_FEE_BPS = 2000, feeETH floors to 0 for any uncharged base < 5 wei.
    function test_HarvestPerformanceFee_DoesNotChargeWhenFeeRoundsToZero() public {
        _configurePerformanceFees();

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        uint256 dustBase = 4; // 4 * 2000 / 10000 = 0
        _accrueMockLpFees(mockStrategy1, dustBase);

        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);
        uint256 chargedBefore = mockStrategy1.cumulativeLpFeesChargedInETH();

        _harvestFeeFromStrategy(strategy1);

        assertEq(mockStrategy1.cumulativeLpFeesChargedInETH(), chargedBefore);
        assertEq(mockStrategy1.cumulativeLpFeesEarnedInETH() - chargedBefore, dustBase);

        // Grow the base just enough that feeETH becomes 1 wei (combined base = 5).
        _accrueMockLpFees(mockStrategy1, 5);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 1);

        uint256 treasuryBefore = token.balanceOf(DAO_TREASURY);
        _harvestFeeFromStrategy(strategy1);

        assertGt(token.balanceOf(DAO_TREASURY), treasuryBefore);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);
        assertEq(mockStrategy1.cumulativeLpFeesChargedInETH(), mockStrategy1.cumulativeLpFeesEarnedInETH());
    }

    function test_HarvestPerformanceFee_ClearsPendingAfterHarvest() public {
        vm.prank(admin);
        strategyManager.setDaoTreasury(DAO_TREASURY);
        vm.prank(admin);
        strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        registry.grantRole(Auth.MINTER_ROLE, address(strategyManager));

        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);

        assertEq(
            strategyManager.pendingPerformanceFeeInETH(strategy1),
            _expectedPendingFeeEth(LP_FEE_BASE_1, PERFORMANCE_FEE_BPS)
        );

        _harvestFeeFromStrategy(strategy1);

        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);
    }

    function test_HarvestPerformanceFee_AccessControl() public {
        vm.prank(admin);
        strategyManager.setDaoTreasury(DAO_TREASURY);
        vm.prank(admin);
        strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        registry.grantRole(Auth.MINTER_ROLE, address(strategyManager));

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientInvalidCaller.selector, Auth.CONTROLLER));
        strategyManager.harvestPerformanceFeeFromStrategy(strategy1);

        vm.prank(controller);
        strategyManager.harvestPerformanceFeeFromStrategy(strategy1);

        registry.grantRole(Auth.KEEPER_ROLE, user1);
        vm.prank(user1);
        controllerContract.harvestPerformanceFeeFromStrategy(strategy1);

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_3);
        vm.prank(admin);
        controllerContract.harvestPerformanceFeeFromStrategy(strategy1);
    }

    function test_HarvestPerformanceFee_WhenPaused_Reverts() public {
        vm.prank(admin);
        strategyManager.setDaoTreasury(DAO_TREASURY);
        vm.prank(admin);
        strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        registry.grantRole(Auth.MINTER_ROLE, address(strategyManager));

        strategyManager.pause();

        vm.prank(controller);
        vm.expectRevert();
        strategyManager.harvestPerformanceFeeFromStrategy(strategy1);

        vm.prank(controller);
        vm.expectRevert();
        strategyManager.harvestPerformanceFeeFromStrategies();

        vm.prank(controller);
        vm.expectRevert();
        strategyManager.harvestPerformanceFeeFromStrategies(0, 1);
    }

    function test_HarvestPerformanceFee_WhenStrategyPaused_ReturnsZero() public {
        _configurePerformanceFees();

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        registry.grantRole(Auth.MINTER_ROLE, address(strategyManager));

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        assertGt(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        mockStrategy1.setPaused(true);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        uint256 treasuryBefore = token.balanceOf(DAO_TREASURY);
        vm.prank(controller);
        (uint256 eveAmount, uint256 feeETH) = strategyManager.harvestPerformanceFeeFromStrategy(strategy1);
        assertEq(eveAmount, 0);
        assertEq(feeETH, 0);
        assertEq(token.balanceOf(DAO_TREASURY), treasuryBefore);

        mockStrategy1.setPaused(false);
        assertGt(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        vm.prank(controller);
        (eveAmount, feeETH) = strategyManager.harvestPerformanceFeeFromStrategy(strategy1);
        assertGt(eveAmount, 0);
        assertGt(feeETH, 0);
    }

    function test_HarvestPerformanceFeeFromStrategies_WithPagination() public {
        _configurePerformanceFees();

        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        strategyManager.addStrategy(strategy3, 40, 30);
        vm.stopPrank();

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        _accrueMockLpFees(mockStrategy2, LP_FEE_BASE_2);
        _accrueMockLpFees(mockStrategy3, LP_FEE_BASE_3);

        assertGt(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);
        assertGt(strategyManager.pendingPerformanceFeeInETH(strategy2), 0);
        assertGt(strategyManager.pendingPerformanceFeeInETH(strategy3), 0);

        uint256 treasuryBefore = token.balanceOf(DAO_TREASURY);
        _harvestFeesFromStrategies(0, 2);

        assertGt(token.balanceOf(DAO_TREASURY), treasuryBefore);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy2), 0);
        assertGt(strategyManager.pendingPerformanceFeeInETH(strategy3), 0);

        treasuryBefore = token.balanceOf(DAO_TREASURY);
        _harvestFeesFromStrategies(2, 3);

        assertGt(token.balanceOf(DAO_TREASURY), treasuryBefore);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy3), 0);
    }

    function test_HarvestPerformanceFeeFromStrategies_WithPagination_InvalidRange() public {
        _configurePerformanceFees();

        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        _accrueMockLpFees(mockStrategy2, LP_FEE_BASE_2);

        vm.prank(controller);
        vm.expectRevert(IStrategyManager.StrategyManagerInvalidRange.selector);
        strategyManager.harvestPerformanceFeeFromStrategies(0, 3);

        vm.prank(controller);
        vm.expectRevert(IStrategyManager.StrategyManagerInvalidRange.selector);
        strategyManager.harvestPerformanceFeeFromStrategies(1, 0);
    }

    function test_HarvestPerformanceFee_AllStrategies() public {
        vm.prank(admin);
        strategyManager.setDaoTreasury(DAO_TREASURY);
        vm.prank(admin);
        strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        vm.prank(admin);
        strategyManager.addStrategy(strategy2, 60, 50);

        registry.grantRole(Auth.MINTER_ROLE, address(strategyManager));

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        _accrueMockLpFees(mockStrategy2, LP_FEE_BASE_2);

        uint256 totalFeeETH = strategyManager.pendingPerformanceFeeInETH(strategy1)
            + strategyManager.pendingPerformanceFeeInETH(strategy2);

        uint256 expectedEves = _expectedEvesToMint(totalFeeETH);
        uint256 treasuryEveBefore = token.balanceOf(DAO_TREASURY);

        // Harvest from all strategies at once — one EVE mint for the summed feeETH
        _harvestAllFeesFromStrategies();

        assertEq(token.balanceOf(DAO_TREASURY) - treasuryEveBefore, expectedEves);
    }

    function test_HarvestPerformanceFeeFromStrategies_SingleBatchMint() public {
        _configurePerformanceFees();

        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        strategyManager.addStrategy(strategy3, 40, 30);
        vm.stopPrank();

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        _accrueMockLpFees(mockStrategy2, LP_FEE_BASE_2);
        _accrueMockLpFees(mockStrategy3, LP_FEE_BASE_3);

        uint256 totalFeeETH = strategyManager.pendingPerformanceFeeInETH(strategy1)
            + strategyManager.pendingPerformanceFeeInETH(strategy2) + strategyManager.pendingPerformanceFeeInETH(strategy3);

        uint256 expectedEves = _expectedEvesToMint(totalFeeETH);
        uint256 treasuryBefore = token.balanceOf(DAO_TREASURY);
        _harvestAllFeesFromStrategies();
        assertEq(token.balanceOf(DAO_TREASURY) - treasuryBefore, expectedEves);
    }

    function test_HarvestPerformanceFeeFromStrategies_PartialSuccess_WhenOneStrategyReverts() public {
        _configurePerformanceFees();

        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        _accrueMockLpFees(mockStrategy2, LP_FEE_BASE_2);
        mockStrategy1.setRevertSettlePerformanceFee(true);

        uint256 expectedFeeETH = strategyManager.pendingPerformanceFeeInETH(strategy2);
        uint256 expectedEves = _expectedEvesToMint(expectedFeeETH);
        uint256 treasuryBefore = token.balanceOf(DAO_TREASURY);

        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit IStrategyManager.StrategyHarvestFailed(
            strategy1, abi.encodeWithSelector(MockStrategy.MockStrategySettlePerformanceFeeReverted.selector)
        );
        vm.expectEmit(true, true, false, true, address(strategyManager));
        emit IStrategyManager.PerformanceFeePaid(strategy2, DAO_TREASURY, expectedEves, expectedFeeETH);

        vm.prank(controller);
        (uint256 eveAmount, uint256 feeETH) = strategyManager.harvestPerformanceFeeFromStrategies();

        assertEq(eveAmount, expectedEves);
        assertEq(feeETH, expectedFeeETH);
        assertEq(token.balanceOf(DAO_TREASURY) - treasuryBefore, expectedEves);
        assertGt(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy2), 0);
    }

    function test_HarvestPerformanceFeeFromStrategy_RevertsWhenSettleFails() public {
        _configurePerformanceFees();

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        mockStrategy1.setRevertSettlePerformanceFee(true);

        vm.prank(controller);
        vm.expectRevert(MockStrategy.MockStrategySettlePerformanceFeeReverted.selector);
        strategyManager.harvestPerformanceFeeFromStrategy(strategy1);
    }

    function test_WithdrawFromStrategies_ContinuesWhenPreWithdrawHarvestFails() public {
        _configurePerformanceFees();

        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        _accrueMockLpFees(mockStrategy2, LP_FEE_BASE_2);
        mockStrategy1.setRevertSettlePerformanceFee(true);

        vm.deal(strategy1, 10 ether);
        vm.deal(strategy2, 10 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);
        mockStrategy2.setMaxWithdrawal(5 ether);

        uint256 controllerBefore = controller.balance;

        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit IStrategyManager.StrategyHarvestFailed(
            strategy1, abi.encodeWithSelector(MockStrategy.MockStrategySettlePerformanceFeeReverted.selector)
        );

        vm.prank(controller);
        uint256 withdrawn = strategyManager.withdrawFromStrategies(10 ether);

        assertGt(withdrawn, 0);
        assertEq(controller.balance, controllerBefore + withdrawn);
        assertGt(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy2), 0);
    }

    function test_PendingPerformanceFeeInETH_NotRegistered() public {
        vm.expectRevert(IStrategyManager.StrategyManagerStrategyNotRegistered.selector);
        strategyManager.pendingPerformanceFeeInETH(strategy1);
    }

    function test_HarvestPerformanceFeeFromStrategy_NotRegistered() public {
        vm.prank(controller);
        vm.expectRevert(IStrategyManager.StrategyManagerStrategyNotRegistered.selector);
        strategyManager.harvestPerformanceFeeFromStrategy(strategy1);
    }

    function test_PendingPerformanceFeeInETH() public {
        vm.prank(admin);
        strategyManager.setDaoTreasury(DAO_TREASURY);
        vm.prank(admin);
        strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        registry.grantRole(Auth.MINTER_ROLE, address(strategyManager));

        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        vm.prank(admin);
        strategyManager.setPerformanceFeeBps(0);
        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        vm.prank(admin);
        strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);
        assertEq(
            strategyManager.pendingPerformanceFeeInETH(strategy1),
            _expectedPendingFeeEth(LP_FEE_BASE_1, PERFORMANCE_FEE_BPS)
        );

        _harvestFeeFromStrategy(strategy1);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_3);
        assertEq(
            strategyManager.pendingPerformanceFeeInETH(strategy1),
            _expectedPendingFeeEth(LP_FEE_BASE_3, PERFORMANCE_FEE_BPS)
        );
    }

    function test_AddStrategy_NoPhantomLpFeeOnRegistration() public {
        vm.prank(admin);
        strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        assertEq(
            strategyManager.pendingPerformanceFeeInETH(strategy1),
            _expectedPendingFeeEth(LP_FEE_BASE_1, PERFORMANCE_FEE_BPS)
        );
    }

    function test_RemoveReAddStrategy_PreservesStrategyFeeCounters() public {
        _configurePerformanceFees();

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        _harvestFeeFromStrategy(strategy1);

        for (uint256 i; i < 2; ++i) {
            mockStrategy1.setNavInETH(ALLOWED_NAV_RESIDUE);
            vm.prank(admin);
            strategyManager.removeStrategy(strategy1);

            mockStrategy1.setNavInETH(10e18);
            vm.prank(admin);
            strategyManager.addStrategy(strategy1, 80, 70);

            uint256 treasuryBeforeLoopHarvest = token.balanceOf(DAO_TREASURY);
            _harvestFeeFromStrategy(strategy1);
            assertEq(token.balanceOf(DAO_TREASURY), treasuryBeforeLoopHarvest);
        }

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_2);
        uint256 treasuryBefore = token.balanceOf(DAO_TREASURY);
        _harvestFeeFromStrategy(strategy1);
        assertGt(token.balanceOf(DAO_TREASURY), treasuryBefore);
    }

    /*//////////////////////////////////////////////////////////////
                    LP FEE ACCOUNTING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_LpFee_Deposit_DoesNotAccrueFee() public {
        _configurePerformanceFees();

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        uint256 depositAmount = 5 ether;
        mockStrategy1.setMaxDeposit(depositAmount);
        vm.deal(address(strategyManager), depositAmount);
        vm.prank(controller);
        strategyManager.depositToStrategy(strategy1, depositAmount);

        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        assertEq(
            strategyManager.pendingPerformanceFeeInETH(strategy1),
            _expectedPendingFeeEth(LP_FEE_BASE_1, PERFORMANCE_FEE_BPS)
        );
    }

    function test_LpFee_OnlyNewFeesAreChargeableAfterHarvest() public {
        _configurePerformanceFees();

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        _harvestFeeFromStrategy(strategy1);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_3);
        assertEq(
            strategyManager.pendingPerformanceFeeInETH(strategy1),
            _expectedPendingFeeEth(LP_FEE_BASE_3, PERFORMANCE_FEE_BPS)
        );
    }

    function test_LpFee_NavIncreaseWithoutLpFeesDoesNotAccrue() public {
        _configurePerformanceFees();

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        mockStrategy1.setNavInETH(37.5e18);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        mockStrategy1.setNavInETH(40e18);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);
    }

    /*//////////////////////////////////////////////////////////////
            WITHDRAWAL PERFORMANCE FEE FLOW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawFromStrategy_HarvestsPerformanceFeeBeforeWithdrawal() public {
        _configurePerformanceFees();

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        uint256 pendingFeeETH = strategyManager.pendingPerformanceFeeInETH(strategy1);
        uint256 expectedEves = _expectedEvesToMint(pendingFeeETH);

        vm.deal(strategy1, 10 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);

        uint256 treasuryBefore = token.balanceOf(DAO_TREASURY);
        uint256 controllerBefore = controller.balance;

        vm.expectEmit(true, true, false, true);
        emit IStrategyManager.PerformanceFeePaid(strategy1, DAO_TREASURY, expectedEves, pendingFeeETH);

        vm.prank(controller);
        uint256 withdrawn = strategyManager.withdrawFromStrategy(strategy1, 5 ether);

        assertEq(token.balanceOf(DAO_TREASURY) - treasuryBefore, expectedEves);
        assertEq(withdrawn, 5 ether);
        assertEq(controller.balance - controllerBefore, 5 ether);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);
    }

    function test_WithdrawFromStrategy_NoPerformanceFeeMintWithoutGains() public {
        _configurePerformanceFees();

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        vm.deal(strategy1, 10 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);

        uint256 treasuryBefore = token.balanceOf(DAO_TREASURY);
        uint256 controllerBefore = controller.balance;

        vm.prank(controller);
        uint256 withdrawn = strategyManager.withdrawFromStrategy(strategy1, 5 ether);

        assertEq(token.balanceOf(DAO_TREASURY), treasuryBefore);
        assertEq(withdrawn, 5 ether);
        assertEq(controller.balance - controllerBefore, 5 ether);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);
    }

    function test_WithdrawFromStrategy_SecondWithdrawOnlyFeesNewLpFees() public {
        _configurePerformanceFees();

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        vm.deal(strategy1, 20 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);

        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, 5 ether);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        uint256 treasuryAfterFirst = token.balanceOf(DAO_TREASURY);

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_3);
        uint256 pendingFeeETH = strategyManager.pendingPerformanceFeeInETH(strategy1);
        uint256 expectedEves = _expectedEvesToMint(pendingFeeETH);

        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, 5 ether);

        assertEq(token.balanceOf(DAO_TREASURY) - treasuryAfterFirst, expectedEves);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);
    }

    function test_WithdrawFromStrategy_NoDoubleChargeAfterHarvest() public {
        _configurePerformanceFees();

        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        vm.deal(strategy1, 10 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);

        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, 5 ether);

        uint256 treasuryAfterWithdraw = token.balanceOf(DAO_TREASURY);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, 3 ether);
        assertEq(token.balanceOf(DAO_TREASURY), treasuryAfterWithdraw);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);
    }

    function test_WithdrawFromStrategies_HarvestsPerformanceFeePerStrategy() public {
        _configurePerformanceFees();

        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        _accrueMockLpFees(mockStrategy2, LP_FEE_BASE_2);

        vm.deal(strategy1, 10 ether);
        vm.deal(strategy2, 10 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);
        mockStrategy2.setMaxWithdrawal(5 ether);

        uint256 pending1 = strategyManager.pendingPerformanceFeeInETH(strategy1);
        uint256 pending2 = strategyManager.pendingPerformanceFeeInETH(strategy2);
        assertGt(pending1, 0);
        assertGt(pending2, 0);

        uint256 treasuryBefore = token.balanceOf(DAO_TREASURY);

        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, 5 ether);
        assertGt(token.balanceOf(DAO_TREASURY), treasuryBefore);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);

        treasuryBefore = token.balanceOf(DAO_TREASURY);
        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy2, 5 ether);
        assertGt(token.balanceOf(DAO_TREASURY), treasuryBefore);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy2), 0);
    }

    function test_WithdrawFromStrategies_BatchWithdraw_HarvestsAndClearsPendingFees() public {
        _configurePerformanceFees();

        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        _accrueMockLpFees(mockStrategy2, LP_FEE_BASE_2);

        vm.deal(strategy1, 10 ether);
        vm.deal(strategy2, 10 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);
        mockStrategy2.setMaxWithdrawal(5 ether);

        assertGt(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);
        assertGt(strategyManager.pendingPerformanceFeeInETH(strategy2), 0);

        uint256 totalFeeETH = strategyManager.pendingPerformanceFeeInETH(strategy1)
            + strategyManager.pendingPerformanceFeeInETH(strategy2);
        uint256 expectedEves = _expectedEvesToMint(totalFeeETH);

        uint256 treasuryBefore = token.balanceOf(DAO_TREASURY);

        vm.prank(controller);
        strategyManager.withdrawFromStrategies(10 ether);

        assertEq(token.balanceOf(DAO_TREASURY) - treasuryBefore, expectedEves);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy1), 0);
        assertEq(strategyManager.pendingPerformanceFeeInETH(strategy2), 0);
    }

    /*//////////////////////////////////////////////////////////////
                   STRATEGY DEPOSIT COOLDOWN TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Registers strategy1 as healthy with deposit/withdraw capacity and enables the cooldown.
    function _setUpCooldownStrategy() internal {
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setMaxDeposit(10 ether);
        mockStrategy1.setIsHealthy(true);
        vm.deal(strategy1, 5 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);

        vm.prank(admin);
        strategyManager.setStrategyDepositCooldown(STRATEGY_DEPOSIT_COOLDOWN);
    }

    function test_SetStrategyDepositCooldown() public {
        vm.expectEmit(false, false, false, true, address(strategyManager));
        emit IStrategyManager.StrategyDepositCooldownUpdated(0, STRATEGY_DEPOSIT_COOLDOWN);

        vm.prank(admin);
        strategyManager.setStrategyDepositCooldown(STRATEGY_DEPOSIT_COOLDOWN);

        assertEq(strategyManager.strategyDepositCooldown(), STRATEGY_DEPOSIT_COOLDOWN);
    }

    function test_SetStrategyDepositCooldown_AccessControl() public {
        vm.prank(user1);
        vm.expectRevert();
        strategyManager.setStrategyDepositCooldown(STRATEGY_DEPOSIT_COOLDOWN);

        vm.prank(controller);
        vm.expectRevert();
        strategyManager.setStrategyDepositCooldown(STRATEGY_DEPOSIT_COOLDOWN);
    }

    function test_SetStrategyDepositCooldown_AtMax() public {
        uint256 maxCooldown = strategyManager.MAX_STRATEGY_DEPOSIT_COOLDOWN();

        vm.prank(admin);
        strategyManager.setStrategyDepositCooldown(maxCooldown);

        assertEq(strategyManager.strategyDepositCooldown(), maxCooldown);
    }

    function test_SetStrategyDepositCooldown_RevertsAboveMax() public {
        uint256 maxCooldown = strategyManager.MAX_STRATEGY_DEPOSIT_COOLDOWN();

        vm.prank(admin);
        vm.expectRevert(IStrategyManager.StrategyManagerInvalidStrategyDepositCooldown.selector);
        strategyManager.setStrategyDepositCooldown(maxCooldown + 1);
    }

    function test_StrategyDepositCooldown_DefaultDisabled_AllowsImmediateRedeposit() public {
        assertEq(strategyManager.strategyDepositCooldown(), 0);

        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setMaxDeposit(10 ether);
        mockStrategy1.setIsHealthy(true);
        vm.deal(strategy1, 5 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);

        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, 1 ether);

        // Cooldown disabled (default): immediate re-deposit keeps current behavior
        assertFalse(strategyManager.isStrategyInDepositCooldown(strategy1));

        vm.deal(controller, 1 ether);
        controllerContract.depositToStrategy(strategy1, 1 ether);

        assertEq(strategy1.balance, 5 ether);
    }

    function test_DepositToStrategy_RevertsDuringCooldown() public {
        _setUpCooldownStrategy();

        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, 1 ether);

        assertEq(strategyManager.lastStrategyWithdrawal(strategy1), block.timestamp);
        assertTrue(strategyManager.isStrategyInDepositCooldown(strategy1));

        vm.deal(controller, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyManager.StrategyManagerStrategyInDepositCooldown.selector, strategy1)
        );
        controllerContract.depositToStrategy(strategy1, 1 ether);
    }

    function test_DepositToStrategy_SucceedsAfterCooldownElapsed() public {
        _setUpCooldownStrategy();

        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, 1 ether);

        vm.warp(block.timestamp + STRATEGY_DEPOSIT_COOLDOWN);
        assertFalse(strategyManager.isStrategyInDepositCooldown(strategy1));

        vm.deal(controller, 1 ether);
        controllerContract.depositToStrategy(strategy1, 1 ether);

        assertEq(strategy1.balance, 5 ether);
    }

    function test_DepositToStrategy_CooldownEnabledWithoutPriorWithdrawal_Succeeds() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setMaxDeposit(10 ether);
        mockStrategy1.setIsHealthy(true);

        vm.prank(admin);
        strategyManager.setStrategyDepositCooldown(STRATEGY_DEPOSIT_COOLDOWN);

        // Never withdrawn from: not in cooldown even at low block.timestamp
        assertEq(strategyManager.lastStrategyWithdrawal(strategy1), 0);
        assertFalse(strategyManager.isStrategyInDepositCooldown(strategy1));

        vm.deal(controller, 1 ether);
        controllerContract.depositToStrategy(strategy1, 1 ether);

        assertEq(strategy1.balance, 1 ether);
    }

    function test_DepositToStrategies_SkipsStrategyInCooldown() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        mockStrategy1.setMaxDeposit(5 ether);
        mockStrategy2.setMaxDeposit(5 ether);
        mockStrategy1.setIsHealthy(true);
        mockStrategy2.setIsHealthy(true);

        vm.deal(strategy1, 2 ether);
        mockStrategy1.setMaxWithdrawal(2 ether);

        vm.prank(admin);
        strategyManager.setStrategyDepositCooldown(STRATEGY_DEPOSIT_COOLDOWN);

        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, 2 ether);
        assertEq(strategy1.balance, 0);

        vm.deal(controller, 10 ether);
        controllerContract.depositToStrategies(10 ether);

        // strategy1 is cooling down and skipped; strategy2 receives funds up to its maxDeposit
        assertEq(strategy1.balance, 0);
        assertEq(strategy2.balance, 5 ether);
    }

    function test_DepositToStrategies_AllInCooldown_RefundsController() public {
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setMaxDeposit(5 ether);
        mockStrategy1.setIsHealthy(true);
        vm.deal(strategy1, 2 ether);
        mockStrategy1.setMaxWithdrawal(2 ether);

        vm.prank(admin);
        strategyManager.setStrategyDepositCooldown(STRATEGY_DEPOSIT_COOLDOWN);

        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, 2 ether);

        vm.deal(controller, 10 ether);
        uint256 controllerBalanceBefore = controller.balance;
        controllerContract.depositToStrategies(10 ether);

        assertEq(controller.balance, controllerBalanceBefore);
        assertEq(strategy1.balance, 0);
    }

    function test_WithdrawFromStrategy_NotBlockedByCooldown() public {
        _setUpCooldownStrategy();

        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, 1 ether);
        assertTrue(strategyManager.isStrategyInDepositCooldown(strategy1));

        uint256 controllerBalanceBefore = controller.balance;

        // Withdrawals are exempt from the cooldown so exit liquidity is never blocked
        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, 1 ether);

        assertEq(controller.balance - controllerBalanceBefore, 1 ether);
    }

    function test_WithdrawFromStrategies_RecordsLastStrategyWithdrawal() public {
        vm.startPrank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        strategyManager.addStrategy(strategy2, 60, 50);
        vm.stopPrank();

        vm.deal(strategy1, 5 ether);
        vm.deal(strategy2, 5 ether);
        mockStrategy1.setMaxWithdrawal(5 ether);
        mockStrategy2.setMaxWithdrawal(5 ether);

        vm.prank(controller);
        strategyManager.withdrawFromStrategies(10 ether);

        assertEq(strategyManager.lastStrategyWithdrawal(strategy1), block.timestamp);
        assertEq(strategyManager.lastStrategyWithdrawal(strategy2), block.timestamp);
    }

    function test_EmergencyPaths_NotBlockedByCooldown() public {
        _setUpCooldownStrategy();

        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, 1 ether);
        assertTrue(strategyManager.isStrategyInDepositCooldown(strategy1));

        // emergencyWithdrawToController ignores the cooldown
        vm.deal(address(strategyManager), 1 ether);
        vm.prank(admin);
        strategyManager.emergencyWithdrawToController();
        assertEq(address(strategyManager).balance, 0);
    }

    function test_RemoveStrategy_PreservesLastStrategyWithdrawalAcrossReAdd() public {
        _setUpCooldownStrategy();

        vm.prank(controller);
        strategyManager.withdrawFromStrategy(strategy1, 1 ether);
        uint256 withdrawnAt = strategyManager.lastStrategyWithdrawal(strategy1);
        assertGt(withdrawnAt, 0);
        assertTrue(strategyManager.isStrategyInDepositCooldown(strategy1));

        mockStrategy1.setNavInETH(0);
        vm.prank(admin);
        strategyManager.removeStrategy(strategy1);

        // Cooldown clock is wall-clock on the address — not cleared on deregister
        assertEq(strategyManager.lastStrategyWithdrawal(strategy1), withdrawnAt);

        // Re-add while still inside the window: deposits must remain blocked
        vm.prank(admin);
        strategyManager.addStrategy(strategy1, 80, 70);
        mockStrategy1.setMaxDeposit(10 ether);
        mockStrategy1.setIsHealthy(true);

        assertTrue(strategyManager.isStrategyInDepositCooldown(strategy1));

        vm.deal(controller, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyManager.StrategyManagerStrategyInDepositCooldown.selector, strategy1)
        );
        controllerContract.depositToStrategy(strategy1, 1 ether);

        // After the window elapses, deposits succeed again
        vm.warp(withdrawnAt + STRATEGY_DEPOSIT_COOLDOWN);
        assertFalse(strategyManager.isStrategyInDepositCooldown(strategy1));

        controllerContract.depositToStrategy(strategy1, 1 ether);
        assertEq(strategy1.balance, 5 ether); // 4 ether left after withdraw + 1 ether redeposited
    }
}
