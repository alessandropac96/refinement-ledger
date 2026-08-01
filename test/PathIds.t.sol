// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RefinementLedger} from "../src/RefinementLedger.sol";
import {Ledger} from "../src/Ledger.sol";

/// @dev Tests for the intrinsic-naming spike. They check the *concepts* the idea
///      turns on, not the arithmetic of any particular construction: if we later
///      swap how a name is folded, these should still say the same things.
contract PathIdsTest is Test {
    Ledger internal ledger;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    bytes32 internal constant NIL = bytes32(0);

    function setUp() public {
        ledger = new Ledger();
    }

    /// A name is a statement about shape, not a pointer into state: given the
    /// root's name and the trajectory, anyone recomputes it with no access to the
    /// ledger at all. Recomputed here by hand rather than through the contract's
    /// helper, so nothing of the ledger is involved in the check.
    function test_aNameIsVerifiableWithoutTheLedger() public {
        uint256 a = ledger.mint(10, alice, bytes32("GENESIS"), NIL);
        vm.prank(alice);
        uint256 moved = ledger.refine(a, 6, bob, bytes32("MOVED"), NIL);
        vm.prank(bob);
        uint256 ided = ledger.refine(moved, 3, bob, bytes32("IDENTIFIED"), NIL);
        vm.prank(bob);
        uint256 one = ledger.refine(ided, 1, bob, bytes32("SOLD"), NIL);

        bytes32 rootName = ledger.rootNameOf(a);
        uint256[] memory path = ledger.pathOf(one);

        bytes32 recomputed = rootName;
        for (uint256 i; i < path.length; ++i) {
            recomputed = keccak256(abi.encode(recomputed, path[i]));
        }

        assertEq(recomputed, ledger.nameOf(one), "a name is not derivable from its trajectory");
        assertEq(ledger.nameFromPath(rootName, path), ledger.nameOf(one));
    }

    /// Law 5, at the level of names. An event that touched other members must not
    /// rename the ones it did not touch.
    function test_remainderKeepsItsNameWhenASiblingDeparts() public {
        uint256 a = ledger.mint(10, alice, bytes32("GENESIS"), NIL);
        bytes32 before = ledger.nameOf(a);

        vm.prank(alice);
        ledger.refine(a, 3, bob, bytes32("MOVED"), NIL);
        assertEq(ledger.nameOf(a), before, "a departure renamed the remainder");

        vm.prank(alice);
        ledger.refine(a, 2, bob, bytes32("MOVED"), NIL);
        assertEq(ledger.nameOf(a), before, "a second departure renamed the remainder");

        vm.prank(alice);
        ledger.terminate(a, 1, bytes32("BROKEN"), NIL);
        assertEq(ledger.nameOf(a), before, "a death renamed the survivors");
    }

    /// A class nothing ever happened to has an empty trajectory, so it keeps the
    /// root's name however much churn happens around it. Nothing distinguishes
    /// it, so nothing should name it apart.
    function test_anUntouchedClassKeepsTheRootName() public {
        uint256 a = ledger.mint(12, alice, bytes32("GENESIS"), NIL);
        bytes32 rootName = ledger.rootNameOf(a);

        assertEq(ledger.pathOf(a).length, 0);
        assertEq(ledger.nameOf(a), rootName);

        vm.prank(alice);
        uint256 s = ledger.refine(a, 5, bob, bytes32("MOVED"), NIL);
        vm.prank(bob);
        uint256 t = ledger.refine(s, 2, bob, bytes32("SPLIT"), NIL);
        vm.prank(bob);
        ledger.refine(t, 1, alice, bytes32("SOLD"), NIL);

        assertEq(ledger.nameOf(a), rootName, "churn elsewhere renamed an untouched class");
        assertEq(ledger.nameOfSlot(1), rootName, "a slot nothing happened to changed name");
    }

    /// Extrinsic names depend on global allocation order; intrinsic ones depend
    /// only on the shape of the refinement. Same distinctions drawn, in ledgers
    /// that allocated their batches in opposite orders — the handles differ, the
    /// trajectories do not, and neither do the names those trajectories fold to.
    function test_namesFollowShapeNotAllocationOrder() public {
        Ledger first = new Ledger();
        Ledger second = new Ledger();

        // first: the batch we care about is allocated before the other one
        uint256 subjectA = first.mint(10, alice, bytes32("GENESIS"), NIL);
        first.mint(4, bob, bytes32("GENESIS"), NIL);

        // second: the same batch, allocated after
        second.mint(4, bob, bytes32("GENESIS"), NIL);
        uint256 subjectB = second.mint(10, alice, bytes32("GENESIS"), NIL);

        uint256 leafA = _drive(first, subjectA);
        uint256 leafB = _drive(second, subjectB);

        assertTrue(leafA != leafB, "the two ledgers should disagree on the extrinsic name");

        uint256[] memory pathA = first.pathOf(leafA);
        uint256[] memory pathB = second.pathOf(leafB);
        assertEq(pathA.length, pathB.length, "same shape, different trajectory length");
        for (uint256 i; i < pathA.length; ++i) {
            assertEq(pathA[i], pathB[i], "allocation order leaked into the trajectory");
        }

        // Everything below a root is pure shape, so with a common root the names
        // agree exactly. What a root should be bound to is the open question.
        bytes32 shared = keccak256("some agreed root");
        assertEq(
            first.nameFromPath(shared, pathA),
            second.nameFromPath(shared, pathB),
            "identical refinements produced different intrinsic names"
        );
    }

    /// Divergences from the same parent are distinguished, so classes that are
    /// genuinely different are named differently.
    function test_siblingsAreNamedApart() public {
        uint256 a = ledger.mint(9, alice, bytes32("GENESIS"), NIL);

        vm.prank(alice);
        uint256 x = ledger.refine(a, 3, bob, bytes32("MOVED"), NIL);
        vm.prank(alice);
        uint256 y = ledger.refine(a, 3, bob, bytes32("MOVED"), NIL);

        assertTrue(ledger.nameOf(x) != ledger.nameOf(y), "siblings share a name");
        assertTrue(ledger.nameOf(x) != ledger.nameOf(a), "a departure shares its parent's name");

        assertEq(ledger.pathOf(x)[0], 0);
        assertEq(ledger.pathOf(y)[0], 1);
    }

    /// A name denotes a class. It denotes an element exactly when the class is a
    /// singleton — the same boundary `ownerOf` enforces, for the same reason.
    function test_aNameIsAnElementNameOnlyAtCardinalityOne() public {
        uint256 a = ledger.mint(3, alice, bytes32("GENESIS"), NIL);

        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.NotRigid.selector, uint256(1)));
        ledger.elementNameOf(1);

        // but the class it sits in is nameable, and the name is shared
        assertEq(ledger.nameOfSlot(1), ledger.nameOfSlot(2), "members of a class must share a name");

        vm.prank(alice);
        uint256 s = ledger.refine(a, 1, bob, bytes32("SOLD"), NIL);
        assertEq(ledger.elementNameOf(s), ledger.nameOf(s), "a singleton's class name is its element name");

        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.NotRigid.selector, uint256(1)));
        ledger.elementNameOf(1);
    }

    /// The name space is exactly the set of distinctions drawn: every live class
    /// in the worked example gets its own name, and there are no others.
    function test_liveClassesAreNamedDistinctly() public {
        uint256 a = ledger.mint(10, alice, bytes32("GENESIS"), NIL);
        vm.prank(alice);
        uint256 moved = ledger.refine(a, 6, bob, bytes32("MOVED"), NIL);
        vm.prank(bob);
        uint256 ided = ledger.refine(moved, 3, bob, bytes32("IDENTIFIED"), NIL);
        vm.prank(bob);
        uint256 p = ledger.refine(ided, 1, bob, bytes32("SOLD"), NIL);
        vm.prank(bob);
        uint256 q = ledger.refine(ided, 1, bob, bytes32("SOLD"), NIL);

        uint256[5] memory live = [a, moved, ided, p, q];
        for (uint256 i; i < 5; ++i) {
            for (uint256 j = i + 1; j < 5; ++j) {
                assertTrue(ledger.nameOf(live[i]) != ledger.nameOf(live[j]), "two live classes share a name");
            }
        }
    }

    function test_rejectsUnknownClasses() public {
        ledger.mint(2, alice, bytes32("GENESIS"), NIL);

        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.NoSuchClass.selector, uint256(2)));
        ledger.nameOf(2);

        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.NoSuchClass.selector, uint256(2)));
        ledger.pathOf(2);
    }

    /// Same refinements, whatever the batch's handle happens to be.
    function _drive(Ledger l, uint256 handle) internal returns (uint256 leaf) {
        vm.prank(alice);
        uint256 s = l.refine(handle, 6, bob, bytes32("MOVED"), NIL);
        vm.prank(bob);
        leaf = l.refine(s, 3, bob, bytes32("IDENTIFIED"), NIL);
    }
}
