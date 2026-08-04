// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IStrategy} from "../../src/interfaces/IStrategy.sol";

/**
 * @title MockStrategy
 * @notice Mock strategy contract for testing
 * @dev Implements IStrategy interface with configurable behavior.
 *      Allocation weights live on StrategyManager — not on the strategy.
 */
contract MockStrategy is IStrategy {
    error MockStrategyNavReverted();
    error MockStrategyNotPaused();
    error MockStrategyDepositReverted();
    error MockStrategyWithdrawReverted();
    error MockStrategyRebalanceReverted();
    error MockStrategySyncReverted();
    error MockStrategySettlePerformanceFeeReverted();
    error MockStrategyCallerNotStrategyManager();

    // ============ State Variables ============
    string private _name;
    uint256 private _genesisTimestamp;
    uint256 private _navInETH;
    uint256 private _totalDeposited;
    uint256 private _totalWithdrawn;
    bool private _isHealthy;
    uint256 private _maxDeposit;
    uint256 private _maxWithdrawal;
    uint256 private _withdrawalFeeBps;
    bool private _revertNavInETH;
    bool private _revertDeposit;
    bool private _revertWithdraw;
    bool private _revertRebalance;
    bool private _revertSync;
    bool private _revertSettlePerformanceFee;
    bool private _paused;
    address public controller;
    address public strategyManager;

    uint256 private _cumulativeLpFeesEarnedInETH;
    uint256 private _cumulativeLpFeesChargedInETH;

    // ============ Constructor ============
    constructor(string memory name_, address controller_, address strategyManager_) {
        _name = name_;
        _genesisTimestamp = block.timestamp;
        _isHealthy = true;
        _maxDeposit = type(uint256).max;
        _maxWithdrawal = type(uint256).max;
        controller = controller_;
        strategyManager = strategyManager_;
    }

    // ============ View Functions ============
    function name() external view override returns (string memory) {
        return _name;
    }

    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    function genesisTimestamp() external view override returns (uint256) {
        return _genesisTimestamp;
    }

    function navInETH() external view override returns (uint256) {
        if (_revertNavInETH) revert MockStrategyNavReverted();
        return _navInETH;
    }

    function totalDeposited() external view override returns (uint256) {
        return _totalDeposited;
    }

    function totalWithdrawn() external view override returns (uint256) {
        return _totalWithdrawn;
    }

    function isHealthy() external view override returns (bool) {
        return _isHealthy;
    }

    function maxDeposit() external view override returns (uint256) {
        return _maxDeposit;
    }

    function maxWithdrawal() external view override returns (uint256) {
        return _maxWithdrawal;
    }

    function paused() external view override returns (bool) {
        return _paused;
    }

    // ============ Setters (for testing) ============
    function setNavInETH(uint256 nav_) external {
        _navInETH = nav_;
    }

    function setRevertNavInETH(bool revert_) external {
        _revertNavInETH = revert_;
    }

    function setPaused(bool paused_) external {
        _paused = paused_;
    }

    function setIsHealthy(bool healthy_) external {
        _isHealthy = healthy_;
    }

    function setRevertDeposit(bool revert_) external {
        _revertDeposit = revert_;
    }

    function setRevertWithdraw(bool revert_) external {
        _revertWithdraw = revert_;
    }

    function setRevertRebalance(bool revert_) external {
        _revertRebalance = revert_;
    }

    function setRevertSync(bool revert_) external {
        _revertSync = revert_;
    }

    function setRevertSettlePerformanceFee(bool revert_) external {
        _revertSettlePerformanceFee = revert_;
    }

    function setMaxDeposit(uint256 maxDeposit_) external {
        _maxDeposit = maxDeposit_;
    }

    function setMaxWithdrawal(uint256 maxWithdrawal_) external {
        _maxWithdrawal = maxWithdrawal_;
    }

    function setUnchargedLpFeeBaseInETH(uint256 uncharged_) external {
        _cumulativeLpFeesEarnedInETH = _cumulativeLpFeesChargedInETH + uncharged_;
    }

    function cumulativeLpFeesEarnedInETH() external view returns (uint256) {
        return _cumulativeLpFeesEarnedInETH;
    }

    function cumulativeLpFeesChargedInETH() external view returns (uint256) {
        return _cumulativeLpFeesChargedInETH;
    }

    function setWithdrawalFeeBps(uint256 feeBps_) external {
        _setWithdrawalFeeBps(feeBps_);
    }

    function withdrawalFeeBps() external view returns (uint256) {
        return _withdrawalFeeBps;
    }

    function _setWithdrawalFeeBps(uint256 feeBps_) internal {
        require(feeBps_ < 10_000, "MockStrategy: fee too high");
        _withdrawalFeeBps = feeBps_;
    }

    // ============ Strategy Functions ============
    function deposit() external payable override {
        if (_revertDeposit) revert MockStrategyDepositReverted();
        _totalDeposited += msg.value;
        emit FundsDeposited(msg.value);
    }

    function investIdleETH() external override returns (uint256 invested) {
        invested = address(this).balance;
        if (invested > 0) emit FundsInvested(invested);
    }

    function withdraw(address _receiver, uint256 _amount) external override returns (uint256) {
        if (_revertWithdraw) revert MockStrategyWithdrawReverted();
        require(_receiver != address(0), "MockStrategy: zero receiver");
        require(_amount > 0, "MockStrategy: zero amount");
        require(address(this).balance >= _amount, "MockStrategy: insufficient balance");

        uint256 fee = _amount * _withdrawalFeeBps / 10_000;
        uint256 netAmount = _amount - fee;
        require(netAmount > 0, "MockStrategy: net zero after fee");

        // Net amount everywhere: _totalWithdrawn, the transfer, the event, and the return
        // value all report the ETH actually delivered to the receiver (mirroring UniCLStrat,
        // whose totalWithdrawn() also tracks what was sent, not the gross request).
        _totalWithdrawn += netAmount;
        (bool success,) = payable(_receiver).call{value: netAmount}("");
        require(success, "MockStrategy: transfer failed");
        emit FundsWithdrawn(netAmount);
        return netAmount;
    }

    function rebalance() external override {
        if (_revertRebalance) revert MockStrategyRebalanceReverted();
        if (_isHealthy) {
            revert StrategyIsHealthy();
        }
        _isHealthy = true;
        emit Rebalanced();
    }

    function sync() external override {
        if (_revertSync) revert MockStrategySyncReverted();
        emit Synced();
    }

    function pendingPerformanceFeeInETH(uint256 _performanceFeeBps) external view override returns (uint256 feeETH) {
        if (_performanceFeeBps == 0 || _paused) return 0;
        uint256 uncharged = _cumulativeLpFeesEarnedInETH - _cumulativeLpFeesChargedInETH;
        return uncharged * _performanceFeeBps / 10_000;
    }

    function settlePerformanceFee(uint256 _performanceFeeBps) external override returns (uint256 feeETH) {
        if (msg.sender != strategyManager) revert MockStrategyCallerNotStrategyManager();
        if (_revertSettlePerformanceFee) revert MockStrategySettlePerformanceFeeReverted();
        if (_performanceFeeBps == 0 || _paused) return 0;

        uint256 uncharged = _cumulativeLpFeesEarnedInETH - _cumulativeLpFeesChargedInETH;
        if (uncharged == 0) return 0;

        feeETH = uncharged * _performanceFeeBps / 10_000;
        // Mirror UniCLStrat: do not write off dust that rounds to a zero ETH fee.
        if (feeETH == 0) return 0;

        _cumulativeLpFeesChargedInETH = _cumulativeLpFeesEarnedInETH;
        emit PerformanceFeeSettled(feeETH);
    }

    function emergencyExit() external override {
        if (!_paused) revert MockStrategyNotPaused();

        uint256 ethBalanceBefore = address(this).balance;
        (bool success,) = strategyManager.call{value: ethBalanceBefore}("");
        require(success, "MockStrategy: transfer failed");
        _cumulativeLpFeesChargedInETH = _cumulativeLpFeesEarnedInETH;
        emit EmergencyExited(ethBalanceBefore);
    }

    // ============ Receive Function ============
    receive() external payable {
        // Allow receiving ETH
    }
}
