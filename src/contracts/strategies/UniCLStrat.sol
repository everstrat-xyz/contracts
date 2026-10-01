// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering
// solhint-disable gas-strict-inequalities, max-states-count
// solhint-disable immutable-vars-naming, gas-indexed-events, gas-increment-by-one
pragma solidity ^0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {RegistryClient} from "registry/client/RegistryClient.sol";

import {Auth} from "../../libraries/Auth.sol";

import {IOracle} from "../../interfaces/IOracle.sol";
import {IConverter} from "../../interfaces/IConverter.sol";
import {IRegistry} from "interfaces/IRegistry.sol";

import {IStrategy} from "../../interfaces/IStrategy.sol";
import {IUniCLStrat} from "../../interfaces/strategies/IUniCLStrat.sol";
import {IUniswapV3Pool} from "../../interfaces/integrations/uniswap/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "../../interfaces/integrations/uniswap/IUniswapV3Factory.sol";
import {IWETH} from "../../interfaces/integrations/IWETH.sol";

import {LiquidityAmounts} from "../../libraries/integrations/uniswap/LiquidityAmounts.sol";
import {TickMath} from "../../libraries/integrations/uniswap/TickMath.sol";
import {TickUtils} from "../../libraries/integrations/uniswap/TickUtils.sol";
import {UniCLStratLib} from "../../libraries/strategies/UniCLStratLib.sol";

/**
 * @title UniCLStrat
 * @notice Native-ETH IStrategy implementation that deploys funds into a Uniswap V3-style WETH pair.
 *         Swap, wrap, and unwrap operations are delegated to the shared Converter.
 * @dev The contract is intentionally static/non-upgradeable. It keeps the external protocol surface small and
 *      reports all value in ETH for StrategyManager and AMM pricing.
 *      Oracle assumptions (not checked at construction): ETH (`address(0)`) and the pool's
 *      paired token must both have USD feeds on the protocol Oracle — inventory-balancing
 *      swaps and idle paired-token NAV call `Oracle.convert`. For emergency unwind into
 *      StrategyManager NAV, also whitelist the paired token via `addSupportedERC20`.
 *      Go-live (see `DeployUniCLStrat` NatSpec): timelock `setAllowedAdapter` (+ paired feed /
 *      optional `addSupportedERC20`) → `DeployUniCLStrat` bytecode → timelock `addStrategy`.
 */
