// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";

import {RegistryClientUpgradeable} from "registry/client/RegistryClientUpgradeable.sol";

import {Auth} from "../libraries/Auth.sol";
import {Math} from "../libraries/Math.sol";
import {ExitQueueLimits} from "../libraries/ExitQueueLimits.sol";

import {IExitQueue} from "../interfaces/IExitQueue.sol";
import {IAMM} from "../interfaces/IAMM.sol";

contract ExitQueue is IExitQueue, Initializable, UUPSUpgradeable, RegistryClientUpgradeable, PausableUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    using Math for uint256;

    // ============ Constants ============

    /**
     * @inheritdoc IExitQueue
     */
    uint256 public constant MAX_BATCH_PROCESSING_TIME = 3 days;

    /**
     * @inheritdoc IExitQueue
     */
    uint256 public constant MAX_LIVE_PRICED_BATCHES = ExitQueueLimits.MAX_LIVE_PRICED_BATCHES;

    /**
     * @dev Seed for the transient-storage slot that pins a batch's settlement price for the
     *      rest of the transaction once {pullRequest} has read it (audit G1). Slot for batch
     *      `id` is `keccak256(abi.encode(id, _SETTLEMENT_PRICE_TSLOT_SEED))`. Transient storage
     *      only: no persistent slot is used, so the storage layout is unchanged.
     */
    bytes32 private constant _SETTLEMENT_PRICE_TSLOT_SEED = keccak256("everstrat.exitqueue.settlementPrice");

    // ============ State Variables ============

    /**
     * @notice Mapping from batch ID to redemption request batch.
     */
    mapping(uint256 batchId => RedemptionRequestBatch) private _redemptionRequestBatches;

    /**
     * @notice Current batch ID, i.e. ID of the batch where the next request will be added.
     *
     * Note: since this variable is incremented in {priceBatch}, batch with this ID
     * is NOT priced yet. Also, batch IDs start from 1, as ID 0 is used in AMM::exit()
     * to indicate that the request was processed immediately.
     */
    uint256 public currentBatchId;

    /**
     * @inheritdoc IExitQueue
     */
    uint256 public liveScanFromBatchId;

    // ============ Initialization ============

    /**
     * @notice Constructor that disables initialization of the implementation contract
     * @dev This prevents the implementation contract from being initialized
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the exit queue
     * @param _registry Address of the protocol Registry (role authority and contract keys)
     */
    function initialize(address _registry) external initializer {
        // Initializing the first batch.
        currentBatchId = 1;
        liveScanFromBatchId = 1;
        _redemptionRequestBatches[currentBatchId].createdAt = uint64(block.timestamp);

        __UUPSUpgradeable_init();
        __RegistryClient_init(_registry);
        __Pausable_init();
    }

    // ============ Metadata ============
    /**
     * @notice Get the version of the exit queue
     * @return string The version of the exit queue
     */
    function version() public pure returns (string memory) {
        return "1.1.0";
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IExitQueue
     */
    function batchInfo(uint256 _batchId)
        external
        view
        returns (
            bool canBeProcessed,
            uint256 finalEvePrice,
            uint256 totalTokensToBurn,
            uint256 createdAt,
            uint256 pricedAt
        )
    {
        RedemptionRequestBatch storage batch = _redemptionRequestBatches[_batchId];
        // Audit G1: an in-window priced batch settles at the live base price, not at the price
        // recorded by {priceBatch}. Unpriced and lapsed batches return the stored value and
        // never touch NAV.
        uint256 price = _isInWindow(batch) ? _settlementPrice(_batchId) : batch.finalEvePrice;
        return (batch.canBeProcessed, price, batch.totalTokensToBurn, batch.createdAt, batch.pricedAt);
    }

    /**
     * @inheritdoc IExitQueue
     */
    function liveRedemptionOffsets() public pure returns (uint256 liabilityETH, uint256 escrowedSupply) {
        // Audit G1: queued EVE stays ordinary equity until it is paid, so there is no
        // fixed-price carve-out of NAV or supply, and nothing to re-add when a batch lapses.
        // Kept (always zero) so AMM and StrategyManager pricing need no change.
        return (0, 0);
    }

    /**
     * @inheritdoc IExitQueue
     */
    function requestInfo(uint256 _batchId, address _user)
        external
        view
        returns (
            bool processed,
            bool closedDueToSlippage,
            uint256 evePriceAtRequestTime,
            uint256 tokensToBurn,
            uint256 priceTolerance
        )
    {
        RedemptionRequestBatch storage batch = _redemptionRequestBatches[_batchId];
        RedemptionRequest storage request = batch.requests[_user];
        return (
            request.processed,
            request.closedDueToSlippage,
            request.evePriceAtRequestTime,
            request.tokensToBurn,
            request.priceTolerance
        );
    }

    /**
     * @inheritdoc IExitQueue
     */
    function requestCanBeClosed(uint256 _batchId, address _user) external view returns (bool) {
        RedemptionRequestBatch storage batch = _redemptionRequestBatches[_batchId];
        RedemptionRequest storage request = batch.requests[_user];

        return _requestCanBeClosed(batch, request, _user);
    }

    /**
     * @inheritdoc IExitQueue
     */
    function unprocessedUsersCount(uint256 _batchId) external view returns (uint256) {
        RedemptionRequestBatch storage batch = _redemptionRequestBatches[_batchId];
        return batch.unprocessedUsers.length();
    }

    /**
     * @inheritdoc IExitQueue
     */
    function unprocessedUsers(uint256 _batchId, uint256 _startIndex, uint256 _endIndex)
        external
        view
        returns (address[] memory users)
    {
        RedemptionRequestBatch storage batch = _redemptionRequestBatches[_batchId];

        if (_endIndex > batch.unprocessedUsers.length() || _startIndex >= _endIndex) revert ExitQueueInvalidRange();

        users = new address[](_endIndex - _startIndex);
        for (uint256 i = _startIndex; i < _endIndex; i++) {
            users[i - _startIndex] = batch.unprocessedUsers.at(i);
        }
    }

    /**
     * @inheritdoc IExitQueue
     */
    function unprocessedUsers(uint256 _batchId) external view returns (address[] memory users) {
        RedemptionRequestBatch storage batch = _redemptionRequestBatches[_batchId];
        return batch.unprocessedUsers.values();
    }

    // ============ Controller Functions ============

    /**
     * @inheritdoc IExitQueue
     */
    function priceBatch(uint256 _evePrice) external onlyAuthContract(Auth.CONTROLLER) whenNotPaused {
        if (_evePrice == 0) revert ExitQueueZeroPrice();

        _advanceLo();
        if (currentBatchId - liveScanFromBatchId >= MAX_LIVE_PRICED_BATCHES) {
            revert ExitQueueTooManyLivePricedBatches();
        }

        RedemptionRequestBatch storage batch = _redemptionRequestBatches[currentBatchId];

        // No sense to price an empty batch - wait for the requests to be pushed.
        if (batch.unprocessedUsers.length() == 0) revert ExitQueueBatchIsEmpty();

        batch.finalEvePrice = _evePrice;
        batch.canBeProcessed = true;
        batch.pricedAt = uint64(block.timestamp);
        emit BatchPriced(currentBatchId);

        // A new batch is created after the old batch is priced.
        _redemptionRequestBatches[++currentBatchId].createdAt = uint64(block.timestamp);
    }

    // ============ AMM Functions ============

    /**
     * @inheritdoc IExitQueue
     */
    function pushRequest(address _user, uint256 _evePriceAtRequestTime, uint256 _tokensToBurn, uint256 _priceTolerance)
        external
        onlyAuthContract(Auth.AMM)
        whenNotPaused
        returns (uint256 batchId_)
    {
        batchId_ = currentBatchId;
        RedemptionRequestBatch storage batch = _redemptionRequestBatches[batchId_];

        // No need to check whether the request was processed, because
        // we push the request to the batch that is not priced yet,
        // which means that `batch.canBeProcessed` is false.
        if (batch.unprocessedUsers.contains(_user)) {
            revert ExitQueueRequestAlreadyInBatch();
        }

        batch.requests[_user] = RedemptionRequest({
            evePriceAtRequestTime: _evePriceAtRequestTime,
            tokensToBurn: _tokensToBurn,
            priceTolerance: _priceTolerance,
            processed: false,
            closedDueToSlippage: false
        });

        if (_tokensToBurn > type(uint128).max - batch.totalTokensToBurn) revert ExitQueueTokensOverflow();
        batch.totalTokensToBurn += uint128(_tokensToBurn);
        batch.unprocessedUsers.add(_user);

        emit RequestPushed(batchId_, _user);
    }

    /**
     * @inheritdoc IExitQueue
     */
    function pullRequest(uint256 _batchId, address _user) external onlyAuthContract(Auth.AMM) whenNotPaused {
        RedemptionRequestBatch storage batch = _redemptionRequestBatches[_batchId];
        RedemptionRequest storage request = batch.requests[_user];

        if (!batch.canBeProcessed) revert ExitQueueBatchCannotBeProcessed();
        if (block.timestamp - batch.pricedAt > MAX_BATCH_PROCESSING_TIME) revert ExitQueueBatchExpired();
        if (request.processed) revert ExitQueueRequestAlreadyProcessed();
        if (!batch.unprocessedUsers.contains(_user)) {
            revert ExitQueueRequestNotInBatch();
        }

        // Audit G1: judge slippage against the price the request is actually settled at.
        uint256 settlementPrice = _pinSettlementPrice(_batchId);
        if (settlementPrice.isRelativelyLessThan(request.evePriceAtRequestTime, request.priceTolerance)) {
            // If slippage is too high, the request must be closed.
            request.closedDueToSlippage = true;
        }

        batch.unprocessedUsers.remove(_user);
        batch.totalTokensToBurn -= uint128(request.tokensToBurn);
        request.processed = true;

        _advanceLo();

        emit RequestPulled(_batchId, _user, !request.closedDueToSlippage);
    }

    /**
     * @inheritdoc IExitQueue
     */
    function closeRequest(uint256 _batchId, address _user)
        external
        onlyAuthContract(Auth.AMM)
        returns (bool _closedViaEscapeHatch)
    {
        RedemptionRequestBatch storage batch = _redemptionRequestBatches[_batchId];
        RedemptionRequest storage request = batch.requests[_user];

        _validateRequestCanBeClosed(batch, request, _user);
        _closedViaEscapeHatch = batch.canBeProcessed && block.timestamp - batch.pricedAt > MAX_BATCH_PROCESSING_TIME;

        batch.unprocessedUsers.remove(_user);
        batch.totalTokensToBurn -= uint128(request.tokensToBurn);
        delete batch.requests[_user];

        _advanceLo();

        emit RequestClosed(_batchId, _user, _closedViaEscapeHatch);
    }

    // ============ Internal Functions ============

    /**
     * @notice Whether `_batch` is priced and still inside `MAX_BATCH_PROCESSING_TIME`
     */
    function _isInWindow(RedemptionRequestBatch storage _batch) internal view returns (bool) {
        return _batch.canBeProcessed && block.timestamp - _batch.pricedAt <= MAX_BATCH_PROCESSING_TIME;
    }

    /**
     * @notice Settlement price of an in-window batch: the price pinned earlier in this
     * transaction by {pullRequest}, otherwise the live AMM base price.
     * @dev The pin keeps Controller, AMM and this contract on one price per transaction.
     *      Without it, `AMM.processRedemption` re-reads {batchInfo} after burning the EVE but
     *      before locking the ETH (live price momentarily too high), and later requests in a
     *      `processRequests` loop would see the price nudged up by payout rounding dust. Either
     *      way the AMM would want more ETH than the Controller sent.
     */
    function _settlementPrice(uint256 _batchId) internal view returns (uint256 price_) {
        price_ = _tloadSettlementPrice(_batchId);
        if (price_ == 0) price_ = IAMM(Auth.amm(registry())).eveBasePriceInETH();
    }

    /**
     * @notice Read the settlement price for `_batchId` and pin it for the rest of the transaction
     * @dev The first pull of a batch in a transaction reads the same live price the Controller
     *      just read through {batchInfo}: the only state change in between is the Controller
     *      sending ETH to the AMM, which leaves NAV unchanged. Settling `t` EVE at that price
     *      (payout rounded down) leaves the price for remaining holders unchanged or higher by dust.
     */
    function _pinSettlementPrice(uint256 _batchId) internal returns (uint256 price_) {
        price_ = _settlementPrice(_batchId);
        if (price_ == 0) revert ExitQueueZeroPrice();
        bytes32 slot = _settlementPriceTSlot(_batchId);
        assembly ("memory-safe") {
            tstore(slot, price_)
        }
    }

    function _tloadSettlementPrice(uint256 _batchId) internal view returns (uint256 price_) {
        bytes32 slot = _settlementPriceTSlot(_batchId);
        assembly ("memory-safe") {
            price_ := tload(slot)
        }
    }

    function _settlementPriceTSlot(uint256 _batchId) internal pure returns (bytes32) {
        return keccak256(abi.encode(_batchId, _SETTLEMENT_PRICE_TSLOT_SEED));
    }

    /**
     * @notice Advance {liveScanFromBatchId} past priced batches that are empty or past
     * `MAX_BATCH_PROCESSING_TIME`. Ids in `[liveScanFromBatchId, currentBatchId)` are
     * priced by construction. Does not change live offsets (the view already time-filters);
     * keeps the scan bounded after writes.
     */
    function _advanceLo() internal {
        uint256 lo_ = liveScanFromBatchId;
        uint256 current_ = currentBatchId;
        while (lo_ < current_) {
            RedemptionRequestBatch storage batch = _redemptionRequestBatches[lo_];
            bool expired = block.timestamp - batch.pricedAt > MAX_BATCH_PROCESSING_TIME;
            if (!expired && batch.unprocessedUsers.length() > 0) break;
            unchecked {
                ++lo_;
            }
        }
        liveScanFromBatchId = lo_;
    }

    /**
     * @notice Validate if a request can be closed
     * @param _batch The batch
     * @param _request The request
     * @param _user The user
     */
    function _validateRequestCanBeClosed(
        RedemptionRequestBatch storage _batch,
        RedemptionRequest storage _request,
        address _user
    ) internal view {
        if (_request.processed) revert ExitQueueRequestAlreadyProcessed();
        if (!_batch.unprocessedUsers.contains(_user)) {
            revert ExitQueueRequestNotInBatch();
        }
        /* If the batch is priced, all the requests are considered final and
        must be pulled from the queue by the AMM.

        The only possible exception here is if the maximum time allowed for processing a batch
        has been exceeded.
        */
        if (_batch.canBeProcessed && block.timestamp - _batch.pricedAt <= MAX_BATCH_PROCESSING_TIME) {
            revert ExitQueueRequestCannotBeClosed();
        }
    }

    /**
     * @notice Check if a request can be closed
     * @param _batch The batch
     * @param _request The request
     * @param _user The user
     * @return bool True if the request can be closed, false otherwise
     */
    function _requestCanBeClosed(
        RedemptionRequestBatch storage _batch,
        RedemptionRequest storage _request,
        address _user
    ) internal view returns (bool) {
        if (_request.processed) return false;
        if (!_batch.unprocessedUsers.contains(_user)) return false;
        if (_batch.canBeProcessed && block.timestamp - _batch.pricedAt <= MAX_BATCH_PROCESSING_TIME) {
            return false;
        }
        return true;
    }

    // ============ Pausable Functions ============

    /**
     * @notice Pause the exit queue
     */
    function pause() external onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the exit queue
     */
    function unpause() external onlyAuthRole(Auth.ADMIN_ROLE) {
        _unpause();
    }

    // ============ Upgradeability ============

    /**
     * @inheritdoc UUPSUpgradeable
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyAuthRole(Auth.ADMIN_ROLE) {}

    // ============ Storage Gap ============
    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}
