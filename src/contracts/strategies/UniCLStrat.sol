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
    uint256 public constant SWAP_DEADLINE_OFFSET = 15 minutes;
    /// @dev Maximum deviation tolerated between an adapter quote and the Chainlink-implied
    ///      amount. NOTE: adapter quotes are net of the DEX pool fee while the Chainlink
    ///      amount is a gross mid-price, so the pool's fee tier consumes part of this
    ///      budget on the floor side. Units reminder — Uniswap V3 fees are in hundredths
    ///      of a bip (1e-6): tier 3000 = 0.3% = 30 bps, tier 10000 = 1% = 100 bps. So
    ///      200 bps supports fee tiers up to 1% (100 bps), leaving at least 100 bps of
    ///      genuine TWAP-vs-Chainlink drift allowance; route configs should prefer pools
    ///      with fee tiers <= 0.3% (30 bps, leaving 170 bps of drift allowance).
    uint256 public constant MAX_QUOTE_DEVIATION_BPS = 200;

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

    /// @dev Cumulative LP trading fees earned in native pool token amounts (lifetime).
    ///      Advanced by `_accrueLpFees` / `_tryAccrueLpFees` (settle / remove-collect /
    ///      emergency exit), not by `sync()`.
    uint256 private _cumulativeLpFeesEarned0;
    uint256 private _cumulativeLpFeesEarned1;
    /// @dev Cumulative LP fee token amounts already charged via `settlePerformanceFee`, or
    ///      written off on emergency exit (`charged = earned` in `_resetLpFeeAccounting`).
    uint256 private _cumulativeLpFeesCharged0;
    uint256 private _cumulativeLpFeesCharged1;
    /// @dev Snapshot of aggregate `tokensOwed` at the last accrue pass (per pool token).
    ///      Pending/settle include the live `tokensOwed - snapshot` delta without a sync flush.
    ///      `_tryGetLpFeesOwedAmounts` falls back to this when either `positions` read reverts.
    uint256 private _lpFeesOwedSnapshot0;
    uint256 private _lpFeesOwedSnapshot1;

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

    // ============ Strategy Views ============
    function navInETH() public view returns (uint256) {
        (uint256 _amount0, uint256 _amount1) = _balances();
        return address(this).balance + _tokenValueInETH(address(token0), _amount0)
            + _tokenValueInETH(address(token1), _amount1);
    }

    function maxDeposit() external view returns (uint256) {
        return _maxDeposit();
    }

    function maxWithdrawal() public view returns (uint256) {
        if (paused()) return 0;
        return navInETH();
    }

    function isHealthy() public view returns (bool) {
        if (paused()) return false;
        if (!_isCalm()) return false;
        if (!initTicks) return true;

        int24 _tick = _currentTick();
        if (_tick <= positionMain.tickLower || _tick >= positionMain.tickUpper) return false;

        int24 _centerTick = (positionMain.tickLower + positionMain.tickUpper) / 2;
        return _abs(_tick - _centerTick) <= _abs(rebalanceTickThreshold);
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

        _removeLiquidityAndCollect();

        _balanceInventory();
        _setTicksIfNeeded();
        _addLiquidity();

        emit FundsDeposited(_depositAmount);
    }

    /**
     * @notice Deploys idle native ETH (e.g. donations) into the underlying protocol.
     * @dev Callable only by strategy admin. Going through `_removeLiquidityAndCollect` pokes and
     *      accrues any pending LP fees into the performance-fee base (same as deposit/withdraw).
     *      The invested amount is capped at the remaining capacity (`maxDeposit()`). Return value
     *      and `FundsInvested` report only the idle native ETH actually deployed. Collected
     *      WETH/ETH from existing positions may also be re-deployed in this call but is excluded
     *      from `invested` and the event amount.
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
        _removeLiquidityAndCollect();
        _balanceInventory();
        _setTicksIfNeeded();
        _addLiquidity();

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
     *        remainder is sourced from WETH (liquidity removal plus paired-token conversion),
     *        of which exactly the needed amount is unwrapped. Native ETH is never wrapped
     *        just to be unwrapped again. Remaining WETH/paired inventory is rebalanced and
     *        re-added as liquidity only when the pool is calm. The unwind itself is
     *        intentionally not calm-gated: `navInETH()` marks at TWAP/oracle (a skewed
     *        burn does not crystallize IL into NAV), the conversion swap is independently
     *        bounded, and a calm revert would stall exit liquidity when redemptions spike.
     *        See `docs/STRATEGY_GUARDRAILS.md` §1.1.1.
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

            _removeLiquidityAndCollect();

            _convertToWeth(_remainder);

            uint256 _wethBalance = weth.balanceOf(address(this));
            uint256 _wethToUnwrap = _wethBalance < _remainder ? _wethBalance : _remainder;
            _withdrawn = _idleETH + _wethToUnwrap;
            if (_withdrawn == 0) revert UniCLStratInsufficientWETH();

            _totalWithdrawn += _withdrawn;

            // Unwrap only the WETH portion to this contract, then deliver idle ETH +
            // unwrapped remainder to the receiver in a single native transfer.
            if (_wethToUnwrap > 0) IConverter(_registry.converter()).unwrapWETH(_wethToUnwrap, address(this));
            payable(_receiver).sendValue(_withdrawn);

            if (_isCalm()) {
                _balanceInventory();
                _addLiquidity();
            }
        }

        emit FundsWithdrawn(_withdrawn);
    }

    function rebalance() external onlyAuthContract(Auth.STRATEGY_MANAGER) whenNotPaused nonReentrant {
        if (isHealthy()) revert StrategyIsHealthy();
        if (!_isCalm()) revert UniCLStratNotCalm();

        _removeLiquidityAndCollect();
        _balanceInventory();
        _setTicks();
        _addLiquidity();

        emit Rebalanced();
    }

    /**
     * @notice Refreshes on-chain state via the keeper path.
     * @dev Pokes Uniswap V3 positions with `burn(..., 0)` so accrued LP fees flow into
     *      `tokensOwed` (NAV and `pendingPerformanceFeeInETH` both read that storage). Does not
     *      call `_accrueLpFees()` — the pending view already includes the live
     *      `tokensOwed - snapshot` delta, and settle/remove accrue when they need durable
     *      counters. Does not remove liquidity or call `collect()`.
     */
    function sync() external onlyAuthContract(Auth.STRATEGY_MANAGER) whenNotPaused nonReentrant {
        _pokePositions();
        emit Synced();
    }

    /**
     * @inheritdoc IStrategy
     * @dev Over already-materialized `tokensOwed` plus stored counters (via the live
     *      `tokensOwed - snapshot` delta in `_unchargedLpFeeAmounts`). Unpoked fee growth is
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

        _accrueLpFees();
        (uint256 _uncharged0, uint256 _uncharged1) = _unchargedLpFeeAmounts();
        if (_uncharged0 == 0 && _uncharged1 == 0) return 0;

        uint256 _feeBaseETH =
            _tokenValueInETH(address(token0), _uncharged0) + _tokenValueInETH(address(token1), _uncharged1);
        feeETH = _feeBaseETH * _performanceFeeBps / BASIS_POINTS;
        // Dust base: floor-division to zero must not write off the uncharged amounts.
        if (feeETH == 0) return 0;

        _cumulativeLpFeesCharged0 = _cumulativeLpFeesEarned0;
        _cumulativeLpFeesCharged1 = _cumulativeLpFeesEarned1;
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
     *      already holds. The LP-fee accounting reset (see {_resetLpFeeAccounting}) best-effort
     *      accrues via {_tryAccrueLpFees} (snapshot fallback if `positions` reverts), so a
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

        // Paired-token `balanceOf` is best-effort: a paused/blacklisted token must not hostage
        // the ETH sweep. Parameterless catch — same returndata-bomb rationale as pause-time paths.
        try pairedToken.balanceOf(address(this)) returns (uint256 _pairedBalance) {
            if (_pairedBalance > 0) {
                // trySafeTransfer (not try/catch on transfer): empty returndata from USDT-style
                // tokens cannot be ABI-decoded as `bool` and would revert outside catch scope,
                // hostaging the ETH sweep. OZ treats empty returndata + code as success.
                if (!pairedToken.trySafeTransfer(strategyManagerAddress, _pairedBalance)) {
                    emit PairedTokenTransferSkipped();
                }
            }
        } catch {
            emit PairedTokenTransferSkipped();
        }

        _resetLpFeeAccounting();

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
        IConverter converter = IConverter(_registry.converter());

        if (_swapAdapter == address(0)) revert UniCLStratInvalidRouteConfig();
        if (_swapAdapter.code.length == 0) revert UniCLStratInvalidRouteConfig();
        if (!converter.validateRoute(_swapAdapter, _wethToPairedTokenPath)) revert UniCLStratInvalidRouteConfig();
        if (!converter.validateRoute(_swapAdapter, _pairedTokenToWethPath)) revert UniCLStratInvalidRouteConfig();

        (address _tokenIn, address _tokenOut) = converter.routeTokens(_swapAdapter, _wethToPairedTokenPath);
        if (_tokenIn != address(weth) || _tokenOut != address(pairedToken)) {
            revert UniCLStratInvalidRouteConfig();
        }

        (_tokenIn, _tokenOut) = converter.routeTokens(_swapAdapter, _pairedTokenToWethPath);
        if (_tokenIn != address(pairedToken) || _tokenOut != address(weth)) {
            revert UniCLStratInvalidRouteConfig();
        }
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

    function _balances() private view returns (uint256 _amount0, uint256 _amount1) {
        (uint256 _poolAmount0, uint256 _poolAmount1) = _balancesOfPool();
        _amount0 = token0.balanceOf(address(this)) + _poolAmount0;
        _amount1 = token1.balanceOf(address(this)) + _poolAmount1;
    }

    function _balancesOfPool() private view returns (uint256 _amount0, uint256 _amount1) {
        uint160 _sqrtPriceX96 = _twapSqrtPrice();
        (uint256 _mainAmount0, uint256 _mainAmount1) = _amountsForPosition(positionMain, _sqrtPriceX96);
        (uint256 _altAmount0, uint256 _altAmount1) = _amountsForPosition(positionAlt, _sqrtPriceX96);
        _amount0 = _mainAmount0 + _altAmount0;
        _amount1 = _mainAmount1 + _altAmount1;
    }

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
        _requireTwapAvailable(_interval);
        _requireObservationCardinality(_interval);
    }

    /// @dev `pool.observe([interval, 0])` must succeed for the configured window.
    function _requireTwapAvailable(uint32 _interval) internal view {
        (bool _available,) = _observeTwap(_interval);
        if (!_available) revert UniCLStratPoolTWAPNotAvailable();
    }

    /// @dev In-use ring length (`slot0.observationCardinality`, not Next) must cover
    ///      `ceil(_interval / MAX_BLOCK_SECONDS)` slots, floored at
    ///      {MIN_OBSERVATION_CARDINALITY}. Rejects the quiet cardinality-1 pool that
    ///      still serves `observe` by extrapolating with the current tick.
    function _requireObservationCardinality(uint32 _interval) internal view {
        (,,, uint16 _cardinality,,,) = pool.slot0();
        uint16 _required = _requiredObservationCardinality(_interval);
        if (_cardinality < _required) {
            revert UniCLStratInsufficientObservationCardinality(_cardinality, _required);
        }
    }

    function _requiredObservationCardinality(uint32 _interval) internal pure returns (uint16) {
        uint256 _required = (uint256(_interval) + MAX_BLOCK_SECONDS - 1) / MAX_BLOCK_SECONDS;
        if (_required < MIN_OBSERVATION_CARDINALITY) _required = MIN_OBSERVATION_CARDINALITY;
        // Uniswap's ring is uint16; a window that needs more slots cannot be densely
        // served by any V3 pool. Callers must reject `> MAX_TWAP_INTERVAL` first.
        if (_required > type(uint16).max) revert UniCLStratInvalidConfig();
        return uint16(_required);
    }

    /// @dev Shared with the UniswapV3ConverterAdapter via {TickUtils.tryMeanTick};
    ///      rounds toward negative infinity, matching Uniswap's OracleLibrary.
    function _observeTwap(uint32 _interval) internal view returns (bool _success, int56 _twapTick) {
        (bool _ok, int24 _meanTick) = TickUtils.tryMeanTick(pool, _interval);
        return (_ok, _meanTick);
    }

    // ============ Internal Liquidity ============

    function _addLiquidity() internal {
        if (!initTicks || paused()) return;

        _mintPosition(positionMain);
        _mintPosition(positionAlt);
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

    function _removeLiquidityAndCollect() internal {
        // Poke before accruing so fee growth since the last update is folded into
        // `tokensOwed`. Accrue before collect so the delta is locked into
        // `_cumulativeLpFeesEarned*` before owed is zeroed (the pending view's live
        // delta would otherwise be lost). Accruing after a full burn would also pick
        // up withdrawn principal briefly sitting in `tokensOwed` and inflate the fee base.
        _pokePositions();
        _accrueLpFees();
        _removePosition(positionMain);
        _removePosition(positionAlt);
        _lpFeesOwedSnapshot0 = 0;
        _lpFeesOwedSnapshot1 = 0;
    }

    function _pokePositions() internal {
        _pokePosition(positionMain);
        _pokePosition(positionAlt);
    }

    function _pokePosition(Position memory _position) internal {
        if (!_positionIsValid(_position)) return;

        (uint128 _liquidity,,,,) = pool.positions(_positionKey(_position));
        if (_liquidity > 0) {
            pool.burn(_position.tickLower, _position.tickUpper, 0);
        }
    }

    function _removePosition(Position memory _position) internal {
        if (!_positionIsValid(_position)) return;

        (uint128 _liquidity,,,,) = pool.positions(_positionKey(_position));
        if (_liquidity > 0) {
            pool.burn(_position.tickLower, _position.tickUpper, _liquidity);
        }

        pool.collect(address(this), _position.tickLower, _position.tickUpper, type(uint128).max, type(uint128).max);
    }

    function _setTicksIfNeeded() internal {
        if (!initTicks) _setTicks();
    }

    function _setTicks() internal {
        int24 _tick = _currentTick();
        int24 _width = positionWidth * tickSpacing;

        (positionMain.tickLower, positionMain.tickUpper) = TickUtils.baseTicks(_tick, _width, tickSpacing);
        _setAltTicks(_tick, _width);
        initTicks = true;
    }

    function _setAltTicks(int24 _tick, int24 _width) internal {
        int24 _tickFloor = TickUtils.floor(_tick, tickSpacing);
        (uint256 _balance0, uint256 _balance1) = (token0.balanceOf(address(this)), token1.balanceOf(address(this)));
        uint256 _value0 = _tokenValueInETH(address(token0), _balance0);
        uint256 _value1 = _tokenValueInETH(address(token1), _balance1);

        if (_value0 < _value1) {
            positionAlt.tickLower = _tickFloor - _width;
            positionAlt.tickUpper = _tickFloor - tickSpacing;
        } else if (_value1 < _value0) {
            positionAlt.tickLower = _tickFloor + tickSpacing;
            positionAlt.tickUpper = _tickFloor + _width;
        } else {
            positionAlt.tickLower = 0;
            positionAlt.tickUpper = 0;
        }
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

    function _amountsForPosition(Position memory _position, uint160 _sqrtPriceX96)
        internal
        view
        returns (uint256 _amount0, uint256 _amount1)
    {
        if (!_positionIsValid(_position)) return (0, 0);

        (uint128 _liquidity,,, uint128 _owed0, uint128 _owed1) = pool.positions(_positionKey(_position));
        if (_liquidity > 0) {
            (_amount0, _amount1) = _amountsForLiquidityAtSqrtPrice(_position, _liquidity, _sqrtPriceX96);
        }

        _amount0 += _owed0;
        _amount1 += _owed1;
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
        (uint256 _uncharged0, uint256 _uncharged1) = _unchargedLpFeeAmounts();
        return _tokenValueInETH(address(token0), _uncharged0) + _tokenValueInETH(address(token1), _uncharged1);
    }

    function _unchargedLpFeeAmounts() internal view returns (uint256 uncharged0, uint256 uncharged1) {
        (uint256 _current0, uint256 _current1) = _lpFeesOwedAmounts();

        // Live delta: pending/settle can see fees materialized since the last `_accrueLpFees`
        // without requiring sync to flush counters (sync is poke-only).
        uint256 _earned0 = _cumulativeLpFeesEarned0;
        uint256 _earned1 = _cumulativeLpFeesEarned1;
        if (_current0 > _lpFeesOwedSnapshot0) {
            _earned0 += _current0 - _lpFeesOwedSnapshot0;
        }
        if (_current1 > _lpFeesOwedSnapshot1) {
            _earned1 += _current1 - _lpFeesOwedSnapshot1;
        }

        uncharged0 = _earned0 - _cumulativeLpFeesCharged0;
        uncharged1 = _earned1 - _cumulativeLpFeesCharged1;
    }

    /// @dev Flushes `tokensOwed - snapshot` into `_cumulativeLpFeesEarned*` and advances the
    ///      snapshot. Required before collect (or the live delta is lost when owed → 0) and
    ///      before settle charges. Not used by `sync()` — poke alone is enough for NAV/pending.
    function _accrueLpFees() internal {
        (uint256 _current0, uint256 _current1) = _lpFeesOwedAmounts();
        _accrueLpFeesFrom(_current0, _current1);
    }

    /// @dev Best-effort accrue for emergency paths. Uses {_tryGetLpFeesOwedAmounts}: on a
    ///      degraded pool the current amounts fall back to the snapshot, so this is a no-op
    ///      on earned/snapshot and cannot revert.
    function _tryAccrueLpFees() internal {
        (uint256 _current0, uint256 _current1) = _tryGetLpFeesOwedAmounts();
        _accrueLpFeesFrom(_current0, _current1);
    }

    function _accrueLpFeesFrom(uint256 _current0, uint256 _current1) internal {
        if (_current0 > _lpFeesOwedSnapshot0) {
            _cumulativeLpFeesEarned0 += _current0 - _lpFeesOwedSnapshot0;
        }
        if (_current1 > _lpFeesOwedSnapshot1) {
            _cumulativeLpFeesEarned1 += _current1 - _lpFeesOwedSnapshot1;
        }
        _lpFeesOwedSnapshot0 = _current0;
        _lpFeesOwedSnapshot1 = _current1;
    }

    /// @dev Writes off pending LP fees after emergency exit so that only fee growth after
    ///      the reset is feeable. Best-effort accrues (snapshot fallback if `positions`
    ///      reverts), then aligns charged to earned — the same pattern as
    ///      `settlePerformanceFee`. In-pool fees at reset time (including fees already
    ///      charged via settle, which leaves tokens in-pool) become wind-down value and are
    ///      never charged again on resume. Zeroing the counters instead would let the
    ///      `tokensOwed - snapshot(0)` delta re-accrue already-charged fees as freshly
    ///      earned, double-charging them at the next settle. When the pool is degraded the
    ///      snapshot fallback makes accrue a no-op; charged = earned still clears counter
    ///      pending, while any unread live growth above the snapshot stays feeable on resume.
    function _resetLpFeeAccounting() internal {
        _tryAccrueLpFees();
        _cumulativeLpFeesCharged0 = _cumulativeLpFeesEarned0;
        _cumulativeLpFeesCharged1 = _cumulativeLpFeesEarned1;
    }

    /// @dev Fail-closed aggregate `tokensOwed` across both positions. Used by NAV/pending/
    ///      normal accrue paths where a degraded pool should revert.
    function _lpFeesOwedAmounts() internal view returns (uint256 amount0, uint256 amount1) {
        (,,, uint128 _mainOwed0, uint128 _mainOwed1) = pool.positions(_positionKey(positionMain));
        (,,, uint128 _altOwed0, uint128 _altOwed1) = pool.positions(_positionKey(positionAlt));

        amount0 = uint256(_mainOwed0) + uint256(_altOwed0);
        amount1 = uint256(_mainOwed1) + uint256(_altOwed1);
    }

    /// @dev Best-effort aggregate `tokensOwed`. If either `positions` read reverts, falls
    ///      back to the last aggregate snapshot (all-or-nothing — the snapshot is not
    ///      per-position, so mixing a live leg with the aggregate snapshot is unsafe).
    function _tryGetLpFeesOwedAmounts() internal view returns (uint256 amount0, uint256 amount1) {
        // NOTE: parameterless catches mirror `_pauseStrategy` — binding the revert data
        // would copy unbounded returndata into memory from a degraded pool.
        try pool.positions(_positionKey(positionMain)) returns (
            uint128, uint256, uint256, uint128 _main0, uint128 _main1
        ) {
            try pool.positions(_positionKey(positionAlt)) returns (
                uint128, uint256, uint256, uint128 _alt0, uint128 _alt1
            ) {
                return (uint256(_main0) + uint256(_alt0), uint256(_main1) + uint256(_alt1));
            } catch {}
        } catch {}

        return (_lpFeesOwedSnapshot0, _lpFeesOwedSnapshot1);
    }

    function _balanceInventory() internal {
        uint256 _wethBalance = weth.balanceOf(address(this));
        uint256 _pairedBalance = pairedToken.balanceOf(address(this));
        uint256 _wethValue = _tokenValueInETH(address(weth), _wethBalance);
        uint256 _pairedValue = _tokenValueInETH(address(pairedToken), _pairedBalance);

        if (_wethValue > _pairedValue) {
            uint256 _excessWethValue = (_wethValue - _pairedValue) / 2;
            if (_excessWethValue > 0) {
                _swapWethToPairedToken(_excessWethValue);
            }
        } else if (_pairedValue > _wethValue) {
            uint256 _excessPairedValue = (_pairedValue - _wethValue) / 2;
            if (_excessPairedValue > 0) {
                _swapPairedTokenToWeth(_ethValueToTokenAmount(address(pairedToken), _excessPairedValue));
            }
        }
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

    /**
     * @notice Swaps `_amountIn` along `_path` via the shared Converter, using an on-chain
     *         quote as the base for slippage protection.
     *
     * @dev ── Security model for the on-chain quote ──────────────────────────────────
     *      _swapViaRouteExactAmountIn derives `_minAmountOut` from `converter.quoteSwapExactAmountIn()`. The quote
     *      and the swap execute ATOMICALLY in the same transaction (same block, same
     *      `block.timestamp`), so the quote-then-swap pattern on its own provides no
     *      protection against same-block pool manipulation: an attacker who can move the
     *      quote source before this transaction executes (a flash loan in the same block,
     *      or a miner/builder ordering attack) moves the derived `_minAmountOut` along
     *      with the execution price. The layers below are what make the pattern safe,
     *      NOT the quote itself:
     *
     *      0. **TWAP-based quote source**: the UniswapV3ConverterAdapter prices off the
     *         pool TWAP cross-checked against Chainlink — neither input is movable within
     *         a single block, so a same-block manipulation cannot drag the quote (and
     *         hence `_minAmountOut`) toward a manipulated execution price. Other adapters
     *         may quote from spot pool state, which is why the strategy keeps its own
     *         adapter-agnostic defence layers (1–3 below).
     *
     *      1. **Calm-period guard** (`_isCalm`): a *caller-path* check, not
     *         enforced in this helper. Minting callers (`deposit` /
     *         `investIdleETH` / `rebalance`, and the re-add branch of
     *         `withdraw`) require calm before inventory swaps. `withdraw` →
     *         `_convertToWeth` reaches this helper while the pool may be
     *         dislocated; layers 0, 2, and 3 carry that path. Rationale:
     *         `docs/STRATEGY_GUARDRAILS.md` §1.1.1.
     *
     *      2. **Slippage cap** (`MAX_SWAP_SLIPPAGE_BPS = 200`): even against a
     *         manipulated quote, the minimum output floor caps the loss at 2 % of the
     *         quoted amount.
     *
     *      3. **Oracle bounds** (`MAX_QUOTE_DEVIATION_BPS = 200`): the quoted amount is
     *         cross-referenced against an independent price source (Chainlink) to detect
     *         quote manipulation in any swap pool (not just the strategy pool).  Both an
     *         upper and a lower bound are enforced symmetrically — a quote below the floor
     *         or above the ceiling reverts.  This layer does not rely on pool state and
     *         is enforced here even when the adapter performs its own oracle cross-check.
     *
     *      ── Fee interaction with the oracle bounds ──────────────────────────────────────
     *      Adapter quotes are net of the DEX pool fee, while the Chainlink reference is a
     *      gross mid-price. Even with TWAP and Chainlink perfectly aligned, the quote sits
     *      `fee tier` bps below the oracle amount, consuming part of the floor budget.
     *      MAX_QUOTE_DEVIATION_BPS (200) therefore must exceed the route's fee tier — see
     *      the constant's documentation.
     *     ────────────────────────────────────────────────────────────────────────────
     *
     *      A per-swap deadline (`block.timestamp + SWAP_DEADLINE_OFFSET`) is forwarded to
     *      the Converter/router, but it is NOT a defence layer: it is computed from
     *      `block.timestamp` at execution time, so it can never expire within this
     *      transaction. It only satisfies the router interface.
     */
    function _swapViaRouteExactAmountIn(bytes memory _path, uint256 _amountIn) internal returns (uint256 _amountOut) {
        if (_amountIn == 0) return 0;

        IConverter _converter = IConverter(_registry.converter());

        uint256 _quotedAmount;
        try _converter.quoteSwapExactAmountIn(swapAdapter, _path, _amountIn) returns (uint256 _result) {
            _quotedAmount = _result;
        } catch {
            revert UniCLStratQuoteFailed();
        }

        // Oracle sanity bounds: reject quotes that deviate too far from the
        // Chainlink mid-price in either direction. Both floors and ceilings catch
        // flash-loan-assisted manipulation of the quote pool (which may be a different
        // fee tier than the strategy pool).
        uint256 _oracleAmountOut = _calculateOracleAmountOut(_converter, _path, _amountIn);
        _enforceOracleBounds(_quotedAmount, _oracleAmountOut);

        uint256 _minAmountOut = _quotedAmount * (BASIS_POINTS - swapSlippageBps) / BASIS_POINTS;

        _amountOut = _converter.executeSwapExactAmountIn(
            swapAdapter, _path, _amountIn, _minAmountOut, block.timestamp + SWAP_DEADLINE_OFFSET
        );
    }

    /**
     * @notice Reverts when a DEX-quoted amount deviates from the oracle-implied amount by more
     *         than `MAX_QUOTE_DEVIATION_BPS` in either direction.
     * @dev Shared by both swap directions. For exact-input swaps `_quoted`/`_oracleAmount` are
     *      output amounts; for exact-output swaps they are input amounts. The symmetric
     *      floor/ceiling band is direction-agnostic, so a single helper serves both. Reverts
     *      with {UniCLStratQuoteBelowOracleFloor} or {UniCLStratQuoteExceedsOracleCeiling}.
     * @param _quoted The amount returned by the DEX adapter quote
     * @param _oracleAmount The independent oracle-implied amount to bound against
     */
    function _enforceOracleBounds(uint256 _quoted, uint256 _oracleAmount) internal pure {
        uint256 _oracleFloor = _oracleAmount * (BASIS_POINTS - MAX_QUOTE_DEVIATION_BPS) / BASIS_POINTS;
        uint256 _oracleCeiling = _oracleAmount * (BASIS_POINTS + MAX_QUOTE_DEVIATION_BPS) / BASIS_POINTS;
        if (_quoted < _oracleFloor) {
            revert UniCLStratQuoteBelowOracleFloor(_quoted, _oracleAmount);
        }
        if (_quoted > _oracleCeiling) {
            revert UniCLStratQuoteExceedsOracleCeiling(_quoted, _oracleAmount);
        }
    }

    /**
     * @notice Computes the fair expected swap output using the protocol oracle (Chainlink)
     *         as an independent price source, decoupled from any DEX pool state.
     * @dev Decodes the output token from the DEX route path and derives the oracle-based
     *      expected amount via the protocol's ETH/USD and token/USD price feeds.
     *      The path encoding is adapter-specific; this function extracts the last 20 bytes
     *      which, for Uniswap V3 packed encoding, is always the final output token.
     * @param _converter The resolved Converter instance (passed by caller to avoid duplicate lookups)
     * @param _path Adapter-specific route bytes
     * @param _amountIn The input amount for the swap
     * @return _oracleAmountOut The oracle-based fair output amount in token decimals
     */
    function _calculateOracleAmountOut(IConverter _converter, bytes memory _path, uint256 _amountIn)
        internal
        view
        returns (uint256 _oracleAmountOut)
    {
        // Decode the output token using the adapter-agnostic helper rather than
        // assuming a specific path encoding (Uniswap V3 packed, etc.).  This keeps
        // the oracle ceiling correct even if setRouteConfig is called with a
        // non-Uniswap adapter (Curve, Balancer, etc.).
        (, address _outToken) = _converter.routeTokens(swapAdapter, _path);

        if (_outToken == address(weth)) {
            // pairedToken -> WETH: compute pairedToken value in ETH using oracle
            return _tokenValueInETH(address(pairedToken), _amountIn);
        } else {
            // WETH -> pairedToken: compute WETH value in pairedToken using oracle
            return _ethValueToTokenAmount(_outToken, _amountIn);
        }
    }

    /**
     * @notice Swaps along `_path` for exactly `_amountOut` of the output token via the
     *         shared Converter, with an oracle-bounded, slippage-padded input cap.
     *
     * @dev Symmetric counterpart of {_swapViaRouteExactAmountIn} — the same
     *      in-helper security model applies (TWAP-based quote, slippage cap,
     *      oracle bounds), mirrored onto the input side: the quoted required
     *      input is checked against the Chainlink-implied input, and the
     *      slippage tolerance pads the input MAXIMUM instead of flooring the
     *      output minimum. The calm-period guard is a caller-path check, not
     *      enforced here; {_convertToWeth} (withdraw) is the intended non-calm
     *      caller.
     *
     *      Balance-cap fallback: if the slippage-padded maximum input exceeds the
     *      strategy's balance of the input token, the exact output is unaffordable.
     *      Instead of reverting, the function falls back to a best-effort exact-input
     *      swap of the whole input-token balance — the same "cap the input at the
     *      available balance" pattern used by {_swapWethToPairedToken} and
     *      {_swapPairedTokenToWeth}.
     *
     * @param _path Adapter-specific route bytes (forward encoding, same as exact-input)
     * @param _amountOut The exact output amount desired
     * @return _amountIn The input amount actually spent
     */
    function _swapViaRouteExactAmountOut(bytes memory _path, uint256 _amountOut) internal returns (uint256 _amountIn) {
        if (_amountOut == 0) return 0;

        IConverter _converter = IConverter(_registry.converter());

        uint256 _quotedAmountIn;
        try _converter.quoteSwapExactAmountOut(swapAdapter, _path, _amountOut) returns (uint256 _result) {
            _quotedAmountIn = _result;
        } catch {
            revert UniCLStratQuoteFailed();
        }

        // Oracle sanity bounds on the required input (mirror of _swapViaRouteExactAmountIn's output
        // bounds): a quote demanding too much input (above the ceiling) overprices the
        // swap; one demanding too little (below the floor) signals a manipulated quote.
        uint256 _oracleAmountIn = _calculateOracleAmountIn(_converter, _path, _amountOut);
        _enforceOracleBounds(_quotedAmountIn, _oracleAmountIn);

        uint256 _maxAmountIn = _quotedAmountIn * (BASIS_POINTS + swapSlippageBps) / BASIS_POINTS;

        (address _inToken,) = _converter.routeTokens(swapAdapter, _path);
        uint256 _inBalance = IERC20Metadata(_inToken).balanceOf(address(this));

        // Balance-cap fallback: the exact output is unaffordable — swap the whole
        // input-token balance best-effort via the exact-input path instead.
        if (_maxAmountIn > _inBalance) {
            _swapViaRouteExactAmountIn(_path, _inBalance);
            return _inBalance;
        }

        return _converter.executeSwapExactAmountOut(
            swapAdapter, _path, _amountOut, _maxAmountIn, block.timestamp + SWAP_DEADLINE_OFFSET
        );
    }

    /**
     * @notice Computes the fair required swap input for an exact output using the protocol
     *         oracle (Chainlink) as an independent price source.
     * @dev Input-side mirror of {_calculateOracleAmountOut}: decodes the input token from the
     *      route via the adapter-agnostic helper and converts the desired output amount
     *      into input-token terms through the oracle cross-rate.
     * @param _converter The resolved Converter instance (passed by caller to avoid duplicate lookups)
     * @param _path Adapter-specific route bytes
     * @param _amountOut The desired output amount of the swap
     * @return _oracleAmountIn The oracle-based fair input amount in token decimals
     */
    function _calculateOracleAmountIn(IConverter _converter, bytes memory _path, uint256 _amountOut)
        internal
        view
        returns (uint256 _oracleAmountIn)
    {
        (address _inToken,) = _converter.routeTokens(swapAdapter, _path);

        if (_inToken == address(weth)) {
            // WETH -> pairedToken: required WETH input equals the ETH value of the output
            return _tokenValueInETH(address(pairedToken), _amountOut);
        } else {
            // pairedToken -> WETH: required pairedToken input for the ETH-denominated output
            return _ethValueToTokenAmount(_inToken, _amountOut);
        }
    }

    function _tokenValueInETH(address _token, uint256 _amount) internal view returns (uint256) {
        if (_amount == 0) return 0;
        if (_token == address(weth)) return _amount;

        // Direct token -> ETH cross-rate (single rounding step, both feeds staleness-checked).
        return IOracle(_registry.oracle()).convert(_token, address(0), _amount, IERC20Metadata(_token).decimals(), 18);
    }

    function _ethValueToTokenAmount(address _token, uint256 _ethAmount) internal view returns (uint256) {
        if (_ethAmount == 0) return 0;
        if (_token == address(weth)) return _ethAmount;

        // Direct ETH -> token cross-rate (single rounding step, both feeds staleness-checked).
        return
            IOracle(_registry.oracle()).convert(address(0), _token, _ethAmount, 18, IERC20Metadata(_token).decimals());
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
