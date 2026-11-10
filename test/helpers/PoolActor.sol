// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @dev Test-only router and factory position holder. Pays exclusively from its prefunded balance.
contract PoolActor is IUnlockCallback {
    IPoolManager public immutable manager;
    address private immutable controller;

    constructor(IPoolManager manager_) {
        manager = manager_;
        controller = msg.sender;
    }

    modifier onlyController() {
        require(msg.sender == controller, "controller only");
        _;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        onlyController
        returns (BalanceDelta)
    {
        return abi.decode(manager.unlock(abi.encode(uint8(0), key, abi.encode(params, hookData))), (BalanceDelta));
    }

    function modify(PoolKey memory key, int24 lower, int24 upper, int256 liquidity)
        external
        onlyController
        returns (BalanceDelta)
    {
        ModifyLiquidityParams memory params = ModifyLiquidityParams(lower, upper, liquidity, bytes32(0));
        return abi.decode(manager.unlock(abi.encode(uint8(1), key, abi.encode(params))), (BalanceDelta));
    }

    function swapTwice(PoolKey memory key, SwapParams memory first, SwapParams memory second)
        external
        onlyController
        returns (BalanceDelta)
    {
        return abi.decode(manager.unlock(abi.encode(uint8(2), key, abi.encode(first, second))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, PoolKey memory key, bytes memory args) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            (SwapParams memory params, bytes memory hookData) = abi.decode(args, (SwapParams, bytes));
            delta = manager.swap(key, params, hookData);
        } else if (action == 1) {
            ModifyLiquidityParams memory params = abi.decode(args, (ModifyLiquidityParams));
            (delta,) = manager.modifyLiquidity(key, params, "");
        } else {
            (SwapParams memory first, SwapParams memory second) = abi.decode(args, (SwapParams, SwapParams));
            delta = manager.swap(key, first, "") + manager.swap(key, second, "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 owed = uint256(-int256(delta));
            manager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transfer(address(manager), owed), "payment failed");
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        }
    }
}
