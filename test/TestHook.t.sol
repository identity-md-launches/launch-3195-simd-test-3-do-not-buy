// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {PoolActor} from "./helpers/PoolActor.sol";
import {TestHook} from "../src/TestHook.sol";
import {TestToken} from "../src/TestToken.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";

abstract contract SwapCases is HookFixture {
    using StateLibrary for IPoolManager;

    function test_buyExactInputPaysVaultInIMD() public {
        Trade memory t = _trade(true, true, 100 ether);
        assertEq(_imdDelta(t.userDelta), -100 ether);
        assertEq(t.paid, 0.75 ether);
        assertGt(_tokenDelta(t.userDelta), 0);
        assertEq(t.deferred, 0);
    }

    function test_buyExactOutputPaysVaultInIMD() public {
        Trade memory t = _trade(true, false, 100 ether);
        assertEq(_tokenDelta(t.userDelta), 100 ether);
        assertGt(t.paid, 0);
        assertEq(t.deferred, 0);
    }

    function test_sellExactInputPaysVaultInIMD() public {
        Trade memory t = _trade(false, true, 100 ether);
        assertEq(_tokenDelta(t.userDelta), -100 ether);
        assertGt(_imdDelta(t.userDelta), 0);
        assertGt(t.paid, 0);
        assertEq(t.deferred, 0);
    }

    function test_sellExactOutputPreservesRequestedNetIMD() public {
        Trade memory t = _trade(false, false, 100 ether);
        assertEq(_imdDelta(t.userDelta), 100 ether);
        assertGt(t.paid, 0);
        assertEq(t.deferred, 0);
    }

    function testFuzz_fullSwapsConserveFunds(uint128 amount, bool buy, bool exactInput) public {
        uint256 requested = bound(amount, 1, 10_000 ether);
        Trade memory t = _trade(buy, exactInput, requested);
        int256 specified = buy == exactInput ? _imdDelta(t.userDelta) : _tokenDelta(t.userDelta);
        assertEq(specified, exactInput ? -int256(requested) : int256(requested));
        assertEq(t.deferred, 0);
    }

    function testFuzz_priceLimitChargesOnlyExecutedIMD(uint128 amount, bool buy, bool exactInput) public {
        uint256 requested = bound(amount, 1_000 ether, 1_000_000 ether);
        SwapParams memory p = _params(buy, exactInput, requested);
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(p.zeroForOne ? int24(-1) : int24(1));
        Trade memory t = _trade(p, hex"deadbeef");
        uint256 executed = uint256(
            exactInput
                ? -(buy ? _imdDelta(t.userDelta) : _tokenDelta(t.userDelta))
                : (buy ? _tokenDelta(t.userDelta) : _imdDelta(t.userDelta))
        );
        assertGt(executed, 0);
        assertLt(executed, requested, "expected partial execution");
        assertGt(t.paid, 0);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, p.sqrtPriceLimitX96);
    }

    function test_hugeExactInputPartialFillDoesNotOverflowOrTaxUnusedBudget() public {
        SwapParams memory p = _params(true, true, uint256(1) << 200);
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(p.zeroForOne ? int24(-1) : int24(1));
        Trade memory t = _trade(p, "");
        assertLt(t.paid, 1 ether);
        assertGt(t.paid, 0);
    }

    function test_largestSignedExactInputCanPartiallyFill() public {
        SwapParams memory p = _params(true, true, 100 ether);
        p.amountSpecified = type(int256).min;
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(p.zeroForOne ? int24(-1) : int24(1));
        Trade memory t = _trade(p, "");
        assertGt(t.paid, 0);
        assertLt(t.paid, 1 ether);
    }

    function test_dustAmountsDoNotCauseReverts() public {
        uint256[8] memory amounts = [uint256(1), 2, 132, 133, 134, 399, 400, 10_000];
        for (uint256 i; i < amounts.length; ++i) {
            _trade(true, true, amounts[i]);
            _trade(false, true, amounts[i]);
            _trade(true, false, amounts[i]);
            _trade(false, false, amounts[i]);
        }
    }

    function test_timeBlocksSenderAndHookDataCannotChangeRate() public {
        uint256 snapshot = vm.snapshotState();
        Trade memory first = _trade(true, true, 100 ether);
        assertTrue(vm.revertToState(snapshot));
        vm.warp(2 ** 48);
        vm.roll(2 ** 48);
        Trade memory later = _trade(_params(true, true, 100 ether), abi.encode(makeAddr("redirect"), uint256(9999)));
        assertEq(later.paid, first.paid);
        assertEq(BalanceDelta.unwrap(later.userDelta), BalanceDelta.unwrap(first.userDelta));
        assertEq(imd.balanceOf(makeAddr("redirect")), 0);
    }

    function test_factoryCanCollectAndWithdrawLiquidity() public {
        _trade(true, true, 100 ether);
        _trade(false, true, 100 ether);
        uint256 vaultBefore = imd.balanceOf(VAULT);
        BalanceDelta collected = actor.modify(key, -600, 600, 0);
        assertGe(collected.amount0(), 0);
        assertGe(collected.amount1(), 0);
        assertGt(int256(collected.amount0()) + collected.amount1(), 0);
        BalanceDelta removed = actor.modify(key, -600, 600, -LIQUIDITY);
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        assertEq(imd.balanceOf(VAULT), vaultBefore);
        _assertSettled();
    }

    function test_multipleSwapsInOneUnlockClearTransientFee() public {
        uint256 vaultBefore = imd.balanceOf(VAULT);
        uint256 actorImdBefore = imd.balanceOf(address(actor));
        actor.swapTwice(key, _params(true, true, 100 ether), _params(false, true, 100 ether));
        assertGt(imd.balanceOf(VAULT) - vaultBefore, 0.75 ether);
        assertLt(imd.balanceOf(VAULT) - vaultBefore, 1.5 ether);
        assertLt(imd.balanceOf(address(actor)), actorImdBefore);
        _assertSettled();
        _trade(true, false, 100 ether);
    }

    function test_partialFillAcrossTicksAndExhaustedLiquidity() public {
        actor.modify(key, -60, 60, LIQUIDITY);
        for (uint256 i; i < 4; ++i) {
            uint256 snapshot = vm.snapshotState();
            SwapParams memory p = _params(i < 2, i % 2 == 0, 1_000_000 ether);
            p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(p.zeroForOne ? int24(-1200) : int24(1200));
            Trade memory t = _trade(p, "");
            assertGt(t.paid, 0);
            assertLt(uint256(t.poolImd < 0 ? -t.poolImd : t.poolImd), 1_000_000 ether);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_revertedQuoteDoesNotDoubleLPFees() public {
        _trade(true, true, 100 ether);
        BalanceDelta collected = actor.modify(key, -600, 600, 0);
        // 1.25% of the 99.25 IMD entering the AMM; Q128 fee-growth division can lose one wei.
        assertApproxEqAbs(uint256(_imdDelta(collected)), 1.240625 ether, 1);
        assertEq(_tokenDelta(collected), 0);
    }
}

contract TokenFirstHookTest is SwapCases {
    function setUp() public {
        _setUp(true, false, true);
    }
}

contract IMDFirstHookTest is SwapCases {
    function setUp() public {
        _setUp(false, false, true);
    }
}

contract HookFailureTest is HookFixture {
    function setUp() public {
        _setUp(true, false, true);
    }

    function test_constructorRejectsInvalidParametersWithoutCallingExternalContracts() public {
        vm.expectRevert(TestHook.InvalidDeployment.selector);
        this.attemptDeployment(IPoolManager(address(0)), address(token));
        vm.expectRevert(TestHook.InvalidDeployment.selector);
        this.attemptDeployment(manager, address(0));
        vm.expectRevert(TestHook.InvalidDeployment.selector);
        this.attemptDeployment(manager, IMD);
        address futureManager = makeAddr("unbuilt test manager");
        address futureToken = makeAddr("unbuilt test token");
        TestHook unbuilt = _deployHook(IPoolManager(futureManager), futureToken);
        assertEq(address(unbuilt.poolManager()), futureManager);
        assertEq(unbuilt.token(), futureToken);
    }

    function attemptDeployment(IPoolManager pm, address launchToken) external returns (address) {
        return address(new TestHook(pm, launchToken));
    }

    function test_poolCannotInitializeBeforePredictedHookHasCode() public {
        address predicted = address((uint160(makeAddr("counterfactual hook")) & ~Hooks.ALL_HOOK_MASK) | FLAGS);
        PoolKey memory futureKey = key;
        futureKey.hooks = IHooks(predicted);
        assertEq(predicted.code.length, 0);
        vm.expectRevert();
        manager.initialize(futureKey, PRICE);
    }

    function test_unrepresentableExactOutputCannotWrapIntoExactInput() public {
        SwapParams memory p = _params(false, false, uint256(type(int256).max));
        vm.prank(address(manager));
        vm.expectRevert(TestHook.SwapAmountTooLarge.selector);
        hook.beforeSwap(address(this), key, p, "");
        _trade(false, false, 100 ether);
    }

    function test_allEnabledCallbacksRejectNonManager() public {
        SwapParams memory p = _params(true, true, 1 ether);
        vm.expectRevert(TestHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, PRICE);
        vm.expectRevert(TestHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(TestHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, p, BalanceDeltaLibrary.ZERO_DELTA, "");
        vm.expectRevert(TestHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
        vm.expectRevert(TestHook.NotSelf.selector);
        hook.quoteSwap(key, p);
    }

    function test_permissionsMatchRealCreate2Address() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x20cc);
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity || p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate || p.afterDonate || p.afterInitialize);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
    }

    function test_initializationAcceptsFactoryAndRejectsWrongPoolParameters() public {
        // No caller allowlist: the factory's sender is accepted by the immutable pool validation.
        vm.prank(address(manager));
        assertEq(hook.beforeInitialize(makeAddr("launch factory"), key, PRICE), IHooks.beforeInitialize.selector);

        PoolKey memory bad = key;
        bad.fee = 3000;
        vm.expectRevert();
        manager.initialize(bad, PRICE);
        bad.fee = 0x800000;
        vm.expectRevert();
        manager.initialize(bad, PRICE);
        bad = key;
        bad.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(bad, PRICE);
        bad = key;
        bad.currency0 = Currency.wrap(address(0));
        vm.expectRevert();
        manager.initialize(bad, PRICE);
        bad = key;
        bad.currency0 = Currency.wrap(makeAddr("wrong token"));
        vm.prank(address(manager));
        vm.expectRevert(TestHook.WrongPool.selector);
        hook.beforeInitialize(address(this), bad, PRICE);
    }

    function test_wrongPoolCannotSpoofSwapCallbacks() public {
        PoolKey memory wrong = key;
        wrong.fee = 0;
        SwapParams memory p = _params(true, true, 1 ether);
        vm.prank(address(manager));
        vm.expectRevert(TestHook.WrongPool.selector);
        hook.beforeSwap(address(this), wrong, p, "");
        vm.prank(address(manager));
        vm.expectRevert(TestHook.WrongPool.selector);
        hook.afterSwap(address(this), wrong, p, BalanceDeltaLibrary.ZERO_DELTA, "");
    }

    function test_vaultTransferRevertDefersFeesAndAnyoneCanRedeemOnlyToVault() public {
        MockIMD(IMD).setFailureMode(1);
        Trade memory buy = _trade(true, true, 100 ether);
        Trade memory sell = _trade(false, true, 100 ether);
        assertEq(buy.paid + sell.paid, 0);
        uint256 pending = buy.deferred + sell.deferred;
        assertGt(pending, 0);
        assertEq(hook.pendingFees(), pending);
        vm.expectRevert();
        hook.redeemFees(pending);
        assertEq(hook.pendingFees(), pending, "failed redemption destroyed claims");
        MockIMD(IMD).setFailureMode(0);
        address stranger = makeAddr("permissionless keeper");
        uint256 vaultBefore = imd.balanceOf(VAULT);
        vm.prank(stranger);
        hook.redeemFees(pending / 2);
        assertEq(imd.balanceOf(VAULT) - vaultBefore, pending / 2);
        assertEq(imd.balanceOf(stranger), 0);
        hook.redeemFees(pending - pending / 2);
        assertEq(imd.balanceOf(VAULT) - vaultBefore, pending);
        assertEq(hook.pendingFees(), 0);
        vm.expectRevert();
        hook.redeemFees(1);
        _assertSettled();
    }

    function test_falseReturningTransferAlsoDefersFees() public {
        MockIMD(IMD).setFailureMode(2);
        Trade memory buy = _trade(true, false, 100 ether);
        Trade memory sell = _trade(false, false, 100 ether);
        assertEq(buy.paid + sell.paid, 0);
        assertGt(buy.deferred, 0);
        assertGt(sell.deferred, 0);
        MockIMD(IMD).setFailureMode(0);
        uint256 pending = hook.pendingFees();
        hook.redeemFees(pending);
        assertEq(hook.pendingFees(), 0);
        _assertSettled();
    }

    function test_rejectsInvalidRedemptionAmounts() public {
        vm.expectRevert(TestHook.InvalidRedemption.selector);
        hook.redeemFees(0);
        vm.expectRevert(TestHook.InvalidRedemption.selector);
        hook.redeemFees(type(uint256).max);
    }

    function test_adminSelectorsCannotRedirectFeesEvenFromFactoryOrVault() public {
        bytes[9] memory calls = [
            abi.encodeWithSignature("setVault(address)", address(this)),
            abi.encodeWithSignature("setFee(uint256)", uint256(9999)),
            abi.encodeWithSignature("setFeeBps(uint256)", uint256(9999)),
            abi.encodeWithSignature("transferOwnership(address)", address(this)),
            abi.encodeWithSignature("upgradeTo(address)", address(this)),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("setPoolManager(address)", address(this)),
            abi.encodeWithSignature("withdraw(address,uint256)", address(this), uint256(1)),
            abi.encodeWithSignature("initialize(address)", address(this))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(VAULT);
            (bool vaultOK,) = address(hook).call(calls[i]);
            assertFalse(vaultOK);
            (bool factoryOK,) = address(hook).call(calls[i]);
            assertFalse(factoryOK);
        }
        _trade(true, true, 100 ether);
        assertEq(imd.balanceOf(VAULT), 0.75 ether);
        assertEq(hook.FEE_BPS(), 75);
        assertEq(hook.VAULT(), VAULT);
    }

    function test_invalidSwapIsAtomicAndDoesNotPoisonNextSwap() public {
        uint256 vaultBefore = imd.balanceOf(VAULT);
        SwapParams memory p = _params(true, true, 100 ether);
        p.sqrtPriceLimitX96 = PRICE;
        vm.expectRevert();
        actor.swap(key, p, "");
        assertEq(imd.balanceOf(VAULT), vaultBefore);
        assertEq(hook.pendingFees(), 0);
        _trade(true, true, 100 ether);
    }

    function test_noMintPauseUpgradeOrExternalOwnershipInRuntime() public view {
        _assertNoEscapeOpcode(address(hook).code);
        _assertNoEscapeOpcode(address(token).code);
        assertLt(address(hook).code.length, 24_576);
    }

    function _assertNoEscapeOpcode(bytes memory code) private pure {
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) require(op != 0xff && op != 0xf4 && op != 0xf2, "escape opcode");
            if (op == 0 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}

contract EmptyAndOneSidedPoolTest is HookFixture {
    function setUp() public {
        _setUp(true, false, false);
    }

    function test_noLiquidityChargesNothingInAllFourModes() public {
        for (uint256 i; i < 4; ++i) {
            uint256 snapshot = vm.snapshotState();
            SwapParams memory p = _params(i < 2, i % 2 == 0, 100 ether);
            p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(p.zeroForOne ? int24(-60) : int24(60));
            Trade memory t = _trade(p, "");
            assertEq(t.paid + t.deferred, 0);
            assertEq(BalanceDelta.unwrap(t.userDelta), 0);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_freshManagerWithOnlyLaunchTokensCanProcessBuy() public {
        // token is currency0. Range starts at current tick, so only currency0 is deposited.
        actor.modify(key, 0, 600, LIQUIDITY);
        assertEq(imd.balanceOf(address(manager)), 0);
        assertGt(token.balanceOf(address(manager)), 0);
        Trade memory t = _trade(true, true, 100 ether);
        assertEq(t.paid, 0);
        assertEq(t.deferred, 0.75 ether);
        assertGt(_tokenDelta(t.userDelta), 0);
        hook.redeemFees(t.deferred);
        assertEq(imd.balanceOf(VAULT), 0.75 ether);
        assertEq(hook.pendingFees(), 0);
        _trade(false, true, 10 ether);
    }
}
