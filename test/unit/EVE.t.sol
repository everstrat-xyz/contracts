// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {EVE} from "../../src/contracts/EVE.sol";
import {Registry} from "registry/Registry.sol";
import {Auth} from "../../src/libraries/Auth.sol";
import {IRegistryClient} from "interfaces/IRegistryClient.sol";

import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";

/**
 * @title EVE Test
 * @notice Comprehensive test suite for EVE contract
 */
contract EVETest is ProtocolTestBase {
    EVE public token;
    Registry public registry;

    address public owner;
    address public user;
    address public newOwner;

    // Test amounts
    uint256 public constant MINT_AMOUNT = 1000;
    uint256 public constant TRANSFER_AMOUNT = 100;
    uint256 public constant REMAINING_AMOUNT = 900;
    uint256 public constant APPROVAL_AMOUNT = 100;
    uint256 public constant APPROVAL_LARGE_AMOUNT = 500;
    uint256 public constant TRANSFER_FROM_AMOUNT = 200;
    uint256 public constant TRANSFER_FROM_REMAINING = 800;
    uint256 public constant ALLOWANCE_REMAINING = 300;
    uint256 public constant TOKEN_DECIMALS = 18;
    uint256 public constant BURN_AMOUNT = 500;
    uint256 public constant BURN_FROM_AMOUNT = 300;
    uint256 public constant BURN_FROM_ALLOWANCE = 200;
    uint256 public constant BURN_FROM_INSUFFICIENT = 200;
    uint256 public constant BURN_INSUFFICIENT = 200;
    uint256 public constant BURN_FROM_SMALL = 100;
    uint256 public constant MINT_SMALL_AMOUNT = 100;
    uint256 public constant BURN_SMALL_AMOUNT = 100;
    uint256 public constant BURN_FROM_GREATER_THAN_SUPPLY = MINT_AMOUNT + BURN_SMALL_AMOUNT;
    bytes4 public constant ERC20_INSUFFICIENT_ALLOWANCE_SELECTOR = 0xfb8f41b2;
    bytes4 public constant ERC20_INSUFFICIENT_BALANCE_SELECTOR = 0xe450d38c;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        owner = address(this);
        user = address(0x1);
        newOwner = address(0x2);

        registry = _deployRegistry(owner);
        token = new EVE(address(registry));

        vm.prank(owner);
        registry.grantRole(Auth.MINTER_ROLE, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialize() public view {
        assertEq(address(token.registry()), address(registry));
        assertTrue(registry.hasRole(Auth.MINTER_ROLE, address(this)));
        assertEq(token.name(), "Everything Strategy");
        assertEq(token.symbol(), "EVE");
        assertEq(token.decimals(), TOKEN_DECIMALS);
        assertEq(token.totalSupply(), 0);
        assertEq(token.version(), "1.0.0");
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Transfer() public {
        // Deal tokens to owner first
        deal(address(token), owner, MINT_AMOUNT, true);

        vm.expectEmit(true, true, false, true);
        emit Transfer(owner, user, TRANSFER_AMOUNT);

        bool success = token.transfer(user, TRANSFER_AMOUNT);

        assertTrue(success);
        assertEq(token.balanceOf(owner), REMAINING_AMOUNT);
        assertEq(token.balanceOf(user), TRANSFER_AMOUNT);
    }

    function test_TransferInsufficientBalance() public {
        vm.expectRevert();
        token.transfer(user, TRANSFER_AMOUNT);
    }

    function test_Approve() public {
        vm.expectEmit(true, true, false, true);
        emit Approval(owner, user, APPROVAL_AMOUNT);

        bool success = token.approve(user, APPROVAL_AMOUNT);

        assertTrue(success);
        assertEq(token.allowance(owner, user), APPROVAL_AMOUNT);
    }

    function test_TransferFrom() public {
        // Deal tokens to owner
        deal(address(token), owner, MINT_AMOUNT, true);

        // Approve user to spend
        token.approve(user, APPROVAL_LARGE_AMOUNT);

        // Transfer from owner to newOwner as user
        vm.prank(user);
        bool success = token.transferFrom(owner, newOwner, TRANSFER_FROM_AMOUNT);

        assertTrue(success);
        assertEq(token.balanceOf(owner), TRANSFER_FROM_REMAINING);
        assertEq(token.balanceOf(newOwner), TRANSFER_FROM_AMOUNT);
        assertEq(token.allowance(owner, user), ALLOWANCE_REMAINING);
    }

    function test_TransferFromInsufficientAllowance() public {
        deal(address(token), owner, MINT_AMOUNT, true);
        token.approve(user, APPROVAL_AMOUNT);

        vm.prank(user);
        vm.expectRevert();
        token.transferFrom(owner, newOwner, TRANSFER_FROM_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                        MINTING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_OwnerCanMint() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), user, MINT_AMOUNT);

        token.mint(user, MINT_AMOUNT);

        assertEq(token.balanceOf(user), MINT_AMOUNT);
        assertEq(token.totalSupply(), MINT_AMOUNT);
    }

    function test_NonOwnerCannotMint() public {
        vm.prank(user);
        vm.expectRevert();
        token.mint(user, MINT_AMOUNT);
    }

    function test_MintToZeroAddress() public {
        vm.expectRevert();
        token.mint(address(0), MINT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                        BURNING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Burn() public {
        // Deal tokens first
        deal(address(token), owner, MINT_AMOUNT, true);

        vm.expectEmit(true, true, false, true);
        emit Transfer(owner, address(0), BURN_AMOUNT);

        token.burn(BURN_AMOUNT);

        assertEq(token.balanceOf(owner), BURN_AMOUNT);
        assertEq(token.totalSupply(), BURN_AMOUNT);
    }

    function test_BurnInsufficientBalance() public {
        deal(address(token), owner, MINT_SMALL_AMOUNT, true);

        vm.expectRevert();
        token.burn(BURN_INSUFFICIENT);
    }

    function test_BurnFrom() public {
        // Deal tokens to user
        deal(address(token), user, MINT_AMOUNT, true);

        // Approve owner to burn
        vm.prank(user);
        token.approve(owner, BURN_AMOUNT);

        // Burn from user as owner
        token.burnFrom(user, BURN_FROM_AMOUNT);

        assertEq(token.balanceOf(user), MINT_AMOUNT - BURN_FROM_AMOUNT);
        assertEq(token.totalSupply(), MINT_AMOUNT - BURN_FROM_AMOUNT);
        assertEq(token.allowance(user, owner), BURN_FROM_ALLOWANCE);
    }

    function test_BurnFromInsufficientAllowance() public {
        deal(address(token), user, MINT_AMOUNT, true);

        vm.prank(user);
        token.approve(owner, MINT_SMALL_AMOUNT);

        vm.expectRevert();
        token.burnFrom(user, BURN_FROM_AMOUNT);
    }

    function test_UserCanBurnOwnTokens() public {
        deal(address(token), user, MINT_AMOUNT, true);

        vm.prank(owner);
        registry.grantRole(Auth.MINTER_ROLE, user);

        vm.prank(user);
        token.burn(BURN_SMALL_AMOUNT);

        assertEq(token.balanceOf(user), MINT_AMOUNT - BURN_SMALL_AMOUNT);
    }

    function test_MinterCanBurnFromWithAllowance() public {
        deal(address(token), user, MINT_AMOUNT, true);

        vm.prank(user);
        token.approve(owner, BURN_SMALL_AMOUNT);

        uint256 supplyBefore = token.totalSupply();

        vm.expectEmit(true, true, false, true);
        emit Transfer(user, address(0), BURN_SMALL_AMOUNT);

        token.burnFrom(user, BURN_SMALL_AMOUNT);

        assertEq(token.balanceOf(user), MINT_AMOUNT - BURN_SMALL_AMOUNT);
        assertEq(token.allowance(user, owner), 0);
        assertEq(token.totalSupply(), supplyBefore - BURN_SMALL_AMOUNT);
    }

    function test_MinterCannotBurnFromWithoutAllowance() public {
        deal(address(token), user, MINT_AMOUNT, true);

        vm.expectRevert(abi.encodeWithSelector(ERC20_INSUFFICIENT_ALLOWANCE_SELECTOR, owner, 0, BURN_SMALL_AMOUNT));
        token.burnFrom(user, BURN_SMALL_AMOUNT);
    }

    function test_MinterCannotBurnFromWhenAccountHasInsufficientBalance() public {
        deal(address(token), user, MINT_SMALL_AMOUNT, true);

        vm.prank(user);
        token.approve(owner, BURN_FROM_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(ERC20_INSUFFICIENT_BALANCE_SELECTOR, user, MINT_SMALL_AMOUNT, BURN_FROM_AMOUNT)
        );
        token.burnFrom(user, BURN_FROM_AMOUNT);
    }

    function test_MinterCannotBurnFromGreaterThanTotalSupply() public {
        deal(address(token), user, MINT_AMOUNT, true);

        vm.prank(user);
        token.approve(owner, BURN_FROM_GREATER_THAN_SUPPLY);

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20_INSUFFICIENT_BALANCE_SELECTOR, user, MINT_AMOUNT, BURN_FROM_GREATER_THAN_SUPPLY
            )
        );
        token.burnFrom(user, BURN_FROM_GREATER_THAN_SUPPLY);
    }

    function test_NonMinterCannotBurnFromWithAllowance() public {
        deal(address(token), owner, MINT_AMOUNT, true);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.MINTER_ROLE));
        token.burnFrom(owner, BURN_SMALL_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                        ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_MinterRole_AccessControl() public {
        vm.prank(owner);
        registry.grantRole(Auth.MINTER_ROLE, newOwner);
        assertTrue(registry.hasRole(Auth.MINTER_ROLE, newOwner));

        vm.prank(owner);
        registry.revokeRole(Auth.MINTER_ROLE, newOwner);
        assertFalse(registry.hasRole(Auth.MINTER_ROLE, newOwner));

        vm.prank(user);
        vm.expectRevert();
        registry.grantRole(Auth.MINTER_ROLE, newOwner);
    }

    /*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_InitializeWithAnyOwner(address anyOwner) public {
        vm.assume(anyOwner != address(0));

        Registry newRegistry = _deployRegistry(anyOwner);
        EVE newToken = new EVE(address(newRegistry));

        assertEq(address(newToken.registry()), address(newRegistry));
    }

    function testFuzz_MintAmount(uint256 amount) public {
        vm.assume(amount < type(uint256).max / 2);

        token.mint(user, amount);

        assertEq(token.balanceOf(user), amount);
        assertEq(token.totalSupply(), amount);
    }

    function testFuzz_BurnAmount(uint256 mintAmount, uint256 burnAmount) public {
        vm.assume(mintAmount < type(uint256).max / 2);
        vm.assume(burnAmount <= mintAmount);

        deal(address(token), owner, mintAmount, true);

        token.burn(burnAmount);

        assertEq(token.balanceOf(owner), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function testFuzz_Transfer(address recipient, uint256 amount) public {
        vm.assume(recipient != address(0));
        vm.assume(amount < type(uint256).max / 2);

        deal(address(token), owner, amount, true);
        token.transfer(recipient, amount);

        assertEq(token.balanceOf(recipient), amount);
    }
}

/**
 * @title EVEV2Mock
 * @notice Mock contract for testing upgrades
 */
contract EVEV2Mock is EVE {
    constructor(address initialOwner) EVE(initialOwner) {}

    function version() public pure override returns (string memory) {
        return "2.0.0";
    }

    function newFunctionV2() public pure returns (string memory) {
        return "This is a new function in V2";
    }
}
