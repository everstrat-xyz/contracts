// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ProtocolTestBase} from "../../../helpers/ProtocolTestBase.sol";
import {IStrategy} from "../../../../src/interfaces/IStrategy.sol";

contract BatchIsolationStrategy is IStrategy {
    error PreflightReverted();

    bool public revertMaxDeposit;
    bool public revertMaxWithdrawal;
    bool public revertHealthy;
    bool public revertPaused;
    bool public healthy = true;
    bool public pauseState;
    bool public revertSync;
    uint256 public revertDataSize;
    uint256 public maxDepositValue = 10 ether;
    uint256 public maxWithdrawalValue = 10 ether;
    uint256 public depositCalls;
    uint256 public withdrawalCalls;
    uint256 public rebalanceCalls;
    uint256 public syncCalls;

    receive() external payable {}

    function setPreflightReverts(bool md, bool mw, bool h, bool p) external {
        revertMaxDeposit = md;
        revertMaxWithdrawal = mw;
        revertHealthy = h;
        revertPaused = p;
    }

    function setHealthy(bool value) external {
        healthy = value;
    }

    function setSyncBomb(bool enabled, uint256 size) external {
        revertSync = enabled;
        revertDataSize = size;
    }

    function name() external pure override returns (string memory) {
        return "Batch isolation strategy";
    }

    function version() external pure override returns (string memory) {
        return "1";
    }

    function genesisTimestamp() external pure override returns (uint256) {
        return 1;
    }

    function navInETH() external view override returns (uint256) {
        return address(this).balance;
    }

    function totalDeposited() external view override returns (uint256) {
        return address(this).balance;
    }

    function totalWithdrawn() external view override returns (uint256) {
        return withdrawalCalls;
    }

    function isHealthy() external view override returns (bool) {
        if (revertHealthy) revert PreflightReverted();
        return healthy;
    }

    function maxDeposit() external view override returns (uint256) {
        if (revertMaxDeposit) revert PreflightReverted();
        return maxDepositValue;
    }

    function maxWithdrawal() external view override returns (uint256) {
        if (revertMaxWithdrawal) revert PreflightReverted();
        return maxWithdrawalValue;
    }

    function paused() external view override returns (bool) {
        if (revertPaused) revert PreflightReverted();
        return pauseState;
    }

    function deposit() external payable override {
        ++depositCalls;
    }

    function investIdleETH() external pure override returns (uint256) {
        return 0;
    }

    function withdraw(address receiver, uint256 amount) external override returns (uint256) {
        ++withdrawalCalls;
        uint256 paid = amount < address(this).balance ? amount : address(this).balance;
        (bool ok,) = payable(receiver).call{value: paid}("");
        require(ok);
        return paid;
    }

    function rebalance() external override {
        ++rebalanceCalls;
        healthy = true;
    }

    function sync() external override {
        if (revertSync) _revertWithSize(revertDataSize);
        ++syncCalls;
    }

    function pendingPerformanceFeeInETH(uint256) external pure override returns (uint256) {
        return 0;
    }

    function settlePerformanceFee(uint256) external pure override returns (uint256) {
        return 0;
    }

    function emergencyExit() external override {}

    function _revertWithSize(uint256 size) private pure {
        assembly {
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, size))
            revert(ptr, size)
        }
    }
}

contract StrategyBatchIsolationVerificationTest is ProtocolTestBase {
    ProtocolContracts private protocol;
    BatchIsolationStrategy private bad;
    BatchIsolationStrategy private healthy;

    function setUp() public {
        protocol = _deployProtocol(address(this), 5e17);
        bad = new BatchIsolationStrategy();
        healthy = new BatchIsolationStrategy();
        protocol.strategyManager.addStrategy(address(bad), 50, 50);
        protocol.strategyManager.addStrategy(address(healthy), 50, 50);
    }

    function test_A_DepositPreflightViewsAbortBeforeHealthyPeer() public {
        vm.deal(address(protocol.strategyManager), 2 ether);

        bad.setPreflightReverts(true, false, false, false);
        vm.prank(address(protocol.controller));
        vm.expectRevert(BatchIsolationStrategy.PreflightReverted.selector);
        protocol.strategyManager.depositToStrategies(2 ether);
        assertEq(healthy.depositCalls(), 0);

        bad.setPreflightReverts(false, false, true, false);
        vm.prank(address(protocol.controller));
        vm.expectRevert(BatchIsolationStrategy.PreflightReverted.selector);
        protocol.strategyManager.depositToStrategies(2 ether);
        assertEq(healthy.depositCalls(), 0);
    }

    function test_A_WithdrawalMaxViewAbortsBeforeHealthyPeer() public {
        vm.deal(address(healthy), 2 ether);
        bad.setPreflightReverts(false, true, false, false);

        vm.prank(address(protocol.controller));
        vm.expectRevert(BatchIsolationStrategy.PreflightReverted.selector);
        protocol.strategyManager.withdrawFromStrategies(2 ether);
        assertEq(healthy.withdrawalCalls(), 0);
        assertEq(address(healthy).balance, 2 ether);
    }

    function test_A_PausedAndHealthViewsAbortRebalanceAndSyncBatches() public {
        healthy.setHealthy(false);
        bad.setPreflightReverts(false, false, false, true);

        vm.prank(address(protocol.controller));
        vm.expectRevert(BatchIsolationStrategy.PreflightReverted.selector);
        protocol.strategyManager.checkAndRebalanceStrategies();
        assertEq(healthy.rebalanceCalls(), 0);

        vm.prank(address(protocol.controller));
        vm.expectRevert(BatchIsolationStrategy.PreflightReverted.selector);
        protocol.strategyManager.syncStrategies();
        assertEq(healthy.syncCalls(), 0);

        bad.setPreflightReverts(false, false, true, false);
        vm.prank(address(protocol.controller));
        vm.expectRevert(BatchIsolationStrategy.PreflightReverted.selector);
        protocol.strategyManager.checkAndRebalanceStrategies();
        assertEq(healthy.rebalanceCalls(), 0);
    }

    function test_B_OversizedCaughtReasonExhaustsBatchGasAndRollsBackPeer() public {
        bad.setSyncBomb(true, 4);
        vm.prank(address(protocol.controller));
        (bool compactOk,) =
            address(protocol.strategyManager).call{gas: 30_000_000}(abi.encodeWithSignature("syncStrategies()"));
        assertTrue(compactOk);
        assertEq(healthy.syncCalls(), 1);

        // The callee can afford to form 3 MB of returndata, but binding/copying it in
        // catch(bytes) cannot complete inside a mainnet-scale 30m gas envelope.
        bad.setSyncBomb(true, 3_000_000);
        vm.prank(address(protocol.controller));
        (bool oversizedOk,) =
            address(protocol.strategyManager).call{gas: 30_000_000}(abi.encodeWithSignature("syncStrategies()"));
        assertFalse(oversizedOk);
        assertEq(healthy.syncCalls(), 1);
    }
}
