// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RefinementCore} from "../src/RefinementCore.sol";
import {RefinementLedger} from "../src/RefinementLedger.sol";
import {LedgerLoggable} from "../src/extensions/LedgerLoggable.sol";
import {PartitionCheck} from "./helpers/PartitionCheck.sol";

/// @dev A ledger with no provenance whatsoever. If this compiles and refines
///      correctly, the algebra genuinely does not depend on facts — which is the
///      whole claim the logs extraction makes.
contract StructuralLedger is RefinementLedger {
    function mint(uint256 count, address to) external returns (uint256) {
        return _allocate(count, to);
    }

    function refine(uint256 handle, uint256 count, address to) external returns (uint256) {
        return _refine(handle, count, to);
    }

    function terminate(uint256 handle, uint256 count) external returns (uint256) {
        return _terminate(handle, count);
    }
}

/// @dev An extension that only observes. Verifies the hook chain reaches every
///      layer and that `super` ordering is preserved.
contract CountingLedger is LedgerLoggable {
    uint256 public cuts;
    uint256 public batches;
    uint256 public lastCount;

    function mint(uint256 count, address to) external returns (uint256) {
        return _allocate(count, to);
    }

    function refine(uint256 handle, uint256 count, address to) external returns (uint256) {
        return _refine(handle, count, to);
    }

    function _afterAllocate(uint256 handle, uint256 hi) internal override {
        super._afterAllocate(handle, hi);
        ++batches;
    }

    function _afterCut(uint256 parent, uint256 subject, uint256 count) internal override {
        super._afterCut(parent, subject, count);
        ++cuts;
        lastCount = count;

        // the layers below have already run: index and snapshot are in place
        assertIndexed(parent, subject);
    }

    function assertIndexed(uint256 parent, uint256 subject) internal view {
        uint256[] storage kids = _children[parent];
        require(kids[kids.length - 1] == subject, "index not written before this hook");
    }
}

contract ExtensionTest is PartitionCheck {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    /// The core carries the whole worked example with no log layer present.
    function test_coreRefinesWithoutAnyProvenance() public {
        StructuralLedger l = new StructuralLedger();

        uint256 a = l.mint(10, alice);
        assertEq(a, 1);

        vm.prank(alice);
        uint256 moved = l.refine(a, 6, bob);
        assertEq(moved, 5, "gauge policy is core, not a log concern");
        assertEq(l.sizeOf(a), 4);

        vm.prank(bob);
        uint256 ided = l.refine(moved, 3, bob);
        assertEq(ided, 8);

        vm.prank(bob);
        assertEq(l.refine(ided, 1, bob), 10);
        vm.prank(bob);
        assertEq(l.refine(ided, 1, bob), 9);

        assertTiles(l, a, 10);
        assertEq(l.classOf(6), 5);
        assertTrue(l.isRigid(9));
        assertEq(l.ownerOf(9), bob);
        assertEq(l.nextSlot(), 11);
    }

    function test_coreTerminatesWithoutAnyProvenance() public {
        StructuralLedger l = new StructuralLedger();
        uint256 a = l.mint(6, alice);

        vm.prank(alice);
        uint256 dead = l.terminate(a, 2);

        assertEq(dead, 5);
        assertTrue(l.classAt(dead).terminal);
        assertTiles(l, a, 6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RefinementCore.ClassTerminal.selector, dead));
        l.refine(dead, 1, bob);
    }

    /// Hooks reach every layer, bottom-up.
    function test_hookChainRunsThroughEveryLayer() public {
        CountingLedger l = new CountingLedger();

        uint256 a = l.mint(8, alice);
        assertEq(l.batches(), 1);
        assertEq(l.cuts(), 0);

        vm.prank(alice);
        uint256 s = l.refine(a, 3, bob);

        assertEq(l.cuts(), 1);
        assertEq(l.lastCount(), 3);
        assertEq(l.childrenOf(a)[0], s, "core index");
        assertEq(l.parentLogLenOf(s), 0, "log snapshot");

        // full-width refine distinguishes nobody, so no cut and no hook
        vm.prank(bob);
        l.refine(s, 3, alice);
        assertEq(l.cuts(), 1, "a full-width event must not cut");
    }

    /// The snapshot is taken by the hook, so it is correct even when the concrete
    /// contract never calls it — the point of putting invariants in hooks.
    function test_snapshotIsTakenWithoutTheEntryPointAskingForIt() public {
        CountingLedger l = new CountingLedger();
        uint256 a = l.mint(10, alice);

        vm.prank(alice);
        uint256 first = l.refine(a, 2, alice);
        assertEq(l.parentLogLenOf(first), 0);

        // CountingLedger has no way to append facts at all, yet every cut still
        // records where the parent's log stood.
        vm.prank(alice);
        uint256 second = l.refine(a, 2, alice);
        assertEq(l.parentLogLenOf(second), 0);
        assertEq(l.historyOfClass(second).length, 0);
    }
}
