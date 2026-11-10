// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../src/TestToken.sol";

contract TestTokenTest is Test {
    TestToken private token;

    function setUp() public {
        token = new TestToken();
    }

    function test_launchSupplyMetadataAndFactoryAllocations() public {
        uint256 supply = 1_000_000_000 ether;
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(address(this)), supply);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "SIMD TEST 3 - DO NOT BUY");
        assertEq(token.symbol(), "SIMDTEST3");
        assertEq(token.LOGO_URI(), "https://www.si-md.xyz/logo.jpg");
        address distributor = makeAddr("swarm distributor");
        address pool = makeAddr("pool manager");
        address remainder = 0xD68114FC3359F93Ccc93BeE90229ac366bC173bE;
        token.transfer(distributor, supply / 10);
        token.transfer(pool, supply * 2669 / 10_000);
        token.transfer(remainder, supply * 6331 / 10_000);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(distributor), supply / 10);
        assertEq(token.balanceOf(pool), supply * 2669 / 10_000);
        assertEq(token.balanceOf(remainder), supply * 6331 / 10_000);
        assertEq(token.totalSupply(), supply);
    }

    function test_transfersAreUntaxedAndUnauthorizedSpenderCannotMoveFunds() public {
        address holder = makeAddr("holder");
        address stranger = makeAddr("stranger");
        token.transfer(holder, 100 ether);
        assertEq(token.balanceOf(holder), 100 ether);
        vm.prank(stranger);
        vm.expectRevert();
        token.transferFrom(holder, stranger, 1);
        assertEq(token.balanceOf(holder), 100 ether);
        vm.prank(holder);
        token.approve(stranger, 10 ether);
        vm.prank(stranger);
        token.transferFrom(holder, stranger, 10 ether);
        assertEq(token.balanceOf(holder), 90 ether);
        assertEq(token.balanceOf(stranger), 10 ether);
        assertEq(token.allowance(holder, stranger), 0);
    }

    function test_factoryCannotMintPauseOrUpgrade() public {
        bytes[5] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", address(this), uint256(1)),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("blacklist(address)", address(this)),
            abi.encodeWithSignature("upgradeTo(address)", address(this)),
            abi.encodeWithSignature("transferOwnership(address)", address(this))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertTrue(token.transfer(makeAddr("recipient"), 1 ether));
    }
}
