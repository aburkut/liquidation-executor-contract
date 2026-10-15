// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArbBatchTest, PricedV3Pool} from "./ArbBatch.t.sol";

/// Gas of the version-4 entry points against `executePacked`, the same
/// winning plan through each, every run from the same pre-state.
contract ArbBatchGasTest is ArbBatchTest {
    function _gas(bytes memory call) internal returns (uint256 used) {
        vm.prank(operatorAddr);
        uint256 g = gasleft();
        (bool ok,) = address(exec).call(call);
        used = g - gasleft();
        require(ok || call.length == 0, "call failed");
    }

    function test_gas_of_the_new_entry_points() public {
        PricedV3Pool open = _pool(WIN);
        PricedV3Pool unmoved = _pool(WIN);
        unmoved.setPrice(1e30);
        bytes memory win = _cycle(address(open), address(_pool(WIN)), 0, 0);
        bytes memory idle = _cycle(address(unmoved), address(_pool(WIN)), 1.5e30, 0);
        bytes memory lose = _cycle(address(_pool(WIN)), address(_pool(LOSE)), 0, 0);
        uint256 s = vm.snapshotState();

        uint256 packed = _gas(abi.encodeWithSelector(exec.executePacked.selector, win));
        vm.revertToState(s);
        uint256 before = _gas(abi.encodeWithSelector(exec.executePackedBefore.selector, type(uint64).max, win));
        vm.revertToState(s);
        bytes[] memory one = new bytes[](1);
        one[0] = win;
        uint256 batch1 = _gas(abi.encodeWithSelector(exec.executeBatch.selector, type(uint64).max, 0, one));
        vm.revertToState(s);
        bytes[] memory two = new bytes[](2);
        two[0] = idle;
        two[1] = win;
        uint256 batchIdle = _gas(abi.encodeWithSelector(exec.executeBatch.selector, type(uint64).max, 0, two));
        vm.revertToState(s);
        two[0] = lose;
        uint256 batchLose = _gas(abi.encodeWithSelector(exec.executeBatch.selector, type(uint64).max, 0, two));
        vm.revertToState(s);
        bytes[] memory wins = new bytes[](2);
        wins[0] = win;
        wins[1] = _cycle(address(_pool(WIN)), address(_pool(WIN)), 0, 0);
        uint256 batch2 = _gas(abi.encodeWithSelector(exec.executeBatch.selector, type(uint64).max, 0, wins));
        vm.revertToState(s);
        vm.roll(100);
        vm.prank(operatorAddr);
        uint256 g = gasleft();
        (bool ok,) = address(exec).call(abi.encodeWithSelector(exec.executePackedBefore.selector, 99, win));
        uint256 late = g - gasleft();
        assertFalse(ok);

        emit log_named_uint("executePacked (one winning plan)", packed);
        emit log_named_uint("executePackedBefore (same plan)", before);
        emit log_named_uint("executeBatch [win]", batch1);
        emit log_named_uint("executeBatch [idle, win]", batchIdle);
        emit log_named_uint("executeBatch [lose, win]", batchLose);
        emit log_named_uint("executeBatch [win, win]", batch2);
        emit log_named_uint("executePackedBefore past the deadline", late);
    }
}
