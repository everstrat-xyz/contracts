// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title IOracle
 * @notice Protocol price oracle: Token / USD feeds plus optional Token A / Token B pair feeds
 * @dev Mental model
 *      - **Supporting a token** means registering its Token / USD Chainlink feed via
 *        {updateUsdFeedInfo}. There is no separate "addToken" path — the first successful
 *        `updateUsdFeedInfo` call is what adds the token to the supported set
 *        ({isTokenSupported} becomes true, {UsdFeedAdded} is emitted).
 *      - **Pair feeds are optional overlays** on top of already-supported tokens. They do
 *        not replace USD registration; {convert} prefers a registered (or inverted) pair
 *        feed when present, otherwise falls back to a USD cross-rate.
 *      - Native ETH is denoted by `address(0)` everywhere.
 *      - All prices returned by view helpers are normalized to 18 decimals.
 *      - USD feeds must quote in USD — documented on {updateUsdFeedInfo}.
 */
interface IOracle {
    /// @notice Chainlink aggregator + staleness bound (shared by USD and pair feeds)
    /// @dev For USD feeds, `priceFeed` must quote the token in USD (see {updateUsdFeedInfo}).
    ///      For pair feeds, `priceFeed` quotes the base token in quote-token terms.
    struct FeedInfo {
        AggregatorV3Interface priceFeed;
        uint256 stalenessInterval;
    }

    /// @notice Per-token storage: required USD feed plus optional outbound pair feeds
    /// @dev Storage-only type (contains a mapping / set). Not returned from external views —
    ///      use {getUsdFeedInfo} / {getPairFeedInfo} / {getSupportedPairs} instead.
    struct TokenInfo {
        FeedInfo usdFeedInfo;
        mapping(address quoteToken => FeedInfo) pairFeedInfo;
        EnumerableSet.AddressSet supportedPairs;
    }

    /**
     * @notice Token / USD feed registered for the first time (token is now supported)
     * @dev Emitted by the first {updateUsdFeedInfo} call for `_token`. Subsequent updates
     *      emit {UsdFeedUpdated} / {UsdStalenessIntervalUpdated} instead.
     */
    event UsdFeedAdded(address indexed token, address priceFeed, uint256 stalenessInterval);

    /**
     * @notice Token fully unregistered (USD feed cleared; outbound and inbound pair feeds cleared)
     * @dev Emitted by {removeToken}. Inverse of the first {updateUsdFeedInfo} for that token.
     */
    event TokenRemoved(address indexed token);

    /**
     * @notice Token / USD aggregator address changed for an already-supported token
     */
    event UsdFeedUpdated(address indexed token, address oldPriceFeed, address newPriceFeed);

    /**
     * @notice Token / USD staleness interval changed for an already-supported token
     */
    event UsdStalenessIntervalUpdated(
        address indexed token, uint256 oldStalenessInterval, uint256 newStalenessInterval
    );

    /**
     * @notice Direct Token A / Token B pair feed registered for the first time
     */
    event PairFeedAdded(address indexed tokenA, address indexed tokenB, address priceFeed, uint256 stalenessInterval);

    /**
     * @notice Direct Token A / Token B pair feed removed
     */
    event PairFeedRemoved(address indexed tokenA, address indexed tokenB);

    /**
     * @notice Pair-feed aggregator address changed
     */
    event PairFeedUpdated(address indexed tokenA, address indexed tokenB, address oldPriceFeed, address newPriceFeed);

    /**
     * @notice Pair-feed staleness interval changed
     */
    event PairStalenessIntervalUpdated(
        address indexed tokenA, address indexed tokenB, uint256 oldStalenessInterval, uint256 newStalenessInterval
    );

    error OracleInvalidPrice();
    error OracleInvalidTimestamp();
    error OracleStalePrice();
    /// @notice Token has no registered Token / USD feed (not in the supported set)
    error OracleTokenNotSupported();
    error OracleZeroAddress();
    error OracleZeroStalenessInterval();
    error OracleNothingToUpdate();
    error OracleNoRoundData();
    error OracleInvalidFeedDecimals();
    error OracleIdenticalTokens();
    /// @notice No direct Token A / Token B pair feed is registered for this ordered pair
    error OraclePairNotRegistered();

    function version() external pure returns (string memory);

    /**
     * @notice Current Token / USD price (uses the token's configured staleness interval)
     * @return price USD price with 18 decimals
     * @return timestamp Feed `updatedAt`
     */
    function getUsdPrice(address _token) external view returns (uint256 price, uint256 timestamp);

    /**
     * @notice Current Token / USD price with a caller-supplied staleness bound
     */
    function getUsdPriceWithStalenessCheck(address _token, uint256 _maxStaleness)
        external
        view
        returns (uint256 price);

    /**
     * @notice Whether `_token` has a registered Token / USD feed
     * @dev Equivalent to "has `updateUsdFeedInfo` succeeded at least once and not been
     *      undone by `removeToken`". Pair feeds alone never make a token supported.
     */
    function isTokenSupported(address _token) external view returns (bool supported);

    /// @notice All tokens that currently have a registered Token / USD feed
    function getSupportedTokens() external view returns (address[] memory tokens);

    function getSupportedTokenCount() external view returns (uint256 count);

    /// @notice Token / USD {FeedInfo} for a supported token
    function getUsdFeedInfo(address _token) external view returns (FeedInfo memory feedInfo);

