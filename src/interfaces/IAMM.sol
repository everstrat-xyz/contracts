// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IAMM {
    /**
     * @notice User has entered the protocol and minted tokens under deposited ETH.
     */
    event UserEntered(address indexed user, uint256 deposit, uint256 tokensMinted, uint256 timestamp);

    /**
     * @notice User has redeemed ETH by burning protocol tokens.
     */
    event RedeemedImmediately(address indexed user, uint256 redeemedETH, uint256 tokensBurned, uint256 timestamp);

    /**
     * @notice Redemption request with given batch ID has been placed to the exit queue.
     */
    event RedemptionQueued(address indexed user, uint256 indexed redemptionBatchId, uint256 timestamp);

    /**
     * @notice Redemption request with given batch ID has been cancelled.
     */
    event RedemptionCancelled(
        address indexed user, uint256 indexed redemptionBatchId, bool viaEscapeHatch, uint256 timestamp
    );

    /**
     * @notice Redemption request with given batch ID has been processed.
     * @dev No `closedDueToSlippage` flag is included in the event since it can be retrieved from the request info.
     */
    event RedemptionProcessed(address indexed user, uint256 indexed redemptionBatchId, uint256 timestamp);

    /**
     * @notice User has claimed their redemption.
     */
    event Claimed(address indexed user, uint256 claimableETH, uint256 timestamp);

    /**
     * @notice Initial mint has been performed.
     */
    event Bootstrapped(address indexed user, uint256 deposit, uint256 userTokensMinted, uint256 timestamp);

    /**
     * @notice Value of connector weight has been changed from `initial` to `current`.
     * @dev Emitted by the constructor (`initial` is zero) and by `setConnectorWeight()`
     * (`initial` is the prior stored value).
     */
    event ConnectorWeightChanged(uint256 initial, uint256 current);

    /**
     * @notice Minimum ETH required for batch (queued) exit has been changed.
     * @dev Emitted by the constructor (`initial` is zero) and by `setMinBatchExitETH()`
     * (`initial` is the prior stored value).
     */
    event MinBatchExitETHChanged(uint256 initial, uint256 current);

    /**
     * @notice Provided address is a zero address.
     */
    error AMMZeroAddress();

    /**
     * @notice Specified value does not belong
     * to the range (0; 1e18].
     */
    error AMMInvalidRange();

    /**
     * @notice Specified minimum ETH required for batch (queued) exit is too high.
     */
    error AMMInvalidMinBatchExitETH();

    /**
     * @notice Deposit is insufficient to mint specified minimum
     * of output tokens.
     */
    error AMMInsufficientDeposit();

    /**
     * @notice Deposit is less than the minimum initial deposit.
     */
    error AMMLessThanMinInitialDeposit();

    /**
     * @notice Sent ETH amount is insufficient.
     */
    error AMMInsufficientSentETH();

    /**
     * @notice Specified minimum output tokens amount is not valid.
     * Possibly it is less than zero or not equal to 1 when
     * there is no initial liquidity.
     */
    error AMMInvalidTokensToMintAmount();

    /**
     * @notice Specified tokens to burn amount is zero.
     */
    error AMMZeroTokensToBurnAmount();

    /**
     * @notice Specified requested ETH amount is zero.
     */
    error AMMZeroETHRequested();

    /**
     * @notice Specified amount of ETH to redeem is too much
     * for given maximum amount of tokens to burn.
     */
    error AMMTooMuchETHRequested();

    /**
     * @notice Total supply of protocol tokens is zero.
     */
    error AMMZeroTotalSupply();

    /**
     * @notice Staleness interval is zero.
     */
    error AMMInvalidStalenessInterval();

    /**
     * @notice Provided redemption request id does not exist.
     */
    error AMMInvalidRequestId();

    /**
     * @notice Redemption request with specified id has already been processed.
     */
    error AMMAlreadyProcessed();

    /**
     * @notice Caller is not a redemption request owner.
     */
    error AMMNotRequestOwner();

    /**
     * @notice Specified requested ETH amount is too low
     * to be redeemed.
     */
    error AMMTooLowETHRequested();

    /**
     * @notice Redemption ETH is below the minimum required for batch (queued) exit.
     */
    error AMMTooLowBatchExitETH();

    /**
     * @notice No claimable balance for the given user.
     */
    error AMMNoClaimableBalance();

    /**
     * @notice Strategy Manager does not implement the expected interface.
     */
    error AMMInvalidStrategyManager();

    /**
     * @notice Thrown when the NAV is underflowing. This can happen only if the AMM
     * is not properly wired to the Strategy Manager.
     */
    error AMMNAVUnderflow();

    /**
     * @notice Caller is not whitelisted (see `Whitelist.isWhitelisted()`). Only gates
     * `enter()`/`enterWithInvite()` — `exit()` is never gated so users can always leave.
     */
    error AMMNotWhitelisted(address user);

    /**
     * @notice Gets the current free balance of the contract,
     * which is the balance of the contract minus the locked amount for claims.
     * @return uint256 The free balance of the contract.
     */
    function freeBalance() external view returns (uint256);

    /**
     * @notice Connector weight of the bonding curve, range (0; 1e18].
     * @return uint256 The connector weight (1e18 represents 1.0).
     */
    function connectorWeight() external view returns (uint256);

    /**
     * @notice Gets the current base price per token in terms of ETH.
     * @return uint256 The base price of 1 EVE in ETH terms.
     */
    function eveBasePriceInETH() external view returns (uint256);

    /**
     * @notice Gets the current premium price per token in terms of ETH.
     * @return uint256 The premium price of 1 EVE in ETH terms.
     */
    function evePremiumPriceInETH() external view returns (uint256);

    /**
     * @notice Get the current EVE token base price in USD terms (18 decimals)
     * @return uint256 Current EVE token base price in USD
     */
    function eveBasePriceInUSD() external view returns (uint256);

    /**
     * @notice Get the current EVE token premium price in USD terms (18 decimals)
     * @return uint256 Current EVE token premium price in USD
     */
    function evePremiumPriceInUSD() external view returns (uint256);

    /**
     * @notice Function to enter protocol and mint tokens under ETH.
     * Minting is priced at the premium price (NAV / (supply * cw)), so entrants
     * pay the bonding-curve premium above the NAV-backed base price.
     *
     * Requirements:
     * - Minimum amount of tokens to mint is positive.
     * - ETH sent is sufficient to mint specified minimum number of tokens.
     * - Caller is whitelisted (see `Whitelist.isWhitelisted()`)
     * @param _minTokensToMint Minimum amount of tokens to mint.
     */
    function enter(uint256 _minTokensToMint) external payable;

    /**
     * @notice Redeems a server-signed invite voucher on the protocol Whitelist and enters
     * the protocol in a single transaction.
     *
     * Requirements:
     * - Same as `enter()`, except the caller need not already be whitelisted
     * - The voucher is valid per `Whitelist.whitelist()` (unused invite, unexpired
     *   deadline, authorized signer, bound to `msg.sender`). Already-whitelisted callers
     *   (including after `Whitelist.disable()`) see a no-op redemption and still enter.
     * @dev Permissionless w.r.t. the voucher recipient — `msg.sender` both redeems the
     * voucher and enters, so a relayer forwarding this call cannot redirect the minted
     * EVE to itself.
     * @param _minTokensToMint Minimum amount of tokens to mint.
     * @param _inviteId Opaque server-generated invite identifier.
     * @param _deadline Unix timestamp after which the voucher is no longer valid.
     * @param _signature EIP-712 signature over the voucher, from an authorized signer.
     */
    function enterWithInvite(uint256 _minTokensToMint, bytes32 _inviteId, uint256 _deadline, bytes calldata _signature)
        external
        payable;

    /**
     * @notice Function to redeem ETH by burning protocol tokens.
     * Burning is priced at the base price (NAV / supply), so EVE is always redeemed
     * against the assets backing it and the base price grows with supply as the
     * bonding-curve premium is retained by remaining holders.
     *
     * Requirements:
     * - Amount of requested ETH is positive
     * - Maximum amount of tokens to burn is positive
     * - Total supply of protocol tokens is positive
     * - Maximum amount of tokens to burn is sufficient to redeem
     * enough ETH
     * - When AMM liquidity is insufficient, the ETH actually redeemed
     * (`ethToRedeem`, recalculated from `tokensToBurn` after rounding from
     * `_requestedETH`) must be at least `minBatchExitETH` (immediate exit
     * has no such minimum; the check is not applied to `_requestedETH` alone)
     * - Relative slippage tolerance is in the range [0; 1e18],
     * which represents the range [0; 1]
     * @param _requestedETH Desired amount of ETH to be redeemed.
     * @param _maxTokensToBurn Maximum amount of protocol tokens to be burned.
     * @param _priceTolerance Allowed relative slippage
     * @return batchId ID of the redemption request batch. If the redemption is immediate, the returned batch id is 0.
     */
    function exit(uint256 _requestedETH, uint256 _maxTokensToBurn, uint256 _priceTolerance)
        external
        returns (uint256 batchId);

    /**
     * @notice Process a queued redemption request (called by controller).
     *
     * Requirements:
     * - Provided batch id does exist in the exit queue
     * - Sent ETH is sufficient to redeem the requested ETH (only if the request is within the price tolerance.
     * otherwise the request is closed and the user is refunded the tokens, so no ETH is needed)
     * - User request exists in this batch
     * - User request has not been processed in this batch yet
     * - Relative slippage is in the bounds previously specified by user
     * - Caller is the controller contract
     * @param _batchId ID of the redemption request batch to process.
     * @param _user User who requested the redemption.
     */
    function processRedemption(uint256 _batchId, address _user) external payable;

    /**
     * @notice Function to claim a redemption for the given user.
     *
     * Requirements:
     * - Claimable balance for the given user is positive
     * @dev Intentionally works when the contract is paused so users can always
     * receive their credited ETH.
     */
    function claim() external;

    /**
     * @notice Cancel a pending redemption request.
     *
     * Note: This function can be called even if the contract is paused,
     * so it can be used as an emergency withdrawal mechanism for users.
     *
     * Requirements:
     * - Provided batch id does exists in the exit queue
     * - User request exists in this batch
     * - User request has not been processed in this batch yet
     * @param _batchId ID of the redemption request batch to cancel.
     */
    function cancelRedemption(uint256 _batchId) external;

    /**
     * @notice Function to set connection weight of the bonding curve.
     *
     * Requirements:
     * - Connector weight belongs to the range (0; 1e18]
     * - Caller is the controller contract
     * @param _cw Desired connector weight.
     */
    function setConnectorWeight(uint256 _cw) external;

    /**
     * @notice Set the minimum ETH required to queue a batch exit.
     *
     * Requirements:
     * - Caller has ADMIN_ROLE
     * - `_minBatchExitETH` must not exceed `MIN_BATCH_EXIT_ETH_UPPER_BOUND`
     * @param _minBatchExitETH Minimum ETH (18 decimals) for queued redemptions.
     * Set to zero to disable the check.
     */
    function setMinBatchExitETH(uint256 _minBatchExitETH) external;
}
