// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {Registry} from "registry/Registry.sol";
import {Whitelist} from "../../src/contracts/Whitelist.sol";
import {IWhitelist} from "../../src/interfaces/IWhitelist.sol";
import {IRegistryClient} from "interfaces/IRegistryClient.sol";
import {Auth} from "../../src/libraries/Auth.sol";

import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";

/**
 * @title Whitelist Test
 * @notice Comprehensive unit tests for the Whitelist contract.
 */
contract WhitelistTest is ProtocolTestBase {
    Registry public registry;
    Whitelist public whitelist;

    address public admin = makeAddr("admin");
    address public security = makeAddr("security");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public relayer = makeAddr("relayer");

    uint256 public constant SIGNER_PK = 0xA11CE;
    uint256 public constant OTHER_SIGNER_PK = 0xB0B;
    address public signer;
    address public otherSigner;

    uint256 public constant FUTURE_DEADLINE = 1_000_000_000_000;

    function setUp() public {
        signer = vm.addr(SIGNER_PK);
        otherSigner = vm.addr(OTHER_SIGNER_PK);

        registry = _deployRegistry(admin);

        vm.prank(admin);
        registry.grantRole(Auth.SECURITY_ROLE, security);

        whitelist = new Whitelist(address(registry));

        vm.warp(1); // block.timestamp starts non-zero so deadline checks are meaningful
    }

    /*//////////////////////////////////////////////////////////////
                        HELPERS
    //////////////////////////////////////////////////////////////*/

    function _addSigner(address _signer) internal {
        vm.prank(admin);
        whitelist.addSigner(_signer);
    }

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

    function _signInvite(uint256 _pk, Whitelist _w, address _user, bytes32 _inviteId, uint256 _deadline)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 structHash = keccak256(abi.encode(_w.INVITE_TYPEHASH(), _user, _inviteId, _deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(_w), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_pk, digest);
        signature = abi.encodePacked(r, s, v);
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_RevertsOnZeroRegistry() public {
        vm.expectRevert(IRegistryClient.RegistryClientZeroRegistry.selector);
        new Whitelist(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        isWhitelisted()
    //////////////////////////////////////////////////////////////*/

    function test_IsWhitelisted_FalseByDefault() public view {
        assertFalse(whitelist.isWhitelisted(user1));
    }

    function test_IsWhitelisted_TrueWhenLocallyWhitelisted() public {
        address[] memory users = new address[](1);
        users[0] = user1;
        vm.prank(admin);
        whitelist.addToWhitelist(users);

        assertTrue(whitelist.isWhitelisted(user1));
    }

    function test_IsWhitelisted_TrueForEveryoneWhenDisabled() public {
        vm.prank(admin);
        whitelist.disable();

        assertTrue(whitelist.isWhitelisted(user1));
        assertTrue(whitelist.isWhitelisted(user2));
    }

    function test_IsWhitelisted_TrueForBannedUserWhenDisabled() public {
        vm.startPrank(admin);
        whitelist.removeFromWhitelist(user1);
        assertFalse(whitelist.isWhitelisted(user1));
        assertTrue(whitelist.isBanned(user1));

        whitelist.disable();
        vm.stopPrank();

        // disable() opens the protocol: pre-disable bans no longer gate entry.
        assertTrue(whitelist.isWhitelisted(user1));
        assertTrue(whitelist.isBanned(user1));
        assertTrue(whitelist.isWhitelisted(user2));
    }

    function _singleton(address _a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = _a;
    }

    /*//////////////////////////////////////////////////////////////
                        whitelist()
    //////////////////////////////////////////////////////////////*/

    function test_Whitelist_AlreadyWhitelisted_NoOp() public {
        _addSigner(signer);
        vm.prank(admin);
        whitelist.addToWhitelist(_singleton(user1));

        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(SIGNER_PK, whitelist, user1, inviteId, FUTURE_DEADLINE);

        // No revert, and the invite is left unconsumed.
        whitelist.whitelist(user1, inviteId, FUTURE_DEADLINE, signature);

        assertFalse(whitelist.isInviteUsed(inviteId));
    }

    function test_Whitelist_RevertsWhenUserBanned() public {
        _addSigner(signer);
        vm.prank(admin);
        whitelist.removeFromWhitelist(user1);

        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(SIGNER_PK, whitelist, user1, inviteId, FUTURE_DEADLINE);

        vm.expectRevert(abi.encodeWithSelector(IWhitelist.WhitelistUserBanned.selector, user1));
        whitelist.whitelist(user1, inviteId, FUTURE_DEADLINE, signature);
    }

    function test_Whitelist_RevertsWhenInviteAlreadyUsed() public {
        _addSigner(signer);
        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature1 = _signInvite(SIGNER_PK, whitelist, user1, inviteId, FUTURE_DEADLINE);
        whitelist.whitelist(user1, inviteId, FUTURE_DEADLINE, signature1);

        // Same inviteId, different (unwhitelisted) recipient.
        bytes memory signature2 = _signInvite(SIGNER_PK, whitelist, user2, inviteId, FUTURE_DEADLINE);

        vm.expectRevert(abi.encodeWithSelector(IWhitelist.WhitelistInviteAlreadyUsed.selector, inviteId));
        whitelist.whitelist(user2, inviteId, FUTURE_DEADLINE, signature2);
    }

    function test_Whitelist_RevertsWhenDeadlineExpired() public {
        _addSigner(signer);
        vm.warp(FUTURE_DEADLINE + 1);

        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(SIGNER_PK, whitelist, user1, inviteId, FUTURE_DEADLINE);

        vm.expectRevert(abi.encodeWithSelector(IWhitelist.WhitelistSignatureExpired.selector, FUTURE_DEADLINE));
        whitelist.whitelist(user1, inviteId, FUTURE_DEADLINE, signature);
    }

    function test_Whitelist_RevertsOnMalformedSignature() public {
        bytes32 inviteId = keccak256("invite-1");
        bytes memory badSignature = hex"1234";

        vm.expectRevert();
        whitelist.whitelist(user1, inviteId, FUTURE_DEADLINE, badSignature);
    }

    function test_Whitelist_RevertsWhenSignerNotAuthorized() public {
        // otherSigner is never added via addSigner().
        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(OTHER_SIGNER_PK, whitelist, user1, inviteId, FUTURE_DEADLINE);

        vm.expectRevert(IWhitelist.WhitelistInvalidSignature.selector);
        whitelist.whitelist(user1, inviteId, FUTURE_DEADLINE, signature);
    }

    function test_Whitelist_SucceedsWithValidVoucher() public {
        _addSigner(signer);
        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(SIGNER_PK, whitelist, user1, inviteId, FUTURE_DEADLINE);

        vm.expectEmit(true, true, false, true, address(whitelist));
        emit IWhitelist.UserWhitelisted(user1, inviteId, block.timestamp);
        whitelist.whitelist(user1, inviteId, FUTURE_DEADLINE, signature);

        assertTrue(whitelist.isWhitelisted(user1));
        assertTrue(whitelist.isInviteUsed(inviteId));
    }

    function test_Whitelist_VoucherIsBoundToTheSpecifiedUser() public {
        _addSigner(signer);
        bytes32 inviteId = keccak256("invite-1");
        // Voucher signed for user1...
        bytes memory signature = _signInvite(SIGNER_PK, whitelist, user1, inviteId, FUTURE_DEADLINE);

        // ...cannot be used to whitelist user2.
        vm.expectRevert(IWhitelist.WhitelistInvalidSignature.selector);
        whitelist.whitelist(user2, inviteId, FUTURE_DEADLINE, signature);
    }

    function test_Whitelist_IsPermissionless_RelayerCanSubmit() public {
        _addSigner(signer);
        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(SIGNER_PK, whitelist, user1, inviteId, FUTURE_DEADLINE);

        vm.prank(relayer);
        whitelist.whitelist(user1, inviteId, FUTURE_DEADLINE, signature);

        assertTrue(whitelist.isWhitelisted(user1));
    }

    function test_Whitelist_ReplayAfterWhitelistedIsNoOpNotRevert() public {
        _addSigner(signer);
        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(SIGNER_PK, whitelist, user1, inviteId, FUTURE_DEADLINE);
        whitelist.whitelist(user1, inviteId, FUTURE_DEADLINE, signature);

        // Replaying the exact same (now-consumed) voucher for the same, already-whitelisted
        // user must be a no-op, not a WhitelistInviteAlreadyUsed revert.
        whitelist.whitelist(user1, inviteId, FUTURE_DEADLINE, signature);
    }

    function test_Whitelist_NoOpWhenDisabled() public {
        _addSigner(signer);
        vm.prank(admin);
        whitelist.disable();

        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(SIGNER_PK, whitelist, user1, inviteId, FUTURE_DEADLINE);

        // disable() makes isWhitelisted true for everyone, so redemption is a no-op.
        whitelist.whitelist(user1, inviteId, FUTURE_DEADLINE, signature);

        assertFalse(whitelist.isInviteUsed(inviteId));
    }

    /*//////////////////////////////////////////////////////////////
                        addToWhitelist()
    //////////////////////////////////////////////////////////////*/

    function test_AddToWhitelist_AccessControl() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        whitelist.addToWhitelist(_singleton(user1));
    }

    function test_AddToWhitelist_RevertsOnZeroAddress() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = address(0);

        vm.prank(admin);
        vm.expectRevert(IWhitelist.WhitelistZeroAddress.selector);
        whitelist.addToWhitelist(users);
    }

    function test_AddToWhitelist_WhitelistsAllAddresses() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        vm.prank(admin);
        whitelist.addToWhitelist(users);

        assertTrue(whitelist.isWhitelisted(user1));
        assertTrue(whitelist.isWhitelisted(user2));
    }

    function test_AddToWhitelist_RevertsWhenDisabled() public {
        vm.startPrank(admin);
        whitelist.disable();

        vm.expectRevert(IWhitelist.WhitelistIsDisabled.selector);
        whitelist.addToWhitelist(_singleton(user1));
        vm.stopPrank();
    }

    function test_AddToWhitelist_ClearsPriorBan() public {
        _addSigner(signer);
        bytes32 inviteId = keccak256("invite-after-unban");
        bytes memory signature = _signInvite(SIGNER_PK, whitelist, user1, inviteId, FUTURE_DEADLINE);

        vm.startPrank(admin);
        whitelist.removeFromWhitelist(user1);
        assertTrue(whitelist.isBanned(user1));
        assertFalse(whitelist.isWhitelisted(user1));

        whitelist.addToWhitelist(_singleton(user1));
        vm.stopPrank();

        assertFalse(whitelist.isBanned(user1));
        assertTrue(whitelist.isWhitelisted(user1));

        // Ban lift also restores the permissionless voucher path for that address.
        // Already whitelisted => redeem is a no-op (invite left unconsumed).
        whitelist.whitelist(user1, inviteId, FUTURE_DEADLINE, signature);
        assertFalse(whitelist.isInviteUsed(inviteId));
    }

    /*//////////////////////////////////////////////////////////////
                        removeFromWhitelist()
    //////////////////////////////////////////////////////////////*/

    function test_RemoveFromWhitelist_AccessControl() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        whitelist.removeFromWhitelist(user1);
    }

    function test_RemoveFromWhitelist_BansUserPermanently() public {
        vm.startPrank(admin);
        whitelist.addToWhitelist(_singleton(user1));
        assertTrue(whitelist.isWhitelisted(user1));

        whitelist.removeFromWhitelist(user1);
        vm.stopPrank();

        assertFalse(whitelist.isWhitelisted(user1));
        assertTrue(whitelist.isBanned(user1));
    }

    function test_RemoveFromWhitelist_BlocksStaleUnconsumedVoucher() public {
        _addSigner(signer);
        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(SIGNER_PK, whitelist, user1, inviteId, FUTURE_DEADLINE);

        // Ban happens before the voucher is ever redeemed.
        vm.prank(admin);
        whitelist.removeFromWhitelist(user1);

        vm.expectRevert(abi.encodeWithSelector(IWhitelist.WhitelistUserBanned.selector, user1));
        whitelist.whitelist(user1, inviteId, FUTURE_DEADLINE, signature);
    }

    function test_RemoveFromWhitelist_RevertsWhenDisabled() public {
        vm.startPrank(admin);
        whitelist.disable();

        vm.expectRevert(IWhitelist.WhitelistIsDisabled.selector);
        whitelist.removeFromWhitelist(user1);
        vm.stopPrank();
    }

    function test_RemoveFromWhitelist_PreDisableBanLiftedByDisable() public {
        vm.startPrank(admin);
        whitelist.removeFromWhitelist(user1);
        assertFalse(whitelist.isWhitelisted(user1));

        whitelist.disable();
        vm.stopPrank();

        assertTrue(whitelist.isWhitelisted(user1));
    }

    /*//////////////////////////////////////////////////////////////
                        addSigner() / removeSigner()
    //////////////////////////////////////////////////////////////*/

    function test_AddSigner_AccessControl() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        whitelist.addSigner(signer);
    }

    function test_AddSigner_SecurityRoleCannotAddSigner() public {
        vm.prank(security);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        whitelist.addSigner(signer);
    }

    function test_AddSigner_RevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IWhitelist.WhitelistZeroAddress.selector);
        whitelist.addSigner(address(0));
    }

    function test_AddSigner_RevertsWhenAlreadyAdded() public {
        _addSigner(signer);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IWhitelist.WhitelistSignerAlreadyAdded.selector, signer));
        whitelist.addSigner(signer);
    }

    function test_AddSigner_Succeeds() public {
        assertFalse(whitelist.isSigner(signer));
        _addSigner(signer);
        assertTrue(whitelist.isSigner(signer));
    }

    function test_AddSigner_RevertsWhenDisabled() public {
        vm.startPrank(admin);
        whitelist.disable();

        vm.expectRevert(IWhitelist.WhitelistIsDisabled.selector);
        whitelist.addSigner(signer);
        vm.stopPrank();
    }

    function test_RemoveSigner_RevertsWhenCallerHasNeitherRole() public {
        _addSigner(signer);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRegistryClient.RegistryClientCallerHasNoneOfRoles.selector, Auth.ADMIN_ROLE, Auth.SECURITY_ROLE
            )
        );
        whitelist.removeSigner(signer);
    }

    function test_RemoveSigner_RevertsWhenSignerNotFound() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IWhitelist.WhitelistSignerNotFound.selector, signer));
        whitelist.removeSigner(signer);
    }

    function test_RemoveSigner_AdminCanRemove() public {
        _addSigner(signer);

        vm.prank(admin);
        whitelist.removeSigner(signer);

        assertFalse(whitelist.isSigner(signer));
    }

    function test_RemoveSigner_SecurityCanRemoveInstantly() public {
        _addSigner(signer);

        vm.prank(security);
        whitelist.removeSigner(signer);

        assertFalse(whitelist.isSigner(signer));
    }

    function test_RemoveSigner_RevokedSignerCanNoLongerWhitelist() public {
        _addSigner(signer);
        vm.prank(security);
        whitelist.removeSigner(signer);

        bytes32 inviteId = keccak256("invite-1");
        bytes memory signature = _signInvite(SIGNER_PK, whitelist, user1, inviteId, FUTURE_DEADLINE);

        vm.expectRevert(IWhitelist.WhitelistInvalidSignature.selector);
        whitelist.whitelist(user1, inviteId, FUTURE_DEADLINE, signature);
    }

    function test_RemoveSigner_RevertsWhenDisabled() public {
        _addSigner(signer);

        vm.startPrank(admin);
        whitelist.disable();

        vm.expectRevert(IWhitelist.WhitelistIsDisabled.selector);
        whitelist.removeSigner(signer);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        disable()
    //////////////////////////////////////////////////////////////*/

    function test_Disable_AccessControl() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        whitelist.disable();
    }

    function test_Disable_SecurityRoleCannotDisable() public {
        vm.prank(security);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        whitelist.disable();
    }

    function test_Disable_Succeeds() public {
        assertFalse(whitelist.disabled());

        vm.prank(admin);
        whitelist.disable();

        assertTrue(whitelist.disabled());
        assertTrue(whitelist.isWhitelisted(user1));
        assertTrue(whitelist.isWhitelisted(user2));
    }

    function test_Disable_RevertsWhenAlreadyDisabled() public {
        vm.startPrank(admin);
        whitelist.disable();

        vm.expectRevert(IWhitelist.WhitelistIsDisabled.selector);
        whitelist.disable();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        version()
    //////////////////////////////////////////////////////////////*/

    function test_Version() public view {
        assertEq(whitelist.version(), "1.0.0");
    }
}
