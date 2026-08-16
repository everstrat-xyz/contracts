// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";

import {RegistryClientUpgradeable} from "registry/client/RegistryClientUpgradeable.sol";

import {Auth} from "../libraries/Auth.sol";
import {Math} from "../libraries/Math.sol";
import {ExitQueueLimits} from "../libraries/ExitQueueLimits.sol";

import {IExitQueue} from "../interfaces/IExitQueue.sol";

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
        return "1.0.0";
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
        return (batch.canBeProcessed, batch.finalEvePrice, batch.totalTokensToBurn, batch.createdAt, batch.pricedAt);
    }

    /**
     * @inheritdoc IExitQueue
     */
    function liveRedemptionOffsets() public view returns (uint256 liabilityETH, uint256 escrowedSupply) {
        uint256 lo_ = liveScanFromBatchId;
        uint256 current_ = currentBatchId;
        for (uint256 id = lo_; id < current_; ++id) {
            RedemptionRequestBatch storage batch = _redemptionRequestBatches[id];
            uint128 tokens = batch.totalTokensToBurn;
            if (tokens == 0) continue;
            if (block.timestamp - batch.pricedAt > MAX_BATCH_PROCESSING_TIME) continue;
            escrowedSupply += tokens;
            liabilityETH += uint256(tokens).convertAssets(batch.finalEvePrice);
        }
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

        if (batch.finalEvePrice.isRelativelyLessThan(request.evePriceAtRequestTime, request.priceTolerance)) {
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
