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
        bool canBeProcessed;
        // This price is in ETH terms (and normalized to 18 decimals)
        uint256 finalEvePrice;
        uint256 totalTokensToBurn;
        uint256 createdAt;
        // Equals zero if the batch is not priced
        uint256 pricedAt;
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
     * @notice Thrown when request cannot be closed at the moment (batch is priced,
     * so the request must be pulled from the queue by the AMM)
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
     * @notice Maximum time allowed for processing a batch in seconds, i.e. maximum time between batch
     * pricing and the moment when all the requests in the batch must be processed.
     */
    function MAX_BATCH_PROCESSING_TIME() external pure returns (uint256);

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
     * @param _evePrice The final EVE settlement price (the base price, NAV / supply)
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
