// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

interface IExitQueue {
    /**
     * @notice Struct to denote redemption request in the queue.
     */
    struct RedemptionRequest {
        bool processed;
        // This flag is set to true if the request was closed due to slippage,
        // and if this is set to true, `processed` must be set to true as well.
        bool closedDueToSlippage;
        uint256 evePriceAtRequestTime;
        uint256 tokensToBurn;
        uint256 priceTolerance;
    }

    /**
     * @notice Struct to denote redemption request batch.
     * New batches are supposed to be created once in some relatively short interval of time,
     * and users can submit only one request per batch.
     *
     * Note: existing batch can be priced (and thus, new batch can be created) only
     * if it is not empty. Hence, difference between current timestamp and `createdAt`
     * can be greater than standard interval between batches.
     */
    struct RedemptionRequestBatch {
        // Packed into slot 0 (8 + 8 + 16): hot path for liveRedemptionOffsets loads this
        // word then `finalEvePrice`. `canBeProcessed` is redundant with `pricedAt != 0`
        // for "is priced"; lapse is the clock, not this flag (it stays true after expiry).
        uint64 pricedAt;
        uint64 createdAt;
        uint128 totalTokensToBurn;
        // This price is in ETH terms (and normalized to 18 decimals)
        uint256 finalEvePrice;
        bool canBeProcessed;
        mapping(address user => RedemptionRequest request) requests;
        EnumerableSet.AddressSet unprocessedUsers;
    }

    /**
     * @notice Emitted when a batch is priced
     * @param batchId The ID of the batch
     */
    event BatchPriced(uint256 indexed batchId);

    /**
     * @notice Emitted when a request is pushed to a batch
     * @param batchId The ID of the batch
     * @param user The address of the user
     */
    event RequestPushed(uint256 indexed batchId, address indexed user);

    /**
     * @notice Emitted when a request is pulled from a batch.
     * @param batchId The ID of the batch
     * @param user The address of the user
     * @param isWithinTolerance Whether the request is within the price tolerance
     */
    event RequestPulled(uint256 indexed batchId, address indexed user, bool isWithinTolerance);

    /**
     * @notice Emitted when a request is manually closed by user.
     * @param batchId The ID of the batch
     * @param user The address of the user
     * @param viaEscapeHatch Request was closed since it was not handled within the
     * expected time window
     */
    event RequestClosed(uint256 indexed batchId, address indexed user, bool viaEscapeHatch);

    /**
     * @notice Thrown when provided address is zero
     */
    error ExitQueueZeroAddress();

    /**
     * @notice Thrown when provided price is zero
     */
    error ExitQueueZeroPrice();

    /**
     * @notice Thrown when batch cannot be processed at the moment (`batch.canBeProcessed` is false)
     */
    error ExitQueueBatchCannotBeProcessed();

    /**
     * @notice Thrown when batch is empty and cannot be priced
     */
    error ExitQueueBatchIsEmpty();

    /**
     * @notice Thrown when request is not in batch
     */
    error ExitQueueRequestNotInBatch();

    /**
     * @notice Thrown when request is already processed
     */
    error ExitQueueRequestAlreadyProcessed();

    /**
     * @notice Thrown when request cannot be closed at the moment (batch is priced
     * and still within `MAX_BATCH_PROCESSING_TIME` of `pricedAt`).
     */
    error ExitQueueRequestCannotBeClosed();

    /**
     * @notice Thrown when request is already in batch
     */
    error ExitQueueRequestAlreadyInBatch();

    /**
     * @notice Thrown when invalid range is provided
     */
    error ExitQueueInvalidRange();

    /**
     * @notice Thrown when `pullRequest` is called after `MAX_BATCH_PROCESSING_TIME`.
     * Live NAV has already dropped the batch's liability; settlement is no longer allowed.
     */
    error ExitQueueBatchExpired();

    /**
     * @notice Thrown when pricing would leave more than `MAX_LIVE_PRICED_BATCHES` ids in
     * `[liveScanFromBatchId, currentBatchId)`. Production overlap is ~3 (CRE `minBatchAge`
     * vs `MAX_BATCH_PROCESSING_TIME`); CRE `MAX_BATCH_SCAN` is this same cap (aliased). A
     * DoS bound, not a target.
     */
    error ExitQueueTooManyLivePricedBatches();

    /**
     * @notice Thrown when adding to `totalTokensToBurn` would exceed `uint128`.
     */
    error ExitQueueTokensOverflow();

    /**
     * @notice Maximum time after `pricedAt` during which `pullRequest` may settle a
     * priced batch. After this window, `pullRequest` reverts (`ExitQueueBatchExpired`)
     * because live NAV has already dropped the batch's liability. Users recover via
     * `closeRequest` / `AMM.cancelRedemption` (escape hatch).
     */
    function MAX_BATCH_PROCESSING_TIME() external pure returns (uint256);

    /**
     * @notice Max width of `[liveScanFromBatchId, currentBatchId)` that `priceBatch` will
     * allow. CRE `MAX_BATCH_SCAN` is this value (both alias `ExitQueueLimits.MAX_LIVE_PRICED_BATCHES`).
     * Not a production cadence target — CRE `minBatchAge` (1 day) vs `MAX_BATCH_PROCESSING_TIME`
     * (3 days) implies ~3 overlapping priced batches. The cap is an `enter()` gas / DoS bound.
     */
    function MAX_LIVE_PRICED_BATCHES() external pure returns (uint256);