    /**
     * @notice Convert token amount → USD using the token's Token / USD feed
     * @dev Do NOT chain with {convertUsdToToken} for token-to-token — use {convert}
     *      (single rounding division).
     */
    function convertTokenToUSD(address _token, uint256 _amount, uint8 _inputDecimals) external view returns (uint256);

    /**
     * @notice Convert USD amount → token using the token's Token / USD feed
     * @dev Do NOT chain with {convertTokenToUSD} for token-to-token — use {convert}
     *      (single rounding division).
     */
    function convertUsdToToken(address _token, uint256 _amount, uint8 _outputDecimals)
        external
        view
        returns (uint256);

    /**
     * @notice Convert `_tokenIn` amount → `_tokenOut` amount
     * @dev Preference order (fail-closed — a registered but stale/invalid pair feed does
     *      **not** silently fall back to USD):
     *      1. Direct pair feed `_tokenIn` / `_tokenOut`
     *      2. Inverted pair feed `_tokenOut` / `_tokenIn`
     *      3. USD cross-rate from both Token / USD feeds (`amountIn * priceIn / priceOut`)
     *      Both tokens must be USD-supported. Native ETH = `address(0)`.
     *      Case 3 assumes both USD feeds quote in USD (see {updateUsdFeedInfo}) and
     *      carries two feeds' staleness/deviation surfaces — prefer a direct pair feed
     *      via {updatePairFeedInfo} when available.
     */
    function convert(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint8 _inputDecimals,
        uint8 _outputDecimals
    ) external view returns (uint256);

    /**
     * @notice Whether a direct `_tokenA` / `_tokenB` pair feed is registered
     * @dev Ordered: (`A`,`B`) is distinct from (`B`,`A`). Does not imply USD support by
     *      itself — pair registration already requires both sides to be USD-supported.
     */
    function isPairSupported(address _tokenA, address _tokenB) external view returns (bool supported);

    /**
     * @notice Quote tokens for which `_tokenA` has an outbound pair feed
     */
    function getSupportedPairs(address _tokenA) external view returns (address[] memory pairs);

    /**
     * @notice {FeedInfo} for a registered `_tokenA` / `_tokenB` pair feed
     */
    function getPairFeedInfo(address _tokenA, address _tokenB) external view returns (FeedInfo memory feedInfo);

    /**
     * @notice Current `_tokenA` / `_tokenB` pair price (quote per base, 18 decimals)
     * @dev Uses the pair feed's configured staleness interval. Does not synthesize a
     *      price from USD feeds when the pair is unregistered — use {convert} for that.
     */
    function getPairPrice(address _tokenA, address _tokenB) external view returns (uint256 price, uint256 timestamp);

    /**
     * @notice Current `_tokenA` / `_tokenB` pair price with a caller-supplied staleness bound
     */
    function getPairPriceWithStalenessCheck(address _tokenA, address _tokenB, uint256 _maxStaleness)
        external
        view
        returns (uint256 price);

    /**
     * @notice Register or update a token's Token / USD feed
     * @dev **This is token registration.** First call for `_token`:
     *      - validates feed decimals (≤ 18)
     *      - stores {FeedInfo}
     *      - adds `_token` to the supported set
     *      - emits {UsdFeedAdded}
     *      Later calls update the feed and/or staleness and emit {UsdFeedUpdated} /
     *      {UsdStalenessIntervalUpdated}. Reverts {OracleNothingToUpdate} if unchanged.
     *
     *      USD-QUOTE INVARIANT: `_priceFeed` MUST quote the token in
     *      USD (Chainlink "<BASE> / USD"). A non-USD quote does NOT revert here but
     *      corrupts every conversion involving `_token`. Not checked on-chain —
     *      `description()` is advisory metadata (spoofable; legitimate USD-quoted
     *      wrappers may not follow the naming convention). Deploy scripts assert the
     *      convention via ProtocolDeployBase._assertUsdQuotedFeed; timelocked feed
     *      updates must be reviewed for USD quote, decimals ≤ 18, and staleness matching
     *      the feed heartbeat. Pair feeds ({updatePairFeedInfo}) are exempt.
     * @param _token Token address (`address(0)` = native ETH)
     * @param _priceFeed Token / USD Chainlink aggregator (MUST quote token / USD)
     * @param _stalenessInterval Max age of `updatedAt` in seconds (must be > 0)
     */
    function updateUsdFeedInfo(address _token, address _priceFeed, uint256 _stalenessInterval) external;

    /**
     * @notice Unregister a token (clear USD feed + all related pair feeds)
     * @dev Inverse of the first {updateUsdFeedInfo}. Clears:
     *      - outbound pair feeds from `_token`
     *      - inbound pair feeds on other tokens that quote `_token`
     *      - the Token / USD feed and supported-set membership
     *      Emits {PairFeedRemoved} for each cleared pair, then {TokenRemoved}.
     */
    function removeToken(address _token) external;

    /**
     * @notice Register or update an optional `_tokenA` / `_tokenB` pair feed
     * @dev Both tokens must already be USD-supported ({OracleTokenNotSupported} otherwise).
     *      The aggregator must quote `_tokenA` in `_tokenB` terms. Pair feeds never make a
     *      token "supported" on their own — call {updateUsdFeedInfo} first.
     */
    function updatePairFeedInfo(address _tokenA, address _tokenB, address _priceFeed, uint256 _stalenessInterval)
        external;

    /**
     * @notice Remove a direct `_tokenA` / `_tokenB` pair feed
     * @dev Does not affect either token's USD registration / supported status.
     */
    function removePairFeedInfo(address _tokenA, address _tokenB) external;
}
