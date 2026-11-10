// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "../helpers/HookFixture.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TestHook} from "../../src/TestHook.sol";
import {AtomicSwapActor} from "../helpers/AtomicSwapActor.sol";

/// @notice Uses ROBINHOOD_RPC_URL at the assignment's pinned block, or skips when it is absent.
/// @dev Uses live IMD bytecode/state;
/// the launch token, hook and a real v4 PoolManager are deployed locally into the fork.
contract RobinhoodForkTest is HookFixture {
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 111_252_324;

    function _tokenFirst() internal pure virtual returns (bool) {
        return true;
    }

    function setUp() public {
        string memory url = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        // The pinned RPC header includes an l1BlockNumber; NUMBER exposes that parent height.
        // The fork selection above pins Robinhood state, independently of the NUMBER opcode.
        assertEq(block.chainid, 4663, "requires Robinhood Chain mainnet");
        assertGt(IMD.code.length, 0, "IMD missing at fork block");
        assertEq(IERC20Metadata(IMD).symbol(), "IMD");
        assertEq(IERC20Metadata(IMD).decimals(), 18);
        _setUp(_tokenFirst(), true, true);
    }

    function testFork_buyExactInputFeeArrivesInLiveIMD() public {
        Trade memory t = _trade(true, true, 100 ether);
        assertEq(t.paid, 0.75 ether);
        assertEq(t.deferred, 0);
    }

    function testFork_buyExactOutputFeeArrivesInLiveIMD() public {
        Trade memory t = _trade(true, false, 100 ether);
        assertEq(_tokenDelta(t.userDelta), 100 ether);
        assertGt(t.paid, 0);
        assertEq(t.deferred, 0);
    }

    function testFork_sellExactInputFeeArrivesInLiveIMD() public {
        Trade memory t = _trade(false, true, 100 ether);
        assertGt(t.paid, 0);
        assertEq(t.deferred, 0);
    }

    function testFork_sellExactOutputFeeArrivesInLiveIMD() public {
        Trade memory t = _trade(false, false, 100 ether);
        assertEq(_imdDelta(t.userDelta), 100 ether);
        assertGt(t.paid, 0);
        assertEq(t.deferred, 0);
    }

    function testFork_noTimeBasedTaxAndNoFeeRedirect() public {
        uint256[4] memory delays = [uint256(1), 7 days, 365 days, 10 * 365 days];
        address redirect = makeAddr("fork fee redirect");
        uint256 redirectBalance = imd.balanceOf(redirect);
        uint256 vaultETH = VAULT.balance;
        bytes32 hookCode = address(hook).codehash;
        for (uint256 mode; mode < 4; ++mode) {
            uint256 snapshot = vm.snapshotState();
            SwapParams memory p = _params(mode < 2, mode % 2 == 0, 100 ether);
            Trade memory before = _trade(p, "");
            assertTrue(vm.revertToState(snapshot));
            snapshot = vm.snapshotState();
            uint256 future = vm.getBlockTimestamp() + delays[mode];
            vm.warp(future);
            assertEq(vm.getBlockTimestamp(), future);
            _tryRedirect(VAULT, redirect);
            _tryRedirect(address(this), redirect);
            _tryRedirect(redirect, redirect);
            Trade memory after_ = _trade(p, abi.encode(redirect, uint256(0), uint256(10_000)));
            assertEq(after_.paid, before.paid);
            assertEq(after_.deferred, 0);
            assertEq(BalanceDelta.unwrap(after_.userDelta), BalanceDelta.unwrap(before.userDelta));
            assertEq(imd.balanceOf(redirect), redirectBalance);
            assertEq(VAULT.balance, vaultETH, "fee converted to ETH");
            assertEq(address(hook).codehash, hookCode);
            assertEq(hook.VAULT(), VAULT);
            assertEq(hook.FEE_BPS(), 75);
            assertEq(address(hook.poolManager()), address(manager));
            assertEq(hook.token(), address(token));
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testFork_partialFillsChargeOnlyExecutedIMD() public {
        for (uint256 i; i < 4; ++i) {
            uint256 snapshot = vm.snapshotState();
            SwapParams memory p = _params(i < 2, i % 2 == 0, 1000 ether);
            p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(p.zeroForOne ? int24(-1) : int24(1));
            Trade memory t = _trade(p, "");
            assertGt(t.paid, 0);
            assertEq(t.deferred, 0);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testFork_freshManagerDefersThenRedeemsToFixedVault() public {
        _setUp(_tokenFirst(), true, false);
        // Seed only the launch token, on either side of the sorted key.
        if (_tokenFirst()) actor.modify(key, 0, 600, LIQUIDITY);
        else actor.modify(key, -600, 0, LIQUIDITY);
        assertEq(imd.balanceOf(address(manager)), 0);
        Trade memory t = _trade(true, true, 100 ether);
        assertEq(t.paid, 0);
        assertEq(t.deferred, 0.75 ether);
        uint256 vaultBefore = imd.balanceOf(VAULT);
        vm.prank(makeAddr("fork keeper"));
        hook.redeemFees(t.deferred);
        assertEq(imd.balanceOf(VAULT) - vaultBefore, 0.75 ether);
        assertEq(hook.pendingFees(), 0);
        _assertSettled();
    }

    function testFork_dustAndRoundingBoundariesAllFourModes() public {
        uint256[8] memory amounts = [uint256(1), 132, 133, 134, 399, 400, 9999, 10_000];
        uint256 vaultETH = VAULT.balance;
        for (uint256 mode; mode < 4; ++mode) {
            for (uint256 i; i < amounts.length; ++i) {
                uint256 snapshot = vm.snapshotState();
                Trade memory t = _trade(mode < 2, mode % 2 == 0, amounts[i]);
                assertEq(t.deferred, 0);
                if (mode == 0) assertEq(t.paid, amounts[i] * 75 / 10_000);
                if (mode == 3) assertEq(_imdDelta(t.userDelta), int256(amounts[i]));
                assertEq(VAULT.balance, vaultETH);
                assertTrue(vm.revertToState(snapshot));
            }
        }
    }

    function testFork_failedInputSettlementRollsBackFeeAndPool() public {
        for (uint256 mode; mode < 4; ++mode) {
            uint256 snapshot = vm.snapshotState();
            bool buy = mode < 2;
            SwapParams memory p = _params(buy, mode % 2 == 0, 100 ether);
            if (buy) {
                deal(IMD, address(actor), 0);
            } else {
                uint256 held = token.balanceOf(address(actor));
                vm.prank(address(actor));
                token.transfer(address(this), held);
            }
            bytes32 beforeState = _forkStateFingerprint();
            vm.expectRevert();
            actor.swap(key, p, "");
            assertEq(_forkStateFingerprint(), beforeState, "failed settlement retained fee or pool changes");
            if (buy) deal(IMD, address(actor), FUNDS);
            else token.transfer(address(actor), FUNDS);
            Trade memory t = _trade(p, "");
            assertGt(t.paid, 0, "failed swap poisoned the next one");
            assertEq(t.deferred, 0);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testFork_invalidPriceAndZeroAmountAreAtomic() public {
        bytes32 beforeState = _forkStateFingerprint();
        SwapParams memory p = _params(true, true, 0);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        actor.swap(key, p, "");
        assertEq(_forkStateFingerprint(), beforeState);
        p.amountSpecified = -100 ether;
        p.sqrtPriceLimitX96 = PRICE;
        vm.expectRevert();
        actor.swap(key, p, "");
        assertEq(_forkStateFingerprint(), beforeState);
        _trade(true, true, 100 ether);
    }

    function testFork_deferredClaimsCannotBeStolenOverdrawnOrRedeemedTwice() public {
        _setUp(_tokenFirst(), true, false);
        if (_tokenFirst()) actor.modify(key, 0, 600, LIQUIDITY);
        else actor.modify(key, -600, 0, LIQUIDITY);
        _trade(true, true, 100 ether);
        uint256 pending = hook.pendingFees();
        assertEq(pending, 0.75 ether);
        address stranger = makeAddr("fork claim thief");
        uint256 strangerBalance = imd.balanceOf(stranger);
        uint256 id = uint256(uint160(IMD));
        bytes32 beforeState = _forkStateFingerprint();
        vm.expectRevert();
        vm.prank(stranger);
        manager.transferFrom(address(hook), stranger, id, 1);
        assertEq(_forkStateFingerprint(), beforeState);
        assertEq(manager.balanceOf(stranger, id), 0);
        assertEq(manager.allowance(address(hook), stranger, id), 0);
        assertFalse(manager.isOperator(address(hook), stranger));

        vm.expectRevert();
        hook.redeemFees(pending + 1);
        assertEq(_forkStateFingerprint(), beforeState);
        vm.expectRevert(TestHook.InvalidRedemption.selector);
        hook.redeemFees(0);
        vm.expectRevert(TestHook.InvalidRedemption.selector);
        hook.redeemFees(uint256(uint128(type(int128).max)) + 1);
        assertEq(_forkStateFingerprint(), beforeState);

        uint256 vaultBefore = imd.balanceOf(VAULT);
        vm.prank(stranger);
        hook.redeemFees(1);
        assertEq(hook.pendingFees(), pending - 1);
        assertEq(imd.balanceOf(VAULT), vaultBefore + 1);
        vm.prank(stranger);
        hook.redeemFees(pending - 1);
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(VAULT), vaultBefore + pending);
        assertEq(imd.balanceOf(stranger), strangerBalance);
        beforeState = _forkStateFingerprint();
        vm.expectRevert();
        hook.redeemFees(1);
        assertEq(_forkStateFingerprint(), beforeState);
    }

    function testFork_unpaidBatchRollsBackAndRetryPaysExactlyOnce() public {
        AtomicSwapActor batch = new AtomicSwapActor(manager, hook, key);
        token.transfer(address(batch), FUNDS);
        deal(IMD, address(batch), FUNDS);
        SwapParams[] memory swaps = new SwapParams[](4);
        for (uint256 i; i < 4; ++i) {
            swaps[i] = _params(i < 2, i % 2 == 0, 100 ether);
        }
        uint256 vaultBefore = imd.balanceOf(VAULT);
        AtomicSwapActor.Observation[] memory results = batch.rejectThenRetry(swaps, "");
        uint256 paid;
        int256 imdChange;
        int256 tokenChange;
        for (uint256 i; i < results.length; ++i) {
            int256 imdDelta = _imdDelta(results[i].delta);
            uint256 gross = i < 2 ? uint256(-imdDelta) : uint256(imdDelta) + results[i].paid;
            assertEq(results[i].paid, gross * 75 / 10_000);
            assertGt(results[i].paid, 0);
            assertEq(results[i].deferred, 0);
            paid += results[i].paid;
            imdChange += imdDelta;
            tokenChange += _tokenDelta(results[i].delta);
        }
        assertEq(imd.balanceOf(VAULT), vaultBefore + paid);
        assertEq(hook.pendingFees(), 0);
        assertEq(int256(imd.balanceOf(address(batch))) - int256(FUNDS), imdChange);
        assertEq(int256(token.balanceOf(address(batch))) - int256(FUNDS), tokenChange);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function _tryRedirect(address caller, address recipient) private {
        bytes[5] memory attempts = [
            abi.encodeWithSignature("setVault(address)", recipient),
            abi.encodeWithSignature("setFeeBps(uint256)", uint256(0)),
            abi.encodeWithSignature("transferOwnership(address)", recipient),
            abi.encodeWithSignature("upgradeTo(address)", recipient),
            abi.encodeWithSignature("pause()")
        ];
        for (uint256 i; i < attempts.length; ++i) {
            vm.prank(caller);
            (bool ok,) = address(hook).call(attempts[i]);
            assertFalse(ok, "mutable hook configuration");
        }
    }

    function _forkStateFingerprint() private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        bytes32 poolState = keccak256(abi.encode(price, tick, protocolFee, lpFee, growth0, growth1));
        return keccak256(
            abi.encode(
                poolState,
                imd.balanceOf(VAULT),
                hook.pendingFees(),
                imd.balanceOf(address(manager)),
                token.balanceOf(address(manager)),
                imd.balanceOf(address(actor)),
                token.balanceOf(address(actor))
            )
        );
    }
}

contract RobinhoodIMDFirstForkTest is RobinhoodForkTest {
    function _tokenFirst() internal pure override returns (bool) {
        return false;
    }
}