    /**
     * @notice Get the version of the exit queue
     * @return string The version of the exit queue
     */
    function version() external pure returns (string memory);

    /**
     * @notice Current batch ID, i.e. ID of the batch where the next request will be added.
     * The batch with this ID is not priced yet; batch IDs start from 1.
     * @return uint256 The current batch ID
     */
    function currentBatchId() external view returns (uint256);

    /**
     * @notice Left cursor of the live-NAV scan `[liveScanFromBatchId, currentBatchId)`.
     * Every id in that range has been priced (`priceBatch` increments `currentBatchId`
     * only after marking the batch priced). Equals `currentBatchId` when the range is
     * empty — including at initialize, when batch 1 is the unpriced current batch.
     * Advanced on writes past empty or expired batches; the view still time-filters
     * so liability lapses at expiry with no tx.
     */
    function liveScanFromBatchId() external view returns (uint256);

    /**
     * @notice Live share-price offsets for in-window priced, unfinished batches.
     * `liabilityETH` is deducted from StrategyManager NAV; `escrowedSupply` from EVE
     * `totalSupply` in AMM pricing and fee mint. Both are zero for unpriced requests
     * (still cancellable equity) and for batches past `MAX_BATCH_PROCESSING_TIME`.
     * @return liabilityETH ETH reserved for in-window priced redemptions
     * @return escrowedSupply EVE still escrowed on the AMM for those redemptions
     */
    function liveRedemptionOffsets() external view returns (uint256 liabilityETH, uint256 escrowedSupply);

    /**
     * @notice Get the information about a batch
     * @param _batchId The ID of the batch
     * @return canBeProcessed Whether the batch can be processed
     * @return finalEvePrice The final EVE price
     * @return totalTokensToBurn The total amount of tokens to burn
     * @return createdAt The timestamp when the batch was created
     * @return pricedAt The timestamp when the batch was priced
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
        );

    /**
     * @notice Get the information about a request
     * @param _batchId The ID of the batch
     * @param _user The address of the user
     * @return processed Whether the request has been processed
     * @return closedDueToSlippage Whether the request was closed due to slippage
     * @return evePriceAtRequestTime The EVE price at the time of the request
     * @return tokensToBurn The amount of tokens to burn
     * @return priceTolerance The price tolerance
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
        );

    /**
     * @notice Check if a request can be closed
     * @param _batchId The ID of the batch
     * @param _user The address of the user
     * @return bool True if the request can be closed, false otherwise
     */
    function requestCanBeClosed(uint256 _batchId, address _user) external view returns (bool);

    /**
     * @notice Get the number of unprocessed users in a batch
     * @param _batchId The ID of the batch
     * @return count The number of unprocessed users
     */
    function unprocessedUsersCount(uint256 _batchId) external view returns (uint256);

    /**
     * @notice Get the addresses of the unprocessed users in a batch in the given range
     * @param _batchId The ID of the batch
     * @param _startIndex The start index (inclusive)
     * @param _endIndex The end index (exclusive)
     * @return users The addresses of the unprocessed users
     */
    function unprocessedUsers(uint256 _batchId, uint256 _startIndex, uint256 _endIndex)
        external
        view
        returns (address[] memory users);

    /**
     * @notice Get the addresses of all the unprocessed users in a batch
     * @param _batchId The ID of the batch
     * @return users The addresses of the unprocessed users
     */
    function unprocessedUsers(uint256 _batchId) external view returns (address[] memory users);

    /**
     * @notice Price a batch (makes it possible to process requests inside it)
     *
     * Requirements:
     * - Contract is not paused
     * - `_evePrice` is non-zero
     * - `[liveScanFromBatchId, currentBatchId)` width is below `MAX_LIVE_PRICED_BATCHES`
     * @param _evePrice The final EVE settlement price (the live base price, NAV−L / live supply)
     */
    function priceBatch(uint256 _evePrice) external;

    /**
     * @notice Push a request to a current batch
     *
     * Requirements:
     * - Contract is not paused
     * @param _user The address of the user
     * @param _evePriceAtRequestTime The EVE price at the time of the request
     * @param _tokensToBurn The amount of tokens to burn
     * @param _priceTolerance The price tolerance
     * @return batchId_ The ID of the batch
     */
    function pushRequest(address _user, uint256 _evePriceAtRequestTime, uint256 _tokensToBurn, uint256 _priceTolerance)
        external
        returns (uint256 batchId_);

    /**
     * @notice Pull a request from a batch (removes it from the batch)
     *
     * Requirements:
     * - Contract is not paused
     * - Batch is priced and still inside `MAX_BATCH_PROCESSING_TIME`
     * @param _batchId The ID of the batch
     * @param _user The address of the user
     */
    function pullRequest(uint256 _batchId, address _user) external;

    /**
     * @notice Close a request in a batch.
     *
     * Note: This function completely removes the request from the batch, which allows user
     * to submit a new request in the same batch. Also, it works even if the contract is paused,
     * so it can be used as an emergency withdrawal mechanism for users.
     * @param _batchId The ID of the batch
     * @param _user The address of the user
     * @return _viaEscapeHatch Whether a request was closed via escape hatch (i.e.
     * since it was not handled in the expected time window)
     */
    function closeRequest(uint256 _batchId, address _user) external returns (bool _viaEscapeHatch);
}
