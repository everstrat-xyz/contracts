// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, func-name-mixedcase
// solhint-disable gas-small-strings
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {Registry} from "registry/Registry.sol";
import {Auth} from "../../src/libraries/Auth.sol";
import {Converter} from "../../src/contracts/Converter.sol";
import {IConverter} from "../../src/interfaces/IConverter.sol";
import {IRegistryClient} from "interfaces/IRegistryClient.sol";
import {UniswapV3ConverterAdapter} from "../../src/contracts/adapters/UniswapV3ConverterAdapter.sol";
import {IUniswapV3ConverterAdapter} from "../../src/interfaces/adapters/IUniswapV3ConverterAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockConverterAdapter} from "../mocks/MockConverterAdapter.sol";
import {MockSimpleOracle} from "../mocks/MockSimpleOracle.sol";
import {MockWETH, MockUniCLPool, MockUniCLRouter, MockUniswapV3Factory} from "../mocks/UniCLStratMocks.sol";

// ================================
// ConverterTestBase
// ================================

contract ConverterTestBase is Test {
    using SafeERC20 for IERC20;

    // -------- Constants --------
    uint256 public constant VALID_AMOUNT = 10 ether;
    uint256 public constant LARGE_AMOUNT = 1000 ether;
    uint256 public constant DUST_AMOUNT = 1 wei;
    uint256 public constant SWAP_AMOUNT = 10 ether;
    uint256 public constant WRAP_AMOUNT = 10 ether;
    uint256 public constant DEADLINE_FAR = type(uint256).max;

    // For a 1:1 mock router, output == input. These are caller-supplied slippage bounds.
    uint256 public constant MIN_OUT_EXACT = SWAP_AMOUNT;
    uint256 public constant MIN_OUT_ZERO = 0;
    uint256 public constant MIN_OUT_TOO_HIGH = SWAP_AMOUNT + 1;

    // TWAP + Chainlink quote parameters. The mock pool sits at tick 0 (1:1 price) and the
    // mock oracle prices both tokens at $1, so the TWAP quote equals the input net of the pool fee.
    uint24 public constant POOL_FEE = 3000;
    uint256 public constant POOL_FEE_DENOMINATOR = 1_000_000;
    int24 public constant POOL_TICK_SPACING = 60;
    int24 public constant POOL_INITIAL_TICK = 0;
    uint32 public constant TWAP_INTERVAL = 1800;
    uint256 public constant ORACLE_PRICE_USD = 1e18;
    uint256 public constant EXPECTED_QUOTE_OUT = SWAP_AMOUNT * (POOL_FEE_DENOMINATOR - POOL_FEE) / POOL_FEE_DENOMINATOR;
    uint256 public constant EXPECTED_QUOTE_IN = SWAP_AMOUNT * POOL_FEE_DENOMINATOR / (POOL_FEE_DENOMINATOR - POOL_FEE);

    bytes32 public constant ROUTE_ID_1 = keccak256("route_weth_to_pair");
    bytes32 public constant ROUTE_ID_2 = keccak256("route_pair_to_weth");
    bytes32 public constant ROUTE_ID_EMPTY = bytes32(0);

    bytes4 public constant REGISTRY_CLIENT_MISSING_ROLE_SELECTOR =
        bytes4(keccak256("RegistryClientMissingRole(bytes32)"));
    bytes4 public constant REGISTRY_CLIENT_INVALID_CALLER_SELECTOR =
        bytes4(keccak256("RegistryClientInvalidCaller(bytes32)"));

    // -------- Addresses --------
    address public admin;
    address public caller;
    address public unauthorized;
    address public receiver;
    address public strategyManager;

    // -------- Contracts --------
    Registry public registry;
    Converter public converter;
    Converter public implementation;
    MockWETH public weth;
    MockERC20 public pairedToken;
    MockUniCLRouter public router;
    MockUniCLPool public pool;
    MockUniswapV3Factory public factory;
    MockSimpleOracle public oracle;
    UniswapV3ConverterAdapter public adapter;

    bytes public wethToPairedPath;
    bytes public pairedToWethPath;

    receive() external payable {}

    function setUp() public virtual {
        admin = address(this);
        caller = makeAddr("caller");
        unauthorized = makeAddr("unauthorized");
        receiver = makeAddr("receiver");
        strategyManager = makeAddr("strategyManager");

        _deployMocks();
        // Create registry before deploying the Converter so it can be wired in
        registry = _deployRegistryWithAdmin(admin);
        _deployConverter();
        registry.registerContract(Auth.CONVERTER, address(converter));
        // Give strategyManager address dummy code so Registry accepts it
        vm.etch(strategyManager, hex"01");
        registry.registerContract(Auth.STRATEGY_MANAGER, strategyManager);
        // Grant CONVERTER_CALLER_MANAGER_ROLE to the Converter (admin is ADMIN_ROLE) so that
        // grantCallerRole/revokeCallerRole can administer CONVERTER_CALLER_ROLE on the Registry.
        {
            bytes32[] memory initRoles = new bytes32[](1);
            address[] memory initAccounts = new address[](1);
            initRoles[0] = Auth.CONVERTER_CALLER_MANAGER_ROLE;
            initAccounts[0] = address(converter);
            registry.grantRoles(initRoles, initAccounts);
        }

        converter.setAllowedAdapter(address(adapter), true);
        // Simulate StrategyManager granting caller permission via Converter → Registry
        _grantCallerRole(caller);
    }

    function _deployMocks() internal {
        weth = new MockWETH();
        pairedToken = new MockERC20("Paired Token", "PAIR", 18);
        router = new MockUniCLRouter(weth, pairedToken);
        pool = new MockUniCLPool(address(weth), address(pairedToken), POOL_TICK_SPACING, POOL_INITIAL_TICK);
        factory = new MockUniswapV3Factory();
        factory.setPool(address(weth), address(pairedToken), POOL_FEE, address(pool));
        oracle = new MockSimpleOracle();
        oracle.setPrice(address(0), ORACLE_PRICE_USD);
        oracle.setPrice(address(pairedToken), ORACLE_PRICE_USD);
        adapter = _newAdapter();

        wethToPairedPath = abi.encodePacked(address(weth), POOL_FEE, address(pairedToken));
        pairedToWethPath = abi.encodePacked(address(pairedToken), POOL_FEE, address(weth));
    }

    function _newAdapter() internal returns (UniswapV3ConverterAdapter) {
        return new UniswapV3ConverterAdapter(
            address(router), address(factory), address(oracle), address(weth), TWAP_INTERVAL
        );
    }

    function _deployConverter() internal {
        implementation = new Converter();
        bytes memory initData = abi.encodeWithSelector(Converter.initialize.selector, address(registry), address(weth));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        converter = Converter(payable(address(proxy)));
    }

    // -------- Helpers --------

    /// @dev The Registry constructor rejects `_admin == msg.sender`; deploy through a
    ///      dedicated bootstrap key and renounce its temporary ADMIN_ROLE so `_admin`
    ///      (this test contract) ends as the sole admin.
    function _deployRegistryWithAdmin(address _admin) internal returns (Registry _registry) {
        address bootstrapDeployer = makeAddr("registryBootstrapDeployer");
        vm.prank(bootstrapDeployer);
        _registry = new Registry(_admin);
        vm.prank(bootstrapDeployer);
        _registry.renounceRole(Auth.ADMIN_ROLE, bootstrapDeployer);
    }

    function _grantCallerRole(address _account) internal {
        vm.prank(strategyManager);
        converter.grantCallerRole(_account);
    }

    function _revokeCallerRole(address _account) internal {
        vm.prank(strategyManager);
        converter.revokeCallerRole(_account);
    }

    function _fundCallerWETH(uint256 _amount) internal {
        vm.deal(caller, _amount);
        vm.prank(caller);
        weth.deposit{value: _amount}();
    }

    function _fundCallerPairedToken(uint256 _amount) internal {
        vm.prank(caller);
        pairedToken.mint(caller, _amount);
    }

    function _approveConverterForCallerWETH(uint256 _amount) internal {
        vm.prank(caller);
        IERC20(address(weth)).forceApprove(address(converter), _amount);
    }

    function _approveConverterForCallerPairedToken(uint256 _amount) internal {
        vm.prank(caller);
        IERC20(address(pairedToken)).forceApprove(address(converter), _amount);
    }

    function _setupCallerForSwap(address _tokenIn, uint256 _amount) internal {
        if (_tokenIn == address(weth)) {
            _fundCallerWETH(_amount);
            _approveConverterForCallerWETH(_amount);
        } else {
            _fundCallerPairedToken(_amount);
            _approveConverterForCallerPairedToken(_amount);
        }
    }

    function _expectRegistryMissingRoleRevert(bytes32 _role) internal {
        vm.expectRevert(abi.encodeWithSelector(REGISTRY_CLIENT_MISSING_ROLE_SELECTOR, _role));
    }

    function _expectCallerHasNoneOfRoles(bytes32 _primaryRole, bytes32 _secondaryRole) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IRegistryClient.RegistryClientCallerHasNoneOfRoles.selector, _primaryRole, _secondaryRole
            )
        );
    }

    function _expectRegistryInvalidCallerRevert(bytes32 _contractKey) internal virtual {
        vm.expectRevert(abi.encodeWithSelector(REGISTRY_CLIENT_INVALID_CALLER_SELECTOR, _contractKey));
    }
}

