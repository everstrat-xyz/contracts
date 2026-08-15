// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {RegistryClient} from "registry/client/RegistryClient.sol";

import {Auth} from "../libraries/Auth.sol";
import {Math} from "../libraries/Math.sol";

import {IAMM} from "../interfaces/IAMM.sol";
import {IRegistry} from "interfaces/IRegistry.sol";

import {EVE} from "./EVE.sol";
import {Oracle} from "./Oracle.sol";
import {StrategyManager} from "./StrategyManager.sol";
import {ExitQueue} from "./ExitQueue.sol";
import {Whitelist} from "./Whitelist.sol";

contract AMM is IAMM, RegistryClient, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address payable;

    using Auth for IRegistry;

    // ============ Constants ============

    /// @notice The admin role identifier (authority on Registry)
    bytes32 public constant ADMIN_ROLE = Auth.ADMIN_ROLE;

    /**
     * @notice Amount of tokens that will be forever locked after the
     * initial mint.
     */
    uint256 private constant _DEAD_SUPPLY = 1e18;

    /**
     * @notice Minimum initial deposit for the first minter (in normalized
     * form, i.e. with 18 decimals).
     */
    uint256 public constant MIN_INITIAL_DEPOSIT_USD = 1000e18;

    /**
     * @notice Default minimum ETH for batch (queued) exit.
     */
    uint256 public constant DEFAULT_MIN_BATCH_EXIT_ETH = 1e15;

    /**
     * @notice Upper bound for minimum ETH required for batch (queued) exit.
     */
    uint256 public constant MIN_BATCH_EXIT_ETH_UPPER_BOUND = 5e16; // 0.05 ETH

    // ============ Storage Variables ============

    /**
     * @notice Amount of ETH that is locked for claims.
     */
    uint256 public lockedForClaims;

    /**
     * @dev Connector weight of a bonding curve.
     *
     * As CW in math formulas must belong to the range (0; 1],
     * values in Solidity will be taken from the range (0; 1e18],
     * i.e. (0; Math.SCALE_FACTOR], to denote the same span (e.g., 5e17 represents 0.5).
     */
    uint256 public connectorWeight;

    /**
     * @notice Minimum ETH required to queue a batch exit. Immediate exit is unrestricted.
     */
    uint256 public minBatchExitETH;

    // bool variables (packed together)
    /**
     * @notice Shows if the initial mint was performed and dead supply was locked.
     * @dev Users can check if there's liquidity in the pool by querying this or checking EVE supply > 0
     */
    bool public bootstrapped;

    /**
     * @notice Mapping from user to claimable ETH amount for implementing
     * pull-over-push pattern.
     */
    mapping(address user => uint256) public claimableBalances;

    // ============ Constructor ============

    /**
     * @notice Constructor for the bonding curve contract.
     * @param _registry Address of the protocol Registry (role authority and contract addresses).
     * @param _cw Initial connector weight value.
     */
    constructor(address _registry, uint256 _cw) RegistryClient(_registry) {
        _setConnectorWeight(_cw);
        _setMinBatchExitETH(DEFAULT_MIN_BATCH_EXIT_ETH);
    }

    // ============ receive() Function ============

    /**
     * @notice Used to receive ETH which will be used for immediate redemptions
     */
    receive() external payable {}

    // ============ User Functions ============

    /**
     * @inheritdoc IAMM
     */
    function enter(uint256 _minTokensToMint) external payable whenNotPaused nonReentrant {
        if (!_isWhitelisted(msg.sender)) revert AMMNotWhitelisted(msg.sender);

        _enter(_minTokensToMint);
    }

    /**
     * @inheritdoc IAMM
     */
    function enterWithInvite(uint256 _minTokensToMint, bytes32 _inviteId, uint256 _deadline, bytes calldata _signature)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        Whitelist(_registry.whitelist()).whitelist(msg.sender, _inviteId, _deadline, _signature);

        _enter(_minTokensToMint);
    }

    /**
     * @inheritdoc IAMM
     */
    function exit(uint256 _requestedETH, uint256 _maxTokensToBurn, uint256 _priceTolerance)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 batchId)
    {
        if (_requestedETH == 0) revert AMMZeroETHRequested();
        if (_maxTokensToBurn == 0) revert AMMZeroTokensToBurnAmount();

        if (_priceTolerance > Math.SCALE_FACTOR) revert AMMInvalidRange();

        EVE eve = EVE(_registry.eve());

        uint256 totalSupply = eve.totalSupply();
        uint256 nav = _navInETH();

        // Burning settles at the base (NAV) price, so EVE is always redeemed against
        // the assets backing it. Live supply excludes in-window priced escrow (NAV is
        // already net of that liability via StrategyManager).
        uint256 basePrice = _basePriceFromNAV(nav, _liveSupply(totalSupply));

        uint256 evePrice = basePrice;

        uint256 tokensToBurn = _ethToProtocolTokens(_requestedETH, evePrice);
        if (tokensToBurn == 0) revert AMMTooLowETHRequested();
        if (_maxTokensToBurn < tokensToBurn) revert AMMTooMuchETHRequested();

        // Re-calculating actual amount of ETH to redeem to avoid sending collateral more than worth of the burned tokens
        uint256 ethToRedeem = _calculateETHToTransfer(tokensToBurn, evePrice);
        address payable redeemer = payable(msg.sender);

        if (_freeBalance() >= ethToRedeem) {
            eve.burnFrom(msg.sender, tokensToBurn);
            redeemer.sendValue(ethToRedeem);

            emit RedeemedImmediately(redeemer, ethToRedeem, tokensToBurn, block.timestamp);
        } else {
            if (ethToRedeem < minBatchExitETH) revert AMMTooLowBatchExitETH();

            IERC20(address(eve)).safeTransferFrom(redeemer, address(this), tokensToBurn);

            batchId =
                ExitQueue(payable(_registry.exitQueue())).pushRequest(redeemer, evePrice, tokensToBurn, _priceTolerance);

            emit RedemptionQueued(redeemer, batchId, block.timestamp);
        }
    }

    /**
     * @inheritdoc IAMM
     */
    function cancelRedemption(uint256 _batchId) external nonReentrant {
        ExitQueue exitQueue = ExitQueue(_registry.exitQueue());
        (,,, uint256 tokensToBurn,) = exitQueue.requestInfo(_batchId, msg.sender);
        bool viaEscapeHatch = exitQueue.closeRequest(_batchId, msg.sender);
        IERC20(address(_registry.eve())).safeTransfer(msg.sender, tokensToBurn);
        emit RedemptionCancelled(msg.sender, _batchId, viaEscapeHatch, block.timestamp);
    }

    /**
     * @inheritdoc IAMM
     */
    function claim() external nonReentrant {
        uint256 claimableETH = claimableBalances[msg.sender];
        if (claimableETH == 0) revert AMMNoClaimableBalance();

        claimableBalances[msg.sender] = 0;
        lockedForClaims -= claimableETH;
        payable(msg.sender).sendValue(claimableETH);

        emit Claimed(msg.sender, claimableETH, block.timestamp);
    }

    // ============ Owner/Controller Functions ============

    /**
     * @inheritdoc IAMM
     */
    function processRedemption(uint256 _batchId, address _user)
        external
        payable
        onlyAuthContract(Auth.CONTROLLER)
        whenNotPaused
        nonReentrant
    {
        ExitQueue exitQueue = ExitQueue(_registry.exitQueue());
        EVE eve = EVE(_registry.eve());

        exitQueue.pullRequest(_batchId, _user);
        (, bool closedDueToSlippage,, uint256 tokensToBurn,) = exitQueue.requestInfo(_batchId, _user);

        uint256 ethToRedeem = 0;
        if (closedDueToSlippage) {
            IERC20(address(eve)).safeTransfer(_user, tokensToBurn);
        } else {
            eve.burn(tokensToBurn);

            (, uint256 evePrice,,,) = exitQueue.batchInfo(_batchId);

            ethToRedeem = _calculateETHToTransfer(tokensToBurn, evePrice);
            if (msg.value < ethToRedeem) revert AMMInsufficientSentETH();

            claimableBalances[_user] += ethToRedeem;
            lockedForClaims += ethToRedeem;
        }

        uint256 remaining = msg.value - ethToRedeem;
        if (remaining > 0) {
            payable(_registry.controller()).sendValue(remaining);
        }

        emit RedemptionProcessed(_user, _batchId, block.timestamp);
    }

    /**
     * @inheritdoc IAMM
     */
    function setConnectorWeight(uint256 _cw) external onlyAuthRole(Auth.ADMIN_ROLE) {
        _setConnectorWeight(_cw);
    }

    /**
     * @inheritdoc IAMM
     */
    function setMinBatchExitETH(uint256 _minBatchExitETH) external onlyAuthRole(Auth.ADMIN_ROLE) {
        _setMinBatchExitETH(_minBatchExitETH);
    }

    /**
     * @notice Pause the contract.
     */
    function pause() external onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract.
     */
    function unpause() external onlyAuthRole(Auth.ADMIN_ROLE) {
        _unpause();
    }

    // ============ Internal Functions ============

    /**
     * @notice Function to calculate amount ETH to transfer based on number of tokens and price.
     * @param _tokensAmount Number of protocol tokens.
     * @param _evePrice Price of the EVE token in ETH terms.
     * @return uint256 Amount of ETH to transfer.
     */
    function _calculateETHToTransfer(uint256 _tokensAmount, uint256 _evePrice) internal pure returns (uint256) {
        return Math.convertAssets(_tokensAmount, _evePrice);
    }

    /**
     * @dev Calculates the number of protocol tokens equivalent to the given ETH amount.
     * @param _ethAmount Amount of ETH to convert to protocol tokens.
     * @param _evePrice Price of the EVE token in ETH terms.
     * @return uint256 Number of protocol tokens equivalent to the given ETH amount.
     */
    function _ethToProtocolTokens(uint256 _ethAmount, uint256 _evePrice) internal pure returns (uint256) {
        return Math.convertAssetsInverse(_ethAmount, _evePrice);
    }

    /**
     * @dev Calculates the current EVE token base price in USD terms
     * @param _totalSupply Current total supply of the EVE token (normalized).
     * @return uint256 Current base price of EVE token in USD terms.
     */
    function _eveBasePriceInUSD(uint256 _totalSupply) internal view returns (uint256) {
        uint256 basePriceETH = _basePriceFromNAV(_navInETH(), _totalSupply);
        return Oracle(_registry.oracle()).convertTokenToUSD(address(0), basePriceETH, Math.DECIMALS_NORMALIZED);
    }

    /**
     * @dev Calculates the current EVE token premium price in USD terms
     * @param _totalSupply Current total supply of the EVE token (normalized).
     * @return uint256 Current premium price of EVE token in USD terms.
     */
    function _evePremiumPriceInUSD(uint256 _totalSupply) internal view returns (uint256) {
        uint256 premiumPriceETH = _premiumPriceFromNAV(_navInETH(), _totalSupply);
        return Oracle(_registry.oracle()).convertTokenToUSD(address(0), premiumPriceETH, Math.DECIMALS_NORMALIZED);
    }

    /**
     * @dev EVE base price in ETH terms from a pre-fetched NAV.
     * Formula: base_price = NAV_total / EVE_supply (NAV_total = strategy NAVs +
     * controller balance + AMM free balance). Callers pass the NAV explicitly so
     * flows that need several prices read NAV only once, and flows with an in-flight
     * deposit can pass {_navInETHPendingTransfer} instead of {_navInETH}.
     * @return uint256 Base price of EVE token in ETH terms (18 decimals).
     */
    function _basePriceFromNAV(uint256 _navTotal, uint256 _totalSupply) internal pure returns (uint256) {
        if (_totalSupply == 0) revert AMMZeroTotalSupply();

        return Math.basePrice(_navTotal, _totalSupply);
    }

    /**
     * @dev EVE premium price in ETH terms from a pre-fetched NAV.
     * Formula: premium_price = NAV_total / (EVE_supply * cw) (NAV_total = strategy
     * NAVs + controller balance + AMM free balance). Callers pass the NAV explicitly
     * so flows that need several prices read NAV only once, and flows with an in-flight
     * deposit can pass {_navInETHPendingTransfer} instead of {_navInETH}.
     * @return uint256 Premium price of EVE token in ETH terms (18 decimals).
     */
    function _premiumPriceFromNAV(uint256 _navTotal, uint256 _totalSupply) internal view returns (uint256) {
        if (_totalSupply == 0) revert AMMZeroTotalSupply();

        return Math.premiumPrice(_navTotal, _totalSupply, connectorWeight);
    }

    /**
     * @dev Calculates current NAV of the protocol in ETH terms with normalized
     * (i.e. 1e18) decimals. Does not adjust for any in-flight deposit; flows that
     * receive ETH which is not yet protocol-owned must use
     * {_navInETHPendingTransfer} instead. Locked claim ETH is excluded from NAV.
     * @return uint256 Current protocol NAV in ETH terms.
     */
    function _navInETH() internal view returns (uint256) {
        // If this reverts, the AMM is not registered or StrategyManager wiring is incomplete.
        return StrategyManager(payable(_registry.strategyManager())).totalNAVInETH();
    }

    /**
     * @dev NAV in ETH excluding `msg.value`, the caller's incoming deposit during
     * `enter()`. {totalNAVInETH} includes `amm.freeBalance()`, which already holds the
     * incoming ETH for the current call, but that deposit is not yet protocol-owned and
     * must not inflate the price the depositor pays — so it is subtracted here.
     * @return uint256 Protocol NAV in ETH terms with the pending deposit removed.
     */
    function _navInETHPendingTransfer() internal view returns (uint256) {
        // The invariant: totalNAVInETH() includes amm.freeBalance(), so subtraction is safe.
        uint256 nav = _navInETH();
        if (nav < msg.value) revert AMMNAVUnderflow();

        return nav - msg.value;
    }

    /**
     * @dev Calculates the free balance of the contract.
     * Free balance is the balance of the contract minus the locked amount for claims.
     * @return uint256 Free balance of the contract.
     */
    function _freeBalance() internal view returns (uint256) {
        return address(this).balance - lockedForClaims;
    }

    /**
     * @dev EVE supply participating in live share price: `totalSupply` minus in-window
     * priced escrow. Unpriced queued tokens stay in the denominator (cancellable equity).
     */
    function _liveSupply(uint256 _totalSupply) internal view returns (uint256) {
        (, uint256 escrowed) = ExitQueue(payable(_registry.exitQueue())).liveRedemptionOffsets();
        if (_totalSupply < escrowed) revert AMMEscrowExceedsSupply();
        return _totalSupply - escrowed;
    }

    /**
     * @dev Whether `_user` is whitelisted per the protocol Whitelist contract.
     */
    function _isWhitelisted(address _user) internal view returns (bool) {
        return Whitelist(_registry.whitelist()).isWhitelisted(_user);
    }

    /**
     * @dev Shared body of `enter()` and `enterWithInvite()`: both wrappers apply
     * `whenNotPaused`/`nonReentrant` and their own whitelist check before delegating here.
     * @param _minTokensToMint Minimum amount of tokens to mint.
     */
    function _enter(uint256 _minTokensToMint) internal {
        if (_minTokensToMint == 0) revert AMMInvalidTokensToMintAmount();

        EVE eve = EVE(_registry.eve());
        address controller = _registry.controller();

        if (!bootstrapped) {
            _bootstrap(_minTokensToMint, address(eve), controller);
            return;
        }

        uint256 totalSupply = eve.totalSupply();
        uint256 nav = _navInETHPendingTransfer();

        uint256 evePrice = _premiumPriceFromNAV(nav, _liveSupply(totalSupply));
        uint256 tokensToMint = _ethToProtocolTokens(msg.value, evePrice);
        if (tokensToMint < _minTokensToMint) revert AMMInsufficientDeposit();

        /* Not re-calculating received ETH here, since rounding is already favoring the protocol,
        and under the normal conditions re-calculation will actually cost user
        more ETH than they would get back.
        */
        payable(controller).sendValue(msg.value);

        eve.mint(msg.sender, tokensToMint);

        emit UserEntered(msg.sender, msg.value, tokensToMint, block.timestamp);
    }

    /**
     * @dev Bootstrap function for first deposit.
     * @param _minTokensToMint Minimum amount of protocol tokens.
     * @param eve Address of the EVE token.
     * @param controller Address of the controller.
     */
    function _bootstrap(uint256 _minTokensToMint, address eve, address controller) internal {
        uint256 deposit = msg.value;
        Oracle oracle = Oracle(_registry.oracle());

        uint256 depositUSD = oracle.convertTokenToUSD(address(0), deposit, Math.DECIMALS_NORMALIZED);
        if (depositUSD < MIN_INITIAL_DEPOSIT_USD) revert AMMLessThanMinInitialDeposit();

        uint256 tokensToMint = depositUSD;
        uint256 userTokens = tokensToMint - _DEAD_SUPPLY;

        if (userTokens < _minTokensToMint) revert AMMInsufficientDeposit();

        EVE(eve).mint(address(0x000000000000000000000000000000000000dEaD), _DEAD_SUPPLY);
        EVE(eve).mint(msg.sender, userTokens);

        payable(controller).sendValue(deposit);

        bootstrapped = true;

        emit Bootstrapped(msg.sender, deposit, userTokens, block.timestamp);
    }

    /**
     * @dev Internal function to set connector weight.
     * @param _cw Desired connector weight.
     */
    function _setConnectorWeight(uint256 _cw) internal {
        if (_cw == 0) revert AMMInvalidRange();
        if (_cw > Math.SCALE_FACTOR) revert AMMInvalidRange();

        emit ConnectorWeightChanged(connectorWeight, _cw);
        connectorWeight = _cw;
    }

    /**
     * @dev Internal function to set minimum ETH required for batch (queued) exit.
     * @param _minBatchExitETH Desired minimum ETH required for batch (queued) exit.
     */
    function _setMinBatchExitETH(uint256 _minBatchExitETH) internal {
        if (_minBatchExitETH > MIN_BATCH_EXIT_ETH_UPPER_BOUND) revert AMMInvalidMinBatchExitETH();
        emit MinBatchExitETHChanged(minBatchExitETH, _minBatchExitETH);
        minBatchExitETH = _minBatchExitETH;
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IAMM
     */
    function freeBalance() external view returns (uint256) {
        return _freeBalance();
    }

    /**
     * @inheritdoc IAMM
     */
    function eveBasePriceInETH() external view returns (uint256) {
        uint256 supply = EVE(_registry.eve()).totalSupply();
        return _basePriceFromNAV(_navInETH(), _liveSupply(supply));
    }

    /**
     * @inheritdoc IAMM
     */
    function evePremiumPriceInETH() external view returns (uint256) {
        uint256 supply = EVE(_registry.eve()).totalSupply();
        return _premiumPriceFromNAV(_navInETH(), _liveSupply(supply));
    }

    /**
     * @inheritdoc IAMM
     */
    function eveBasePriceInUSD() external view returns (uint256) {
        return _eveBasePriceInUSD(_liveSupply(EVE(_registry.eve()).totalSupply()));
    }

    /**
     * @inheritdoc IAMM
     */
    function evePremiumPriceInUSD() external view returns (uint256) {
        return _evePremiumPriceInUSD(_liveSupply(EVE(_registry.eve()).totalSupply()));
    }
}
