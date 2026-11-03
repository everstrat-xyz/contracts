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
import {ICLFactory} from "../../interfaces/integrations/aero/ICLFactory.sol";
import {ICLPool} from "../../interfaces/integrations/aero/ICLPool.sol";
import {IWETH} from "../../interfaces/integrations/IWETH.sol";

import {TickMath} from "../../libraries/integrations/uniswap/TickMath.sol";
import {TickUtils} from "../../libraries/integrations/uniswap/TickUtils.sol";
import {AeroCLPositionLib} from "../../libraries/strategies/AeroCLPositionLib.sol";
import {AeroCLRangeLib} from "../../libraries/strategies/AeroCLRangeLib.sol";
import {UniCLStratLib} from "../../libraries/strategies/UniCLStratLib.sol";

/**
 * @title AeroCLStrat
 * @notice Native-ETH IStrategy implementation that deploys funds into an Aero (Slipstream) WETH
 *         concentrated-liquidity pool, **unstaked** (earns swap fees, not gauge rewards).
 *         Swap, wrap, and unwrap operations are delegated to the shared Converter.
 * @dev Same behaviour as UniCLStrat v2, split across three contracts so the Phase 2 gauge strategy
 *      can reuse range management unchanged and add NFT/gauge logic on top:
 *      - this contract: configuration, access control, the `IStrategy` entry points, pause /
 *        emergency exit, the calm / TWAP / cardinality gates and the mint callback;
 *      - {AeroCLRangeLib}: range management (main placement / re-centering, ratio swap, alt
 *        placement, WETH sourcing for withdrawals);
 *      - {AeroCLPositionLib}: how a position is held and read (mint / burn / collect / positions),
 *        LP-fee accounting and valuation.
 *      All range state lives in one {AeroCLPositionLib-RangeState} storage struct. Swaps and
 *      inventory math reuse the venue-agnostic parts of {UniCLStratLib}; UniCLStrat itself is
 *      unchanged, so a security fix to its range logic must be ported here by hand.
 *      Slipstream specifics:
 *      - `slot0` has 6 fields (no `feeProtocol`); a 7-field decode reverts. Everything that reads
 *        spot goes through {AeroCLPositionLib-slot0}.
 *      - `CLFactory.getPool` is keyed by tick spacing, not fee (the fee is dynamic), and the
 *        `uint24` overload is also spacing-keyed.
 *      `token0/1`, `tickSpacing`, `observe`, `positions`, `mint`, `burn`, `collect` and the
 *      `uniswapV3MintCallback` name are ABI-identical and go through `IUniswapV3Pool`.
 *      Slipstream fees are dynamic (swap-fee hook); `DeployAeroCLStrat` warns when the pool's fee
 *      cap exceeds the quote-deviation budget. Unstaked LPs keep their pro-rata swap fees net of
 *      the factory's `unstakedFee` share (0 on Ethereum mainnet at deployment;
 *      governance-adjustable). Gauge staking (AERO rewards) is Phase 2, `AeroCLGaugeStrat`.
 *
 *      The contract is intentionally static/non-upgradeable. It keeps the external protocol surface small and
 *      reports all value in ETH for StrategyManager and AMM pricing.
 *      Oracle assumptions (not checked at construction): ETH (`address(0)`) and the pool's
 *      paired token must both have USD feeds on the protocol Oracle — inventory-balancing
 *      swaps and idle paired-token NAV call `Oracle.convert`. For emergency unwind into
 *      StrategyManager NAV, also whitelist the paired token via `addSupportedERC20`.
 *      Go-live (see `DeployAeroCLStrat` NatSpec): timelock `setAllowedAdapter` (+ paired feed /
 *      optional `addSupportedERC20`) → `DeployAeroCLStrat` bytecode → timelock `addStrategy`.
 */
