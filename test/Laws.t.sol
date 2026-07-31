// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RefinementLedger} from "../src/RefinementLedger.sol";
import {LedgerLoggable} from "../src/extensions/LedgerLoggable.sol";
import {Ledger} from "../src/Ledger.sol";
import {PartitionCheck} from "./helpers/PartitionCheck.sol";

/// @dev The five laws from the README, made executable.
contract LawsTest is PartitionCheck {
    Ledger internal ledger;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    bytes32 internal constant GENESIS = bytes32("GENESIS");
    bytes32 internal constant MOVED = bytes32("MOVED");
    bytes32 internal constant NIL = bytes32(0);

    function setUp() public {
        ledger = new Ledger();
    }

    // --- Law 1 + 2: conservation and refinement ------------------------------

    function testFuzz_law1_partitionAlwaysTiles(uint256 size, uint256[8] memory counts) public {
        size = bound(size, 1, 40);
        uint256 root = ledger.mint(size, alice, GENESIS, NIL);

        uint256[] memory handles = new uint256[](counts.length + 1);
        handles[0] = root;
        uint256 n = 1;

        for (uint256 i; i < counts.length; ++i) {
            uint256 h = handles[counts[i] % n];
            RefinementLedger.Class memory c = ledger.classAt(h);
            if (c.terminal) continue;

            uint256 sz = c.hi - h + 1;
            uint256 count = (counts[i] % sz) + 1;

            vm.prank(c.owner);
            uint256 s = (i % 4 == 3)
                ? ledger.terminate(h, count, bytes32("T"), NIL)
                : ledger.refine(h, count, i % 2 == 0 ? bob : alice, MOVED, NIL);

            if (s != h) handles[n++] = s;
            assertTiles(ledger, root, size);
        }

        assertEq(ledger.nextSlot(), root + size, "slots were created or destroyed after genesis");
    }

    function testFuzz_law2_classesOnlyShrink(uint256 size, uint256 count) public {
        size = bound(size, 2, 40);
        count = bound(count, 1, size - 1);

        uint256 h = ledger.mint(size, alice, GENESIS, NIL);
        RefinementLedger.Class memory before = ledger.classAt(h);

        vm.prank(alice);
        uint256 s = ledger.refine(h, count, bob, MOVED, NIL);

        RefinementLedger.Class memory afterCut = ledger.classAt(h);
        assertLt(afterCut.hi, before.hi, "hi did not shrink");
        assertEq(afterCut.birthHi, before.birthHi, "birthHi moved");
        assertEq(ledger.sizeOf(h), size - count);
        assertEq(ledger.sizeOf(s), count);
        assertGt(s, h, "the departing handle must sit above the remainder");
        assertEq(ledger.classAt(s).birthHi, before.hi, "departing class must inherit the old high bound");
    }

    // --- Law 3: gauge invariance ---------------------------------------------

    /// The gauge is a function of cardinality and count alone. Not of the caller,
    /// not of the timestamp, not of the destination. There is no argument anywhere
    /// in the API by which a caller could name *which* members depart, which is
    /// what makes within-class permutation unobservable.
    function testFuzz_law3_gaugeDependsOnCardinalityAlone(
        uint256 size,
        uint256 count,
        address caller,
        address to,
        uint64 time
    ) public {
        size = bound(size, 2, 40);
        count = bound(count, 1, size - 1);
        vm.assume(caller != address(0) && to != address(0));
        vm.warp(time);

        uint256 h = ledger.mint(size, caller, GENESIS, NIL);
        uint256 hi = ledger.classAt(h).hi;

        vm.prank(caller);
        uint256 s = ledger.refine(h, count, to, MOVED, NIL);

        assertEq(s, hi - count + 1, "gauge policy is not fixed by cardinality alone");
    }

    /// Same counts, different callers, holders and timestamps: identical partition.
    function testFuzz_law3_ledgerIsCanonical(uint256 size, uint256[6] memory counts) public {
        size = bound(size, 1, 40);

        Ledger a = new Ledger();
        Ledger b = new Ledger();

        uint256 rootA = _drive(a, size, counts, alice, bob, 1_000);
        uint256 rootB = _drive(b, size, counts, bob, alice, 9_999_999);

        assertEq(partitionDigest(a, rootA), partitionDigest(b, rootB), "identical counts produced different partitions");
    }

    function _drive(Ledger l, uint256 size, uint256[6] memory counts, address owner, address to, uint64 time)
        internal
        returns (uint256 root)
    {
        vm.warp(time);
        root = l.mint(size, owner, GENESIS, NIL);

        uint256[] memory handles = new uint256[](counts.length + 1);
        handles[0] = root;
        uint256 n = 1;

        for (uint256 i; i < counts.length; ++i) {
            uint256 h = handles[counts[i] % n];
            RefinementLedger.Class memory c = l.classAt(h);
            uint256 sz = c.hi - h + 1;
            uint256 count = (counts[i] % sz) + 1;

            vm.prank(c.owner);
            uint256 s = l.refine(h, count, to, MOVED, NIL);
            if (s != h) handles[n++] = s;
        }
    }

    // --- Law 4: rigidity is monotone -----------------------------------------

    function test_law4_rigidityIsMonotone() public {
        uint256 h = ledger.mint(4, alice, GENESIS, NIL);

        vm.prank(alice);
        uint256 s = ledger.refine(h, 1, alice, bytes32("PICKED"), NIL);
        assertTrue(ledger.isRigid(s));

        // a rigid class cannot be divided further
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.BadCount.selector, s, uint256(2)));
        ledger.refine(s, 2, bob, MOVED, NIL);

        // and every operation it still accepts leaves it rigid
        vm.prank(alice);
        ledger.record(s, bytes32("APPRAISED"), NIL);
        assertTrue(ledger.isRigid(s));

        vm.prank(alice);
        ledger.refine(s, 1, bob, bytes32("SOLD"), NIL);
        assertTrue(ledger.isRigid(s));
        assertEq(ledger.ownerOf(s), bob);

        vm.prank(bob);
        ledger.terminate(s, 1, bytes32("CONSUMED"), NIL);
        assertTrue(ledger.isRigid(s), "a terminal singleton is still a singleton");
    }

    // --- Law 5: cut invariance -----------------------------------------------

    /// The headline law. A cut must leave the reconstructed history of every
    /// non-departing slot byte-identical: the set changed cardinality, its members
    /// did not change history. A member cannot observe the departure of another
    /// member.
    function testFuzz_law5_cutDoesNotTouchTheRemainder(uint256 size, uint256 count, uint256 facts) public {
        size = bound(size, 2, 30);
        count = bound(count, 1, size - 1);
        facts = bound(facts, 0, 5);

        uint256 h = ledger.mint(size, alice, GENESIS, NIL);
        for (uint256 i; i < facts; ++i) {
            vm.prank(alice);
            ledger.record(h, bytes32(i + 1), NIL);
        }

        uint256 remaining = size - count;
        bytes32[] memory before = new bytes32[](remaining);
        for (uint256 k; k < remaining; ++k) {
            before[k] = keccak256(abi.encode(ledger.historyOf(h + k)));
        }
        uint256 logLenBefore = ledger.logLengthOf(h);

        vm.prank(alice);
        ledger.refine(h, count, bob, MOVED, NIL);

        for (uint256 k; k < remaining; ++k) {
            assertEq(keccak256(abi.encode(ledger.historyOf(h + k))), before[k], "a cut modified a non-departing slot");
        }
        assertEq(ledger.logLengthOf(h), logLenBefore, "a cut appended to the remainder's log");
    }

    /// Same law, stated the other way: destroying one item must not touch the nine
    /// that survived it.
    function test_law5_deathOfOneDoesNotTouchTheOthers() public {
        uint256 h = ledger.mint(10, alice, GENESIS, NIL);
        vm.prank(alice);
        ledger.record(h, bytes32("STORED"), NIL);

        bytes32[] memory before = new bytes32[](9);
        for (uint256 k; k < 9; ++k) {
            before[k] = keccak256(abi.encode(ledger.historyOf(h + k)));
        }

        vm.prank(alice);
        ledger.terminate(h, 1, bytes32("BROKEN"), NIL);

        for (uint256 k; k < 9; ++k) {
            assertEq(keccak256(abi.encode(ledger.historyOf(h + k))), before[k], "a survivor's history changed");
        }
        assertEq(ledger.logLengthOf(h), 2, "the survivors' log grew");
        assertEq(ledger.historyOf(h + 9).length, 3, "the departed item did not record its own end");
    }

    /// History length tracks what happened to you, not churn around you.
    function test_law5_historyDoesNotGrowWithSiblingChurn() public {
        uint256 h = ledger.mint(50, alice, GENESIS, NIL);

        for (uint256 i; i < 40; ++i) {
            vm.prank(alice);
            ledger.refine(h, 1, bob, bytes32("SOLD"), NIL);
        }

        assertEq(ledger.sizeOf(h), 10);
        assertEq(ledger.historyOf(h).length, 1, "forty sibling departures lengthened an untouched history");
    }

    // --- snapshots -----------------------------------------------------------

    /// A class that departed must not inherit facts its parent accrued afterwards.
    function test_departedClassDoesNotSeeLaterParentFacts() public {
        uint256 h = ledger.mint(10, alice, GENESIS, NIL);

        vm.prank(alice);
        uint256 s = ledger.refine(h, 4, bob, MOVED, NIL);

        vm.prank(alice);
        ledger.record(h, bytes32("LATER"), NIL);

        LedgerLoggable.Fact[] memory child = ledger.historyOfClass(s);
        assertEq(child.length, 2);
        assertEq(child[0].kind, GENESIS);
        assertEq(child[1].kind, MOVED);

        LedgerLoggable.Fact[] memory parent = ledger.historyOfClass(h);
        assertEq(parent.length, 2);
        assertEq(parent[0].kind, GENESIS);
        assertEq(parent[1].kind, bytes32("LATER"));
    }
}
