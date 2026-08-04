// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {AMM} from "../../src/contracts/AMM.sol";
import {EVE} from "../../src/contracts/EVE.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {Whitelist} from "../../src/contracts/Whitelist.sol";
import {Registry} from "registry/Registry.sol";

import {IAMM} from "../../src/interfaces/IAMM.sol";
import {IWhitelist} from "../../src/interfaces/IWhitelist.sol";

import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";

/**
 * @title AMM Whitelist Gating Test
 * @notice Covers the Whitelist gate on `AMM.enter()`/`enterWithInvite()`. Deploys the
 * protocol WITHOUT disabling the Whitelist (unlike `AMMTest`, which relies on
 * `ProtocolTestBase._deployProtocol()` disabling it by default) so the gate is actually
 * exercised.
 */
contract AMMWhitelistTest is ProtocolTestBase {
    ProtocolContracts internal contracts;
    AMM internal amm;
    Whitelist internal whitelist;
    Oracle internal oracle;
    EVE internal eve;

    address internal admin;
    address internal user1;
    address internal user2;
    address internal signer;

    uint256 internal constant SIGNER_PK = 0xA11CE;
    uint256 internal constant UNAUTHORIZED_SIGNER_PK = 0xBAD;

    uint256 internal constant INITIAL_CW = 9e17;
    int256 internal constant ETH_PRICE = 4000e8;
    uint256 internal constant STALENESS_INTERVAL = 3600;
    uint256 internal constant BOOTSTRAP_ETH_DEPOSIT = 1e18;
    uint256 internal constant BOOTSTRAP_MIN_TOKENS = 1000e18;
    uint256 internal constant FUTURE_DEADLINE = 1_000_000_000_000;

    function setUp() public {
        admin = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        signer = vm.addr(SIGNER_PK);

        contracts = _deployProtocolInstances(admin, INITIAL_CW);
        _registerProtocolContracts(contracts.registry, contracts, admin, true);
        _grantProtocolRoles(contracts.registry, contracts, admin, admin);
        // Deliberately do NOT call _disableWhitelistByDefault(): these tests exercise the
        // gate itself.

        amm = contracts.amm;
        whitelist = contracts.whitelist;
        oracle = contracts.oracle;
        eve = contracts.token;

        MockPriceFeed ethPriceFeed = new MockPriceFeed(8, ETH_PRICE);
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);

        whitelist.addSigner(signer);

        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        HELPERS
    //////////////////////////////////////////////////////////////*/

    function _domainSeparator(Whitelist _w) internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) = _w.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function _signInvite(uint256 _pk, address _user, bytes32 _inviteId, uint256 _deadline)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 structHash = keccak256(abi.encode(whitelist.INVITE_TYPEHASH(), _user, _inviteId, _deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(whitelist), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_pk, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _whitelistAdmin(address _user) internal {
        address[] memory users = new address[](1);
        users[0] = _user;
        whitelist.addToWhitelist(users);
    }

    /*//////////////////////////////////////////////////////////////
                        enter() gating
    //////////////////////////////////////////////////////////////*/

    function test_Enter_RevertsWhenNotWhitelisted() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAMM.AMMNotWhitelisted.selector, user1));
        amm.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
    }

    function test_Enter_RevertsForBannedUser() public {
        whitelist.removeFromWhitelist(user1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAMM.AMMNotWhitelisted.selector, user1));
        amm.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
    }

    function test_Enter_SucceedsWhenAdminWhitelisted() public {
        _whitelistAdmin(user1);

        vm.prank(user1);
        amm.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);

        assertTrue(amm.bootstrapped());
        assertGt(eve.balanceOf(user1), 0);
    }

    function test_Enter_BootstrapperMustAlsoBeWhitelisted() public {
        // The gate applies uniformly: the very first (bootstrap) enter() is not exempt.
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAMM.AMMNotWhitelisted.selector, user1));
        amm.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);

        assertFalse(amm.bootstrapped());
    }

    function test_Enter_SucceedsForEveryoneWhenGateDisabled() public {
        whitelist.disable();

        vm.prank(user1);
        amm.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);

        assertTrue(amm.bootstrapped());
    }

    function test_Enter_SecondUserAlsoGatedAfterBootstrap() public {
        _whitelistAdmin(user1);
        vm.prank(user1);
        amm.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);

        // user2 was never whitelisted.
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IAMM.AMMNotWhitelisted.selector, user2));
        amm.enter{value: 0.5 ether}(1e18);
    }

    /*//////////////////////////////////////////////////////////////
                        enterWithInvite()
    //////////////////////////////////////////////////////////////*/

    function test_EnterWithInvite_WhitelistsAndEntersAtomically() public {
        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(SIGNER_PK, user1, inviteId, FUTURE_DEADLINE);

        vm.prank(user1);
        amm.enterWithInvite{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS, inviteId, FUTURE_DEADLINE, signature);

        assertTrue(whitelist.isWhitelisted(user1));
        assertTrue(whitelist.isInviteUsed(inviteId));
        assertTrue(amm.bootstrapped());
        assertGt(eve.balanceOf(user1), 0);
    }

    function test_EnterWithInvite_RevertsOnUnauthorizedSigner() public {
        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(UNAUTHORIZED_SIGNER_PK, user1, inviteId, FUTURE_DEADLINE);

        vm.prank(user1);
        vm.expectRevert(IWhitelist.WhitelistInvalidSignature.selector);
        amm.enterWithInvite{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS, inviteId, FUTURE_DEADLINE, signature);

        assertFalse(whitelist.isWhitelisted(user1));
        assertFalse(amm.bootstrapped());
    }

    function test_EnterWithInvite_RevertsWhenDeadlineExpired() public {
        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(SIGNER_PK, user1, inviteId, FUTURE_DEADLINE);
        vm.warp(FUTURE_DEADLINE + 1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IWhitelist.WhitelistSignatureExpired.selector, FUTURE_DEADLINE));
        amm.enterWithInvite{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS, inviteId, FUTURE_DEADLINE, signature);
    }

    function test_EnterWithInvite_VoucherIsBoundToCaller() public {
        // Signed for user1...
        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(SIGNER_PK, user1, inviteId, FUTURE_DEADLINE);

        // ...a relayer cannot submit it as msg.sender to redirect the minted EVE to itself.
        vm.prank(user2);
        vm.expectRevert(IWhitelist.WhitelistInvalidSignature.selector);
        amm.enterWithInvite{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS, inviteId, FUTURE_DEADLINE, signature);

        assertFalse(whitelist.isWhitelisted(user2));
    }

    function test_EnterWithInvite_AlreadyWhitelistedLeavesVoucherUnconsumed() public {
        _whitelistAdmin(user1);

        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(SIGNER_PK, user1, inviteId, FUTURE_DEADLINE);

        vm.prank(user1);
        amm.enterWithInvite{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS, inviteId, FUTURE_DEADLINE, signature);

        assertTrue(amm.bootstrapped());
        assertFalse(whitelist.isInviteUsed(inviteId));
    }

    function test_EnterWithInvite_SucceedsAfterGateDisabledWithoutRedeemingVoucher() public {
        whitelist.disable();

        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(SIGNER_PK, user1, inviteId, FUTURE_DEADLINE);

        vm.prank(user1);
        amm.enterWithInvite{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS, inviteId, FUTURE_DEADLINE, signature);

        // whitelist() no-ops when disabled; invite left unconsumed, enter still succeeds.
        assertTrue(amm.bootstrapped());
        assertFalse(whitelist.isInviteUsed(inviteId));
        assertGt(eve.balanceOf(user1), 0);
    }

    function test_EnterWithInvite_RevertsWhenPaused() public {
        vm.prank(admin);
        amm.pause();

        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(SIGNER_PK, user1, inviteId, FUTURE_DEADLINE);

        vm.prank(user1);
        vm.expectRevert();
        amm.enterWithInvite{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS, inviteId, FUTURE_DEADLINE, signature);
    }

    /*//////////////////////////////////////////////////////////////
                        exit() is never gated
    //////////////////////////////////////////////////////////////*/

    function test_Exit_NeverGatedByWhitelist_EvenAfterBan() public {
        _whitelistAdmin(user1);
        vm.prank(user1);
        amm.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);

        uint256 balance = eve.balanceOf(user1);

        whitelist.removeFromWhitelist(user1);
        assertFalse(whitelist.isWhitelisted(user1));

        vm.startPrank(user1);
        eve.approve(address(amm), balance);
        amm.exit(0.01 ether, balance, 1e17);
        vm.stopPrank();
    }
}
