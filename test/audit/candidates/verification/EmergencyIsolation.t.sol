// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ProtocolTestBase} from "../../../helpers/ProtocolTestBase.sol";
import {MockERC20} from "../../../mocks/MockERC20.sol";
import {MockUniCLPool} from "../../../mocks/UniCLStratMocks.sol";
import {MockConverterAdapter} from "../../../mocks/MockConverterAdapter.sol";
import {UniCLStrat} from "../../../../src/contracts/strategies/UniCLStrat.sol";
import {IUniCLStrat} from "../../../../src/interfaces/strategies/IUniCLStrat.sol";
import {Auth} from "../../../../src/libraries/Auth.sol";

contract EmergencyFaultToken is MockERC20 {
    error ApprovalBlocked();
    error BalanceQueryBlocked();

    bool public blockZeroApproval;
    bool public blockBalanceQuery;

    constructor() MockERC20("Emergency Fault Token", "EFT", 18) {}

    function setBlockZeroApproval(bool blocked) external {
        blockZeroApproval = blocked;
    }

    function setBlockBalanceQuery(bool blocked) external {
        blockBalanceQuery = blocked;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        if (blockZeroApproval && value == 0) revert ApprovalBlocked();
        return super.approve(spender, value);
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (blockBalanceQuery) revert BalanceQueryBlocked();
        return super.balanceOf(account);
    }
}

contract EmergencyIsolationVerificationTest is ProtocolTestBase {
    address private security = makeAddr("security");

    ProtocolContracts private protocol;
    EmergencyFaultToken private pairedToken;
    UniCLStrat private strategy;

    function setUp() public {
        protocol = _deployProtocol(address(this), 5e17);
        protocol.registry.grantRole(Auth.SECURITY_ROLE, security);

        pairedToken = new EmergencyFaultToken();
        MockConverterAdapter adapter = new MockConverterAdapter(protocol.weth, pairedToken);
        MockUniCLPool pool = new MockUniCLPool(address(protocol.weth), address(pairedToken), 60, 0);
        protocol.converter.setAllowedAdapter(address(adapter), true);

        bytes memory wethToPaired = abi.encodePacked(address(protocol.weth), uint24(3_000), address(pairedToken));
        bytes memory pairedToWeth = abi.encodePacked(address(pairedToken), uint24(3_000), address(protocol.weth));
        IUniCLStrat.DeploymentConfig memory config = IUniCLStrat.DeploymentConfig({
            addresses: IUniCLStrat.AddressConfig({
                registry: address(protocol.registry),
                weth: address(protocol.weth),
                pool: address(pool)
            }),
            routes: IUniCLStrat.RouteConfig({
                swapAdapter: address(adapter),
                wethToPairedTokenPath: wethToPaired,
                pairedTokenToWethPath: pairedToWeth
            }),
            strategy: IUniCLStrat.StrategyConfig({
                positionWidth: 2,
                rebalanceTickThreshold: 30,
                maxTickDeviation: 10,
                twapInterval: 1_800,
                shortTwapInterval: 60,
                maxTotalNAV: 100 ether
            })
        });
        strategy = new UniCLStrat(config);
    }

    function test_A_ZeroApprovalFailureRollsBackPauseState() public {
        assertEq(protocol.weth.allowance(address(strategy), address(protocol.converter)), type(uint256).max);
        assertEq(pairedToken.allowance(address(strategy), address(protocol.converter)), type(uint256).max);

        pairedToken.setBlockZeroApproval(true);
        vm.prank(security);
        vm.expectRevert();
        strategy.pause();

        assertFalse(strategy.paused());
        // The earlier WETH revocation is rolled back along with `_pause()`.
        assertEq(protocol.weth.allowance(address(strategy), address(protocol.converter)), type(uint256).max);
        assertEq(pairedToken.allowance(address(strategy), address(protocol.converter)), type(uint256).max);

        pairedToken.setBlockZeroApproval(false);
        vm.prank(security);
        strategy.pause();
        assertTrue(strategy.paused());
        assertEq(protocol.weth.allowance(address(strategy), address(protocol.converter)), 0);
        assertEq(pairedToken.allowance(address(strategy), address(protocol.converter)), 0);
    }

    function test_B_PairedBalanceFailureBlocksWethAndNativeSweep() public {
        vm.prank(security);
        strategy.pause();

        vm.deal(address(strategy), 2 ether);
        protocol.weth.mint(address(strategy), 3 ether);
        vm.deal(address(protocol.weth), 3 ether);
        uint256 managerBalanceBefore = address(protocol.strategyManager).balance;

        pairedToken.setBlockBalanceQuery(true);
        vm.prank(security);
        vm.expectRevert(EmergencyFaultToken.BalanceQueryBlocked.selector);
        strategy.emergencyExit();

        assertEq(address(strategy).balance, 2 ether);
        assertEq(protocol.weth.balanceOf(address(strategy)), 3 ether);
        assertEq(address(protocol.strategyManager).balance, managerBalanceBefore);

        pairedToken.setBlockBalanceQuery(false);
        vm.prank(security);
        strategy.emergencyExit();
        assertEq(address(strategy).balance, 0);
        assertEq(protocol.weth.balanceOf(address(strategy)), 0);
        assertEq(address(protocol.strategyManager).balance, managerBalanceBefore + 5 ether);
    }
}
