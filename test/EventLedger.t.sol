// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RefinementLedger} from "../src/RefinementLedger.sol";
import {LedgerEvents} from "../src/extensions/LedgerEvents.sol";
import {EventLedger} from "../src/EventLedger.sol";

/// @dev Tests for the event-first draft. Each one targets a claim the concept
///      makes, so they should survive a change of mechanics.
contract EventLedgerTest is Test {
    EventLedger internal ledger;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    bytes32 internal constant NIL = bytes32(0);

    function setUp() public {
        ledger = new EventLedger();
    }

    // --- one occurrence, one identity ----------------------------------------

    /// The structural claim: something that reaches three classes is one event,
    /// not three. Under the old shape this was three unrelated facts.
    function test_oneOccurrenceReachingManyClassesHasOneIdentity() public {
        (uint256 a,) = ledger.mint(12, alice, bytes32("GENESIS"), NIL);

        vm.prank(alice);
        (, uint256[] memory first) = ledger.occur(bytes32("SPLIT"), NIL, _one(a, 4, alice, false));
        uint256 b = first[0];

        vm.prank(alice);
        (, uint256[] memory second) = ledger.occur(bytes32("SPLIT"), NIL, _one(a, 3, alice, false));
        uint256 c = second[0];

        // three live classes, all alice's
        EventLedger.Touch[] memory flood = new EventLedger.Touch[](3);
        flood[0] = EventLedger.Touch(a, 2, alice, false);
        flood[1] = EventLedger.Touch(b, 4, alice, false);
        flood[2] = EventLedger.Touch(c, 1, alice, false);

        vm.prank(alice);
        (uint256 id, uint256[] memory subjects) = ledger.occur(bytes32("FLOOD"), NIL, flood);

        assertEq(ledger.eventCount(), 4, "one flood, one event");
        for (uint256 i; i < 3; ++i) {
            uint256[] memory t = ledger.touchesOf(subjects[i]);
            assertEq(t[t.length - 1], id, "a class the flood reached does not carry its id");
        }
    }

    // --- identity is the discriminating quotient of history -------------------

    /// A full-width event changes what is known and not who anyone is. This is
    /// the concept's load-bearing claim.
    function test_aFullWidthEventMovesHistoryButNotIdentity() public {
        (uint256 a,) = ledger.mint(6, alice, bytes32("GENESIS"), NIL);

        bytes32 nameBefore = ledger.nameOf(a);
        uint256 historyBefore = ledger.historyOfClass(a).length;
        uint256 discBefore = ledger.discriminantsOf(a).length;

        vm.prank(alice);
        ledger.occur(bytes32("STORED"), NIL, _one(a, 6, alice, false));

        assertEq(ledger.nameOf(a), nameBefore, "an event that told nobody apart moved an identity");
        assertEq(ledger.discriminantsOf(a).length, discBefore, "a full-width event added a discriminant");
        assertEq(ledger.historyOfClass(a).length, historyBefore + 1, "history did not grow");
    }

    /// And an event that does tell members apart moves the identity of exactly
    /// those it separated.
    function test_aDiscriminatingEventMovesOnlyTheIdentityItSeparated() public {
        (uint256 a,) = ledger.mint(10, alice, bytes32("GENESIS"), NIL);
        bytes32 nameBefore = ledger.nameOf(a);

        vm.prank(alice);
        (uint256 id, uint256[] memory subjects) = ledger.occur(bytes32("MOVED"), NIL, _one(a, 6, bob, false));
        uint256 moved = subjects[0];

        assertTrue(moved != a, "a partial event should have divided the class");
        assertEq(ledger.nameOf(a), nameBefore, "the remainder was renamed by an event that missed it");
        assertTrue(ledger.nameOf(moved) != nameBefore, "the departing class kept its old identity");
        assertEq(ledger.birthEventOf(moved), id, "the discriminant is not the event that did the work");
    }

    /// Law 5, now at the level of both history and identity.
    function test_anEventThatMissedYouLeavesNoTrace() public {
        (uint256 a,) = ledger.mint(10, alice, bytes32("GENESIS"), NIL);

        bytes32 name = ledger.nameOf(a);
        uint256 len = ledger.historyOfClass(a).length;
        uint256 touches = ledger.touchesOf(a).length;

        vm.prank(alice);
        ledger.occur(bytes32("MOVED"), NIL, _one(a, 3, bob, false));
        vm.prank(alice);
        ledger.occur(bytes32("BROKEN"), NIL, _one(a, 2, alice, true));

        assertEq(ledger.nameOf(a), name, "identity moved");
        assertEq(ledger.historyOfClass(a).length, len, "history grew");
        assertEq(ledger.touchesOf(a).length, touches, "an event was recorded against the untouched");
    }

    // --- rigidity is a fixed point -------------------------------------------

    /// Once a class is a singleton nothing can divide it again, so it can never
    /// gain another discriminant. Law 4 stops being maintained and becomes true.
    function test_rigidityFreezesIdentity() public {
        (uint256 a,) = ledger.mint(4, alice, bytes32("GENESIS"), NIL);

        vm.prank(alice);
        (, uint256[] memory s) = ledger.occur(bytes32("SOLD"), NIL, _one(a, 1, bob, false));
        uint256 one = s[0];

        assertEq(ledger.sizeOf(one), 1);
        bytes32 frozen = ledger.nameOf(one);

        // everything that can still happen to it is necessarily full-width
        vm.prank(bob);
        ledger.occur(bytes32("SHIPPED"), NIL, _one(one, 1, bob, false));
        vm.prank(bob);
        ledger.occur(bytes32("TASTED"), NIL, _one(one, 1, alice, false));

        assertEq(ledger.nameOf(one), frozen, "a rigid class was renamed");
        assertEq(ledger.historyOfClass(one).length, 4, "its history should still accumulate");
    }

    // --- history without a snapshot index ------------------------------------

    /// A departed class must not inherit what its parent accrued afterwards.
    /// Nothing stores that boundary: the birth event is the boundary.
    function test_aDepartedClassDoesNotInheritLaterParentEvents() public {
        (uint256 a,) = ledger.mint(10, alice, bytes32("GENESIS"), NIL);

        vm.prank(alice);
        ledger.occur(bytes32("EARLY"), NIL, _one(a, 10, alice, false));

        vm.prank(alice);
        (, uint256[] memory s) = ledger.occur(bytes32("DEPARTED"), NIL, _one(a, 4, bob, false));
        uint256 gone = s[0];

        vm.prank(alice);
        ledger.occur(bytes32("LATE"), NIL, _one(a, 6, alice, false));

        LedgerEvents.Event[] memory h = ledger.historyOfClass(gone);
        assertEq(h.length, 3);
        assertEq(h[0].kind, bytes32("GENESIS"));
        assertEq(h[1].kind, bytes32("EARLY"));
        assertEq(h[2].kind, bytes32("DEPARTED"), "a departed class saw a later parent event");

        // the parent kept accruing, and is one longer
        assertEq(ledger.historyOfClass(a).length, 3);
        assertEq(ledger.historyOfClass(a)[2].kind, bytes32("LATE"));
    }

    function test_historyReachesEverySlotIncludingAnonymousOnes() public {
        (uint256 a,) = ledger.mint(10, alice, bytes32("GENESIS"), NIL);
        vm.prank(alice);
        ledger.occur(bytes32("MOVED"), NIL, _one(a, 6, bob, false));

        assertEq(ledger.historyOf(1).length, 1, "an untouched slot has only its genesis");
        assertEq(ledger.historyOf(10).length, 2);
        assertEq(ledger.historyOf(10)[1].kind, bytes32("MOVED"));
    }

    // --- the crack, made explicit --------------------------------------------

    /// One event cutting one class twice would give both children the same
    /// chain of discriminants, and therefore the same identity. Refused rather
    /// than silently collided.
    function test_oneEventMayNotReachTheSameClassTwice() public {
        (uint256 a,) = ledger.mint(10, alice, bytes32("GENESIS"), NIL);

        EventLedger.Touch[] memory t = new EventLedger.Touch[](2);
        t[0] = EventLedger.Touch(a, 3, bob, false);
        t[1] = EventLedger.Touch(a, 1, bob, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EventLedger.RepeatedTouch.selector, a));
        ledger.occur(bytes32("SPLIT"), NIL, t);
    }

    // --- the algebra is untouched --------------------------------------------

    /// Conservation, authority and the gauge are the core's, and the inversion
    /// is orthogonal to all three.
    function test_theUnderlyingAlgebraIsUnchanged() public {
        (uint256 a,) = ledger.mint(10, alice, bytes32("GENESIS"), NIL);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.NotHolder.selector, a, bob));
        ledger.occur(bytes32("STOLEN"), NIL, _one(a, 3, bob, false));

        vm.prank(alice);
        (, uint256[] memory s) = ledger.occur(bytes32("MOVED"), NIL, _one(a, 6, bob, false));

        assertEq(s[0], 5, "touched members still take the top slots");
        assertEq(ledger.sizeOf(a), 4);
        assertEq(ledger.nextSlot(), 11, "nothing was minted or burned after genesis");

        vm.expectRevert(abi.encodeWithSelector(RefinementLedger.NotRigid.selector, uint256(1)));
        ledger.ownerOf(1);
    }

    function _one(uint256 handle, uint256 count, address to, bool ends)
        internal
        pure
        returns (EventLedger.Touch[] memory t)
    {
        t = new EventLedger.Touch[](1);
        t[0] = EventLedger.Touch(handle, count, to, ends);
    }
}
