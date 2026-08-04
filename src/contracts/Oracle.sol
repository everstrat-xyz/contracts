// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {RegistryClientUpgradeable} from "registry/client/RegistryClientUpgradeable.sol";

import {Auth} from "../libraries/Auth.sol";

import {Math} from "../libraries/Math.sol";

import {IOracle} from "../interfaces/IOracle.sol";

/**
 * @title Oracle
 * @notice Protocol price oracle: Token / USD registry with optional Token A / Token B overlays
 * @dev Upgradeable (UUPS). Role authority is the protocol {Registry} (`ADMIN_ROLE`).
 *
 *      **Token support = USD feed registration.** Call {updateUsdFeedInfo} to register a
 *      token; there is no separate add-token API. Pair feeds ({updatePairFeedInfo}) are
 *      optional and require both legs to already be USD-supported.
 *
 *      Shared helpers: {_upsertFeed} / {_readFeed} / {_getPriceWithStalenessCheck}.
 *      Native ETH is `address(0)`. USD feeds must quote in USD — see
 *      {IOracle-updateUsdFeedInfo}.
 */
contract Oracle is IOracle, Initializable, UUPSUpgradeable, RegistryClientUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    using Math for uint256;

    // ============ State Variables ============

    /// @notice Tokens with a registered Token / USD feed (native ETH = address(0))
    EnumerableSet.AddressSet private _supportedTokens;

    /// @notice Per-token USD feed + optional outbound pair feeds
    mapping(address token => TokenInfo) private _tokenInfo;

    // ============ Modifiers ============

    /// @notice Reverts unless `_token` has a registered Token / USD feed
    modifier onlyTokenSupported(address _token) {
        if (!_supportedTokens.contains(_token)) revert OracleTokenNotSupported();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Constructor that disables initialization of the implementation contract
     * @dev This prevents the implementation contract from being initialized
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Metadata ============

    function version() public pure virtual returns (string memory) {
        return "1.1.0";
    }

    // ============ Initialization ============

    /**
     * @notice Initializes the oracle contract
     * @param _registry The protocol Registry (role authority)
     */
    function initialize(address _registry) external initializer {
        __UUPSUpgradeable_init();
        __RegistryClient_init(_registry);
    }

    // ============ UUPS Upgrade Functions ============

    /**
     * @notice Authorizes an upgrade of the contract
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyAuthRole(Auth.ADMIN_ROLE) {}

    // ============ External View Functions ============

    /**
     * @inheritdoc IOracle
     */
    function getSupportedTokenCount() external view returns (uint256 count) {
        return _supportedTokens.length();
    }

    /**
     * @inheritdoc IOracle
     */
    function getSupportedTokens() external view override returns (address[] memory tokens) {
        return _supportedTokens.values();
    }

    /**
     * @inheritdoc IOracle
     */
    function isTokenSupported(address _token) external view override returns (bool supported) {
        return _isTokenSupported(_token);
    }

    /**
     * @inheritdoc IOracle
     */
    function getUsdFeedInfo(address _token)
        external
        view
        onlyTokenSupported(_token)
        returns (FeedInfo memory feedInfo)
    {
        return _tokenInfo[_token].usdFeedInfo;
    }

    /**
     * @inheritdoc IOracle
     */
    function isPairSupported(address _tokenA, address _tokenB) external view returns (bool supported) {
        return _isPairSupported(_tokenA, _tokenB);
    }

    /**
     * @inheritdoc IOracle
     */
    function getSupportedPairs(address _tokenA)
        external
        view
        onlyTokenSupported(_tokenA)
        returns (address[] memory pairs)
    {
        return _tokenInfo[_tokenA].supportedPairs.values();
    }

    /**
     * @inheritdoc IOracle
     */
    function getPairFeedInfo(address _tokenA, address _tokenB) external view returns (FeedInfo memory feedInfo) {
        if (!_isPairSupported(_tokenA, _tokenB)) revert OraclePairNotRegistered();
        return _tokenInfo[_tokenA].pairFeedInfo[_tokenB];
    }

    /**
     * @inheritdoc IOracle
     */
    function getPairPrice(address _tokenA, address _tokenB) external view returns (uint256 price, uint256 timestamp) {
        if (!_isPairSupported(_tokenA, _tokenB)) revert OraclePairNotRegistered();
        return _readFeed(_tokenInfo[_tokenA].pairFeedInfo[_tokenB]);
    }

    /**
     * @inheritdoc IOracle
     */
    function getPairPriceWithStalenessCheck(address _tokenA, address _tokenB, uint256 _maxStaleness)
        external
        view
        returns (uint256 price)
    {
        if (!_isPairSupported(_tokenA, _tokenB)) revert OraclePairNotRegistered();
        (price,) = _getPriceWithStalenessCheck(_tokenInfo[_tokenA].pairFeedInfo[_tokenB].priceFeed, _maxStaleness);
    }

    /**
     * @inheritdoc IOracle
     */
    function getUsdPrice(address _token)
        external
        view
        override
        onlyTokenSupported(_token)
        returns (uint256 price, uint256 timestamp)
    {
        return _readFeed(_tokenInfo[_token].usdFeedInfo);
    }

    /**
     * @inheritdoc IOracle
     */
    function getUsdPriceWithStalenessCheck(address _token, uint256 _maxStaleness)
        external
        view
        override
        onlyTokenSupported(_token)
        returns (uint256 price)
    {
        (price,) = _getPriceWithStalenessCheck(_tokenInfo[_token].usdFeedInfo.priceFeed, _maxStaleness);
    }

    /**
     * @inheritdoc IOracle
     */
    function convertTokenToUSD(address _token, uint256 _amount, uint8 _inputDecimals)
        external
        view
        onlyTokenSupported(_token)
        returns (uint256)
    {
        (uint256 price,) = _readFeed(_tokenInfo[_token].usdFeedInfo);
        return Math.convertAssets(_amount.normalizeDecimals(_inputDecimals), price);
    }

    /**
     * @inheritdoc IOracle
     */
    function convertUsdToToken(address _token, uint256 _amount, uint8 _outputDecimals)
        external
        view
        onlyTokenSupported(_token)
        returns (uint256)
    {
        (uint256 normalizedPrice,) = _readFeed(_tokenInfo[_token].usdFeedInfo);
        return Math.convertAssetsInverse(_amount, normalizedPrice).unnormalizeDecimals(_outputDecimals);
    }

    /**
     * @inheritdoc IOracle
     */
    function convert(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint8 _inputDecimals,
        uint8 _outputDecimals
    ) external view onlyTokenSupported(_tokenIn) onlyTokenSupported(_tokenOut) returns (uint256) {
        uint256 normalizedAmountIn = _amountIn.normalizeDecimals(_inputDecimals);

        if (_tokenIn == _tokenOut) {
            return normalizedAmountIn.unnormalizeDecimals(_outputDecimals);
        }

        // Prefer a registered direct pair feed (tokenIn / tokenOut).
        if (_isPairSupported(_tokenIn, _tokenOut)) {
            (uint256 pairPrice,) = _readFeed(_tokenInfo[_tokenIn].pairFeedInfo[_tokenOut]);
            return Math.convertAssets(normalizedAmountIn, pairPrice).unnormalizeDecimals(_outputDecimals);
        }

        // Next: inverted registered pair feed (tokenOut / tokenIn).
        if (_isPairSupported(_tokenOut, _tokenIn)) {
            (uint256 invertedPrice,) = _readFeed(_tokenInfo[_tokenOut].pairFeedInfo[_tokenIn]);
            return Math.convertAssetsInverse(normalizedAmountIn, invertedPrice).unnormalizeDecimals(_outputDecimals);
        }

        // Fallback: USD cross-rate from both Token / USD feeds.
        (uint256 priceIn,) = _readFeed(_tokenInfo[_tokenIn].usdFeedInfo);
        (uint256 priceOut,) = _readFeed(_tokenInfo[_tokenOut].usdFeedInfo);

        // Single cross-rate division: only one rounding step instead of the two incurred
        // by chaining convertTokenToUSD (÷1e18) and convertUsdToToken (÷priceOut).
        return (normalizedAmountIn * priceIn / priceOut).unnormalizeDecimals(_outputDecimals);
    }

    // ============ External Non-View Functions ============

    /**
     * @inheritdoc IOracle
     */
    function updateUsdFeedInfo(address _token, address _priceFeed, uint256 _stalenessInterval)
        external
        override
        onlyAuthRole(Auth.ADMIN_ROLE)
    {
        (bool added, address oldPriceFeed, uint256 oldStalenessInterval) =
            _upsertFeed(_tokenInfo[_token].usdFeedInfo, _priceFeed, _stalenessInterval);

        if (added) {
            _supportedTokens.add(_token);
            emit UsdFeedAdded(_token, _priceFeed, _stalenessInterval);
            return;
        }

        if (oldPriceFeed != _priceFeed) {
            emit UsdFeedUpdated(_token, oldPriceFeed, _priceFeed);
        }
        if (oldStalenessInterval != _stalenessInterval) {
            emit UsdStalenessIntervalUpdated(_token, oldStalenessInterval, _stalenessInterval);
        }
    }

    /**
     * @inheritdoc IOracle
     */
    function removeToken(address _token) external override onlyTokenSupported(_token) onlyAuthRole(Auth.ADMIN_ROLE) {
        _clearOutboundPairs(_token);
        _clearInboundPairs(_token);

        delete _tokenInfo[_token].usdFeedInfo;
        _supportedTokens.remove(_token);

        emit TokenRemoved(_token);
    }

    /**
     * @inheritdoc IOracle
     */
    function updatePairFeedInfo(address _tokenA, address _tokenB, address _priceFeed, uint256 _stalenessInterval)
        external
        override
        onlyAuthRole(Auth.ADMIN_ROLE)
    {
        if (_tokenA == _tokenB) revert OracleIdenticalTokens();
        if (!_isTokenSupported(_tokenA) || !_isTokenSupported(_tokenB)) revert OracleTokenNotSupported();

        (bool added, address oldPriceFeed, uint256 oldStalenessInterval) =
            _upsertFeed(_tokenInfo[_tokenA].pairFeedInfo[_tokenB], _priceFeed, _stalenessInterval);

        if (added) {
            _tokenInfo[_tokenA].supportedPairs.add(_tokenB);
            emit PairFeedAdded(_tokenA, _tokenB, _priceFeed, _stalenessInterval);
            return;
        }

        if (oldPriceFeed != _priceFeed) {
            emit PairFeedUpdated(_tokenA, _tokenB, oldPriceFeed, _priceFeed);
        }
        if (oldStalenessInterval != _stalenessInterval) {
            emit PairStalenessIntervalUpdated(_tokenA, _tokenB, oldStalenessInterval, _stalenessInterval);
        }
    }

    /**
     * @inheritdoc IOracle
     */
    function removePairFeedInfo(address _tokenA, address _tokenB) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (!_isPairSupported(_tokenA, _tokenB)) revert OraclePairNotRegistered();
        _removePairFeed(_tokenA, _tokenB);
    }

    // ============ Internal Functions ============

    function _isTokenSupported(address _token) internal view returns (bool supported) {
        return _supportedTokens.contains(_token);
    }

    function _isPairSupported(address _tokenA, address _tokenB) internal view returns (bool supported) {
        return _tokenInfo[_tokenA].supportedPairs.contains(_tokenB);
    }

    function _validateFeedParams(address _priceFeed, uint256 _stalenessInterval) internal pure {
        if (_priceFeed == address(0)) revert OracleZeroAddress();
        if (_stalenessInterval == 0) revert OracleZeroStalenessInterval();
    }

    function _validateFeedDecimals(address _priceFeed) internal view {
        if (AggregatorV3Interface(_priceFeed).decimals() > Math.DECIMALS_NORMALIZED) {
            revert OracleInvalidFeedDecimals();
        }
    }

    function _readFeed(FeedInfo storage info_) internal view returns (uint256 price, uint256 timestamp) {
        return _getPriceWithStalenessCheck(info_.priceFeed, info_.stalenessInterval);
    }

    function _getPriceWithStalenessCheck(AggregatorV3Interface _priceFeed, uint256 _maxStaleness)
        internal
        view
        returns (uint256 price, uint256 timestamp)
    {
        (, int256 answer,, uint256 updatedAt,) = _priceFeed.latestRoundData();

        if (updatedAt == 0) revert OracleNoRoundData();
        if (answer <= 0) revert OracleInvalidPrice();

        timestamp = updatedAt;

        if (timestamp > block.timestamp) revert OracleInvalidTimestamp();
        if (block.timestamp - timestamp > _maxStaleness) {
            revert OracleStalePrice();
        }

        // Convert to 18 decimals
        uint256 rawPrice = uint256(answer);
        uint8 feedDecimals = _priceFeed.decimals();
        price = Math.normalizeDecimals(rawPrice, feedDecimals);
    }

    /**
     * @notice Add or update a feed slot. Returns whether the slot was empty, plus prior values on update.
     * @dev Callers are responsible for domain-specific events and secondary bookkeeping (e.g. token set).
     */
    function _upsertFeed(FeedInfo storage info_, address _priceFeed, uint256 _stalenessInterval)
        internal
        returns (bool added, address oldPriceFeed, uint256 oldStalenessInterval)
    {
        _validateFeedParams(_priceFeed, _stalenessInterval);

        oldPriceFeed = address(info_.priceFeed);
        oldStalenessInterval = info_.stalenessInterval;

        if (oldPriceFeed == address(0)) {
            _validateFeedDecimals(_priceFeed);
            info_.priceFeed = AggregatorV3Interface(_priceFeed);
            info_.stalenessInterval = _stalenessInterval;
            return (true, address(0), 0);
        }

        if (oldPriceFeed == _priceFeed && oldStalenessInterval == _stalenessInterval) {
            revert OracleNothingToUpdate();
        }

        if (oldPriceFeed != _priceFeed) {
            _validateFeedDecimals(_priceFeed);
            info_.priceFeed = AggregatorV3Interface(_priceFeed);
        }
        if (oldStalenessInterval != _stalenessInterval) {
            info_.stalenessInterval = _stalenessInterval;
        }
    }

    function _removePairFeed(address _tokenA, address _tokenB) internal {
        delete _tokenInfo[_tokenA].pairFeedInfo[_tokenB];
        _tokenInfo[_tokenA].supportedPairs.remove(_tokenB);
        emit PairFeedRemoved(_tokenA, _tokenB);
    }

    function _clearOutboundPairs(address _token) internal {
        address[] memory pairs = _tokenInfo[_token].supportedPairs.values();
        uint256 length = pairs.length;
        for (uint256 i = 0; i < length; ++i) {
            _removePairFeed(_token, pairs[i]);
        }
    }

    function _clearInboundPairs(address _token) internal {
        address[] memory tokens = _supportedTokens.values();
        uint256 length = tokens.length;
        for (uint256 i = 0; i < length; ++i) {
            address other = tokens[i];
            if (other == _token) continue;
            if (_isPairSupported(other, _token)) {
                _removePairFeed(other, _token);
            }
        }
    }

    // ============ Storage Gap ============
    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     *
     * Storage usage:
     * - EnumerableSet.AddressSet: ~2 slots
     * - mapping(address => TokenInfo): 1 slot (pointer)
     * - AccessControlUpgradeable: inherited storage
     * - UUPSUpgradeable: inherited storage
     * Total used: ~3 slots + inherited storage
     * Gap: 47 slots to maintain 50-slot total reserve
     */
    uint256[47] private __gap;
}