contract AeroCLStrat is IUniCLStrat, RegistryClient, Pausable, ReentrancyGuard {
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
    uint256 public constant MIN_INVENTORY_SWAP_BPS = AeroCLRangeLib.MIN_INVENTORY_SWAP_BPS;

    // ============ Immutable State ============

    IERC20Metadata public immutable token0;
    IERC20Metadata public immutable token1;
    IERC20Metadata public immutable pairedToken;

    IWETH public immutable weth;
    IUniswapV3Pool public immutable pool;
    /// @dev Canonical Slipstream factory used to prove `pool` provenance at construction.
    ICLFactory public immutable factory;

    int24 public immutable tickSpacing;
    uint256 private immutable _genesisTimestamp;

    // ============ Strategy State ============

    uint256 private _totalDeposited;
    uint256 private _totalWithdrawn;

    /// @dev Main / alt ranges, LP-fee accounting and the mint-callback flag; see
    ///      {AeroCLPositionLib-RangeState}. Exposed through {positionMain}, {positionAlt}, {initTicks}.
    AeroCLPositionLib.RangeState private _range;

    uint256 public maxTotalNAV;

    int56 public maxTickDeviation;

    int24 public positionWidth;
    int24 public rebalanceTickThreshold;

    uint32 public twapInterval;
    uint32 public shortTwapInterval;

    /// @notice The whitelisted Converter adapter this strategy routes its swaps through
    address public swapAdapter;

    /// @notice Adapter-specific route bytes for WETH -> pairedToken swaps
    bytes public wethToPairedTokenPath;

    /// @notice Adapter-specific route bytes for pairedToken -> WETH swaps
    bytes public pairedTokenToWethPath;

    /// @notice Slippage tolerance for inventory-balancing swaps (in basis points, 1-200)
    uint256 public swapSlippageBps;

    // ============ Constructor ============
    constructor(DeploymentConfig memory _params) RegistryClient(_params.addresses.registry) {
        _validateConstructorParams(_params);

        weth = IWETH(_params.addresses.weth);
        pool = IUniswapV3Pool(_params.addresses.pool);
        factory = ICLFactory(_params.addresses.factory);

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

        // Factory provenance: only a pool created by the configured Slipstream factory may
        // be trusted as `msg.sender` of `uniswapV3MintCallback`. Without this check an
        // interface-compatible malicious pool could drain inventory during mint.
        // Slipstream keys pools by tick spacing, not fee (the fee is dynamic).
        int24 _spacing = IUniswapV3Pool(_params.addresses.pool).tickSpacing();
        if (factory.getPool(_token0Address, _token1Address, _spacing) != _params.addresses.pool) {
            revert UniCLStratInvalidPool();
        }

        tickSpacing = _spacing;
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
        return "Aero Concentrated Liquidity Strategy";
    }

    function version() external pure returns (string memory) {
        return "1.0.0";
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

    function positionMain() external view returns (int24 tickLower, int24 tickUpper) {
        return (_range.main.tickLower, _range.main.tickUpper);
    }

    function positionAlt() external view returns (int24 tickLower, int24 tickUpper) {
        return (_range.alt.tickLower, _range.alt.tickUpper);
    }

    function initTicks() external view returns (bool) {
        return _range.initTicks;
    }

    // ============ Strategy Views ============
    function navInETH() public view returns (uint256) {
        return address(this).balance
            + AeroCLPositionLib.inventoryValueInETH(
                pool, _range, IOracle(_registry.oracle()), address(weth), address(token0), address(token1), _twapSqrtPrice()
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
        return !AeroCLRangeLib.mainNeedsRecenter(pool, _range, rebalanceTickThreshold);
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
        AeroCLRangeLib.RangeContext memory _ctx = _rangeContext();
        AeroCLRangeLib.recenterIfNeeded(_ctx, _range);
        _deployInventory(_ctx, true);

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
        AeroCLRangeLib.RangeContext memory _ctx = _rangeContext();
        AeroCLRangeLib.recenterIfNeeded(_ctx, _range);
        _deployInventory(_ctx, true);

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
     *        padded by `swapSlippageBps`, fully unwinds instead — see {AeroCLRangeLib-sourceWeth}. Only the
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
            bool _nearFullWithdrawal = _amount * (BASIS_POINTS + swapSlippageBps) >= _navBeforeWithdrawal * BASIS_POINTS;
            AeroCLRangeLib.RangeContext memory _ctx = _rangeContext();
            AeroCLRangeLib.sourceWeth(_ctx, _range, _remainder, _nearFullWithdrawal);

            uint256 _wethBalance = weth.balanceOf(address(this));
            uint256 _wethToUnwrap = _wethBalance < _remainder ? _wethBalance : _remainder;
            _withdrawn = _idleETH + _wethToUnwrap;
            if (_withdrawn == 0) revert UniCLStratInsufficientWETH();

            _totalWithdrawn += _withdrawn;

            // Unwrap only the WETH portion to this contract, then deliver idle ETH +
            // unwrapped remainder to the receiver in a single native transfer.
            if (_wethToUnwrap > 0) IConverter(_registry.converter()).unwrapWETH(_wethToUnwrap, address(this));
            payable(_receiver).sendValue(_withdrawn);

            if (_isCalm()) _deployInventory(_ctx, false);
        }

        emit FundsWithdrawn(_withdrawn);
    }

    function rebalance() external onlyAuthContract(Auth.STRATEGY_MANAGER) whenNotPaused nonReentrant {
        // Calm is checked first: `isHealthy()` reports healthy while the pool is dislocated,
        // so this order is what makes a non-calm call surface `UniCLStratNotCalm` instead of
        // the misleading `StrategyIsHealthy`. The two guards are disjoint in this order.
        if (!_isCalm()) revert UniCLStratNotCalm();
        if (isHealthy()) revert StrategyIsHealthy();

        AeroCLRangeLib.recenter(_rangeContext(), _range);

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
        AeroCLPositionLib.pokePositions(pool, _range);
        emit Synced();
    }

    /**
     * @inheritdoc IStrategy
     * @dev Over already-materialized `tokensOwed` plus stored counters (via the live
     *      `tokensOwed - snapshot` delta in `AeroCLPositionLib.unchargedLpFeeAmounts`). Unpoked fee growth is
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

        (uint256 _uncharged0, uint256 _uncharged1) = AeroCLPositionLib.accrueLpFees(pool, _range);
        if (_uncharged0 == 0 && _uncharged1 == 0) return 0;

        uint256 _feeBaseETH = _pairValueInETH(_uncharged0, _uncharged1);
        feeETH = _feeBaseETH * _performanceFeeBps / BASIS_POINTS;
        // Dust base: floor-division to zero must not write off the uncharged amounts.
        if (feeETH == 0) return 0;

        _range.lpFees.charged0 = _range.lpFees.earned0;
        _range.lpFees.charged1 = _range.lpFees.earned1;
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
     *      already holds. The LP-fee accounting reset (see {AeroCLPositionLib-resetLpFeeAccounting}) best-effort
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

        AeroCLPositionLib.resetLpFeeAccounting(pool, _range);

        emit EmergencyExited(_ethToSend);
    }

    // ============ Uniswap Callback ============

    function uniswapV3MintCallback(uint256 _amount0, uint256 _amount1, bytes calldata) external {
        if (msg.sender != address(pool)) revert UniCLStratCallerNotPool();
        if (!_range.minting) revert UniCLStratInvalidMintCallback();

        if (_amount0 > 0) token0.safeTransfer(address(pool), _amount0);
        if (_amount1 > 0) token1.safeTransfer(address(pool), _amount1);

        _range.minting = false;
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
        AeroCLPositionLib.removeAllLiquidity(pool, _range);
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

    /// @dev Slipstream `slot0` has 6 fields (no `feeProtocol`); decoding it through
    ///      `IUniswapV3Pool` would revert. See {AeroCLPositionLib-slot0}.
    function _currentTick() internal view returns (int24) {
        return AeroCLPositionLib.currentTick(pool);
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
    ///      Same gate as `UniCLStratLib.requireTwapOracle`, inlined because that helper decodes
    ///      the 7-field Uniswap `slot0`.
    function _requireTwapOracle(uint32 _interval) internal view {
        (bool _available,) = _observeTwap(_interval);
        if (!_available) revert UniCLStratPoolTWAPNotAvailable();

        uint256 _required = (uint256(_interval) + MAX_BLOCK_SECONDS - 1) / MAX_BLOCK_SECONDS;
        if (_required < MIN_OBSERVATION_CARDINALITY) _required = MIN_OBSERVATION_CARDINALITY;
        // The ring is uint16; callers reject `> MAX_TWAP_INTERVAL` first, so this cannot overflow.
        (,, uint16 _cardinality) = AeroCLPositionLib.slot0(pool);
        if (_cardinality < _required) {
            revert UniCLStratInsufficientObservationCardinality(_cardinality, uint16(_required));
        }
    }

    /// @dev Shared with the UniswapV3ConverterAdapter via {TickUtils.tryMeanTick};
    ///      rounds toward negative infinity, matching Uniswap's OracleLibrary.
    function _observeTwap(uint32 _interval) internal view returns (bool _success, int56 _twapTick) {
        (bool _ok, int24 _meanTick) = TickUtils.tryMeanTick(pool, _interval);
        return (_ok, _meanTick);
    }

    // ============ Internal Liquidity ============

    /// @dev Deploys idle inventory via {AeroCLRangeLib-deployInventory}. Callers must ensure the
    ///      pool is calm (minting paths) — `pool.mint` has no price bound of its own.
    function _deployInventory(AeroCLRangeLib.RangeContext memory _ctx, bool _allowSwap) internal {
        if (paused()) return;
        AeroCLRangeLib.deployInventory(_ctx, _range, _allowSwap);
    }

    function _rangeContext() internal view returns (AeroCLRangeLib.RangeContext memory) {
        return AeroCLRangeLib.RangeContext({
            pool: pool,
            token0: address(token0),
            token1: address(token1),
            tickSpacing: tickSpacing,
            positionWidth: positionWidth,
            rebalanceTickThreshold: rebalanceTickThreshold,
            twapInterval: twapInterval,
            swap: _swapConfig(),
            wethToPairedTokenPath: wethToPairedTokenPath,
            pairedTokenToWethPath: pairedTokenToWethPath
        });
    }

    // ============ Internal Accounting ============

    function _unchargedLpFeesInETH() internal view returns (uint256) {
        (uint256 _uncharged0, uint256 _uncharged1) = AeroCLPositionLib.unchargedLpFeeAmounts(pool, _range);
        return _pairValueInETH(_uncharged0, _uncharged1);
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
}
