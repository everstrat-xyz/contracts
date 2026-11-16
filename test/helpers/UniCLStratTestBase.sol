// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, one-contract-per-file
// solhint-disable immutable-vars-naming, named-parameters-mapping, gas-custom-errors, gas-strict-inequalities
// solhint-disable gas-calldata-parameters, gas-small-strings
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Registry} from "registry/Registry.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {MockStrategyManagerStub} from "../mocks/MockStrategyManagerStub.sol";
import {UniCLStrat} from "../../src/contracts/strategies/UniCLStrat.sol";
import {Auth} from "../../src/libraries/Auth.sol";
import {ProtocolTestBase} from "./ProtocolTestBase.sol";
import {IUniCLStrat} from "../../src/interfaces/strategies/IUniCLStrat.sol";
import {IRegistryClient} from "interfaces/IRegistryClient.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {MockConverter} from "../mocks/MockConverter.sol";
import {MockConverterAdapter} from "../mocks/MockConverterAdapter.sol";
import {MockUniCLPool, MockWETH, MockUniswapV3Factory} from "../mocks/UniCLStratMocks.sol";
import {LiquidityAmounts} from "../../src/libraries/integrations/uniswap/LiquidityAmounts.sol";
import {TickMath} from "../../src/libraries/integrations/uniswap/TickMath.sol";

