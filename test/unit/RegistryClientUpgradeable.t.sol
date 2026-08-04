// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {IRegistryClient} from "interfaces/IRegistryClient.sol";
import {RegistryClientUpgradeable} from "../../src/contracts/registry/client/RegistryClientUpgradeable.sol";

/// @dev Exposes the internal initializer so the mixin can be exercised in isolation.
contract RegistryClientUpgradeableHarness is RegistryClientUpgradeable {
    function initialize(address _registry) external initializer {
        __RegistryClient_init(_registry);
    }
}

contract RegistryClientUpgradeableTest is Test {
    /// @dev Namespace declared via @custom:storage-location in RegistryClientUpgradeable.
    string internal constant NAMESPACE = "everstrat.storage.RegistryClientUpgradeable";

    /// @dev Must equal REGISTRY_CLIENT_UPGRADEABLE_STORAGE_LOCATION in RegistryClientUpgradeable.
    bytes32 internal constant EXPECTED_STORAGE_LOCATION =
        0xbd1fcda84d3854fffab59d162ed55717edaf79b73401f77c755ab4e42954fe00;

    RegistryClientUpgradeableHarness internal harness;

    function setUp() public {
        harness = new RegistryClientUpgradeableHarness();
    }

    /// @dev ERC-7201: keccak256(abi.encode(uint256(keccak256(namespace)) - 1)) & ~bytes32(uint256(0xff))
    function _erc7201Slot(string memory _namespace) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(_namespace))) - 1)) & ~bytes32(uint256(0xff));
    }

    function test_StorageLocation_MatchesErc7201Formula() public pure {
        assertEq(_erc7201Slot(NAMESPACE), EXPECTED_STORAGE_LOCATION);
    }

    function test_StorageLocation_ContractWritesRegistryToErc7201Slot() public {
        address registryAddress = makeAddr("registry");

        harness.initialize(registryAddress);

        // The registry must live exactly at the slot derived from the declared namespace,
        // proving the contract's private constant matches the ERC-7201 formula.
        bytes32 storedValue = vm.load(address(harness), _erc7201Slot(NAMESPACE));
        assertEq(address(uint160(uint256(storedValue))), registryAddress);
        assertEq(address(harness.registry()), registryAddress);
    }

    function test_Initialize_RevertsOnZeroRegistry() public {
        vm.expectRevert(IRegistryClient.RegistryClientZeroRegistry.selector);
        harness.initialize(address(0));
    }
}
