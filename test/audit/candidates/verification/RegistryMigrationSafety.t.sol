// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, func-name-mixedcase
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Converter} from "contracts/Converter.sol";
import {Auth} from "libraries/Auth.sol";

import {UniCLStratTestBase} from "../../../helpers/UniCLStratTestBase.sol";
import {MockWETH} from "../../../mocks/UniCLStratMocks.sol";

contract RegistryMigrationSafetyVerificationTest is UniCLStratTestBase {
    function test_ConverterRotationLeavesOldAllowanceAndNewConverterUnapproved() public {
        Converter replacement = _rotateConverter(weth);

        assertEq(weth.allowance(address(strategy), address(converter)), type(uint256).max);
        assertEq(pairedToken.allowance(address(strategy), address(converter)), type(uint256).max);
        assertEq(weth.allowance(address(strategy), address(replacement)), 0);
        assertEq(pairedToken.allowance(address(strategy), address(replacement)), 0);

        // wrapETH itself needs no allowance, but the inventory-balancing swap does.
        vm.deal(strategyManager, 1 ether);
        vm.expectRevert();
        vm.prank(strategyManager);
        strategy.deposit{value: 1 ether}();

        // The only built-in refresh is pause -> unpause. It approves the new
        // Converter but cannot revoke the allowance left on the old address.
        vm.prank(admin);
        strategy.pause();
        vm.prank(admin);
        strategy.unpause();

        assertEq(weth.allowance(address(strategy), address(replacement)), type(uint256).max);
        assertEq(pairedToken.allowance(address(strategy), address(replacement)), type(uint256).max);
        assertEq(weth.allowance(address(strategy), address(converter)), type(uint256).max);
        assertEq(pairedToken.allowance(address(strategy), address(converter)), type(uint256).max);
    }

    function test_DifferentWethRotationStrandsSuccessfulDepositOutsideNAVAndEmergencyExit() public {
        MockWETH replacementWeth = new MockWETH();
        _rotateConverter(replacementWeth);

        vm.deal(strategyManager, 1 ether);
        vm.prank(strategyManager);
        strategy.deposit{value: 1 ether}();

        assertEq(replacementWeth.balanceOf(address(strategy)), 1 ether);
        assertEq(weth.balanceOf(address(strategy)), 0);
        assertEq(strategy.totalDeposited(), 1 ether);
        assertEq(strategy.navInETH(), 0);
        assertEq(strategy.maxWithdrawal(), 0);

        vm.prank(admin);
        strategy.pause();
        vm.prank(admin);
        strategy.emergencyExit();

        // emergencyExit only unwraps the strategy's immutable, original WETH.
        assertEq(replacementWeth.balanceOf(address(strategy)), 1 ether);
    }

    function test_DifferentWethRotationBreaksOldWethWithdrawalAfterAllowanceRefresh() public {
        uint256 amount = 1 ether;
        weth.mint(address(strategy), amount);

        MockWETH replacementWeth = new MockWETH();
        Converter replacement = _rotateConverter(replacementWeth);

        // Remove the independent zero-allowance blocker: pause/unpause approves
        // both immutable pool tokens to the replacement Converter.
        vm.prank(admin);
        strategy.pause();
        vm.prank(admin);
        strategy.unpause();
        assertEq(IERC20(address(weth)).allowance(address(strategy), address(replacement)), type(uint256).max);

        // The replacement still tries to pull/unwrap its own WETH, not the old
        // WETH that navInETH() counted and the strategy asked it to unwrap.
        vm.expectRevert();
        vm.prank(strategyManager);
        strategy.withdraw(receiver, amount);

        assertEq(weth.balanceOf(address(strategy)), amount);
        assertEq(replacementWeth.balanceOf(address(strategy)), 0);
    }

    function _rotateConverter(MockWETH converterWeth) internal returns (Converter replacement) {
        Converter implementation = new Converter();
        replacement = Converter(
            payable(
                address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(Converter.initialize, (address(registry), address(converterWeth)))
                    )
                )
            )
        );

        vm.prank(admin);
        replacement.setAllowedAdapter(address(swapAdapter), true);

        // Mirrors production authority: the Converter, not ADMIN_ROLE directly,
        // administers each strategy's global CONVERTER_CALLER_ROLE.
        vm.prank(admin);
        registry.grantRole(Auth.CONVERTER_CALLER_MANAGER_ROLE, address(replacement));
        vm.prank(strategyManager);
        replacement.grantCallerRole(address(strategy));

        vm.prank(admin);
        registry.registerContract(Auth.CONVERTER, address(replacement));
    }
}
