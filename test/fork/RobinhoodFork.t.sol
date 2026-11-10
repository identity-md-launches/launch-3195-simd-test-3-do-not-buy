// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "../helpers/HookFixture.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Opt-in fork suite: pass --fork-url and --fork-block-number to forge test.
/// @dev No environment reads and no RPC needed by the offline suite. Uses live IMD bytecode/state;
/// the launch token, hook and a real v4 PoolManager are deployed locally into the fork.
contract RobinhoodForkTest is HookFixture {
    function _tokenFirst() internal pure virtual returns (bool) {
        return true;
    }

    function setUp() public {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
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
        uint256 snapshot = vm.snapshotState();
        Trade memory before = _trade(true, true, 100 ether);
        assertTrue(vm.revertToState(snapshot));
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 1_000_000);
        vm.prank(VAULT);
        (bool ok,) = address(hook).call(abi.encodeWithSignature("setVault(address)", address(this)));
        assertFalse(ok);
        vm.prank(VAULT);
        (ok,) = address(hook).call(abi.encodeWithSignature("setFeeBps(uint256)", uint256(0)));
        assertFalse(ok);
        Trade memory after_ = _trade(true, true, 100 ether);
        assertEq(after_.paid, before.paid);
        assertEq(BalanceDelta.unwrap(after_.userDelta), BalanceDelta.unwrap(before.userDelta));
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
}

contract RobinhoodIMDFirstForkTest is RobinhoodForkTest {
    function _tokenFirst() internal pure override returns (bool) {
        return false;
    }
}
