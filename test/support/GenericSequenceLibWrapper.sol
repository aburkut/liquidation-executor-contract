// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GenericSequenceLib} from "../../src/libraries/GenericSequenceLib.sol";
import {Op} from "../../src/types/SwapTypes.sol";

/// Test-only: gives the library a deployable address whose `runArb` the
/// harness can DELEGATECALL. Forwards to the library (which is itself
/// invoked as an internal-linked call — solc links the library into this
/// wrapper's bytecode, so `runArb` here runs in the delegatecaller's context).
contract GenericSequenceLibWrapper {
    function runArb(Op[] memory ops, address loanToken, uint256 flashRepay, uint256 loanAmount, address weth) external {
        GenericSequenceLib.runArb(ops, loanToken, flashRepay, loanAmount, weth);
    }

    function run(Op[] memory ops, address loanToken, uint256 flashRepay, address capTok, uint256 capAmt, address weth)
        external
    {
        GenericSequenceLib.run(ops, loanToken, flashRepay, capTok, capAmt, weth);
    }
}