contract UniCLStratTestBase is ProtocolTestBase {
    uint256 public constant INITIAL_TIMESTAMP = 1_700_000_000;
    uint256 public constant MAX_TOTAL_NAV = 100 ether;
    uint256 public constant DEPOSIT_AMOUNT = 10 ether;
    uint256 public constant WITHDRAW_AMOUNT = 3 ether;
    uint256 public constant PERFORMANCE_FEE_BPS = 1_000;
    uint256 public constant MAX_SWAP_SLIPPAGE_BPS = 100;
    uint256 public constant TOKEN_PRICE = 1e8;
    uint256 public constant STALENESS_INTERVAL = 1 hours;
    uint8 public constant PAIRED_TOKEN_DECIMALS = 18;
    uint8 public constant PRICE_FEED_DECIMALS = 8;
    int24 public constant TICK_SPACING = 60;
    int24 public constant INITIAL_TICK = 0;
    int24 public constant POSITION_WIDTH = 2;
    int24 public constant REBALANCE_TICK_THRESHOLD = 30;
    int24 public constant UNHEALTHY_TICK = 60;
    int24 public constant NOT_CALM_TICK = 180;
    int56 public constant MAX_TICK_DEVIATION = 10;
    uint32 public constant TWAP_INTERVAL = 1800; // == MIN_TWAP_INTERVAL
    uint32 public constant SHORT_TWAP_INTERVAL = 60; // == MIN_SHORT_TWAP_INTERVAL
    bytes4 public constant REGISTRY_MISSING_ROLE_SELECTOR = bytes4(keccak256("RegistryClientMissingRole(bytes32)"));

    address public admin = makeAddr("admin");
    address public strategyManager;
    Registry public registry;
    address public daoTreasury = makeAddr("daoTreasury");
    address public receiver = makeAddr("receiver");
    address public user = makeAddr("user");

    MockWETH public weth;
    MockERC20 public pairedToken;
    MockUniCLPool public pool;
    MockUniswapV3Factory public factory;
    MockConverter public converter;
    MockConverterAdapter public swapAdapter;
    Oracle public oracle;
    UniCLStrat public strategy;

    receive() external payable {}

    function setUp() public virtual {
        vm.warp(INITIAL_TIMESTAMP);
        registry = _deployRegistry(admin);
        strategyManager = address(new MockStrategyManagerStub());
        _deployStrategy();
    }

    function _deployStrategy() internal {
        weth = new MockWETH();
        pairedToken = new MockERC20("Paired Token", "PAIR", PAIRED_TOKEN_DECIMALS);
        pool = new MockUniCLPool(address(weth), address(pairedToken), TICK_SPACING, INITIAL_TICK);
        factory = new MockUniswapV3Factory();
        factory.setPool(address(weth), address(pairedToken), pool.fee(), address(pool));
        converter = new MockConverter(weth, pairedToken, strategyManager);
        swapAdapter = new MockConverterAdapter(weth, pairedToken);
        oracle = _deployOracle();

        vm.startPrank(admin);
        registry.registerContract(Auth.ORACLE, address(oracle));
        registry.registerContract(Auth.CONVERTER, address(converter));
        registry.registerContract(Auth.STRATEGY_MANAGER, strategyManager);
        registry.grantRole(Auth.ADMIN_ROLE, admin);
        vm.stopPrank();

        strategy = new UniCLStrat(_defaultConfig());
    }

    function _deployOracle() internal returns (Oracle oracleContract) {
        Oracle implementation = new Oracle();
        bytes memory initData = abi.encodeWithSelector(Oracle.initialize.selector, address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        oracleContract = Oracle(address(proxy));

        MockPriceFeed ethPriceFeed = new MockPriceFeed(PRICE_FEED_DECIMALS, int256(TOKEN_PRICE));
        MockPriceFeed pairedTokenPriceFeed = new MockPriceFeed(PRICE_FEED_DECIMALS, int256(TOKEN_PRICE));

        vm.startPrank(admin);
        oracleContract.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);
        oracleContract.updateUsdFeedInfo(address(pairedToken), address(pairedTokenPriceFeed), STALENESS_INTERVAL);
        vm.stopPrank();
    }

    function _defaultConfig() internal view returns (IUniCLStrat.DeploymentConfig memory) {
        return IUniCLStrat.DeploymentConfig({
            addresses: IUniCLStrat.AddressConfig({
                registry: address(registry),
                weth: address(weth),
                pool: address(pool),
                factory: address(factory)
            }),
            routes: IUniCLStrat.RouteConfig({
                swapAdapter: address(swapAdapter),
                wethToPairedTokenPath: abi.encodePacked(address(weth), uint24(3000), address(pairedToken)),
                pairedTokenToWethPath: abi.encodePacked(address(pairedToken), uint24(3000), address(weth))
            }),
            strategy: IUniCLStrat.StrategyConfig({
                positionWidth: POSITION_WIDTH,
                rebalanceTickThreshold: REBALANCE_TICK_THRESHOLD,
                maxTickDeviation: MAX_TICK_DEVIATION,
                twapInterval: TWAP_INTERVAL,
                shortTwapInterval: SHORT_TWAP_INTERVAL,
                maxTotalNAV: MAX_TOTAL_NAV
            })
        });
    }

    function _deposit(uint256 _amount) internal {
        vm.deal(strategyManager, _amount);
        vm.prank(strategyManager);
        strategy.deposit{value: _amount}();
    }

    function _donate(uint256 _amount) internal {
        vm.deal(user, _amount);
        vm.prank(user);
        (bool success,) = address(strategy).call{value: _amount}("");
        require(success, "donation failed");
    }

    function _mainPosition() internal view returns (IUniCLStrat.Position memory position) {
        (position.tickLower, position.tickUpper) = strategy.positionMain();
    }

    /// @dev Paired-token inventory the strategy holds: idle balance plus both positions marked at
    ///      the TWAP tick plus owed. Mock oracle prices are 1:1, so this is also its ETH value.
    function _pairedInventory() internal view returns (uint256 amount) {
        amount = pairedToken.balanceOf(address(strategy));
        (int24 lower, int24 upper) = strategy.positionMain();
        amount += _pairedInPosition(lower, upper);
        (lower, upper) = strategy.positionAlt();
        amount += _pairedInPosition(lower, upper);
    }

    function _pairedInPosition(int24 _lower, int24 _upper) internal view returns (uint256) {
        if (_lower >= _upper) return 0;
        (uint128 liquidity, uint128 owed0, uint128 owed1,,) =
            pool.positionStates(keccak256(abi.encodePacked(address(strategy), _lower, _upper)));
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtRatioAtTick(pool.twapTick()),
            TickMath.getSqrtRatioAtTick(_lower),
            TickMath.getSqrtRatioAtTick(_upper),
            liquidity
        );
        return pool.token0() == address(pairedToken) ? amount0 + owed0 : amount1 + owed1;
    }

    /// @dev Independent restatement of the NAV exit-cost mark-down: pool fee tier (1e-6 units)
    ///      plus `swapSlippageBps`, applied to the paired-token value and rounded up.
    function _exitCost(uint256 _pairedValue) internal view returns (uint256) {
        uint256 costPips = uint256(pool.fee()) + strategy.swapSlippageBps() * 100;
        return (_pairedValue * costPips + 1e6 - 1) / 1e6;
    }

    /// @dev `navInETH()` with the exit-cost mark-down added back (inventory at oracle marks).
    function _grossNavInETH() internal view returns (uint256) {
        return strategy.navInETH() + _exitCost(_pairedInventory());
    }

    function _assertApproxEqAbs(uint256 _actual, uint256 _expected, uint256 _tolerance) internal pure {
        if (_actual > _expected) {
            require(_actual - _expected <= _tolerance, "ABOVE_TOLERANCE");
        } else {
            require(_expected - _actual <= _tolerance, "BELOW_TOLERANCE");
        }
    }

    function _expectMissingRole(bytes32 _role) internal {
        vm.expectRevert(abi.encodeWithSelector(REGISTRY_MISSING_ROLE_SELECTOR, _role));
    }

    function _expectCallerHasNoneOfRoles(bytes32 _primaryRole, bytes32 _secondaryRole) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IRegistryClient.RegistryClientCallerHasNoneOfRoles.selector, _primaryRole, _secondaryRole
            )
        );
    }

    function _expectInvalidCaller(bytes32 _contractKey) internal {
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientInvalidCaller.selector, _contractKey));
    }
}
