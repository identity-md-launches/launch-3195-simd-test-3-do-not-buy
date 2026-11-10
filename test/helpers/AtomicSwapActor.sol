// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TestHook} from "../../src/TestHook.sol";

/// @dev Test router: observes hook accounting while transient storage is still live.
/// Every entry point spends only this router's prefunded tokens.
contract AtomicSwapActor is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    TestHook private immutable hook;
    address private immutable controller;
    PoolKey private key;

    struct Observation {
        BalanceDelta delta;
        uint256 paid;
        uint256 deferred;
    }

    constructor(IPoolManager manager_, TestHook hook_, PoolKey memory key_) {
        manager = manager_;
        hook = hook_;
        key = key_;
        controller = msg.sender;
    }

    modifier onlyController() {
        require(msg.sender == controller || msg.sender == address(this), "controller only");
        _;
    }

    function run(SwapParams[] memory swaps, bytes memory hookData, bool settle, bool nestedRedemption)
        public
        onlyController
        returns (Observation[] memory observations)
    {
        observations =
            abi.decode(manager.unlock(abi.encode(swaps, hookData, settle, nestedRedemption)), (Observation[]));
        // Unlike checks in the test after a top-level call, these execute in the same transaction.
        require(!manager.isUnlocked(), "manager remained unlocked");
        require(manager.getNonzeroDeltaCount() == 0, "unsettled transaction");
    }

    function rejectThenRetry(SwapParams[] memory swaps, bytes memory hookData)
        external
        onlyController
        returns (Observation[] memory)
    {
        try this.run(swaps, hookData, false, false) {
            revert("unpaid swap succeeded");
        } catch (bytes memory reason) {
            require(bytes4(reason) == IPoolManager.CurrencyNotSettled.selector, "unexpected failure");
        }
        return this.run(swaps, hookData, true, false);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (SwapParams[] memory swaps, bytes memory hookData, bool settle, bool nestedRedemption) =
            abi.decode(data, (SwapParams[], bytes, bool, bool));
        IERC20 imd = IERC20(hook.IMD());
        if (nestedRedemption) {
            uint256 pending = hook.pendingFees();
            uint256 vault = imd.balanceOf(hook.VAULT());
            (bool ok, bytes memory reason) = address(hook).call(abi.encodeCall(TestHook.redeemFees, (1)));
            require(!ok && bytes4(reason) == IPoolManager.AlreadyUnlocked.selector, "nested redemption accepted");
            require(hook.pendingFees() == pending, "nested redemption lost claims");
            require(imd.balanceOf(hook.VAULT()) == vault, "nested redemption moved funds");
        }
        Observation[] memory observations = new Observation[](swaps.length);
        for (uint256 i; i < swaps.length; ++i) {
            uint256 vault = imd.balanceOf(hook.VAULT());
            uint256 pending = hook.pendingFees();
            observations[i].delta = manager.swap(key, swaps[i], hookData);
            observations[i].paid = imd.balanceOf(hook.VAULT()) - vault;
            observations[i].deferred = hook.pendingFees() - pending;
            require(manager.currencyDelta(address(hook), key.currency0) == 0, "hook owes currency0");
            require(manager.currencyDelta(address(hook), key.currency1) == 0, "hook owes currency1");
        }
        if (settle) {
            _settle(key.currency0);
            _settle(key.currency1);
            require(manager.getNonzeroDeltaCount() == 0, "delta escaped batch settlement");
        }
        return abi.encode(observations);
    }

    function _settle(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            manager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(-delta)), "payment failed");
            require(manager.settle() == uint256(-delta), "settled wrong amount");
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(delta));
        }
    }
}
