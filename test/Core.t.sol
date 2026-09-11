// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RefinementCore} from "../src/RefinementCore.sol";

/// @dev The algebra with nothing attached: no LOGs, no holder, no index. If the
///      laws hold here they hold for every composition, because compositions
///      only ever observe.
contract BareCore is RefinementCore {
    uint256 public allocations;
    uint256 public cuts;
    uint256 public terminations;

    function allocate(uint256 count) external returns (uint256) {
        return _allocate(count);
    }

    function touch(uint256 handle, uint256 count) external returns (uint256) {
        return _touch(handle, count);
    }

    function terminate(uint256 handle, uint256 count) external returns (uint256) {
        return _terminate(handle, count);
    }

    function _afterAllocate(uint256 handle, uint256 hi) internal override {
        super._afterAllocate(handle, hi);
        ++allocations;
    }

    function _afterCut(uint256 parent, uint256 subject, uint256 count) internal override {
        super._afterCut(parent, subject, count);
        ++cuts;
    }

    function _afterTerminate(uint256 subject) internal override {
        super._afterTerminate(subject);
        ++terminations;
    }
}

contract CoreTest is Test {
    BareCore internal core;

    function setUp() public {
        core = new BareCore();
    }

    /// Law 1: classes descending from a root tile its interval exactly.
    function test_law1_cutsTileTheLot() public {
        uint256 a = core.allocate(10);
        assertEq(a, 1);

        uint256 moved = core.touch(a, 6);
        assertEq(moved, 5, "departing members take the top slots");
        assertEq(core.sizeOf(a), 4);
        assertEq(core.sizeOf(moved), 6);

        uint256 ided = core.touch(moved, 3);
        assertEq(ided, 8);
        assertEq(core.touch(ided, 1), 10);
        assertEq(core.touch(ided, 1), 9);
        assertEq(core.sizeOf(ided), 1);

        // [1..4] [5..7] [8] [9] [10]
        assertEq(core.hiOf(a), 4);
        assertEq(core.hiOf(moved), 7);
        assertEq(core.hiOf(ided), 8);
        assertEq(core.hiOf(9), 9);
        assertEq(core.hiOf(10), 10);
        assertEq(core.nextSlot(), 11);
    }

    /// Law 2: a full-width touch changes nothing and fires no hook.
    function test_law2_fullWidthTouchIsStructurallySilent() public {
        uint256 a = core.allocate(4);
        assertEq(core.touch(a, 4), a);
        assertEq(core.cuts(), 0);
        assertEq(core.sizeOf(a), 4);
    }

    /// Law 3: lineage is upward pointers only; the root is recoverable by walking.
    function test_law3_lineageWalksToTheRoot() public {
        uint256 a = core.allocate(8);
        uint256 s = core.touch(a, 5);
        uint256 t = core.touch(s, 2);

        assertEq(core.parentOf(a), 0);
        assertEq(core.parentOf(s), a);
        assertEq(core.parentOf(t), s);
        assertEq(core.rootOf(t), a);
        assertEq(core.rootOf(a), a);
    }

    /// Law 4: a rigid class cannot be cut; it can only be touched in full.
    function test_law4_rigidClassesOnlyAcceptFullTouches() public {
        uint256 a = core.allocate(2);
        uint256 s = core.touch(a, 1);
        assertEq(core.sizeOf(s), 1);

        vm.expectRevert(abi.encodeWithSelector(RefinementCore.BadCount.selector, s, 2));
        core.touch(s, 2);
        assertEq(core.touch(s, 1), s);
    }

    function test_terminalClassesFreezeAndKeepTheirInterval() public {
        uint256 a = core.allocate(6);
        uint256 dead = core.terminate(a, 2);

        assertEq(dead, 5);
        assertTrue(core.isTerminal(dead));
        assertEq(core.sizeOf(dead), 2, "terminal classes are not compacted");
        assertEq(core.terminations(), 1);

        vm.expectRevert(abi.encodeWithSelector(RefinementCore.ClassTerminal.selector, dead));
        core.touch(dead, 1);
    }

    function test_hooksFireOncePerTransition() public {
        uint256 a = core.allocate(5);
        core.touch(a, 2);
        core.terminate(a, 1);

        assertEq(core.allocations(), 1);
        assertEq(core.cuts(), 2, "terminate of a partial count is also a cut");
        assertEq(core.terminations(), 1);
    }

    function test_rejectsUnknownAndZero() public {
        vm.expectRevert(abi.encodeWithSelector(RefinementCore.BadCount.selector, 0, 0));
        core.allocate(0);

        vm.expectRevert(abi.encodeWithSelector(RefinementCore.NoSuchClass.selector, 7));
        core.touch(7, 1);

        assertFalse(core.exists(0));
        assertFalse(core.exists(1));
    }

    function test_slotSpaceIsBoundedByThePackedWidth() public {
        core.allocate(type(uint120).max - 1);
        vm.expectRevert(RefinementCore.SlotOverflow.selector);
        core.allocate(2);
        assertEq(core.allocate(1), type(uint120).max);
    }

    function testFuzz_conservation(uint8 size, uint8[8] calldata counts) public {
        uint256 n = bound(size, 1, 64);
        uint256 a = core.allocate(n);

        uint256[] memory live = new uint256[](64);
        uint256 liveCount = 1;
        live[0] = a;

        for (uint256 i; i < counts.length; ++i) {
            uint256 h = live[counts[i] % liveCount];
            uint256 c = (counts[i] % core.sizeOf(h)) + 1;
            uint256 s = core.touch(h, c);
            if (s != h) live[liveCount++] = s;
        }

        uint256 total;
        for (uint256 i; i < liveCount; ++i) {
            total += core.sizeOf(live[i]);
        }
        assertEq(total, n, "members were invented or lost");
    }
}
