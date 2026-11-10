// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Offline IMD stand-in only. Never used by the fork suite or deployed by the launch.
contract MockIMD is ERC20 {
    address private constant VAULT = 0x8Fe1805a83bCF70F514bC716Cd88C05051d6fF21;
    uint8 public failureMode;

    error VaultTransferRejected();

    constructor() ERC20("Mock Identity.md", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailureMode(uint8 mode) external {
        failureMode = mode;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == VAULT) {
            if (failureMode == 1) revert VaultTransferRejected();
            if (failureMode == 2) return false;
        }
        return super.transfer(to, amount);
    }
}
