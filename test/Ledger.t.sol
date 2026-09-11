// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RefinementLedger} from "../src/RefinementLedger.sol";
import {Record} from "../src/interfaces/ILedgerHistory.sol";
import {Ledger} from "../src/Ledger.sol";

contract LedgerTest is Test {
    Ledger internal ledger;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    bytes32 internal constant GENESIS = bytes32("GENESIS");
    bytes32 internal constant MOVED = bytes32("MOVED");
    bytes32 internal constant NIL = bytes32(0);

    function setUp() public {
        ledger = new Ledger();
    }

    // --- the worked example from the README ----------------------------------

    function test_workedExample() public {
        uint256 a = ledger.mint(10, alice, GENESIS, NIL);
        assertEq(a, 1, "first handle is slot 1");
        assertEq(ledger.sizeOf(a), 10);

        // six of them move
        vm.prank(alice);
        uint256 moved = ledger.refine(a, 6, bob, MOVED, NIL);
        assertEq(moved, 5, "touched members take the top slots");
        assertEq(ledger.sizeOf(a), 4, "remainder keeps its handle");
        assertEq(ledger.sizeOf(moved), 6);
        assertEq(ledger.ownerOfClass(a), alice, "remainder did not change hands");
        assertEq(ledger.ownerOfClass(moved), bob);

        // three of the six are individually identified
        vm.prank(bob);
        uint256 ided = ledger.refine(moved, 3, bob, bytes32("IDENTIFIED"), NIL);
        assertEq(ided, 8);
        assertEq(ledger.sizeOf(moved), 3);
        assertEq(ledger.sizeOf(ided), 3);

        // and cut down to singletons
        vm.prank(bob);
        assertEq(ledger.refine(ided, 1, bob, bytes32("S"), NIL), 10);
        vm.prank(bob);
        assertEq(ledger.refine(ided, 1, bob, bytes32("S"), NIL), 9);

        // final partition: [1..4] [5..7] [8] [9] [10]
        assertEq(ledger.sizeOf(1), 4);
        assertEq(ledger.sizeOf(5), 3);
        assertEq(ledger.sizeOf(8), 1);
        assertEq(ledger.sizeOf(9), 1);
        assertEq(ledger.sizeOf(10), 1);

        // nothing was minted or burned after genesis
        assertEq(ledger.nextSlot(), 11);
    }

    function test_classOfResolvesEverySlot() public {
        ledger.mint(10, alice, GENESIS, NIL);
        vm.prank(alice);
        ledger.refine(1, 6, bob, MOVED, NIL);
        vm.prank(bob);
        ledger.refine(5, 3, bob, bytes32("ID"), NIL);

        for (uint256 k = 1; k <= 4; ++k) {
            assertEq(ledger.classOf(k), 1);
        }
        for (uint256 k = 5; k <= 7; ++k) {
            assertEq(ledger.classOf(k), 5);
        }
        for (uint256 k = 8; k <= 10; ++k) {
            assertEq(ledger.classOf(k), 8);
        }
    }

    function test_multipleBatchesAreDisjoint() public {
        uint256 a = ledger.mint(3, alice, GENESIS, NIL);
        uint256 b = ledger.mint(4, bob, GENESIS, NIL);
        uint256 c = ledger.mint(2, carol, GENESIS, NIL);

        assertEq(a, 1);
        assertEq(b, 4);
        assertEq(c, 8);
        assertEq(ledger.classOf(3), a);
        assertEq(ledger.classOf(4), b);
        assertEq(ledger.classOf(7), b);
        assertEq(ledger.classOf(8), c);
        assertEq(ledger.classOf(9), c);
    }

    // --- ownerOf is the misuse defence ---------------------------------------

    function test_ownerOfRevertsUntilRigid() public {
        ledger.mint(3, alice, GENESIS, NIL);

        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.NotRigid.selector, uint256(1)));
        ledger.ownerOf(1);

        // the class has an owner even though no individual slot does
        assertEq(ledger.ownerOfClass(1), alice);

        vm.prank(alice);
        uint256 s = ledger.refine(1, 1, bob, bytes32("SOLD"), NIL);
        assertEq(s, 3);
        assertEq(ledger.ownerOf(3), bob, "a rigid slot has an owner as an item");

        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.NotRigid.selector, uint256(1)));
        ledger.ownerOf(1);
    }

    // --- authority -----------------------------------------------------------

    function test_onlyHolderMayDivide() public {
        ledger.mint(5, alice, GENESIS, NIL);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.NotHolder.selector, uint256(1), bob));
        ledger.refine(1, 2, bob, MOVED, NIL);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.NotHolder.selector, uint256(1), bob));
        ledger.record(1, bytes32("X"), NIL);
    }

    function test_authorityFollowsTheDepartingClass() public {
        ledger.mint(5, alice, GENESIS, NIL);
        vm.prank(alice);
        uint256 s = ledger.refine(1, 2, bob, MOVED, NIL);

        // alice keeps the remainder, bob controls what left
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.NotHolder.selector, s, alice));
        ledger.refine(s, 1, alice, MOVED, NIL);

        vm.prank(bob);
        ledger.refine(s, 1, carol, MOVED, NIL);
    }

    // --- full-width events do not divide -------------------------------------

    function test_fullWidthRefineDoesNotCut() public {
        ledger.mint(6, alice, GENESIS, NIL);

        vm.prank(alice);
        uint256 s = ledger.refine(1, 6, bob, MOVED, NIL);

        assertEq(s, 1, "no cut when the event touched everyone");
        assertEq(ledger.sizeOf(1), 6);
        assertEq(ledger.ownerOfClass(1), bob);
        assertEq(ledger.childrenOf(1).length, 0);
        assertEq(ledger.logLengthOf(1), 2);
    }

    function test_recordChangesNothingStructural() public {
        ledger.mint(6, alice, GENESIS, NIL);

        vm.prank(alice);
        ledger.record(1, bytes32("STORED"), NIL);

        assertEq(ledger.sizeOf(1), 6);
        assertEq(ledger.ownerOfClass(1), alice);
        assertEq(ledger.logLengthOf(1), 2);
    }

    function test_divideWithoutTransferring() public {
        ledger.mint(6, alice, GENESIS, NIL);

        vm.prank(alice);
        uint256 s = ledger.refine(1, 2, alice, bytes32("TESTED"), NIL);

        assertEq(ledger.ownerOfClass(s), alice);
        assertEq(ledger.ownerOfClass(1), alice);
        assertEq(ledger.sizeOf(1), 4);
        assertEq(ledger.sizeOf(s), 2);
    }

    // --- termination ---------------------------------------------------------

    function test_terminatePartial() public {
        ledger.mint(10, alice, GENESIS, NIL);

        vm.prank(alice);
        uint256 dead = ledger.terminate(1, 2, bytes32("BROKEN"), NIL);

        assertEq(dead, 9, "dead slots go high");
        assertEq(ledger.sizeOf(1), 8);
        assertTrue(ledger.classAt(dead).terminal);
        assertEq(ledger.ownerOfClass(dead), alice, "terminal classes keep their holder");

        // frozen
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.ClassTerminal.selector, dead));
        ledger.refine(dead, 1, bob, MOVED, NIL);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.ClassTerminal.selector, dead));
        ledger.terminate(dead, 1, bytes32("AGAIN"), NIL);
    }

    function test_terminateWhole() public {
        ledger.mint(4, alice, GENESIS, NIL);

        vm.prank(alice);
        uint256 dead = ledger.terminate(1, 4, bytes32("LOST"), NIL);

        assertEq(dead, 1);
        assertTrue(ledger.classAt(1).terminal);
        assertEq(ledger.sizeOf(1), 4, "the interval survives; conservation is structural");
    }

    function test_terminalSlotsStillResolveAndKeepHistory() public {
        ledger.mint(10, alice, GENESIS, NIL);
        vm.prank(alice);
        ledger.record(1, bytes32("STORED"), NIL);
        vm.prank(alice);
        uint256 dead = ledger.terminate(1, 2, bytes32("BROKEN"), NIL);

        assertEq(ledger.classOf(10), dead);
        Record[] memory h = ledger.historyOf(10);
        assertEq(h.length, 3);
        assertEq(h[0].kind, GENESIS);
        assertEq(h[1].kind, bytes32("STORED"));
        assertEq(h[2].kind, bytes32("BROKEN"));
    }

    // --- bad input -----------------------------------------------------------

    function test_rejectsBadCounts() public {
        ledger.mint(5, alice, GENESIS, NIL);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.BadCount.selector, uint256(1), uint256(0)));
        ledger.refine(1, 0, bob, MOVED, NIL);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.BadCount.selector, uint256(1), uint256(6)));
        ledger.refine(1, 6, bob, MOVED, NIL);
    }

    function test_rejectsUnknownClassesAndSlots() public {
        ledger.mint(2, alice, GENESIS, NIL);

        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.NoSuchClass.selector, uint256(2)));
        ledger.sizeOf(2);

        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.NoSuchSlot.selector, uint256(0)));
        ledger.classOf(0);

        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.NoSuchSlot.selector, uint256(3)));
        ledger.classOf(3);
    }

    function test_rejectsZeroHolder() public {
        vm.expectRevert(RefinementLedger.ZeroHolder.selector);
        ledger.mint(1, address(0), GENESIS, NIL);
    }

    // --- history -------------------------------------------------------------

    function test_historyIsGenesisFirstAndInherited() public {
        ledger.mint(10, alice, GENESIS, NIL);
        vm.prank(alice);
        ledger.record(1, bytes32("STORED"), NIL);
        vm.prank(alice);
        uint256 moved = ledger.refine(1, 6, bob, MOVED, NIL);
        vm.prank(bob);
        uint256 ided = ledger.refine(moved, 3, bob, bytes32("IDENTIFIED"), NIL);

        Record[] memory h = ledger.historyOf(9);
        assertEq(h.length, 4);
        assertEq(h[0].kind, GENESIS);
        assertEq(h[1].kind, bytes32("STORED"));
        assertEq(h[2].kind, MOVED);
        assertEq(h[3].kind, bytes32("IDENTIFIED"));

        // a slot still anonymous in a class of four has the same history shape
        Record[] memory r = ledger.historyOf(2);
        assertEq(r.length, 2);
        assertEq(r[0].kind, GENESIS);
        assertEq(r[1].kind, bytes32("STORED"));

        assertEq(ledger.historyOfClass(ided).length, 4);
    }

    function test_factsCarryAttribution() public {
        vm.warp(1_700_000_000);
        vm.prank(carol);
        ledger.mint(2, alice, GENESIS, bytes32("doc"));

        Record[] memory h = ledger.historyOf(1);
        assertEq(h[0].author, carol, "the ledger records who said it");
        assertEq(h[0].payload, bytes32("doc"));
        assertEq(h[0].at, uint64(1_700_000_000));
    }
}
