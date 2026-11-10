// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Immutable 75 bps IMD fee for the SIMDTEST3 launch pool. DO NOT BUY the test token.
/// @dev No owner, external configuration, ETH conversion, time logic, or liquidity callbacks.
contract TestHook is IUnlockCallback {
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address public constant VAULT = 0x8Fe1805a83bCF70F514bC716Cd88C05051d6fF21;
    uint256 public constant FEE_BPS = 75;
    uint256 public constant BPS = 10_000;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;

    IPoolManager public immutable poolManager;
    address public immutable token;

    // Used only between the manager's beforeSwap and afterSwap in one call; cleared before payout.
    bytes32 private constant FEE_SLOT = keccak256("simdtest3.hook.current-swap-fee");

    error NotPoolManager();
    error NotSelf();
    error InvalidDeployment();
    error WrongPool();
    error QuoteResult(uint256 imdAmount);
    error UnexpectedQuoteSuccess();
    error InvalidRedemption();
    error SwapAmountTooLarge();

    event FeePaid(uint256 amount);
    event FeeDeferred(uint256 amount);
    event FeesRedeemed(uint256 amount);

    /// @param manager_ The launch's $poolManager. No external constructor calls.
    /// @param token_ The launch's $token, deployed immediately before this hook.
    constructor(IPoolManager manager_, address token_) {
        if (address(manager_) == address(0) || token_ == address(0) || token_ == IMD) {
            revert InvalidDeployment();
        }
        poolManager = manager_;
        token = token_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @dev Also prevents initializing this hook's predicted pool before its code exists.
    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        _checkPool(key);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        uint256 fee = 0;
        if (_imdIsSpecified(key, params)) {
            fee = _specifiedFee(key, params);
        }
        bytes32 slot = FEE_SLOT;
        assembly ("memory-safe") {
            tstore(slot, fee)
        }
        // Computed from the int128 pool delta, so fee is always safely representable as int128.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(SafeCast.toInt128(fee), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _checkPool(key);
        bool specified = _imdIsSpecified(key, params);
        uint256 fee;
        bytes32 slot = FEE_SLOT;
        assembly ("memory-safe") {
            fee := tload(slot)
            tstore(slot, 0)
        }
        if (!specified) {
            int256 imdDelta = Currency.unwrap(key.currency0) == IMD ? delta.amount0() : delta.amount1();
            // Buy: the gross IMD input includes our fee. Sell: deduct from the gross IMD output.
            fee = imdDelta < 0
                ? FullMath.mulDiv(uint256(-imdDelta), FEE_BPS, BPS - FEE_BPS)
                : FullMath.mulDiv(uint256(imdDelta), FEE_BPS, BPS);
        }
        if (fee != 0) _collect(fee);
        return (IHooks.afterSwap.selector, specified ? int128(0) : SafeCast.toInt128(fee));
    }

    /// @notice Reverted simulation used only by this hook, never an executable swap entry point.
    /// @dev v4 suppresses callbacks on a swap whose caller is the hook itself. Reverting rolls back
    /// ALL pool changes, deltas, protocol fees and events. No tokens move in the simulation.
    function quoteSwap(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this)) revert NotSelf();
        BalanceDelta delta = poolManager.swap(key, params, "");
        int256 imdDelta = Currency.unwrap(key.currency0) == IMD ? delta.amount0() : delta.amount1();
        revert QuoteResult(uint256(imdDelta < 0 ? -imdDelta : imdDelta));
    }

    /// @notice Unpaid fees remain IMD claims on the same PoolManager, never ETH or launch tokens.
    function pendingFees() external view returns (uint256) {
        return poolManager.balanceOf(address(this), uint256(uint160(IMD)));
    }

    /// @notice Anyone may redeem an available amount; only the immutable vault can receive it.
    /// @dev A failed redemption reverts atomically, preserving every claim. No swap depends on it.
    function redeemFees(uint256 amount) external {
        if (amount == 0 || amount > uint256(uint128(type(int128).max))) revert InvalidRedemption();
        poolManager.unlock(abi.encode(amount));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), uint256(uint160(IMD)), amount);
        poolManager.take(Currency.wrap(IMD), VAULT, amount);
        emit FeesRedeemed(amount);
        return "";
    }

    function _specifiedFee(PoolKey calldata key, SwapParams calldata params) private returns (uint256 fee) {
        SwapParams memory quoted = params;
        uint256 requested;
        uint256 proposedFee;
        if (params.amountSpecified < 0) {
            // Avoid negating int256.min; the reduced pool input fits int256.
            requested = uint256(-(params.amountSpecified + 1)) + 1;
            proposedFee = FullMath.mulDiv(requested, FEE_BPS, BPS);
            quoted.amountSpecified = -int256(requested - proposedFee);
        } else {
            requested = uint256(params.amountSpecified);
            proposedFee = FullMath.mulDiv(requested, FEE_BPS, BPS - FEE_BPS);
            // v4 adds the specified fee using signed int256 arithmetic. Reject an unrepresentable
            // target explicitly instead of allowing the quote to wrap into an exact-input swap.
            if (requested > uint256(type(int256).max) - proposedFee) revert SwapAmountTooLarge();
            quoted.amountSpecified = int256(requested + proposedFee);
        }

        uint256 executed;
        try this.quoteSwap(key, quoted) {
            revert UnexpectedQuoteSuccess();
        } catch (bytes memory reason) {
            // Only our exact, fixed-size result is a quote. Preserve genuine manager failures.
            if (reason.length != 36 || bytes4(reason) != QuoteResult.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
            assembly ("memory-safe") {
                executed := mload(add(reason, 36))
            }
        }

        if (params.amountSpecified < 0) {
            // Full fill: charge exactly 75 bps of the user's input budget. Partial fill: gross up
            // only the executed pool input; unused budget is never taxed, including zero fills.
            fee = executed == requested - proposedFee ? proposedFee : FullMath.mulDiv(executed, FEE_BPS, BPS - FEE_BPS);
        } else {
            fee = FullMath.mulDiv(executed, FEE_BPS, BPS);
        }
    }

    function _collect(uint256 amount) private {
        // A buy's router settles its input AFTER this callback. There may be too little physical
        // IMD here yet, or IMD may refuse the recipient. A claim keeps swaps live in either case.
        try poolManager.take(Currency.wrap(IMD), VAULT, amount) {
            emit FeePaid(amount);
        } catch {
            poolManager.mint(address(this), uint256(uint160(IMD)), amount);
            emit FeeDeferred(amount);
        }
    }

    function _imdIsSpecified(PoolKey calldata key, SwapParams calldata params) private pure returns (bool) {
        bool currency0Specified = params.zeroForOne == (params.amountSpecified < 0);
        return currency0Specified == (Currency.unwrap(key.currency0) == IMD);
    }

    function _checkPool(PoolKey calldata key) private view {
        (address c0, address c1) = token < IMD ? (token, IMD) : (IMD, token);
        if (
            Currency.unwrap(key.currency0) != c0 || Currency.unwrap(key.currency1) != c1 || key.fee != LP_FEE
                || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(this)
        ) revert WrongPool();
    }
}