contract UniCLStrat is IUniCLStrat, RegistryClient, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;
    using Address for address payable;

    using Auth for IRegistry;

    // ============ Constants ============

    uint256 public constant BASIS_POINTS = 10_000;
    /// @dev Floor for the long TWAP window. The long TWAP anchors both the calm-period band
    ///      (`_isCalm()`) and the LP-position composition used by `navInETH()`, which feeds
    ///      StrategyManager NAV and AMM pricing — so its window must be expensive to bias.
    ///      30 minutes of averaging means an attacker has to sustain a skewed tick across
    ///      ~150 blocks (12s L1). Constructor and `setTwapInterval` / `setShortTwapInterval`
    ///      require both (1) `pool.observe` serving the window (`UniCLStratPoolTWAPNotAvailable`)
    ///      so NAV will compute, and (2) in-use `observationCardinality` covering
    ///      `ceil(interval / MAX_BLOCK_SECONDS)` slots, floored at
    ///      `MIN_OBSERVATION_CARDINALITY` (`UniCLStratInsufficientObservationCardinality`)
    ///      so a quiet cardinality-1 pool cannot mark at a spot-extrapolated TWAP.
    ///      Runtime `navInETH()` still fail-closes on a later `observe` revert.
    uint32 public constant MIN_TWAP_INTERVAL = 1800;
    /// @dev Floor for the short TWAP window used as a secondary calm check. Aligned with the
    ///      UniswapV3ConverterAdapter's MIN_TWAP_INTERVAL (60s) so a single-block flash-loan
    ///      tick skew cannot satisfy the calm-period guard.
    uint32 public constant MIN_SHORT_TWAP_INTERVAL = 60;
    /// @dev Assumed L1 block time when converting a TWAP window into a minimum in-use
    ///      observation cardinality. Matches the ~150-block bias cost of `MIN_TWAP_INTERVAL`.
    uint32 public constant MAX_BLOCK_SECONDS = 12;
    /// @dev Floor on in-use Uniswap observation slots (`slot0.observationCardinality`, not
    ///      `observationCardinalityNext`). Equal to `MIN_TWAP_INTERVAL / MAX_BLOCK_SECONDS`.
    uint16 public constant MIN_OBSERVATION_CARDINALITY = 150;
    /// @dev Longest TWAP window that can be densely covered by Uniswap's uint16 observation
    ///      ring at {MAX_BLOCK_SECONDS} per slot: `type(uint16).max * MAX_BLOCK_SECONDS`.
    ///      Longer windows cannot satisfy the cardinality floor on any V3 pool — fail closed.
    uint32 public constant MAX_TWAP_INTERVAL = uint32(type(uint16).max) * MAX_BLOCK_SECONDS;
    uint256 public constant DEFAULT_SWAP_SLIPPAGE_BPS = 100;
    uint256 public constant MAX_SWAP_SLIPPAGE_BPS = 200;
    uint256 public constant SWAP_DEADLINE_OFFSET = UniCLStratLib.SWAP_DEADLINE_OFFSET;
    /// @dev Maximum deviation tolerated between an adapter quote and the Chainlink-implied
    ///      amount. NOTE: adapter quotes are net of the DEX pool fee while the Chainlink
    ///      amount is a gross mid-price, so the pool's fee tier consumes part of this
    ///      budget on the floor side. Units reminder — Uniswap V3 fees are in hundredths
    ///      of a bip (1e-6): tier 3000 = 0.3% = 30 bps, tier 10000 = 1% = 100 bps. So
    ///      200 bps supports fee tiers up to 1% (100 bps), leaving at least 100 bps of
    ///      genuine TWAP-vs-Chainlink drift allowance; route configs should prefer pools
    ///      with fee tiers <= 0.3% (30 bps, leaving 170 bps of drift allowance).
    uint256 public constant MAX_QUOTE_DEVIATION_BPS = UniCLStratLib.MAX_QUOTE_DEVIATION_BPS;
    /// @dev Inventory swaps smaller than this share (bps) of the value being deployed are
    ///      skipped: the residual is parked in the alt position instead, which is cheaper
    ///      than paying swap gas + fees for a negligible ratio correction.
    uint256 public constant MIN_INVENTORY_SWAP_BPS = 10;

    // ============ Immutable State ============

    IERC20Metadata public immutable token0;
    IERC20Metadata public immutable token1;
    IERC20Metadata public immutable pairedToken;

    IWETH public immutable weth;
    IUniswapV3Pool public immutable pool;
    /// @dev Canonical Uniswap V3 factory used to prove `pool` provenance at construction.
    IUniswapV3Factory public immutable factory;

    int24 public immutable tickSpacing;
    uint256 private immutable _genesisTimestamp;

    // ============ Strategy State ============

    uint256 private _totalDeposited;
    uint256 private _totalWithdrawn;

    /// @dev LP-fee accounting (earned / charged / owed snapshot); see {UniCLStratLib-LpFeeState}.
    UniCLStratLib.LpFeeState private _lpFees;

    uint256 public maxTotalNAV;

    int56 public maxTickDeviation;

    int24 public positionWidth;
    int24 public rebalanceTickThreshold;

    uint32 public twapInterval;
    uint32 public shortTwapInterval;

    bool public initTicks;
    bool private _minting;

    /// @notice The whitelisted Converter adapter this strategy routes its swaps through
    address public swapAdapter;

    /// @notice Adapter-specific route bytes for WETH -> pairedToken swaps
    bytes public wethToPairedTokenPath;

    /// @notice Adapter-specific route bytes for pairedToken -> WETH swaps
    bytes public pairedTokenToWethPath;

    /// @notice Slippage tolerance for inventory-balancing swaps (in basis points, 1-200)
    uint256 public swapSlippageBps;

    Position public positionMain;
    Position public positionAlt;

    // ============ Constructor ============
    constructor(DeploymentConfig memory _params) RegistryClient(_params.addresses.registry) {
        _validateConstructorParams(_params);

        weth = IWETH(_params.addresses.weth);
        pool = IUniswapV3Pool(_params.addresses.pool);
        factory = IUniswapV3Factory(_params.addresses.factory);

        address _token0Address = IUniswapV3Pool(_params.addresses.pool).token0();
        address _token1Address = IUniswapV3Pool(_params.addresses.pool).token1();
        token0 = IERC20Metadata(_token0Address);
        token1 = IERC20Metadata(_token1Address);

        if (_token0Address == _params.addresses.weth) {
            pairedToken = IERC20Metadata(_token1Address);
        } else if (_token1Address == _params.addresses.weth) {
            pairedToken = IERC20Metadata(_token0Address);
        } else {
            revert UniCLStratInvalidPool();
        }

        // Factory provenance: only a pool created by the configured Uniswap V3 factory may
        // be trusted as `msg.sender` of `uniswapV3MintCallback`. Without this check an
        // interface-compatible malicious pool could drain inventory during mint.
        uint24 _fee = IUniswapV3Pool(_params.addresses.pool).fee();
        if (factory.getPool(_token0Address, _token1Address, _fee) != _params.addresses.pool) {
            revert UniCLStratInvalidPool();
        }

        tickSpacing = IUniswapV3Pool(_params.addresses.pool).tickSpacing();
        positionWidth = _params.strategy.positionWidth;
        rebalanceTickThreshold = _params.strategy.rebalanceTickThreshold;
        maxTickDeviation = _params.strategy.maxTickDeviation;
        twapInterval = _params.strategy.twapInterval;
        shortTwapInterval = _params.strategy.shortTwapInterval;
        maxTotalNAV = _params.strategy.maxTotalNAV;
        // Both probes: `observe` so NAV will compute; in-use cardinality so the TWAP is
        // a dense average rather than a cardinality-1 spot extrapolation.
        _requireTwapOracle(twapInterval);
        _requireTwapOracle(shortTwapInterval);
        swapAdapter = _params.routes.swapAdapter;
        wethToPairedTokenPath = _params.routes.wethToPairedTokenPath;
        pairedTokenToWethPath = _params.routes.pairedTokenToWethPath;

        _validateRouteConfig();

        swapSlippageBps = DEFAULT_SWAP_SLIPPAGE_BPS;
        _genesisTimestamp = block.timestamp;

        _giveConverterAllowances();
    }

    // ============ Receive Function ============
    receive() external payable {}

    // ============ Metadata ============
    function name() external pure returns (string memory) {
        return "Uniswap Concentrated Liquidity Strategy";
    }

    function version() external pure returns (string memory) {
        return "2.0.0";
    }

    function genesisTimestamp() external view returns (uint256) {
        return _genesisTimestamp;
    }

    function totalDeposited() external view returns (uint256) {
        return _totalDeposited;
    }

    function totalWithdrawn() external view returns (uint256) {
        return _totalWithdrawn;
    }

    // ============ Strategy Views ============
    function navInETH() public view returns (uint256) {
        return address(this).balance
            + UniCLStratLib.inventoryValueInETH(
                pool,
                IOracle(_registry.oracle()),
                address(weth),
                address(token0),
                address(token1),
                positionMain,
                positionAlt,
                _twapSqrtPrice()
            );
    }

    function maxDeposit() external view returns (uint256) {
        return _maxDeposit();
    }

    function maxWithdrawal() public view returns (uint256) {
        if (paused()) return 0;
        return navInETH();
    }

    /**
     * @notice True unless a rebalance is both needed **and** currently actionable.
     * @dev This view is the protocol's rebalance trigger: StrategyManager
     *      (`_checkAndRebalanceStrategies`) and StrategyKeeperExecutor (`_rebalanceNeeded`)
     *      both act on `!paused() && !isHealthy()`. `false` therefore has to mean
     *      "`rebalance()` would succeed right now" — anything else makes the keeper fire an
     *      upkeep that is a guaranteed revert, swallowed by StrategyManager's `try/catch`
     *      as `StrategyRebalanceFailed` while burning the tick's gas.
     *
     *      Paused and non-calm both report **healthy**. `rebalance()` cannot run in either
     *      state (`whenNotPaused` / `UniCLStratNotCalm`), so position drift is not
     *      actionable — and while the pool is dislocated it is not even knowable, since the
     *      spot tick drift would be measured against is the dislocated one. Read `true` here
     *      as "no action to take", not as a claim that the position is well placed.
     *
     *      Deposit gating is unaffected by that relaxation: every call site pairs
     *      `isHealthy()` with `maxDeposit() > 0`, and `_maxDeposit()` independently returns
     *      0 when paused or not calm, so neither state can admit a deposit. The hard mint
     *      gate remains the `_isCalm()` check inside `deposit()` itself.
     */
    function isHealthy() public view returns (bool) {
        if (paused()) return true;
        if (!_isCalm()) return true;
        return !_mainNeedsRecenter();
    }

    // ============ Strategy Actions ============
    function deposit() external payable onlyAuthContract(Auth.STRATEGY_MANAGER) whenNotPaused nonReentrant {
        uint256 _depositAmount = msg.value;
        if (_depositAmount == 0) revert StrategyZeroDeposit();
        if (!_isCalm()) revert UniCLStratNotCalm();
        // Post-receipt check: `msg.value` is already in `address(this).balance` (and thus
        // in `navInETH()`), so comparing against `_maxDeposit()` would double-count it and
        // reject any deposit above ~50% of advertised headroom (full headroom always reverts).
        if (navInETH() > maxTotalNAV) revert StrategyMaxDepositExceeded();

        _totalDeposited += _depositAmount;

        // Deposit ETH to Converter to get WETH back
        IConverter(_registry.converter()).wrapETH{value: _depositAmount}();

        // Incremental: the new WETH (plus any idle leftovers) is added on top of the existing
        // positions. Only a range that needs re-centering is unwound first.
        _recenterIfNeeded();
        _deployInventory(true);

        emit FundsDeposited(_depositAmount);
    }

    /**
     * @notice Deploys idle native ETH (e.g. donations) into the underlying protocol.
     * @dev Callable only by strategy admin. Same incremental path as `deposit()`: existing
     *      positions are only unwound when the main range needs re-centering. The invested
     *      amount is capped at the remaining capacity (`maxDeposit()`). Return value and
     *      `FundsInvested` report only the idle native ETH actually deployed. Idle WETH/paired
     *      leftovers may also be re-deployed in this call but are excluded from `invested`
     *      and the event amount.
     * @return invested Idle native ETH deployed (0 when balance is zero or no capacity remains)
     */
    function investIdleETH()
        external
        onlyAuthRole(Auth.ADMIN_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 invested)
    {
        uint256 _idle = address(this).balance;
        if (_idle == 0) return 0;
        if (!_isCalm()) revert UniCLStratNotCalm();

        uint256 _capacity = _maxDeposit();
        invested = _idle < _capacity ? _idle : _capacity;
        if (invested == 0) return 0;

        IConverter(_registry.converter()).wrapETH{value: invested}();
        _recenterIfNeeded();
        _deployInventory(true);

        // Idle native ETH only; collected fees re-deployed above are not included.
        emit FundsInvested(invested);
    }

    /**
     * @notice Withdraws `_amount` ETH to `_receiver`, spending idle native ETH first.
     * @dev Idle native ETH (e.g. donations) is counted in `navInETH()` — and therefore in
     *      `maxWithdrawal()` — so `withdraw()` must be able to deliver it. Two paths:
     *      - Idle native ETH covers the request: the payout is sent directly from the native
     *        balance, with no pool or Converter interaction (the LP position stays untouched).
     *      - Idle native ETH falls short: all idle ETH goes toward the payout and only the
     *        remainder is sourced from WETH, of which exactly the needed amount is unwrapped.
     *        Native ETH is never wrapped just to be unwrapped again. When the paired -> WETH
     *        route is tradable, WETH is sourced in order: idle WETH, idle paired token, then a
     *        partial burn of the alt position followed by the main position, sized
     *        (at TWAP marks, padded by slippage + the route's measured cost) to cover the
     *        shortfall. An untradable route, or a request that covers the whole NAV once
     *        padded by `swapSlippageBps`, fully unwinds instead — see {_sourceWeth}. Only the
     *        missing WETH is bought with the paired token; leftovers are re-added without any
     *        inventory swap (main first, alt with the residual) and only when the pool is
     *        calm. The unwind itself is intentionally not calm-gated: `navInETH()` marks at
     *        TWAP/oracle (a skewed burn does not crystallize IL into NAV), the conversion swap
     *        is independently bounded, and a calm revert would stall exit liquidity when
     *        redemptions spike. See `docs/STRATEGY_GUARDRAILS.md` §1.1.1.
     *      In both paths the receiver gets a single native ETH transfer and the return value
     *      is the ETH actually delivered.
     */
    function withdraw(address _receiver, uint256 _amount)
        external
        onlyAuthContract(Auth.STRATEGY_MANAGER)
        whenNotPaused
        nonReentrant
        returns (uint256 _withdrawn)
    {
        if (_receiver == address(0)) revert UniCLStratZeroAddress();
        if (_amount == 0) revert StrategyZeroWithdrawal();

        uint256 _navBeforeWithdrawal = navInETH();
        if (_amount > _navBeforeWithdrawal) revert StrategyMaxWithdrawalExceeded();

        uint256 _idleETH = address(this).balance;

        if (_idleETH >= _amount) {
            // Idle native ETH fully covers the request: pay out directly, leaving the
            // LP position and WETH/paired inventory untouched.
            _withdrawn = _amount;
            _totalWithdrawn += _withdrawn;
            payable(_receiver).sendValue(_withdrawn);
        } else {
            // Spend all idle native ETH toward the payout; source only the remainder
            // from WETH via liquidity removal and paired-token conversion.
            uint256 _remainder = _amount - _idleETH;

            // Padded by slippage, a (near-)full request would burn every position on the
            // partial path anyway: unwind outright and skip the route-cost probe.
            bool _nearFullWithdrawal =
                _amount * (BASIS_POINTS + swapSlippageBps) >= _navBeforeWithdrawal * BASIS_POINTS;
            _sourceWeth(_remainder, _nearFullWithdrawal);

            uint256 _wethBalance = weth.balanceOf(address(this));
            uint256 _wethToUnwrap = _wethBalance < _remainder ? _wethBalance : _remainder;
            _withdrawn = _idleETH + _wethToUnwrap;
            if (_withdrawn == 0) revert UniCLStratInsufficientWETH();

            _totalWithdrawn += _withdrawn;

            // Unwrap only the WETH portion to this contract, then deliver idle ETH +
            // unwrapped remainder to the receiver in a single native transfer.
            if (_wethToUnwrap > 0) IConverter(_registry.converter()).unwrapWETH(_wethToUnwrap, address(this));
            payable(_receiver).sendValue(_withdrawn);

            if (_isCalm()) _deployInventory(false);
        }

        emit FundsWithdrawn(_withdrawn);
    }

    function rebalance() external onlyAuthContract(Auth.STRATEGY_MANAGER) whenNotPaused nonReentrant {
        // Calm is checked first: `isHealthy()` reports healthy while the pool is dislocated,
        // so this order is what makes a non-calm call surface `UniCLStratNotCalm` instead of
        // the misleading `StrategyIsHealthy`. The two guards are disjoint in this order.
        if (!_isCalm()) revert UniCLStratNotCalm();
        if (isHealthy()) revert StrategyIsHealthy();

        _removeLiquidityAndCollect();
        _setMainTicks();
        _deployInventory(true);

        emit Rebalanced();
    }

    /**
     * @notice Refreshes on-chain state via the keeper path.
     * @dev Pokes Uniswap V3 positions with `burn(..., 0)` so accrued LP fees flow into
     *      `tokensOwed` (NAV and `pendingPerformanceFeeInETH` both read that storage). Does not
     *      call `UniCLStratLib.accrueLpFees` — the pending view already includes the live
     *      `tokensOwed - snapshot` delta, and settle/remove accrue when they need durable
     *      counters. Does not remove liquidity or call `collect()`.
     */
    function sync() external onlyAuthContract(Auth.STRATEGY_MANAGER) whenNotPaused nonReentrant {
        UniCLStratLib.pokePositions(pool, positionMain, positionAlt);
        emit Synced();
    }

    /**
     * @inheritdoc IStrategy
     * @dev Over already-materialized `tokensOwed` plus stored counters (via the live
     *      `tokensOwed - snapshot` delta in `UniCLStratLib.unchargedLpFeeAmounts`). Unpoked fee growth is
     *      invisible until `sync()` or a remove/collect poke. Accrue is not required for the
     *      view — only for durable counter updates on settle/remove.
     */
    function pendingPerformanceFeeInETH(uint256 _performanceFeeBps) external view returns (uint256 feeETH) {
        if (_performanceFeeBps == 0 || paused()) return 0;
        return _unchargedLpFeesInETH() * _performanceFeeBps / BASIS_POINTS;
    }

    /**
     * @inheritdoc IStrategy
     * @dev Accrues already-materialized `tokensOwed` into counters, then charges. Does not poke —
     *      settlement matches `pendingPerformanceFeeInETH` (SM/keeper gate on that view). Unpoked
     *      fee growth is picked up by `sync()` or remove/collect. When the ETH-denominated fee
     *      rounds to zero (`feeBaseETH * bps / BASIS_POINTS == 0`), returns without advancing
     *      charged counters so dust remains feeable once the base is large enough to mint ≥ 1 wei.
     */
    function settlePerformanceFee(uint256 _performanceFeeBps)
        external
        nonReentrant
        onlyAuthContract(Auth.STRATEGY_MANAGER)
        returns (uint256 feeETH)
    {
        if (_performanceFeeBps == 0 || paused()) return 0;

        (uint256 _uncharged0, uint256 _uncharged1) =
            UniCLStratLib.accrueLpFees(pool, _lpFees, positionMain, positionAlt);
        if (_uncharged0 == 0 && _uncharged1 == 0) return 0;

        uint256 _feeBaseETH = _pairValueInETH(_uncharged0, _uncharged1);
        feeETH = _feeBaseETH * _performanceFeeBps / BASIS_POINTS;
        // Dust base: floor-division to zero must not write off the uncharged amounts.
        if (feeETH == 0) return 0;

        _lpFees.charged0 = _lpFees.earned0;
        _lpFees.charged1 = _lpFees.earned1;
        emit PerformanceFeeSettled(feeETH);
    }

    // ============ Configuration ============

    function setPositionWidth(int24 _newPositionWidth) external onlyAuthRole(Auth.ADMIN_ROLE) {
        _setPositionWidth(_newPositionWidth);
    }

    function setRebalanceTickThreshold(int24 _newRebalanceTickThreshold) external onlyAuthRole(Auth.ADMIN_ROLE) {
        _setRebalanceTickThreshold(_newRebalanceTickThreshold);
    }

    function setMaxTickDeviation(int56 _newMaxTickDeviation) external onlyAuthRole(Auth.ADMIN_ROLE) {
        _setMaxTickDeviation(_newMaxTickDeviation);
    }

    function setTwapInterval(uint32 _newTwapInterval) external onlyAuthRole(Auth.ADMIN_ROLE) {
        _setTwapInterval(_newTwapInterval);
    }

    function setShortTwapInterval(uint32 _newShortTwapInterval) external onlyAuthRole(Auth.ADMIN_ROLE) {
        _setShortTwapInterval(_newShortTwapInterval);
    }

    function setMaxTotalNAV(uint256 _newMaxTotalNAV) external onlyAuthRole(Auth.ADMIN_ROLE) {
        _setMaxTotalNAV(_newMaxTotalNAV);
    }

    function setRouteConfig(
        address _swapAdapter,
        bytes calldata _wethToPairedTokenPath,
        bytes calldata _pairedTokenToWethPath
    ) external onlyAuthRole(Auth.ADMIN_ROLE) {
        _setRouteConfig(_swapAdapter, _wethToPairedTokenPath, _pairedTokenToWethPath);
    }

    /**
     * @notice Sets the slippage tolerance for inventory-balancing swaps
     * @param _newSwapSlippageBps Slippage in basis points (must not exceed MAX_SWAP_SLIPPAGE_BPS)
     */
    function setSwapSlippageBps(uint256 _newSwapSlippageBps) external onlyAuthRole(Auth.ADMIN_ROLE) {
        _setSwapSlippageBps(_newSwapSlippageBps);
    }

    function pause() external onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE) nonReentrant {
        _pauseStrategy();
    }

    function paused() public view override(Pausable, IStrategy) returns (bool) {
        return super.paused();
    }

    function unpause() external onlyAuthRole(Auth.ADMIN_ROLE) {
        _unpauseStrategy();
    }

    /**
     * @notice Emergency unwind: send liquidity to StrategyManager. ADMIN_ROLE or SECURITY_ROLE. Requires pause.
     * @dev WETH is unwrapped to native ETH via direct weth.withdraw() (not through the Converter).
     *      This is an intentional design choice: emergencyExit must work even when the Converter
     *      is paused, so we bypass the Converter and call the WETH contract directly. WETH unwrap
     *      is strict (canonical WETH does not revert) — same trust assumption as the pause-time
     *      WETH allowance revoke. Native ETH is swept first (strict). Paired-token recovery is
     *      best-effort end-to-end: `balanceOf` is try/catch'd and the transfer uses
     *      {SafeERC20-trySafeTransfer} (reverting tokens, false returns, USDT-style empty
     *      returndata) so neither a bricked balance read nor a failed transfer can roll back the
     *      ETH sweep (emits {PairedTokenTransferSkipped} on either failure; a later
     *      `emergencyExit()` retries once the token responds again). Whitelist the paired token
     *      via `IStrategyManager.addSupportedERC20()` so NAV continues to count recoverable
     *      value when the transfer succeeds.
     *
     *      This function never moves pool liquidity: it only transfers what the strategy
     *      already holds. The LP-fee accounting reset (see {UniCLStratLib-resetLpFeeAccounting}) best-effort
     *      accrues (snapshot fallback if `positions` reverts), so a
     *      degraded pool cannot block the exit. If the pause-time pool unwind was skipped
     *      (see {_pauseStrategy}), any LP liquidity stays in the pool — it remains attributed
     *      to the strategy via `navInETH()` and is recovered once the pool functions again, by
     *      having the admin `unpause()` and then either resume normal withdrawals or re-run
     *      `pause()` (which performs the unwind) followed by another `emergencyExit()`.
     */
    function emergencyExit() external override onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE) nonReentrant {
        if (!paused()) revert UniCLStratNotPaused();

        uint256 _wethBalance = weth.balanceOf(address(this));
        if (_wethBalance > 0) weth.withdraw(_wethBalance);

        uint256 _ethToSend = address(this).balance;

        address strategyManagerAddress = _registry.strategyManager();
        // ETH first: paired-token transfer is best-effort and must not roll back the sweep.
        if (_ethToSend > 0) payable(strategyManagerAddress).sendValue(_ethToSend);

        // Paired-token recovery is best-effort (see {UniCLStratLib-trySweepToken}): a paused or
        // blacklisted token must not hostage the ETH sweep above.
        if (!UniCLStratLib.trySweepToken(address(pairedToken), strategyManagerAddress)) {
            emit PairedTokenTransferSkipped();
        }

        UniCLStratLib.resetLpFeeAccounting(pool, _lpFees, positionMain, positionAlt);

        emit EmergencyExited(_ethToSend);
    }

    // ============ Uniswap Callback ============

    function uniswapV3MintCallback(uint256 _amount0, uint256 _amount1, bytes calldata) external {
        if (msg.sender != address(pool)) revert UniCLStratCallerNotPool();
        if (!_minting) revert UniCLStratInvalidMintCallback();

        if (_amount0 > 0) token0.safeTransfer(address(pool), _amount0);
        if (_amount1 > 0) token1.safeTransfer(address(pool), _amount1);

        _minting = false;
    }

    // ============ Private Configuration Helpers ============

    function _setPositionWidth(int24 _newPositionWidth) private {
        _validatePositiveInt24(_newPositionWidth);
        emit PositionWidthUpdated(positionWidth, _newPositionWidth);
        positionWidth = _newPositionWidth;
    }

    function _setRebalanceTickThreshold(int24 _newRebalanceTickThreshold) private {
        _validatePositiveInt24(_newRebalanceTickThreshold);
        emit RebalanceTickThresholdUpdated(rebalanceTickThreshold, _newRebalanceTickThreshold);
        rebalanceTickThreshold = _newRebalanceTickThreshold;
    }

    function _setMaxTickDeviation(int56 _newMaxTickDeviation) private {
        if (_newMaxTickDeviation <= 0) revert UniCLStratInvalidConfig();
        emit MaxTickDeviationUpdated(maxTickDeviation, _newMaxTickDeviation);
        maxTickDeviation = _newMaxTickDeviation;
    }

    function _setTwapInterval(uint32 _newTwapInterval) private {
        _validateTwapInterval(_newTwapInterval, MIN_TWAP_INTERVAL);
        _requireTwapOracle(_newTwapInterval);
        emit TwapIntervalUpdated(twapInterval, _newTwapInterval);
        twapInterval = _newTwapInterval;
    }

    function _setShortTwapInterval(uint32 _newShortTwapInterval) private {
        _validateTwapInterval(_newShortTwapInterval, MIN_SHORT_TWAP_INTERVAL);
        _requireTwapOracle(_newShortTwapInterval);
        emit ShortTwapIntervalUpdated(shortTwapInterval, _newShortTwapInterval);
        shortTwapInterval = _newShortTwapInterval;
    }

    function _setMaxTotalNAV(uint256 _newMaxTotalNAV) private {
        emit MaxTotalNAVUpdated(maxTotalNAV, _newMaxTotalNAV);
        maxTotalNAV = _newMaxTotalNAV;
    }

    function _setRouteConfig(
        address _swapAdapter,
        bytes calldata _wethToPairedTokenPath,
        bytes calldata _pairedTokenToWethPath
    ) private {
        // Validate against the new values before writing storage, so no partial state
        // mutation occurs even transiently. The storage-based _validateRouteConfig()
        // is used by the constructor where the values are already written.
        _validateRouteConfig(_swapAdapter, _wethToPairedTokenPath, _pairedTokenToWethPath);

        swapAdapter = _swapAdapter;
        wethToPairedTokenPath = _wethToPairedTokenPath;
        pairedTokenToWethPath = _pairedTokenToWethPath;

        emit RouteConfigUpdated(_swapAdapter, _wethToPairedTokenPath, _pairedTokenToWethPath);
    }

    /// @dev Validates route config from constructor-initialised storage (values already written)
    function _validateRouteConfig() private view {
        _validateRouteConfig(swapAdapter, wethToPairedTokenPath, pairedTokenToWethPath);
    }

    /// @dev Validates route config from explicit parameters (check before write)
    function _validateRouteConfig(
        address _swapAdapter,
        bytes memory _wethToPairedTokenPath,
        bytes memory _pairedTokenToWethPath
    ) private view {
        UniCLStratLib.validateRouteConfig(
            IConverter(_registry.converter()),
            _swapAdapter,
            _wethToPairedTokenPath,
            _pairedTokenToWethPath,
            address(weth),
            address(pairedToken)
        );
    }

    function _setSwapSlippageBps(uint256 _newSwapSlippageBps) private {
        if (_newSwapSlippageBps == 0 || _newSwapSlippageBps > MAX_SWAP_SLIPPAGE_BPS) revert UniCLStratInvalidConfig();
        emit SwapSlippageUpdated(swapSlippageBps, _newSwapSlippageBps);
        swapSlippageBps = _newSwapSlippageBps;
    }

    /**
     * @dev Engages the circuit breaker first: `_pause()` touches only local state, so the
     *      SECURITY_ROLE pause can never be blocked by a degraded pool or a paired token
     *      that rejects `approve(0)` (paused / blacklisted USDC). The pool unwind is
     *      best-effort (try/catch self-call, {LiquidityUnwindSkipped} on failure). WETH
     *      Converter allowance is revoked strictly — canonical WETH `approve` does not
     *      revert. The paired-token revoke is best-effort ({ConverterAllowanceRevocationSkipped})
     *      so it cannot roll back the pause, the unwind, or the WETH revoke. Leftover
     *      paired-token approvals while paused are inert: every Converter-calling path is
     *      `whenNotPaused`. `unpause()` restores allowances strictly (fail-closed).
     */
    function _pauseStrategy() private {
        _pause();

        // NOTE: the parameterless catch is deliberate — binding the revert data would copy
        // unbounded returndata into memory, letting a degraded pool grief the pause with a
        // returndata bomb.
        try this.selfRemoveLiquidityAndCollect() {}
        catch {
            emit LiquidityUnwindSkipped();
        }

        address _converter = address(_registry.converter());
        IERC20Metadata(address(weth)).forceApprove(_converter, 0);
        _tryRevokePairedTokenConverterAllowance();
    }

    /**
     * @notice Self-call hook that removes all pool liquidity and collects owed tokens.
     * @dev Callable only by the strategy itself. Exists so the pause path can attempt the
     *      pool unwind inside a try/catch — a degraded pool must never block the circuit
     *      breaker.
     */
    function selfRemoveLiquidityAndCollect() external {
        if (msg.sender != address(this)) revert UniCLStratCallerNotSelf();
        _removeLiquidityAndCollect();
    }

    /**
     * @notice Self-call hook that revokes this strategy's Converter allowance for the paired token.
     * @dev Callable only by the strategy itself. Exists so the pause path can attempt
     *      paired-token `approve(0)` inside a try/catch — a paused or blacklisted token must
     *      never block the circuit breaker or roll back the strict WETH revoke.
     *      Not `nonReentrant`: `pause()` is already entered.
     */
    function selfRevokePairedTokenConverterAllowance() external {
        if (msg.sender != address(this)) revert UniCLStratCallerNotSelf();
        pairedToken.forceApprove(address(_registry.converter()), 0);
    }

    function _unpauseStrategy() private {
        _giveConverterAllowances();
        _unpause();
    }

    // ============ Private View Helpers ============

    function _maxDeposit() internal view returns (uint256) {
        if (paused() || !_isCalm()) return 0;

        uint256 _currentNAV = navInETH();
        if (_currentNAV >= maxTotalNAV) return 0;

        return maxTotalNAV - _currentNAV;
    }

    /**
     * @notice True when spot tick and short TWAP both sit within ±`maxTickDeviation` of the long TWAP.
     * @dev Gates minting paths (`deposit`, `investIdleETH`, `rebalance`, and the
     *      re-add branch of `withdraw`). Does NOT gate `withdraw`'s burn / convert
     *      / payout — `pool.mint` has no price bound of its own, so this check is
     *      the only defence against minting into a dislocated tick. Burns are
     *      marked at TWAP in `navInETH()` and the conversion swap is bounded
     *      independently by quote / oracle / slippage. Rationale:
     *      `docs/STRATEGY_GUARDRAILS.md` §1.1.1.
     */
    function _isCalm() internal view returns (bool) {
        int24 _tick = _currentTick();
        (bool _twapAvailable, int56 _twapTick) = _observeTwap(twapInterval);
        if (!_twapAvailable) return false;

        (bool _shortTwapAvailable, int56 _shortTwapTick) = _observeTwap(shortTwapInterval);
        if (!_shortTwapAvailable) return false;

        int56 _minCalmTick = _twapTick - maxTickDeviation;
        int56 _maxCalmTick = _twapTick + maxTickDeviation;

        if (int56(_tick) < _minCalmTick || int56(_tick) > _maxCalmTick) return false;
        if (_shortTwapTick < _minCalmTick || _shortTwapTick > _maxCalmTick) return false;

        return true;
    }

    function _currentTick() internal view returns (int24 _tick) {
        (, _tick,,,,,) = pool.slot0();
    }

    function _sqrtPrice() internal view returns (uint160 _sqrtPriceX96) {
        (_sqrtPriceX96,,,,,,) = pool.slot0();
    }

    function _twapSqrtPrice() internal view returns (uint160) {
        return TickMath.getSqrtRatioAtTick(int24(_twap()));
    }

    function _twap() internal view returns (int56 _twapTick) {
        (bool _twapAvailable, int56 _observedTwapTick) = _observeTwap(twapInterval);
        if (!_twapAvailable) revert UniCLStratPoolTWAPNotAvailable();
        return _observedTwapTick;
    }

    /// @dev Constructor / setter gate. `observe` succeeding is necessary so `navInETH`
    ///      will compute; in-use cardinality is necessary so that TWAP is not a
    ///      one-observation spot extrapolation. Neither check is sufficient alone.
    function _requireTwapOracle(uint32 _interval) internal view {
        UniCLStratLib.requireTwapOracle(pool, _interval, MIN_OBSERVATION_CARDINALITY, MAX_BLOCK_SECONDS);
    }

    /// @dev Shared with the UniswapV3ConverterAdapter via {TickUtils.tryMeanTick};
    ///      rounds toward negative infinity, matching Uniswap's OracleLibrary.
    function _observeTwap(uint32 _interval) internal view returns (bool _success, int56 _twapTick) {
        (bool _ok, int24 _meanTick) = TickUtils.tryMeanTick(pool, _interval);
        return (_ok, _meanTick);
    }

    // ============ Internal Liquidity ============

    /**
     * @dev Deploys idle WETH / paired-token balances into the pool. Callers must ensure the
     *      pool is calm (minting paths) — `pool.mint` has no price bound of its own.
     *      1. (`_allowSwap`) swap only the imbalance between the idle inventory and the ratio
     *         the main range needs at the current price ({_swapToMainRatio}), not a 50/50 split;
     *      2. add as much as possible to the main range;
     *      3. park whatever the main range could not absorb in the single-sided alt range
     *         ({_deployLeftoverToAlt}), chosen from the token actually left over.
     */
    function _deployInventory(bool _allowSwap) internal {
        if (!initTicks || paused()) return;

        // Leftovers below this (token1 units) stay idle — still counted in NAV and redeployed
        // by the next minting call — instead of paying for an alt mint / re-placement.
        uint256 _minLeftoverValue = _idleValueInToken1(_sqrtPrice()) * MIN_INVENTORY_SWAP_BPS / BASIS_POINTS;

        if (_allowSwap) _swapToMainRatio();
        _mintPosition(positionMain);
        _deployLeftoverToAlt(_minLeftoverValue);
    }

    function _mintPosition(Position memory _position) internal {
        if (!_positionIsValid(_position)) return;

        uint128 _liquidity = _liquidityForPosition(_position);
        if (_liquidity == 0) return;

        if (_position.tickLower == positionMain.tickLower && _position.tickUpper == positionMain.tickUpper) {
            (uint256 _amount0, uint256 _amount1) = _amountsForLiquidity(_position, _liquidity);
            if (_amount0 == 0 || _amount1 == 0) return;
        }

        _minting = true;
        try pool.mint(address(this), _position.tickLower, _position.tickUpper, _liquidity, "") {
            _minting = false;
        } catch (bytes memory _reason) {
            _revertWithReason(_reason);
        }
    }

    /**
     * @dev Parks the inventory left after the main mint in the alt range. The alt range is
     *      single-sided (entirely below spot for a token1 leftover, entirely above for a
     *      token0 leftover), so it can only hold the token that is actually left over:
     *      - existing alt already holds only that token -> add to it;
     *      - existing alt holds the other token (or straddles spot) -> remove it, offer the
     *        returned tokens to the main range again, then re-place the alt range around the
     *        final leftover. Alt ticks are only reassigned once the old position is empty.
     */
    function _deployLeftoverToAlt(uint256 _minLeftoverValue) internal {
        (bool _hasLeftover, bool _leftoverIsToken1) = _leftoverSide(_minLeftoverValue);
        if (!_hasLeftover) return;

        int24 _tick = _currentTick();
        (bool _occupied, bool _holdsOnlyLeftover) = UniCLStratLib.altState(pool, positionAlt, _tick, _leftoverIsToken1);
        if (_occupied) {
            if (_holdsOnlyLeftover) {
                _mintPosition(positionAlt);
                return;
            }

            UniCLStratLib.removeAltLiquidity(pool, _lpFees, positionMain, positionAlt);

            _mintPosition(positionMain);
            (_hasLeftover, _leftoverIsToken1) = _leftoverSide(_minLeftoverValue);
            if (!_hasLeftover) return;
        }

        UniCLStratLib.placeAlt(pool, positionAlt, _tick, _leftoverIsToken1, tickSpacing, positionWidth * tickSpacing);
        _mintPosition(positionAlt);
    }

    /// @dev Which token dominates the idle inventory, compared in token1 units at spot.
    ///      `_hasLeftover` is false when the dominant side is at or below `_minValue`.
    function _leftoverSide(uint256 _minValue) internal view returns (bool, bool) {
        return UniCLStratLib.leftoverSide(address(token0), address(token1), _sqrtPrice(), _minValue);
    }

    function _idleValueInToken1(uint160 _sqrtPriceX96) internal view returns (uint256) {
        return UniCLStratLib.token0InToken1(token0.balanceOf(address(this)), _sqrtPriceX96)
            + token1.balanceOf(address(this));
    }

    /**
     * @dev Swaps the idle inventory towards the value ratio the main range needs at the
     *      current (calm-gated) spot price, which is the price `pool.mint` charges at.
     *      For a range [a, b] and spot p (sqrt prices), the token0 : token1 value split in
     *      token1 units is `p·(b − p)/b : (p − a)` (all token0 below the range, all token1
     *      above it). The swap is cost-adjusted: selling Δ of the excess token only adds
     *      Δ·(1 − cost) of the other, so total value drops by cost·Δ and
     *      `Δ = excess / (1 − cost·w_sold)`, where `w_sold` is the target share of the sold token.
     *      The cost is measured on the configured route (quote vs oracle), since the route
     *      generally trades through a different pool than this one. Swaps below
     *      {MIN_INVENTORY_SWAP_BPS} of the deployed value are skipped. Any residual from
     *      slippage or route/pool price differences is parked in the alt range.
     */
    function _swapToMainRatio() internal {
        (bool _sellWeth, uint256 _amountIn) = UniCLStratLib.routedInventorySwap(
            _swapConfig(),
            wethToPairedTokenPath,
            pairedTokenToWethPath,
            address(token0),
            _sqrtPrice(),
            positionMain,
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this)),
            MIN_INVENTORY_SWAP_BPS
        );
        if (_amountIn == 0) return;

        if (_sellWeth) {
            _swapWethToPairedToken(_amountIn);
        } else {
            _swapPairedTokenToWeth(_amountIn);
        }
    }

    /**
     * @dev Makes at least `_wethTarget` WETH available (best effort). The paired -> WETH leg
     *      goes through the configured route, which generally does not trade through this pool,
     *      so the decision is driven by that route, not by this pool's calm state:
     *      - Route tradable (quote for the shortfall within the oracle band): idle WETH, then
     *        idle paired token, then a partial burn of alt followed by main, sized at TWAP marks
     *        and padded by `swapSlippageBps` + the route's measured cost, so the paired-token
     *        leg still covers the shortfall after conversion. If that still falls short,
     *        everything is unwound as a fallback.
     *      - Route untradable (quote fails or is outside the oracle band): full unwind first,
     *        which maximises the WETH obtained without swapping.
     *      - `_fullUnwind` set by the caller (near-full withdrawal): full unwind first, without
     *        probing the route, since the partial burn would consume every position anyway.
     */
    function _sourceWeth(uint256 _wethTarget, bool _fullUnwind) internal {
        uint256 _wethBalance = weth.balanceOf(address(this));
        if (_wethBalance >= _wethTarget) return;

        if (!_fullUnwind) {
            uint256 _shortfall = _wethTarget - _wethBalance;
            (bool _tradable, uint256 _costBps) =
                UniCLStratLib.routeCostBps(_swapConfig(), pairedTokenToWethPath, _shortfall, true);
            _fullUnwind = !_tradable;

            if (_tradable) {
                uint256 _needed = _shortfall * (BASIS_POINTS + swapSlippageBps + _costBps) / BASIS_POINTS;
                uint256 _pairedBalance = pairedToken.balanceOf(address(this));
                uint256 _idlePairedValue = address(pairedToken) == address(token0)
                    ? _pairValueInETH(_pairedBalance, 0)
                    : _pairValueInETH(0, _pairedBalance);
                if (_needed > _idlePairedValue) _decreaseLiquidityForValue(_needed - _idlePairedValue);
            }
        }

        // Pass 0 converts after the (partial or full) unwind above; pass 1 is the full-unwind
        // fallback when the partial path still leaves WETH short and liquidity remains.
        for (uint256 _pass; _pass < 2; ++_pass) {
            if (_fullUnwind) _removeLiquidityAndCollect();
            _convertToWeth(_wethTarget);
            if (weth.balanceOf(address(this)) >= _wethTarget || !_hasPoolLiquidity()) return;
            _fullUnwind = true;
        }
    }

    /// @dev Burns (and collects) roughly `_value` ETH worth of pool inventory: the alt range
    ///      first (it is out of range and earns nothing), then the main range.
    function _decreaseLiquidityForValue(uint256 _value) internal {
        UniCLStratLib.decreaseLiquidityForValue(
            pool,
            _lpFees,
            positionMain,
            positionAlt,
            _swapConfig(),
            address(token0),
            address(token1),
            _value,
            _twapSqrtPrice()
        );
    }

    /// @dev Full unwind of both positions with LP-fee accrual; see {UniCLStratLib-removeAllLiquidity}.
    function _removeLiquidityAndCollect() internal {
        UniCLStratLib.removeAllLiquidity(pool, _lpFees, positionMain, positionAlt);
    }

    function _positionLiquidity(Position memory _position) internal view returns (uint128 _liquidity) {
        if (!_positionIsValid(_position)) return 0;
        (_liquidity,,,,) = pool.positions(_positionKey(_position));
    }

    function _hasPoolLiquidity() internal view returns (bool) {
        return _positionLiquidity(positionMain) > 0 || _positionLiquidity(positionAlt) > 0;
    }

    /// @dev True when the main range has been placed and spot has left it or drifted past
    ///      `rebalanceTickThreshold` from its center.
    function _mainNeedsRecenter() internal view returns (bool) {
        if (!initTicks) return false;

        int24 _tick = _currentTick();
        if (_tick <= positionMain.tickLower || _tick >= positionMain.tickUpper) return true;

        int24 _centerTick = (positionMain.tickLower + positionMain.tickUpper) / 2;
        return _abs(_tick - _centerTick) > _abs(rebalanceTickThreshold);
    }

    /// @dev Places the main range on first use, and re-centers it (full unwind) when spot has
    ///      drifted out of the healthy band; otherwise leaves existing positions untouched.
    function _recenterIfNeeded() internal {
        if (!initTicks) {
            _setMainTicks();
        } else if (_mainNeedsRecenter()) {
            _removeLiquidityAndCollect();
            _setMainTicks();
        }
    }

    /// @dev Only called when the main position is empty (first placement or after a full unwind).
    function _setMainTicks() internal {
        int24 _width = positionWidth * tickSpacing;
        (positionMain.tickLower, positionMain.tickUpper) = TickUtils.baseTicks(_currentTick(), _width, tickSpacing);
        initTicks = true;
    }

    function _liquidityForPosition(Position memory _position) internal view returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmounts(
            _sqrtPrice(),
            TickMath.getSqrtRatioAtTick(_position.tickLower),
            TickMath.getSqrtRatioAtTick(_position.tickUpper),
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this))
        );
    }

    function _amountsForLiquidity(Position memory _position, uint128 _liquidity)
        internal
        view
        returns (uint256 _amount0, uint256 _amount1)
    {
        return _amountsForLiquidityAtSqrtPrice(_position, _liquidity, _sqrtPrice());
    }

    function _amountsForLiquidityAtSqrtPrice(Position memory _position, uint128 _liquidity, uint160 _sqrtPriceX96)
        internal
        pure
        returns (uint256 _amount0, uint256 _amount1)
    {
        return LiquidityAmounts.getAmountsForLiquidity(
            _sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_position.tickLower),
            TickMath.getSqrtRatioAtTick(_position.tickUpper),
            _liquidity
        );
    }

    function _positionKey(Position memory _position) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), _position.tickLower, _position.tickUpper));
    }

    function _positionIsValid(Position memory _position) internal pure returns (bool) {
        return _position.tickLower < _position.tickUpper && _position.tickLower >= TickMath.MIN_TICK
            && _position.tickUpper <= TickMath.MAX_TICK;
    }

    // ============ Internal Accounting ============

    function _unchargedLpFeesInETH() internal view returns (uint256) {
        (uint256 _uncharged0, uint256 _uncharged1) =
            UniCLStratLib.unchargedLpFeeAmounts(pool, _lpFees, positionMain, positionAlt);
        return _pairValueInETH(_uncharged0, _uncharged1);
    }

    /**
     * @notice Tops up the strategy's WETH balance to `_targetWethAmount` by swapping
     *         paired tokens for exactly the missing WETH amount.
     * @dev Uses an exact-output swap so the strategy receives precisely the WETH it is
     *      missing (no oracle-estimate drift on the output side). If the paired-token
     *      balance cannot cover the required input, {_swapViaRouteExactAmountOut} falls back
     *      to a best-effort exact-input swap of the whole balance — mirroring the
     *      historical "cap the input at the available balance" behaviour.
     */
    function _convertToWeth(uint256 _targetWethAmount) internal {
        uint256 _wethBalance = weth.balanceOf(address(this));
        if (_wethBalance >= _targetWethAmount) return;

        _swapViaRouteExactAmountOut(pairedTokenToWethPath, _targetWethAmount - _wethBalance);
    }

    function _swapWethToPairedToken(uint256 _amountIn) internal {
        if (_amountIn == 0) return;
        uint256 _swapAmountIn = _amountIn > weth.balanceOf(address(this)) ? weth.balanceOf(address(this)) : _amountIn;
        _swapViaRouteExactAmountIn(wethToPairedTokenPath, _swapAmountIn);
    }

    function _swapPairedTokenToWeth(uint256 _amountIn) internal {
        if (_amountIn == 0) return;
        uint256 _balance = pairedToken.balanceOf(address(this));
        uint256 _swapAmountIn = _amountIn > _balance ? _balance : _amountIn;
        _swapViaRouteExactAmountIn(pairedTokenToWethPath, _swapAmountIn);
    }

    /// @dev Oracle-bounded exact-input swap; security model documented in
    ///      {UniCLStratLib-swapExactIn} (TWAP quote, oracle floor/ceiling, slippage cap).
    function _swapViaRouteExactAmountIn(bytes memory _path, uint256 _amountIn) internal returns (uint256) {
        return UniCLStratLib.swapExactIn(_swapConfig(), _path, _amountIn);
    }

    /// @dev Oracle-bounded exact-output swap with balance-cap fallback; see {UniCLStratLib-swapExactOut}.
    function _swapViaRouteExactAmountOut(bytes memory _path, uint256 _amountOut) internal returns (uint256) {
        return UniCLStratLib.swapExactOut(_swapConfig(), _path, _amountOut);
    }

    function _swapConfig() internal view returns (UniCLStratLib.SwapConfig memory) {
        return UniCLStratLib.SwapConfig({
            converter: IConverter(_registry.converter()),
            oracle: IOracle(_registry.oracle()),
            adapter: swapAdapter,
            weth: address(weth),
            pairedToken: address(pairedToken),
            slippageBps: swapSlippageBps
        });
    }

    function _pairValueInETH(uint256 _amount0, uint256 _amount1) internal view returns (uint256) {
        return UniCLStratLib.pairValueInETH(
            IOracle(_registry.oracle()), address(weth), address(token0), address(token1), _amount0, _amount1
        );
    }

    function _giveConverterAllowances() internal {
        token0.forceApprove(address(_registry.converter()), type(uint256).max);
        token1.forceApprove(address(_registry.converter()), type(uint256).max);
        // Note: In a WETH/pairedToken pool, token0 or token1 IS WETH,
        // so the above two approvals cover both pool tokens. No separate
        // WETH approval is needed.
    }

    /// @dev Best-effort paired-token revoke. Parameterless catch — same returndata-bomb
    ///      rationale as the pause-time pool unwind. WETH is revoked strictly by the caller.
    function _tryRevokePairedTokenConverterAllowance() private {
        try this.selfRevokePairedTokenConverterAllowance() {}
        catch {
            emit ConverterAllowanceRevocationSkipped(address(pairedToken));
        }
    }

    // ============ Internal Validation ============
    function _validateConstructorParams(DeploymentConfig memory _params) internal pure {
        if (
            _params.addresses.registry == address(0) || _params.addresses.weth == address(0)
                || _params.addresses.pool == address(0) || _params.addresses.factory == address(0)
        ) {
            revert UniCLStratZeroAddress();
        }

        _validatePositiveInt24(_params.strategy.positionWidth);
        _validatePositiveInt24(_params.strategy.rebalanceTickThreshold);
        if (_params.strategy.maxTickDeviation <= 0) revert UniCLStratInvalidConfig();
        _validateTwapInterval(_params.strategy.twapInterval, MIN_TWAP_INTERVAL);
        _validateTwapInterval(_params.strategy.shortTwapInterval, MIN_SHORT_TWAP_INTERVAL);
    }

    function _validateTwapInterval(uint32 _interval, uint32 _min) internal pure {
        if (_interval < _min || _interval > MAX_TWAP_INTERVAL) revert UniCLStratInvalidConfig();
    }

    function _validatePositiveInt24(int24 _value) internal pure {
        if (_value <= 0) revert UniCLStratInvalidConfig();
    }

    function _revertWithReason(bytes memory _reason) internal pure {
        assembly {
            revert(add(_reason, 32), mload(_reason))
        }
    }

    function _abs(int24 _value) internal pure returns (uint24) {
        return uint24(_value < 0 ? -_value : _value);
    }
}
