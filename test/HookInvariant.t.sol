// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolActor} from "./helpers/PoolActor.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {TestHook} from "../src/TestHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract SwapHandler is Test {
    using StateLibrary for IPoolManager;
    IPoolManager private immutable manager;
    TestHook private immutable hook;
    MockIMD private immutable imd;
    PoolKey private key;
    PoolActor public immutable actor;
    uint256 public accrued;
    uint256 public swaps;

    constructor(IPoolManager manager_, TestHook hook_, PoolKey memory key_) {
        manager = manager_;
        hook = hook_;
        key = key_;
        imd = MockIMD(hook_.IMD());
        actor = new PoolActor(manager_);
    }

    function trade(uint96 seed, bool buy, bool exactInput, bool tightLimit) external {
        uint256 amount = bound(seed, 1, 100 ether);
        bool imd0 = Currency.unwrap(key.currency0) == address(imd);
        bool zeroForOne = buy == imd0;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if (tightLimit) {
            (, int24 tick,,) = manager.getSlot0(key.toId());
            limit = TickMath.getSqrtPriceAtTick(tick + (zeroForOne ? int24(-1) : int24(2)));
        }
        uint256 vaultBefore = imd.balanceOf(hook.VAULT());
        uint256 pendingBefore = hook.pendingFees();
        BalanceDelta delta =
            actor.swap(key, SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit), "");
        uint256 fee = imd.balanceOf(hook.VAULT()) - vaultBefore + hook.pendingFees() - pendingBefore;
        int256 imdDelta = imd0 ? delta.amount0() : delta.amount1();
        uint256 gross = buy ? uint256(-imdDelta) : uint256(imdDelta) + fee;
        assertEq(fee, gross * 75 / 10_000, "sequence changed rate");
        accrued += fee;
        swaps++;
    }

    function failVaultTransfers(uint8 seed) external {
        imd.setFailureMode(seed % 3);
    }

    function redeem(uint128 seed) external {
        uint256 pending = hook.pendingFees();
        if (pending == 0) return;
        uint256 amount = bound(seed, 1, pending);
        uint256 vaultBefore = imd.balanceOf(hook.VAULT());
        if (imd.failureMode() != 0) {
            try hook.redeemFees(amount) {
                assertTrue(false, "blocked transfer succeeded");
            } catch {}
            assertEq(hook.pendingFees(), pending, "failed redemption lost claims");
            assertEq(imd.balanceOf(hook.VAULT()), vaultBefore);
        } else {
            hook.redeemFees(amount);
            assertEq(hook.pendingFees(), pending - amount);
            assertEq(imd.balanceOf(hook.VAULT()), vaultBefore + amount);
        }
    }

    function advance(uint32 seconds_, uint32 blocks_) external {
        vm.warp(block.timestamp + seconds_);
        vm.roll(block.number + blocks_);
    }
}

contract HookInvariantTest is HookFixture {
    SwapHandler private handler;

    function setUp() public {
        _setUp(true, false, true);
        handler = new SwapHandler(manager, hook, key);
        token.transfer(address(handler.actor()), FUNDS);
        MockIMD(IMD).mint(address(handler.actor()), FUNDS);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = SwapHandler.trade.selector;
        selectors[1] = SwapHandler.failVaultTransfers.selector;
        selectors[2] = SwapHandler.redeem.selector;
        selectors[3] = SwapHandler.advance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_feesAlwaysBelongToVaultAndAllDeltasSettle() public view {
        assertEq(imd.balanceOf(VAULT) + hook.pendingFees(), handler.accrued());
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(VAULT), 0);
        _assertSettled();
    }

    function invariant_physicalTokensAreConserved() public view {
        uint256 imdTotal = imd.balanceOf(address(actor)) + imd.balanceOf(address(handler.actor()))
            + imd.balanceOf(address(manager)) + imd.balanceOf(VAULT);
        assertEq(imdTotal, 2 * FUNDS);
        uint256 tokenTotal = token.balanceOf(address(this)) + token.balanceOf(address(actor))
            + token.balanceOf(address(handler.actor())) + token.balanceOf(address(manager));
        assertEq(tokenTotal, token.totalSupply());
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function afterInvariant() public {
        MockIMD(IMD).setFailureMode(0);
        uint256 pending = hook.pendingFees();
        if (pending != 0) hook.redeemFees(pending);
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(VAULT), handler.accrued());
        _assertSettled();
    }
}
