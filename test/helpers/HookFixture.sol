// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TestHook} from "../../src/TestHook.sol";
import {TestToken} from "../../src/TestToken.sol";
import {MockIMD} from "./MockIMD.sol";
import {PoolActor} from "./PoolActor.sol";

abstract contract HookFixture is Test {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant VAULT = 0x8Fe1805a83bCF70F514bC716Cd88C05051d6fF21;
    uint160 internal constant PRICE = 79228162514264337593543950336;
    uint160 internal constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    uint256 internal constant FUNDS = 100_000_000 ether;
    int256 internal constant LIQUIDITY = 1_000_000 ether;

    IPoolManager internal manager;
    TestHook internal hook;
    TestToken internal token;
    IERC20 internal imd = IERC20(IMD);
    PoolActor internal actor;
    PoolKey internal key;

    struct Trade {
        BalanceDelta userDelta;
        int256 poolImd;
        int256 poolToken;
        uint256 paid;
        uint256 deferred;
    }

    struct Balances {
        uint256 userImd;
        uint256 userToken;
        uint256 managerImd;
        uint256 managerToken;
        uint256 vault;
        uint256 pending;
    }

    function _setUp(bool tokenFirst, bool forked, bool seed) internal {
        if (!forked) {
            vm.chainId(4663);
            deployCodeTo("MockIMD.sol:MockIMD", IMD);
        }
        manager = IPoolManager(address(new PoolManager(address(this))));
        // Exercise real deployed token bytecode with both possible currency orderings.
        for (uint256 i; i < 128; ++i) {
            token = new TestToken();
            if ((address(token) < IMD) == tokenFirst) break;
        }
        assertEq(address(token) < IMD, tokenFirst, "could not produce desired currency ordering");
        hook = _deployHook(manager, address(token));
        actor = new PoolActor(manager);
        token.transfer(address(actor), FUNDS);
        if (forked) deal(IMD, address(actor), FUNDS);
        else MockIMD(IMD).mint(address(actor), FUNDS);

        (address a, address b) = tokenFirst ? (address(token), IMD) : (IMD, address(token));
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 12_500, 60, IHooks(address(hook)));
        manager.initialize(key, PRICE);
        if (seed) actor.modify(key, -600, 600, LIQUIDITY);
    }

    function _deployHook(IPoolManager pm, address launchToken) internal returns (TestHook deployed) {
        bytes memory code = abi.encodePacked(type(TestHook).creationCode, abi.encode(pm, launchToken));
        bytes32 hash = keccak256(code);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != FLAGS) continue;
            address at;
            assembly ("memory-safe") {
                at := create2(0, add(code, 32), mload(code), salt)
            }
            require(at == predicted, "CREATE2 deployment failed");
            return TestHook(at);
        }
        revert("no matching CREATE2 salt");
    }

    function _params(bool buy, bool exactInput, uint256 amount) internal view returns (SwapParams memory p) {
        p.zeroForOne = buy == (Currency.unwrap(key.currency0) == IMD);
        p.amountSpecified = exactInput ? -int256(amount) : int256(amount);
        p.sqrtPriceLimitX96 = p.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _trade(bool buy, bool exactInput, uint256 amount) internal returns (Trade memory) {
        return _trade(_params(buy, exactInput, amount), "");
    }

    function _trade(SwapParams memory p, bytes memory data) internal returns (Trade memory t) {
        Balances memory b = Balances(
            imd.balanceOf(address(actor)),
            token.balanceOf(address(actor)),
            imd.balanceOf(address(manager)),
            token.balanceOf(address(manager)),
            imd.balanceOf(VAULT),
            hook.pendingFees()
        );
        vm.recordLogs();
        t.userDelta = actor.swap(key, p, data);
        _readSwapLog(t, vm.getRecordedLogs());
        t.paid = imd.balanceOf(VAULT) - b.vault;
        t.deferred = hook.pendingFees() - b.pending;
        uint256 fee = t.paid + t.deferred;
        int256 userImd = _imdDelta(t.userDelta);
        int256 userToken = _tokenDelta(t.userDelta);
        bool buy = p.zeroForOne == (Currency.unwrap(key.currency0) == IMD);
        uint256 gross = buy ? uint256(-userImd) : uint256(t.poolImd);
        assertEq(fee, gross * 75 / 10_000, "fee must be 75 bps of executed gross IMD");
        assertEq(userImd, t.poolImd - int256(fee), "IMD accounting");
        assertEq(userToken, t.poolToken, "launch token taxed");
        assertEq(int256(imd.balanceOf(address(actor))) - int256(b.userImd), userImd);
        assertEq(int256(token.balanceOf(address(actor))) - int256(b.userToken), userToken);
        assertEq(int256(imd.balanceOf(address(manager))) - int256(b.managerImd), -userImd - int256(t.paid));
        assertEq(int256(token.balanceOf(address(manager))) - int256(b.managerToken), -userToken);
        assertEq(token.balanceOf(VAULT), 0, "vault received launch tokens");
        assertEq(imd.balanceOf(address(hook)), 0, "hook retained ERC20 IMD");
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        _assertSettled();
    }

    function _readSwapLog(Trade memory t, Vm.Log[] memory logs) private view {
        uint256 swapCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP_EVENT) continue;
            // Ignore the reverted quote's logs even on Foundry versions which record reverted logs.
            if (logs[i].topics[2] != bytes32(uint256(uint160(address(actor))))) continue;
            (int128 d0, int128 d1,,,, uint24 lpFee) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            bool imd0 = Currency.unwrap(key.currency0) == IMD;
            (t.poolImd, t.poolToken) = imd0 ? (int256(d0), int256(d1)) : (int256(d1), int256(d0));
            assertEq(lpFee, 12_500, "LP fee changed");
            swapCount++;
        }
        assertEq(swapCount, 1, "must execute exactly one lasting swap");
    }

    function _imdDelta(BalanceDelta delta) internal view returns (int256) {
        return Currency.unwrap(key.currency0) == IMD ? delta.amount0() : delta.amount1();
    }

    function _tokenDelta(BalanceDelta delta) internal view returns (int256) {
        return Currency.unwrap(key.currency0) == IMD ? delta.amount1() : delta.amount0();
    }

    function _assertSettled() internal view {
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(actor), key.currency0), 0);
        assertEq(manager.currencyDelta(address(actor), key.currency1), 0);
    }
}