// ================================
// ConverterInitializeTest
// ================================

contract ConverterInitializeTest is ConverterTestBase {
    function setUp() public override {
        admin = address(this);
        caller = makeAddr("caller");
        unauthorized = makeAddr("unauthorized");
        receiver = makeAddr("receiver");
        _deployMocks();
        registry = _deployRegistryWithAdmin(admin);
    }

    function _deployFresh(address _registry, address _wethAddr) internal returns (Converter) {
        Converter impl = new Converter();
        bytes memory initData = abi.encodeWithSelector(Converter.initialize.selector, _registry, _wethAddr);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return Converter(payable(address(proxy)));
    }

    function test_Initialize_RevertsWhenRegistryIsZero() public {
        Converter impl = new Converter();
        bytes memory initData = abi.encodeWithSelector(Converter.initialize.selector, address(0), address(weth));
        vm.expectRevert(IRegistryClient.RegistryClientZeroRegistry.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertsWhenWethAddressIsZero() public {
        Converter impl = new Converter();
        bytes memory initData = abi.encodeWithSelector(Converter.initialize.selector, address(registry), address(0));
        vm.expectRevert(IConverter.ConverterZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_WithValidParameters() public {
        vm.expectEmit(true, true, false, true);
        emit IConverter.ConverterInitialized(address(registry), address(weth));

        Converter c = _deployFresh(address(registry), address(weth));

        assertEq(c.weth(), address(weth));
        assertTrue(c.isCaller(address(this)) == false);
    }

    function test_Initialize_RevertsWhenAlreadyInitialized() public {
        _deployConverter();
        bytes memory initData = abi.encodeWithSelector(Converter.initialize.selector, address(registry), address(weth));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        address(converter).call(initData);
    }
}

// ================================
// ConverterReceiveTest
// ================================

contract ConverterReceiveTest is ConverterTestBase {
    function test_Receive_AcceptsETH() public {
        vm.deal(address(this), VALID_AMOUNT);
        payable(address(converter)).call{value: VALID_AMOUNT}("");
        assertEq(address(converter).balance, VALID_AMOUNT);
    }

    function test_Receive_UpdatesBalance() public {
        uint256 initialBalance = address(converter).balance;
        vm.deal(address(this), VALID_AMOUNT);
        payable(address(converter)).call{value: VALID_AMOUNT}("");
        assertEq(address(converter).balance, initialBalance + VALID_AMOUNT);
    }

    function test_Receive_WhenPaused_StillAcceptsETH() public {
        converter.pause();
        vm.deal(address(this), VALID_AMOUNT);
        payable(address(converter)).call{value: VALID_AMOUNT}("");
        assertEq(address(converter).balance, VALID_AMOUNT);
    }
}

// ================================
// ConverterWrapETHTest
// ================================

contract ConverterWrapETHTest is ConverterTestBase {
    function test_WrapETH_RevertsWhenCallerNotCaller() public {
        vm.deal(unauthorized, 1);
        _expectRegistryMissingRoleRevert(Auth.CONVERTER_CALLER_ROLE);
        vm.prank(unauthorized);
        converter.wrapETH{value: 1}();
    }

    function test_WrapETH_RevertsWhenPaused() public {
        converter.pause();
        vm.deal(caller, VALID_AMOUNT);
        vm.expectRevert();
        vm.prank(caller);
        converter.wrapETH{value: VALID_AMOUNT}();
    }

    function test_WrapETH_ZeroAmount_NoOp() public {
        vm.prank(caller);
        converter.wrapETH{value: 0}();
        assertEq(weth.balanceOf(caller), 0);
        assertEq(address(converter).balance, 0);
    }

    function test_WrapETH_ValidAmount() public {
        vm.deal(caller, VALID_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit IConverter.ETHWrapped(caller, VALID_AMOUNT);

        vm.prank(caller);
        converter.wrapETH{value: VALID_AMOUNT}();

        assertEq(weth.balanceOf(caller), VALID_AMOUNT);
        assertEq(address(converter).balance, 0);
    }

    function test_WrapETH_DustAmount() public {
        vm.deal(caller, DUST_AMOUNT);
        vm.prank(caller);
        converter.wrapETH{value: DUST_AMOUNT}();
        assertEq(weth.balanceOf(caller), DUST_AMOUNT);
    }

    function test_WrapETH_LargeAmount() public {
        vm.deal(caller, LARGE_AMOUNT);
        vm.prank(caller);
        converter.wrapETH{value: LARGE_AMOUNT}();
        assertEq(weth.balanceOf(caller), LARGE_AMOUNT);
    }

    function test_WrapETH_MultipleSequentialWraps() public {
        vm.deal(caller, VALID_AMOUNT + DUST_AMOUNT);

        vm.prank(caller);
        converter.wrapETH{value: VALID_AMOUNT}();
        assertEq(weth.balanceOf(caller), VALID_AMOUNT);

        vm.prank(caller);
        converter.wrapETH{value: DUST_AMOUNT}();
        assertEq(weth.balanceOf(caller), VALID_AMOUNT + DUST_AMOUNT);
    }

    function test_WrapETH_MaintainsContractBalance() public {
        vm.deal(caller, VALID_AMOUNT);
        vm.deal(address(this), VALID_AMOUNT / 2);
        payable(address(converter)).call{value: VALID_AMOUNT / 2}("");

        uint256 preWrapConverterBalance = address(converter).balance;

        vm.prank(caller);
        converter.wrapETH{value: VALID_AMOUNT}();

        assertEq(address(converter).balance, preWrapConverterBalance);
    }
}

// ================================
// ConverterUnwrapWETHTest
// ================================

contract ConverterUnwrapWETHTest is ConverterTestBase {
    function setUp() public override {
        super.setUp();
        _fundCallerWETH(VALID_AMOUNT);
        _approveConverterForCallerWETH(VALID_AMOUNT);
    }

    function test_UnwrapWETH_RevertsWhenCallerNotCaller() public {
        _expectRegistryMissingRoleRevert(Auth.CONVERTER_CALLER_ROLE);
        vm.prank(unauthorized);
        converter.unwrapWETH(VALID_AMOUNT, receiver);
    }

    function test_UnwrapWETH_RevertsWhenPaused() public {
        converter.pause();
        vm.expectRevert();
        vm.prank(caller);
        converter.unwrapWETH(VALID_AMOUNT, receiver);
    }

    function test_UnwrapWETH_ZeroAmount_NoOp() public {
        uint256 callerBalanceBefore = weth.balanceOf(caller);
        uint256 converterBalanceBefore = weth.balanceOf(address(converter));
        uint256 receiverBalanceBefore = receiver.balance;

        vm.prank(caller);
        converter.unwrapWETH(0, receiver);

        assertEq(weth.balanceOf(caller), callerBalanceBefore);
        assertEq(weth.balanceOf(address(converter)), converterBalanceBefore);
        assertEq(receiver.balance, receiverBalanceBefore);
    }

    function test_UnwrapWETH_RevertsWhenReceiverIsZero() public {
        vm.expectRevert(IConverter.ConverterZeroAddress.selector);
        vm.prank(caller);
        converter.unwrapWETH(VALID_AMOUNT, address(0));
    }

    function test_UnwrapWETH_RevertsWhenInsufficientWETHBalance() public {
        address poorCaller = makeAddr("poorCaller");
        _grantCallerRole(poorCaller);
        vm.prank(poorCaller);
        IERC20(address(weth)).approve(address(converter), VALID_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")), poorCaller, 0, VALID_AMOUNT
            )
        );
        vm.prank(poorCaller);
        converter.unwrapWETH(VALID_AMOUNT, receiver);
    }

    function test_UnwrapWETH_RevertsWhenInsufficientAllowance() public {
        address noAllowCaller = makeAddr("noAllowCaller");
        _grantCallerRole(noAllowCaller);
        _fundCallerWETH(VALID_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientAllowance(address,uint256,uint256)")),
                address(converter),
                0,
                VALID_AMOUNT
            )
        );
        vm.prank(noAllowCaller);
        converter.unwrapWETH(VALID_AMOUNT, receiver);
    }

    function test_UnwrapWETH_ValidAmount() public {
        uint256 callerWethBefore = weth.balanceOf(caller);
        uint256 receiverEthBefore = receiver.balance;

        vm.expectEmit(true, true, false, true);
        emit IConverter.WETHUnwrapped(caller, receiver, VALID_AMOUNT);

        vm.prank(caller);
        converter.unwrapWETH(VALID_AMOUNT, receiver);

        assertEq(weth.balanceOf(caller), callerWethBefore - VALID_AMOUNT);
        assertEq(weth.balanceOf(address(converter)), 0);
        assertEq(receiver.balance, receiverEthBefore + VALID_AMOUNT);
    }

    function test_UnwrapWETH_ToSelf() public {
        uint256 callerWethBefore = weth.balanceOf(caller);
        uint256 callerEthBefore = caller.balance;

        vm.prank(caller);
        converter.unwrapWETH(VALID_AMOUNT, caller);

        assertEq(weth.balanceOf(caller), callerWethBefore - VALID_AMOUNT);
        assertEq(caller.balance, callerEthBefore + VALID_AMOUNT);
    }

    function test_UnwrapWETH_ToDifferentReceiver() public {
        uint256 callerWethBefore = weth.balanceOf(caller);
        uint256 callerEthBefore = caller.balance;
        uint256 receiverEthBefore = receiver.balance;

        vm.prank(caller);
        converter.unwrapWETH(VALID_AMOUNT, receiver);

        assertEq(weth.balanceOf(caller), callerWethBefore - VALID_AMOUNT);
        assertEq(caller.balance, callerEthBefore);
        assertEq(receiver.balance, receiverEthBefore + VALID_AMOUNT);
    }
}

// ================================
// ConverterExecuteSwapTest
// ================================

contract ConverterExecuteSwapTest is ConverterTestBase {
    function setUp() public override {
        super.setUp();
        _setupCallerForSwap(address(weth), SWAP_AMOUNT);
    }

    function test_ExecuteSwap_RevertsWhenCallerNotCaller() public {
        _expectRegistryMissingRoleRevert(Auth.CONVERTER_CALLER_ROLE);
        vm.prank(unauthorized);
        converter.executeSwapExactAmountIn(address(adapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_EXACT, DEADLINE_FAR);
    }

    function test_ExecuteSwap_RevertsWhenPaused() public {
        converter.pause();
        vm.expectRevert();
        vm.prank(caller);
        converter.executeSwapExactAmountIn(address(adapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_EXACT, DEADLINE_FAR);
    }

    function test_ExecuteSwap_ZeroAmount_ReturnsZero() public {
        vm.prank(caller);
        uint256 result =
            converter.executeSwapExactAmountIn(address(adapter), wethToPairedPath, 0, MIN_OUT_ZERO, DEADLINE_FAR);
        assertEq(result, 0);
    }

    function test_ExecuteSwap_RevertsWhenDeadlineExpired() public {
        vm.warp(1000);
        vm.expectRevert(IConverter.ConverterDeadlineExpired.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountIn(address(adapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_EXACT, 999);
    }

    function test_ExecuteSwap_RevertsWhenAdapterNotAllowed() public {
        UniswapV3ConverterAdapter rogue = _newAdapter();
        vm.expectRevert(IConverter.ConverterAdapterNotAllowed.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountIn(address(rogue), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_EXACT, DEADLINE_FAR);
    }

    function test_ExecuteSwap_RevertsWhenRoutePathInvalid() public {
        bytes memory invalidPath = abi.encodePacked(address(weth));
        vm.expectRevert(IConverter.ConverterInvalidRoute.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountIn(address(adapter), invalidPath, SWAP_AMOUNT, MIN_OUT_EXACT, DEADLINE_FAR);
    }

    function test_ExecuteSwap_RevertsWhenInsufficientTokenInBalance() public {
        address poorCaller = makeAddr("poorSwapCaller");
        _grantCallerRole(poorCaller);
        vm.prank(poorCaller);
        IERC20(address(weth)).approve(address(converter), SWAP_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")), poorCaller, 0, SWAP_AMOUNT
            )
        );
        vm.prank(poorCaller);
        converter.executeSwapExactAmountIn(address(adapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_EXACT, DEADLINE_FAR);
    }

    function test_ExecuteSwap_RevertsWhenInsufficientAllowance() public {
        address noAllowCaller = makeAddr("noAllowSwapCaller");
        _grantCallerRole(noAllowCaller);
        _fundCallerWETH(SWAP_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientAllowance(address,uint256,uint256)")),
                address(converter),
                0,
                SWAP_AMOUNT
            )
        );
        vm.prank(noAllowCaller);
        converter.executeSwapExactAmountIn(address(adapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_EXACT, DEADLINE_FAR);
    }

    function test_ExecuteSwap_RevertsWhenOutputBelowMinimum() public {
        vm.expectRevert(IConverter.ConverterInsufficientOutput.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountIn(
            address(adapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_TOO_HIGH, DEADLINE_FAR
        );
    }

    function test_ExecuteSwap_SuccessfulSwap() public {
        uint256 callerWethBefore = weth.balanceOf(caller);
        uint256 callerPairedBefore = pairedToken.balanceOf(caller);

        vm.expectEmit(true, true, true, true);
        emit IConverter.SwapExecuted(caller, address(weth), address(pairedToken), SWAP_AMOUNT, SWAP_AMOUNT);

        vm.prank(caller);
        uint256 amountOut = converter.executeSwapExactAmountIn(
            address(adapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_EXACT, DEADLINE_FAR
        );

        assertEq(weth.balanceOf(caller), callerWethBefore - SWAP_AMOUNT);
        assertEq(pairedToken.balanceOf(caller), callerPairedBefore + amountOut);
        assertEq(amountOut, SWAP_AMOUNT);
        assertEq(router.lastAmountIn(), SWAP_AMOUNT);
        assertEq(router.lastDeadline(), DEADLINE_FAR);
        assertEq(router.lastAmountOutMinimum(), MIN_OUT_EXACT);
    }

    function test_ExecuteSwap_ZeroMinOut() public {
        vm.prank(caller);
        uint256 amountOut = converter.executeSwapExactAmountIn(
            address(adapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_ZERO, DEADLINE_FAR
        );
        assertEq(amountOut, SWAP_AMOUNT);
    }

    function test_ExecuteSwap_DeadlineAtBlockTimestamp() public {
        vm.prank(caller);
        uint256 amountOut = converter.executeSwapExactAmountIn(
            address(adapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_EXACT, block.timestamp
        );
        assertEq(amountOut, SWAP_AMOUNT);
    }

    function test_ExecuteSwap_MultiHopPath_FailsAtUnknownRouter() public {
        MockERC20 tokenA = new MockERC20("Token A", "TA", 18);
        bytes memory multiHopPath =
            abi.encodePacked(address(weth), uint24(3000), address(tokenA), uint24(3000), address(pairedToken));

        vm.expectRevert(IConverter.ConverterInvalidRoute.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountIn(address(adapter), multiHopPath, SWAP_AMOUNT, MIN_OUT_ZERO, DEADLINE_FAR);
    }

    function test_ExecuteSwap_RevertsWhenAdapterDeWhitelisted() public {
        converter.setAllowedAdapter(address(adapter), false);

        vm.expectRevert(IConverter.ConverterAdapterNotAllowed.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountIn(address(adapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_EXACT, DEADLINE_FAR);
    }
}

// ================================
// ConverterMockAdapterSwapTest
// ================================

contract ConverterMockAdapterSwapTest is ConverterTestBase {
    MockConverterAdapter public mockAdapter;

    function setUp() public override {
        super.setUp();
        mockAdapter = new MockConverterAdapter(weth, pairedToken);
        converter.setAllowedAdapter(address(mockAdapter), true);
        _setupCallerForSwap(address(weth), SWAP_AMOUNT);
    }

    function test_Swap_RevertsWhenAdapterSwapReverts() public {
        mockAdapter.setShouldRevertSwap(true);
        vm.expectRevert(IConverter.ConverterSwapFailed.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountIn(
            address(mockAdapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_ZERO, DEADLINE_FAR
        );
    }

    function test_Swap_RevertsWhenOutputBelowMinimum() public {
        mockAdapter.setOutputMultiplier(5e17);
        vm.expectRevert(IConverter.ConverterInsufficientOutput.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountIn(
            address(mockAdapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_EXACT, DEADLINE_FAR
        );
    }

    function test_Swap_SucceedsThroughMockAdapter() public {
        vm.prank(caller);
        uint256 amountOut = converter.executeSwapExactAmountIn(
            address(mockAdapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_EXACT, DEADLINE_FAR
        );
        assertEq(amountOut, SWAP_AMOUNT);
        assertEq(pairedToken.balanceOf(caller), SWAP_AMOUNT);
    }

    function test_Swap_RevertsWhenAdapterRouteTokensReverts() public {
        mockAdapter.setShouldRevertRouteTokens(true);
        vm.expectRevert(IConverter.ConverterAdapterCallFailed.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountIn(
            address(mockAdapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_ZERO, DEADLINE_FAR
        );
    }

    function test_RouteTokens_RevertsWhenAdapterRouteTokensReverts() public {
        mockAdapter.setShouldRevertRouteTokens(true);
        vm.expectRevert(IConverter.ConverterAdapterCallFailed.selector);
        converter.routeTokens(address(mockAdapter), wethToPairedPath);
    }

    function test_QuoteSwap_RevertsWhenAdapterQuoteReverts() public {
        mockAdapter.setShouldRevertQuote(true);
        vm.expectRevert(IConverter.ConverterAdapterCallFailed.selector);
        vm.prank(caller);
        converter.quoteSwapExactAmountIn(address(mockAdapter), wethToPairedPath, SWAP_AMOUNT);
    }
}

// ================================
// ConverterExecuteSwapExactAmountOutTest
// ================================

contract ConverterExecuteSwapExactAmountOutTest is ConverterTestBase {
    function setUp() public override {
        super.setUp();
        _setupCallerForSwap(address(weth), SWAP_AMOUNT);
    }

    function test_ExecuteSwapExactAmountOut_RevertsWhenCallerNotCaller() public {
        _expectRegistryMissingRoleRevert(Auth.CONVERTER_CALLER_ROLE);
        vm.prank(unauthorized);
        converter.executeSwapExactAmountOut(address(adapter), wethToPairedPath, SWAP_AMOUNT, SWAP_AMOUNT, DEADLINE_FAR);
    }

    function test_ExecuteSwapExactAmountOut_RevertsWhenPaused() public {
        converter.pause();
        vm.expectRevert();
        vm.prank(caller);
        converter.executeSwapExactAmountOut(address(adapter), wethToPairedPath, SWAP_AMOUNT, SWAP_AMOUNT, DEADLINE_FAR);
    }

    function test_ExecuteSwapExactAmountOut_ZeroAmountOut_ReturnsZero() public {
        vm.prank(caller);
        uint256 result =
            converter.executeSwapExactAmountOut(address(adapter), wethToPairedPath, 0, SWAP_AMOUNT, DEADLINE_FAR);
        assertEq(result, 0);
    }

    function test_ExecuteSwapExactAmountOut_RevertsWhenDeadlineExpired() public {
        vm.warp(1000);
        vm.expectRevert(IConverter.ConverterDeadlineExpired.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountOut(address(adapter), wethToPairedPath, SWAP_AMOUNT, SWAP_AMOUNT, 999);
    }

    function test_ExecuteSwapExactAmountOut_RevertsWhenAdapterNotAllowed() public {
        UniswapV3ConverterAdapter rogue = _newAdapter();
        vm.expectRevert(IConverter.ConverterAdapterNotAllowed.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountOut(address(rogue), wethToPairedPath, SWAP_AMOUNT, SWAP_AMOUNT, DEADLINE_FAR);
    }

    function test_ExecuteSwapExactAmountOut_RevertsWhenRoutePathInvalid() public {
        bytes memory invalidPath = abi.encodePacked(address(weth));
        vm.expectRevert(IConverter.ConverterInvalidRoute.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountOut(address(adapter), invalidPath, SWAP_AMOUNT, SWAP_AMOUNT, DEADLINE_FAR);
    }

    function test_ExecuteSwapExactAmountOut_RevertsWhenInsufficientTokenInBalance() public {
        address poorCaller = makeAddr("poorExactOutCaller");
        _grantCallerRole(poorCaller);
        vm.prank(poorCaller);
        IERC20(address(weth)).approve(address(converter), SWAP_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")), poorCaller, 0, SWAP_AMOUNT
            )
        );
        vm.prank(poorCaller);
        converter.executeSwapExactAmountOut(address(adapter), wethToPairedPath, SWAP_AMOUNT, SWAP_AMOUNT, DEADLINE_FAR);
    }

    function test_ExecuteSwapExactAmountOut_RevertsWhenInsufficientAllowance() public {
        address noAllowCaller = makeAddr("noAllowExactOutCaller");
        _grantCallerRole(noAllowCaller);
        _fundCallerWETH(SWAP_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientAllowance(address,uint256,uint256)")),
                address(converter),
                0,
                SWAP_AMOUNT
            )
        );
        vm.prank(noAllowCaller);
        converter.executeSwapExactAmountOut(address(adapter), wethToPairedPath, SWAP_AMOUNT, SWAP_AMOUNT, DEADLINE_FAR);
    }

    function test_ExecuteSwapExactAmountOut_SuccessfulSwap() public {
        uint256 callerWethBefore = weth.balanceOf(caller);
        uint256 callerPairedBefore = pairedToken.balanceOf(caller);

        vm.expectEmit(true, true, true, true);
        emit IConverter.SwapExecuted(caller, address(weth), address(pairedToken), SWAP_AMOUNT, SWAP_AMOUNT);

        vm.prank(caller);
        uint256 amountIn = converter.executeSwapExactAmountOut(
            address(adapter), wethToPairedPath, SWAP_AMOUNT, SWAP_AMOUNT, DEADLINE_FAR
        );

        // For a 1:1 mock router, actual input equals output (no surplus)
        assertEq(amountIn, SWAP_AMOUNT);
        assertEq(weth.balanceOf(caller), callerWethBefore - SWAP_AMOUNT);
        assertEq(pairedToken.balanceOf(caller), callerPairedBefore + SWAP_AMOUNT);
    }

    function test_ExecuteSwapExactAmountOut_RefundsUnspentInput() public {
        // Fund and approve twice the needed input; the 1:1 router consumes only
        // SWAP_AMOUNT, and the Converter must refund the surplus to the caller.
        _setupCallerForSwap(address(weth), 2 * SWAP_AMOUNT);
        uint256 callerWethBefore = weth.balanceOf(caller);

        vm.prank(caller);
        uint256 amountIn = converter.executeSwapExactAmountOut(
            address(adapter), wethToPairedPath, SWAP_AMOUNT, 2 * SWAP_AMOUNT, DEADLINE_FAR
        );

        assertEq(amountIn, SWAP_AMOUNT);
        assertEq(weth.balanceOf(caller), callerWethBefore - SWAP_AMOUNT);
        assertEq(pairedToken.balanceOf(caller), SWAP_AMOUNT);
        // No input tokens stranded on the Converter
        assertEq(weth.balanceOf(address(converter)), 0);
    }

    function test_ExecuteSwapExactAmountOut_UsesForwardPathEncoding() public {
        // The router mock enforces Uniswap's reverse encoding for exactOutput; passing the
        // FORWARD path here only succeeds because the adapter reverses it internally.
        _setupCallerForSwap(address(pairedToken), SWAP_AMOUNT);
        uint256 callerWethBefore = weth.balanceOf(caller);

        vm.prank(caller);
        uint256 amountIn = converter.executeSwapExactAmountOut(
            address(adapter), pairedToWethPath, SWAP_AMOUNT, SWAP_AMOUNT, DEADLINE_FAR
        );

        assertEq(amountIn, SWAP_AMOUNT);
        assertEq(router.lastAmountOut(), SWAP_AMOUNT);
        assertEq(weth.balanceOf(caller), callerWethBefore + SWAP_AMOUNT);
        assertEq(pairedToken.balanceOf(caller), 0);
    }

    function test_ExecuteSwapExactAmountOut_DeadlineAtBlockTimestamp() public {
        vm.prank(caller);
        uint256 amountIn = converter.executeSwapExactAmountOut(
            address(adapter), wethToPairedPath, SWAP_AMOUNT, SWAP_AMOUNT, block.timestamp
        );
        assertEq(amountIn, SWAP_AMOUNT);
    }

    function test_ExecuteSwapExactAmountOut_EmitsSwapEvent() public {
        _setupCallerForSwap(address(pairedToken), SWAP_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit IConverter.SwapExecuted(caller, address(pairedToken), address(weth), SWAP_AMOUNT, SWAP_AMOUNT);

        vm.prank(caller);
        converter.executeSwapExactAmountOut(address(adapter), pairedToWethPath, SWAP_AMOUNT, SWAP_AMOUNT, DEADLINE_FAR);
    }

    function test_ExecuteSwapExactAmountOut_MultiHopPath_FailsAtAdapter() public {
        MockERC20 tokenA = new MockERC20("Token A", "TA", 18);
        bytes memory multiHopPath =
            abi.encodePacked(address(weth), uint24(3000), address(tokenA), uint24(3000), address(pairedToken));

        vm.expectRevert(IConverter.ConverterInvalidRoute.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountOut(address(adapter), multiHopPath, SWAP_AMOUNT, SWAP_AMOUNT, DEADLINE_FAR);
    }
}

// ================================
// ConverterMockAdapterSwapExactAmountOutTest
// ================================

contract ConverterMockAdapterSwapExactAmountOutTest is ConverterTestBase {
    MockConverterAdapter public mockAdapter;

    function setUp() public override {
        super.setUp();
        mockAdapter = new MockConverterAdapter(weth, pairedToken);
        converter.setAllowedAdapter(address(mockAdapter), true);
        _setupCallerForSwap(address(weth), SWAP_AMOUNT);
    }

    function test_SwapExactAmountOut_RevertsWhenAdapterSwapExactOutputReverts() public {
        mockAdapter.setShouldRevertSwapExactOutput(true);
        vm.expectRevert(IConverter.ConverterSwapFailed.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountOut(
            address(mockAdapter), wethToPairedPath, SWAP_AMOUNT, SWAP_AMOUNT, DEADLINE_FAR
        );
    }

    function test_SwapExactAmountOut_SucceedsThroughMockAdapter() public {
        vm.prank(caller);
        uint256 amountIn = converter.executeSwapExactAmountOut(
            address(mockAdapter), wethToPairedPath, SWAP_AMOUNT, SWAP_AMOUNT, DEADLINE_FAR
        );
        assertEq(amountIn, SWAP_AMOUNT);
        assertEq(pairedToken.balanceOf(caller), SWAP_AMOUNT);
    }

    function test_SwapExactAmountOut_RevertsWhenAdapterExcessiveInput() public {
        // 0.5x output multiplier makes the adapter spend 2x the authorized maximum.
        // Donate the extra input to the Converter so the overspend itself succeeds and
        // the balance-measured ConverterExcessiveInput bound is what reverts: the check
        // stops an adapter from spending pre-existing Converter balance beyond the
        // caller's authorized maximum.
        mockAdapter.setOutputMultiplier(5e17);
        weth.mint(address(converter), SWAP_AMOUNT);

        vm.expectRevert(IConverter.ConverterExcessiveInput.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountOut(
            address(mockAdapter), wethToPairedPath, SWAP_AMOUNT, SWAP_AMOUNT, DEADLINE_FAR
        );
    }

    function test_SwapExactAmountOut_RevertsWhenAdapterUnderproducesOutput() public {
        // 0.5x mint multiplier makes the adapter produce only half the requested output.
        // Donate pre-existing tokenOut to the Converter so that, without the output
        // balance-delta guard, the final safeTransfer(_amountOut) would silently cover the
        // shortfall from that pre-existing balance. The guard must reject the swap instead.
        mockAdapter.setExactOutputMintMultiplier(5e17);
        pairedToken.mint(address(converter), SWAP_AMOUNT);

        vm.expectRevert(IConverter.ConverterInsufficientOutput.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountOut(
            address(mockAdapter), wethToPairedPath, SWAP_AMOUNT, SWAP_AMOUNT, DEADLINE_FAR
        );
    }
}

// ================================
// ConverterCallerRoleManagementTest
// ================================

contract ConverterCallerRoleManagementTest is ConverterTestBase {
    address public strategy;

    function setUp() public override {
        super.setUp();
        strategy = makeAddr("strategy");
    }

    function test_GrantCallerRole_RevertsWhenCallerNotStrategyManager() public {
        _expectRegistryInvalidCallerRevert(Auth.STRATEGY_MANAGER);
        vm.prank(unauthorized);
        converter.grantCallerRole(strategy);
    }

    function test_GrantCallerRole_RevertsWhenAdminLacksStrategyManagerRole() public {
        // Admin (test contract) is not registered STRATEGY_MANAGER
        _expectRegistryInvalidCallerRevert(Auth.STRATEGY_MANAGER);
        converter.grantCallerRole(strategy);
    }

    function test_GrantCallerRole_RevertsWhenAccountIsZero() public {
        vm.expectRevert(IConverter.ConverterZeroAddress.selector);
        vm.prank(strategyManager);
        converter.grantCallerRole(address(0));
    }

    function test_GrantCallerRole_GrantsRoleAndEmits() public {
        assertFalse(converter.isCaller(strategy));

        vm.expectEmit(true, false, false, true);
        emit IConverter.CallerRoleGranted(strategy);

        vm.prank(strategyManager);
        converter.grantCallerRole(strategy);

        assertTrue(converter.isCaller(strategy));
    }

    function test_GrantCallerRole_GrantedAccountCanWrap() public {
        vm.prank(strategyManager);
        converter.grantCallerRole(strategy);

        vm.deal(strategy, WRAP_AMOUNT);
        vm.prank(strategy);
        converter.wrapETH{value: WRAP_AMOUNT}();
        assertEq(weth.balanceOf(strategy), WRAP_AMOUNT);
    }

    function test_RevokeCallerRole_RevertsWhenCallerNotStrategyManager() public {
        _expectRegistryInvalidCallerRevert(Auth.STRATEGY_MANAGER);
        vm.prank(unauthorized);
        converter.revokeCallerRole(strategy);
    }

    function test_RevokeCallerRole_RevertsWhenAccountIsZero() public {
        vm.expectRevert(IConverter.ConverterZeroAddress.selector);
        vm.prank(strategyManager);
        converter.revokeCallerRole(address(0));
    }

    function test_RevokeCallerRole_RevokesRoleAndEmits() public {
        vm.prank(strategyManager);
        converter.grantCallerRole(strategy);
        assertTrue(converter.isCaller(strategy));

        vm.expectEmit(true, false, false, true);
        emit IConverter.CallerRoleRevoked(strategy);

        vm.prank(strategyManager);
        converter.revokeCallerRole(strategy);

        assertFalse(converter.isCaller(strategy));
    }

    function test_RevokeCallerRole_RevokedAccountCannotWrap() public {
        vm.prank(strategyManager);
        converter.grantCallerRole(strategy);
        vm.prank(strategyManager);
        converter.revokeCallerRole(strategy);

        vm.deal(strategy, WRAP_AMOUNT);
        _expectRegistryMissingRoleRevert(Auth.CONVERTER_CALLER_ROLE);
        vm.prank(strategy);
        converter.wrapETH{value: WRAP_AMOUNT}();
    }
}

// ================================
// ConverterQuoteSwapTest
// ================================

contract ConverterQuoteSwapTest is ConverterTestBase {
    function test_QuoteSwap_ReturnsTwapAmountNetOfFee() public {
        vm.prank(caller);
        uint256 quoted = converter.quoteSwapExactAmountIn(address(adapter), wethToPairedPath, SWAP_AMOUNT);
        assertEq(quoted, EXPECTED_QUOTE_OUT);
    }

    function test_QuoteSwapExactOutput_ReturnsTwapAmountGrossOfFee() public {
        vm.prank(caller);
        uint256 quoted = converter.quoteSwapExactAmountOut(address(adapter), wethToPairedPath, SWAP_AMOUNT);
        assertEq(quoted, EXPECTED_QUOTE_IN);
    }

    function test_QuoteSwap_RevertsWhenAdapterNotAllowed() public {
        UniswapV3ConverterAdapter rogue = _newAdapter();
        vm.expectRevert(IConverter.ConverterAdapterNotAllowed.selector);
        vm.prank(caller);
        converter.quoteSwapExactAmountIn(address(rogue), wethToPairedPath, SWAP_AMOUNT);
    }

    function test_QuoteSwap_RevertsWhenPoolObserveReverts() public {
        pool.setObserveShouldRevert(true);
        vm.expectRevert(IConverter.ConverterAdapterCallFailed.selector);
        vm.prank(caller);
        converter.quoteSwapExactAmountIn(address(adapter), wethToPairedPath, SWAP_AMOUNT);
    }

    function test_QuoteSwap_RevertsWhenOracleReverts() public {
        oracle.setShouldRevert(true);
        vm.expectRevert(IConverter.ConverterAdapterCallFailed.selector);
        vm.prank(caller);
        converter.quoteSwapExactAmountIn(address(adapter), wethToPairedPath, SWAP_AMOUNT);
    }

    function test_QuoteSwap_RevertsWhenTwapDeviatesFromOracle() public {
        // Doubling the paired token's USD price halves the oracle-implied output while
        // the pool TWAP still quotes 1:1 — the adapter must reject the divergence.
        oracle.setPrice(address(pairedToken), ORACLE_PRICE_USD * 2);
        vm.expectRevert(IConverter.ConverterAdapterCallFailed.selector);
        vm.prank(caller);
        converter.quoteSwapExactAmountIn(address(adapter), wethToPairedPath, SWAP_AMOUNT);
    }
}

// ================================
// ConverterSetAllowedAdapterTest
// ================================

contract ConverterSetAllowedAdapterTest is ConverterTestBase {
    function test_SetAllowedAdapter_RevertsWhenCallerNotAdmin() public {
        _expectRegistryMissingRoleRevert(Auth.ADMIN_ROLE);
        vm.prank(unauthorized);
        converter.setAllowedAdapter(address(adapter), true);
    }

    function test_SetAllowedAdapter_RevertsWhenZeroAddress() public {
        vm.expectRevert(IConverter.ConverterZeroAddress.selector);
        converter.setAllowedAdapter(address(0), true);
    }

    function test_SetAllowedAdapter_RevertsWhenApprovingCodelessAddress() public {
        vm.expectRevert(IConverter.ConverterNoCode.selector);
        converter.setAllowedAdapter(makeAddr("eoaAdapter"), true);
    }

    function test_SetAllowedAdapter_Approve() public {
        UniswapV3ConverterAdapter newAdapter = _newAdapter();

        vm.expectEmit(true, false, false, true);
        emit IConverter.AdapterUpdated(address(newAdapter), true);

        converter.setAllowedAdapter(address(newAdapter), true);
        assertTrue(converter.isAdapterAllowed(address(newAdapter)));
    }

    function test_SetAllowedAdapter_Remove() public {
        vm.expectEmit(true, false, false, true);
        emit IConverter.AdapterUpdated(address(adapter), false);

        converter.setAllowedAdapter(address(adapter), false);
        assertFalse(converter.isAdapterAllowed(address(adapter)));
    }

    function test_SetAllowedAdapter_RemoveCodelessAddressAllowed() public {
        address eoa = makeAddr("eoaAdapter");
        vm.expectRevert(IConverter.ConverterAdapterNotAllowed.selector);
        converter.setAllowedAdapter(eoa, false);
    }
}

// ================================
// ConverterViewTest
// ================================

contract ConverterViewTest is ConverterTestBase {
    function test_Weth_ReturnsWETHAddress() public {
        assertEq(converter.weth(), address(weth));
    }

    function test_IsAdapterAllowed_ReturnsTrueForWhitelisted() public {
        assertTrue(converter.isAdapterAllowed(address(adapter)));
    }

    function test_IsAdapterAllowed_ReturnsFalseForUnknown() public {
        assertFalse(converter.isAdapterAllowed(makeAddr("unknown")));
    }

    function test_RouteTokens_ReturnsFirstAndLastToken() public {
        (address tokenIn, address tokenOut) = converter.routeTokens(address(adapter), wethToPairedPath);
        assertEq(tokenIn, address(weth));
        assertEq(tokenOut, address(pairedToken));
    }

    function test_RouteTokens_RevertsWhenAdapterNotAllowed() public {
        UniswapV3ConverterAdapter rogue = _newAdapter();
        vm.expectRevert(IConverter.ConverterAdapterNotAllowed.selector);
        converter.routeTokens(address(rogue), wethToPairedPath);
    }

    function test_RouteTokens_RevertsWhenAdapterCannotDecode() public {
        bytes memory invalidPath = abi.encodePacked(address(weth));
        vm.expectRevert(IConverter.ConverterAdapterCallFailed.selector);
        converter.routeTokens(address(adapter), invalidPath);
    }

    function test_ValidateRoute_ValidPath() public {
        assertTrue(converter.validateRoute(address(adapter), wethToPairedPath));
    }

    function test_ValidateRoute_InvalidPath() public {
        bytes memory invalidPath = abi.encodePacked(address(weth));
        assertFalse(converter.validateRoute(address(adapter), invalidPath));
    }

    function test_ValidateRoute_RevertsWhenAdapterNotAllowed() public {
        UniswapV3ConverterAdapter rogue = _newAdapter();
        vm.expectRevert(IConverter.ConverterAdapterNotAllowed.selector);
        converter.validateRoute(address(rogue), wethToPairedPath);
    }

    function test_IsCaller_ReturnsTrueForGrantedAccount() public {
        assertTrue(converter.isCaller(caller));
    }

    function test_IsCaller_ReturnsFalseForUnknownAccount() public {
        assertFalse(converter.isCaller(unauthorized));
    }

    function test_IsCaller_ReturnsFalseAfterRevoke() public {
        _grantCallerRole(unauthorized);
        assertTrue(converter.isCaller(unauthorized));
        _revokeCallerRole(unauthorized);
        assertFalse(converter.isCaller(unauthorized));
    }
}

// ================================
// ConverterPauseTest
// ================================

contract ConverterPauseTest is ConverterTestBase {
    function test_Pause_RevertsWhenCallerHasNeitherRole() public {
        _expectCallerHasNoneOfRoles(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE);
        vm.prank(unauthorized);
        converter.pause();
    }

    function test_Pause_SecurityCanPauseImmediately() public {
        address security = makeAddr("security");
        registry.grantRole(Auth.SECURITY_ROLE, security);
        vm.prank(security);
        converter.pause();
        assertTrue(converter.paused());
    }

    function test_Pause_WhenNotPaused_Succeeds() public {
        converter.pause();
        assertTrue(converter.paused());
    }

    function test_Pause_WhenAlreadyPaused_Reverts() public {
        converter.pause();
        vm.expectRevert();
        converter.pause();
    }

    function test_Unpause_RevertsWhenCallerNotAdmin() public {
        converter.pause();
        _expectRegistryMissingRoleRevert(Auth.ADMIN_ROLE);
        vm.prank(unauthorized);
        converter.unpause();
    }

    function test_Unpause_SecurityCannotUnpause() public {
        address security = makeAddr("security");
        registry.grantRole(Auth.SECURITY_ROLE, security);
        converter.pause();
        _expectRegistryMissingRoleRevert(Auth.ADMIN_ROLE);
        vm.prank(security);
        converter.unpause();
    }

    function test_Unpause_WhenPaused_Succeeds() public {
        converter.pause();
        converter.unpause();
        assertFalse(converter.paused());
    }

    function test_Unpause_WhenNotPaused_Reverts() public {
        vm.expectRevert();
        converter.unpause();
    }

    function test_PausedState_BlocksWraps() public {
        converter.pause();
        vm.deal(caller, VALID_AMOUNT);
        vm.expectRevert();
        vm.prank(caller);
        converter.wrapETH{value: VALID_AMOUNT}();
    }

    function test_PausedState_BlocksUnwrap() public {
        _fundCallerWETH(VALID_AMOUNT);
        _approveConverterForCallerWETH(VALID_AMOUNT);
        converter.pause();
        vm.expectRevert();
        vm.prank(caller);
        converter.unwrapWETH(VALID_AMOUNT, receiver);
    }

    function test_PausedState_BlocksSwap() public {
        converter.pause();
        vm.expectRevert();
        vm.prank(caller);
        converter.executeSwapExactAmountIn(address(adapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_EXACT, DEADLINE_FAR);
    }

    function test_PausedState_SetAllowedAdapterStillSucceeds() public {
        converter.pause();
        UniswapV3ConverterAdapter newAdapter = _newAdapter();
        converter.setAllowedAdapter(address(newAdapter), true);
        assertTrue(converter.isAdapterAllowed(address(newAdapter)));
    }

    function test_PausedState_QuoteSwapSucceeds() public {
        converter.pause();
        vm.prank(caller);
        uint256 quoted = converter.quoteSwapExactAmountIn(address(adapter), wethToPairedPath, SWAP_AMOUNT);
        assertEq(quoted, EXPECTED_QUOTE_OUT);
    }

    function test_PausedState_ViewFunctionsStillWork() public {
        converter.pause();
        assertEq(converter.weth(), address(weth));
        assertTrue(converter.isAdapterAllowed(address(adapter)));
    }

    function test_OperationsResumeAfterUnpause() public {
        converter.pause();
        converter.unpause();

        vm.deal(caller, VALID_AMOUNT);
        vm.prank(caller);
        converter.wrapETH{value: VALID_AMOUNT}();
        assertEq(weth.balanceOf(caller), VALID_AMOUNT);

        _approveConverterForCallerWETH(VALID_AMOUNT);
        vm.prank(caller);
        converter.unwrapWETH(VALID_AMOUNT, receiver);
        assertEq(receiver.balance, VALID_AMOUNT);
    }
}

// ================================
// ConverterAccessControlTest
// ================================

contract ConverterAccessControlTest is ConverterTestBase {
    function test_AccessControl_AdminHasADMIN_ROLEOnRegistry() public {
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, admin));
    }

    function test_AccessControl_AdminCanGrantCallerPermission() public {
        // Admin sets caller permission via StrategyManager (which onlyAuthContract requires)
        // Admin can not directly grant caller permission since onlyAuthContract restricts to strategyManager
        assertFalse(converter.isCaller(unauthorized));
        _grantCallerRole(unauthorized);
        assertTrue(converter.isCaller(unauthorized));
    }

    function test_AccessControl_AdminCanRevokeCallerPermission() public {
        _grantCallerRole(unauthorized);
        assertTrue(converter.isCaller(unauthorized));
        _revokeCallerRole(unauthorized);
        assertFalse(converter.isCaller(unauthorized));
    }

    function test_AccessControl_NonStrategyManagerCannotGrantCallerPermission() public {
        _expectRegistryInvalidCallerRevert(Auth.STRATEGY_MANAGER);
        vm.prank(unauthorized);
        converter.grantCallerRole(makeAddr("random"));
    }

    function test_AccessControl_NonStrategyManagerCannotRevokeCallerPermission() public {
        _expectRegistryInvalidCallerRevert(Auth.STRATEGY_MANAGER);
        vm.prank(unauthorized);
        converter.revokeCallerRole(caller);
    }

    function test_AccessControl_WrapETHRequiresCallerPermission() public {
        vm.deal(unauthorized, 1);
        _expectRegistryMissingRoleRevert(Auth.CONVERTER_CALLER_ROLE);
        vm.prank(unauthorized);
        converter.wrapETH{value: 1}();
    }

    function test_AccessControl_UnwrapWETHRequiresCallerPermission() public {
        _expectRegistryMissingRoleRevert(Auth.CONVERTER_CALLER_ROLE);
        vm.prank(unauthorized);
        converter.unwrapWETH(1, receiver);
    }

    function test_AccessControl_ExecuteSwapRequiresCallerPermission() public {
        _expectRegistryMissingRoleRevert(Auth.CONVERTER_CALLER_ROLE);
        vm.prank(unauthorized);
        converter.executeSwapExactAmountIn(address(adapter), wethToPairedPath, 1, 0, DEADLINE_FAR);
    }

    function test_AccessControl_QuoteSwapIsPermissionless() public {
        vm.prank(unauthorized);
        uint256 quoted = converter.quoteSwapExactAmountIn(address(adapter), wethToPairedPath, SWAP_AMOUNT);
        assertEq(quoted, EXPECTED_QUOTE_OUT);
    }

    function test_AccessControl_SetAllowedAdapterRequiresAdminRole() public {
        _expectRegistryMissingRoleRevert(Auth.ADMIN_ROLE);
        vm.prank(unauthorized);
        converter.setAllowedAdapter(address(adapter), true);
    }

    function test_AccessControl_PauseRequiresAdminOrSecurityRole() public {
        _expectCallerHasNoneOfRoles(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE);
        vm.prank(unauthorized);
        converter.pause();
    }

    function test_AccessControl_UnpauseRequiresAdminRole() public {
        converter.pause();
        _expectRegistryMissingRoleRevert(Auth.ADMIN_ROLE);
        vm.prank(unauthorized);
        converter.unpause();
    }
}

// ================================
// ConverterUpgradeableTest
// ================================

contract ConverterUpgradeableTest is ConverterTestBase {
    function test_Upgrade_AuthorizedUpgrade_Succeeds() public {
        Converter newImpl = new Converter();
        converter.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_UnauthorizedUpgrade_Reverts() public {
        _expectRegistryMissingRoleRevert(Auth.ADMIN_ROLE);
        vm.prank(unauthorized);
        converter.upgradeToAndCall(address(0), "");
    }

    function test_Upgrade_StatePersistsAfterUpgrade() public {
        Converter newImpl = new Converter();
        converter.upgradeToAndCall(address(newImpl), "");

        assertTrue(converter.isAdapterAllowed(address(adapter)));
        assertEq(converter.weth(), address(weth));
        assertTrue(converter.isCaller(caller));
    }

    function test_Upgrade_FunctionsWorkAfterUpgrade() public {
        Converter newImpl = new Converter();
        converter.upgradeToAndCall(address(newImpl), "");

        vm.deal(caller, VALID_AMOUNT);
        vm.prank(caller);
        converter.wrapETH{value: VALID_AMOUNT}();
        assertEq(weth.balanceOf(caller), VALID_AMOUNT);
    }
}

// ================================
// ConverterEdgeCaseTest
// ================================

contract ConverterEdgeCaseTest is ConverterTestBase {
    function test_EdgeCase_SingleWrap() public {
        vm.deal(caller, WRAP_AMOUNT);
        vm.prank(caller);
        converter.wrapETH{value: WRAP_AMOUNT}();
        assertEq(weth.balanceOf(caller), WRAP_AMOUNT);
    }

    function test_EdgeCase_MultipleSequentialWraps() public {
        vm.deal(caller, LARGE_AMOUNT);
        vm.prank(caller);
        converter.wrapETH{value: WRAP_AMOUNT}();
        vm.prank(caller);
        converter.wrapETH{value: WRAP_AMOUNT}();
        assertEq(weth.balanceOf(caller), WRAP_AMOUNT * 2);
    }

    function test_EdgeCase_SingleUnwrap() public {
        _fundCallerWETH(WRAP_AMOUNT);
        _approveConverterForCallerWETH(WRAP_AMOUNT);
        vm.prank(caller);
        converter.unwrapWETH(WRAP_AMOUNT, receiver);
        assertEq(receiver.balance, WRAP_AMOUNT);
    }

    function test_EdgeCase_SwapZeroAmountIn() public {
        _setupCallerForSwap(address(weth), SWAP_AMOUNT);
        vm.prank(caller);
        uint256 result =
            converter.executeSwapExactAmountIn(address(adapter), wethToPairedPath, 0, MIN_OUT_ZERO, DEADLINE_FAR);
        assertEq(result, 0);
    }

    function test_EdgeCase_SwapWithZeroMinOut() public {
        _setupCallerForSwap(address(weth), SWAP_AMOUNT);
        vm.prank(caller);
        uint256 result = converter.executeSwapExactAmountIn(
            address(adapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_ZERO, DEADLINE_FAR
        );
        assertEq(result, SWAP_AMOUNT);
    }

    function test_EdgeCase_SwapImmediateDeadline() public {
        _setupCallerForSwap(address(weth), SWAP_AMOUNT);
        vm.prank(caller);
        uint256 result = converter.executeSwapExactAmountIn(
            address(adapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_EXACT, block.timestamp
        );
        assertEq(result, SWAP_AMOUNT);
    }

    function test_EdgeCase_SwapExpiredDeadline() public {
        vm.warp(1000);
        vm.expectRevert(IConverter.ConverterDeadlineExpired.selector);
        vm.prank(caller);
        converter.executeSwapExactAmountIn(address(adapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_EXACT, 999);
    }

    function test_EdgeCase_SwapBothDirections() public {
        _setupCallerForSwap(address(weth), SWAP_AMOUNT);
        vm.prank(caller);
        uint256 outA = converter.executeSwapExactAmountIn(
            address(adapter), wethToPairedPath, SWAP_AMOUNT, MIN_OUT_ZERO, DEADLINE_FAR
        );
        assertEq(outA, SWAP_AMOUNT);

        _setupCallerForSwap(address(pairedToken), SWAP_AMOUNT);
        vm.prank(caller);
        uint256 outB = converter.executeSwapExactAmountIn(
            address(adapter), pairedToWethPath, SWAP_AMOUNT, MIN_OUT_ZERO, DEADLINE_FAR
        );
        assertEq(outB, SWAP_AMOUNT);
    }
}

// ================================
// ConverterFuzzTest
// ================================

contract ConverterFuzzTest is ConverterTestBase {
    function testFuzz_WrapETH_WithValidAmount(uint256 _amount) public {
        _amount = bound(_amount, 1, 1000 ether);

        _grantCallerRole(address(this));
        vm.deal(address(this), _amount);

        converter.wrapETH{value: _amount}();

        assertEq(weth.balanceOf(address(this)), _amount);
    }

    function testFuzz_WrapETH_ZeroAmount() public {
        _grantCallerRole(address(this));
        vm.prank(address(this));
        converter.wrapETH{value: 0}();
        assertEq(weth.balanceOf(address(this)), 0);
    }

    function testFuzz_UnwrapWETH_WithValidAmount(uint256 _amount) public {
        _amount = bound(_amount, 1, 100 ether);

        _fundCallerWETH(_amount);
        _approveConverterForCallerWETH(_amount);

        vm.prank(caller);
        converter.unwrapWETH(_amount, receiver);

        assertEq(receiver.balance, _amount);
    }

    function testFuzz_UnwrapWETH_InsufficientBalance(uint256 _amount) public {
        _amount = bound(_amount, 1, 100 ether);

        address poor = makeAddr("poorFuzz");
        _grantCallerRole(poor);
        vm.prank(poor);
        IERC20(address(weth)).approve(address(converter), _amount);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")), poor, 0, _amount
            )
        );
        vm.prank(poor);
        converter.unwrapWETH(_amount, receiver);
    }

    function testFuzz_ExecuteSwap_WithValidAmounts(uint256 _amount) public {
        _amount = bound(_amount, 1, 100 ether);
        _setupCallerForSwap(address(weth), _amount);

        vm.prank(caller);
        uint256 amountOut =
            converter.executeSwapExactAmountIn(address(adapter), wethToPairedPath, _amount, 0, DEADLINE_FAR);
        assertEq(amountOut, _amount);
    }

    function testFuzz_Initialize_WithRandomValidAddresses(address _wethAddr) public {
        vm.assume(_wethAddr != address(0));

        Converter impl = new Converter();
        bytes memory initData = abi.encodeWithSelector(Converter.initialize.selector, address(registry), _wethAddr);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        Converter c = Converter(payable(address(proxy)));

        assertEq(c.weth(), _wethAddr);
    }
}

// ================================
// ConverterRegistryIntegrationTest
// ================================

contract ConverterRegistryIntegrationTest is ConverterTestBase {
    function test_Registry_ConverterRegistered() public {
        assertEq(registry.getContractByKey(Auth.CONVERTER), address(converter));
    }

    function test_Registry_StrategyManagerRegistered() public {
        assertEq(registry.getContractByKey(Auth.STRATEGY_MANAGER), strategyManager);
    }

    function test_Registry_AdminHasAdminRole() public {
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, admin));
    }

    function test_Registry_NonAdminCannotSetAllowedAdapter() public {
        address nonAdmin = makeAddr("nonAdmin");
        _expectRegistryMissingRoleRevert(Auth.ADMIN_ROLE);
        vm.prank(nonAdmin);
        converter.setAllowedAdapter(address(adapter), true);
    }

    function test_Registry_NonStrategyManagerCannotGrantCallerRole() public {
        address random = makeAddr("random");
        _expectRegistryInvalidCallerRevert(Auth.STRATEGY_MANAGER);
        vm.prank(random);
        converter.grantCallerRole(random);
    }
}

// ================================
// UniswapV3ConverterAdapterTest
// ================================

contract UniswapV3ConverterAdapterTest is ConverterTestBase {
    function test_Adapter_RevertsWhenRouterIsZero() public {
        vm.expectRevert(IUniswapV3ConverterAdapter.UniswapV3ConverterAdapterZeroAddress.selector);
        new UniswapV3ConverterAdapter(address(0), address(factory), address(oracle), address(weth), TWAP_INTERVAL);
    }

    function test_Adapter_RevertsWhenFactoryIsZero() public {
        vm.expectRevert(IUniswapV3ConverterAdapter.UniswapV3ConverterAdapterZeroAddress.selector);
        new UniswapV3ConverterAdapter(address(router), address(0), address(oracle), address(weth), TWAP_INTERVAL);
    }

    function test_Adapter_RevertsWhenOracleIsZero() public {
        vm.expectRevert(IUniswapV3ConverterAdapter.UniswapV3ConverterAdapterZeroAddress.selector);
        new UniswapV3ConverterAdapter(address(router), address(factory), address(0), address(weth), TWAP_INTERVAL);
    }

    function test_Adapter_RevertsWhenWethIsZero() public {
        vm.expectRevert(IUniswapV3ConverterAdapter.UniswapV3ConverterAdapterZeroAddress.selector);
        new UniswapV3ConverterAdapter(address(router), address(factory), address(oracle), address(0), TWAP_INTERVAL);
    }

    function test_Adapter_RevertsWhenTwapIntervalTooShort() public {
        uint32 tooShort = adapter.MIN_TWAP_INTERVAL() - 1;
        vm.expectRevert(IUniswapV3ConverterAdapter.UniswapV3ConverterAdapterInvalidTwapInterval.selector);
        new UniswapV3ConverterAdapter(address(router), address(factory), address(oracle), address(weth), tooShort);
    }

    function test_Adapter_Name() public {
        assertEq(adapter.name(), "UniswapV3ConverterAdapter");
    }

    function test_Adapter_ValidateRoute_SingleHop() public {
        assertTrue(adapter.validateRoute(wethToPairedPath));
    }

    function test_Adapter_ValidateRoute_MultiHop() public {
        MockERC20 tokenA = new MockERC20("Token A", "TA", 18);
        bytes memory multiHop =
            abi.encodePacked(address(weth), uint24(3000), address(tokenA), uint24(3000), address(pairedToken));
        assertFalse(adapter.validateRoute(multiHop));
    }

    function test_Adapter_ValidateRoute_TooShort() public {
        assertFalse(adapter.validateRoute(abi.encodePacked(address(weth))));
    }

    function test_Adapter_ValidateRoute_Misaligned() public {
        bytes memory bad = abi.encodePacked(address(weth), uint24(3000), address(pairedToken), uint8(1));
        assertFalse(adapter.validateRoute(bad));
    }

    function test_Adapter_RouteTokens() public {
        (address tokenIn, address tokenOut) = adapter.routeTokens(wethToPairedPath);
        assertEq(tokenIn, address(weth));
        assertEq(tokenOut, address(pairedToken));
    }

    function test_Adapter_RouteTokens_RevertsOnInvalidRoute() public {
        vm.expectRevert(IUniswapV3ConverterAdapter.UniswapV3ConverterAdapterInvalidRoute.selector);
        adapter.routeTokens(abi.encodePacked(address(weth)));
    }

    function test_Adapter_Quote_TwapNetOfFee() public {
        assertEq(adapter.quoteExactAmountIn(wethToPairedPath, SWAP_AMOUNT), EXPECTED_QUOTE_OUT);
    }

    function test_Adapter_Quote_BothDirections() public {
        assertEq(adapter.quoteExactAmountIn(wethToPairedPath, SWAP_AMOUNT), EXPECTED_QUOTE_OUT);
        assertEq(adapter.quoteExactAmountIn(pairedToWethPath, SWAP_AMOUNT), EXPECTED_QUOTE_OUT);
    }

    function test_Adapter_QuoteExactOutput_TwapGrossOfFee() public {
        assertEq(adapter.quoteExactAmountOut(wethToPairedPath, SWAP_AMOUNT), EXPECTED_QUOTE_IN);
    }

    function test_Adapter_Quote_RevertsWhenPoolNotFound() public {
        MockERC20 unknownToken = new MockERC20("Unknown", "UNK", 18);
        bytes memory unknownPath = abi.encodePacked(address(weth), POOL_FEE, address(unknownToken));
        oracle.setPrice(address(unknownToken), ORACLE_PRICE_USD);

        vm.expectRevert(IUniswapV3ConverterAdapter.UniswapV3ConverterAdapterPoolNotFound.selector);
        adapter.quoteExactAmountIn(unknownPath, SWAP_AMOUNT);
    }

    function test_Adapter_Quote_RevertsWhenTwapDeviatesFromOracle() public {
        oracle.setPrice(address(pairedToken), ORACLE_PRICE_USD * 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV3ConverterAdapter.UniswapV3ConverterAdapterQuoteDeviation.selector,
                SWAP_AMOUNT,
                SWAP_AMOUNT / 2
            )
        );
        adapter.quoteExactAmountIn(wethToPairedPath, SWAP_AMOUNT);
    }

    function test_Adapter_ImmutableConfiguration() public {
        assertEq(address(adapter.router()), address(router));
        assertEq(address(adapter.factory()), address(factory));
        assertEq(address(adapter.oracle()), address(oracle));
        assertEq(adapter.weth(), address(weth));
        assertEq(adapter.twapInterval(), TWAP_INTERVAL);
    }
}
