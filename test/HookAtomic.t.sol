// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {AtomicSwapActor} from "./helpers/AtomicSwapActor.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TestHook} from "../src/TestHook.sol";

abstract contract AtomicSwapCases is HookFixture {
    using StateLibrary for IPoolManager;

    AtomicSwapActor internal batchActor;

    function _setUpAtomic(bool tokenFirst) internal {
        _setUp(tokenFirst, false, true);
        batchActor = new AtomicSwapActor(manager, hook, key);
        token.transfer(address(batchActor), FUNDS);
        MockIMD(IMD).mint(address(batchActor), FUNDS);
    }

    /// @dev Four modes in different orders. Compare against independent top-level transactions
    /// from an identical snapshot, including the lasting LP fee growth and final pool price.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_batchAndRetryMatchSeparateTransactions(
        uint96[4] memory seeds,
        uint8 rotation,
        bool reverse,
        uint8 transferMode,
        bool retry
    ) public {
        MockIMD(IMD).setFailureMode(transferMode % 3);
        SwapParams[] memory swaps = new SwapParams[](4);
        for (uint256 i; i < swaps.length; ++i) {
            uint256 mode = (uint256(rotation) + (reverse ? 3 - i : i)) % 4;
            swaps[i] = _params(mode < 2, mode % 2 == 0, bound(seeds[i], 1, 100 ether));
        }
        bytes memory data = abi.encode(makeAddr("batch fee redirect"), uint256(9999));
        uint256 snapshot = vm.snapshotState();
        Trade[] memory expected = new Trade[](swaps.length);
        for (uint256 i; i < swaps.length; ++i) {
            expected[i] = _trade(swaps[i], data);
        }
        bytes32 expectedPool = _poolFingerprint();
        uint256 expectedVault = imd.balanceOf(VAULT);
        uint256 expectedPending = hook.pendingFees();
        assertTrue(vm.revertToState(snapshot));

        uint256 managerImd = imd.balanceOf(address(manager));
        uint256 managerToken = token.balanceOf(address(manager));
        AtomicSwapActor.Observation[] memory actual =
            retry ? batchActor.rejectThenRetry(swaps, data) : batchActor.run(swaps, data, true, false);
        int256 imdChange;
        int256 tokenChange;
        uint256 paid;
        for (uint256 i; i < swaps.length; ++i) {
            assertEq(BalanceDelta.unwrap(actual[i].delta), BalanceDelta.unwrap(expected[i].userDelta), "batch delta");
            assertEq(actual[i].paid, expected[i].paid, "batch payment");
            assertEq(actual[i].deferred, expected[i].deferred, "batch claim");
            imdChange += _imdDelta(actual[i].delta);
            tokenChange += _tokenDelta(actual[i].delta);
            paid += actual[i].paid;
        }
        assertEq(int256(imd.balanceOf(address(batchActor))) - int256(FUNDS), imdChange);
        assertEq(int256(token.balanceOf(address(batchActor))) - int256(FUNDS), tokenChange);
        assertEq(int256(imd.balanceOf(address(manager))) - int256(managerImd), -imdChange - int256(paid));
        assertEq(int256(token.balanceOf(address(manager))) - int256(managerToken), -tokenChange);
        assertEq(_poolFingerprint(), expectedPool, "reverted quote/retry changed pool state");
        assertEq(imd.balanceOf(VAULT), expectedVault);
        assertEq(hook.pendingFees(), expectedPending);
        assertEq(imd.balanceOf(makeAddr("batch fee redirect")), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0, "fee converted into native claims");
    }

    function test_zeroSecondSwapRevertsEarlierPaymentsAndClaims() public {
        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = _params(true, true, 100 ether);
        swaps[1] = _params(false, false, 0);
        for (uint8 mode; mode < 3; ++mode) {
            MockIMD(IMD).setFailureMode(mode);
            bytes32 beforeState = _stateFingerprint();
            vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
            batchActor.run(swaps, "", true, false);
            assertEq(_stateFingerprint(), beforeState, "failed batch retained value or price changes");
        }
        MockIMD(IMD).setFailureMode(0);
        _trade(true, true, 100 ether);
    }

    function test_unsettledBatchCannotKeepPaidOrDeferredFees() public {
        SwapParams[] memory swaps = new SwapParams[](1);
        swaps[0] = _params(true, true, 100 ether);
        for (uint8 mode; mode < 3; ++mode) {
            MockIMD(IMD).setFailureMode(mode);
            bytes32 beforeState = _stateFingerprint();
            vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
            batchActor.run(swaps, "", false, false);
            assertEq(_stateFingerprint(), beforeState, "unpaid trade retained a fee");
        }
    }

    function test_nestedRedemptionPreservesClaimsAndDoesNotBlockSwap() public {
        MockIMD(IMD).setFailureMode(1);
        _trade(true, true, 100 ether);
        uint256 pending = hook.pendingFees();
        assertEq(pending, 0.75 ether);
        MockIMD(IMD).setFailureMode(0);

        SwapParams[] memory swaps = new SwapParams[](1);
        swaps[0] = _params(false, true, 100 ether);
        uint256 beforeVault = imd.balanceOf(VAULT);
        AtomicSwapActor.Observation[] memory actual = batchActor.run(swaps, "", true, true);
        assertGt(actual[0].paid, 0);
        assertEq(actual[0].deferred, 0);
        assertEq(hook.pendingFees(), pending);
        assertEq(imd.balanceOf(VAULT), beforeVault + actual[0].paid);

        vm.prank(makeAddr("redemption keeper"));
        hook.redeemFees(pending);
        assertEq(imd.balanceOf(VAULT), beforeVault + actual[0].paid + pending);
        assertEq(hook.pendingFees(), 0);
    }

    function test_deferredFeesRemainRedeemableAfterAllLiquidityIsRemoved() public {
        MockIMD(IMD).setFailureMode(1);
        for (uint256 i; i < 4; ++i) {
            _trade(i < 2, i % 2 == 0, 100 ether);
        }
        uint256 pending = hook.pendingFees();
        assertGt(pending, 0);
        actor.modify(key, -600, 600, -LIQUIDITY);
        assertEq(manager.getLiquidity(key.toId()), 0);
        assertEq(hook.pendingFees(), pending);
        assertGe(imd.balanceOf(address(manager)), pending, "LP withdrawal spent the vault's claims");
        MockIMD(IMD).setFailureMode(0);
        uint256 beforeVault = imd.balanceOf(VAULT);
        hook.redeemFees(pending);
        assertEq(imd.balanceOf(VAULT), beforeVault + pending);
        assertEq(hook.pendingFees(), 0);
    }

    function test_feeEventsDescribeActualPayoutClaimsAndRedemption() public {
        vm.expectEmit(false, false, false, true, address(hook));
        emit TestHook.FeePaid(0.75 ether);
        Trade memory paid = _trade(true, true, 100 ether);
        assertEq(paid.paid, 0.75 ether);
        assertEq(paid.deferred, 0);
        MockIMD(IMD).setFailureMode(2);
        vm.expectEmit(false, false, false, true, address(hook));
        emit TestHook.FeeDeferred(0.75 ether);
        Trade memory deferred = _trade(true, true, 100 ether);
        assertEq(deferred.paid, 0);
        assertEq(deferred.deferred, 0.75 ether);
        MockIMD(IMD).setFailureMode(0);
        uint256 beforeVault = imd.balanceOf(VAULT);
        vm.expectEmit(false, false, false, true, address(hook));
        emit TestHook.FeesRedeemed(0.75 ether);
        hook.redeemFees(0.75 ether);
        assertEq(imd.balanceOf(VAULT), beforeVault + 0.75 ether);
        assertEq(hook.pendingFees(), 0);
    }

    function _poolFingerprint() internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        return
            keccak256(abi.encode(price, tick, protocolFee, lpFee, growth0, growth1, manager.getLiquidity(key.toId())));
    }

    function _stateFingerprint() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _poolFingerprint(),
                imd.balanceOf(VAULT),
                hook.pendingFees(),
                imd.balanceOf(address(manager)),
                token.balanceOf(address(manager)),
                imd.balanceOf(address(batchActor)),
                token.balanceOf(address(batchActor)),
                imd.balanceOf(address(hook)),
                token.balanceOf(address(hook))
            )
        );
    }
}

contract TokenFirstAtomicSwapTest is AtomicSwapCases {
    function setUp() public {
        _setUpAtomic(true);
    }
}

contract IMDFirstAtomicSwapTest is AtomicSwapCases {
    function setUp() public {
        _setUpAtomic(false);
    }
}
