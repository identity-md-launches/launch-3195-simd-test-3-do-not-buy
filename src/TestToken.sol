// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A valueless launch rehearsal token. DO NOT BUY.
/// @dev All supply belongs to the deploying launch factory for its policy allocations.
contract TestToken is ERC20 {
    string public constant LOGO_URI = "https://www.si-md.xyz/logo.jpg";

    constructor() ERC20("SIMD TEST 3 - DO NOT BUY", "SIMDTEST3") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
