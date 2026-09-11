// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IRefinementLedger} from "../src/interfaces/IRefinementLedger.sol";
import {ILedgerHistory, Record} from "../src/interfaces/ILedgerHistory.sol";
import {ILedgerNames} from "../src/interfaces/ILedgerNames.sol";
import {Ledger} from "../src/Ledger.sol";
import {EventLedger} from "../src/EventLedger.sol";
import {StructuralLedger} from "./Extension.t.sol";

/// @title  LedgerConformance
/// @notice The five laws, stated once, against `IRefinementLedger` alone.
///
/// @dev    Everything below reads the ledger only through the shared interface.
///         `classAt`, `Class`, `hi` and `nextSlot` do not appear, which is the
///         point: a law that needed them would be a law about intervals rather
///         than about refinement, and would silently rule out any second core.
///
///         Writing is a different matter, and the suite does not pretend
///         otherwise. Each shape supplies four small drivers below. That is not a
///         gap being papered over — it is the finding, made concrete. Two
///         implementations agree completely on what is true of a population and
///         disagree on how a caller states an occurrence, and the disagreement
///         costs about six lines per shape.
///
///         Two of the drivers deserve a note.
///
///         `_slotAt` exists because the interface deliberately does not say which
///         slot ids a batch received. The interval core answers `handle + i`; a
///         core built without a pre-allocated pool would answer otherwise. Every
///         other slot in these tests is found by asking `classOf`, never by
///         arithmetic.
///
///         `_history` and `_names` return the zero address when a shape does not
///         implement the optional interface, and the tests that need them return
///         early. `StructuralLedger` records nothing and names nothing and is a
///         first-class instance anyway: incompleteness here is inert, not broken.
abstract contract LedgerConformance is Test {
    IRefinementLedger internal L;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    // --- what each shape supplies --------------------------------------------

    function _newLedger() internal virtual returns (IRefinementLedger);

    function _doMint(uint256 count, address to, bytes32 tag) internal virtual returns (uint256 handle);
    function _doRefine(uint256 handle, uint256 count, address to, bytes32 tag)
        internal
        virtual
        returns (uint256 subject);
    function _doTerminate(uint256 handle, uint256 count, bytes32 tag) internal virtual returns (uint256 subject);

    /// @dev The i'th slot of the batch rooted at `handle`. See the contract note.
    function _slotAt(uint256 handle, uint256 i) internal view virtual returns (uint256);

    function _history() internal view virtual returns (ILedgerHistory) {
        return ILedgerHistory(address(0));
    }

    function _names() internal view virtual returns (ILedgerNames) {
        return ILedgerNames(address(0));
    }

    function setUp() public {
        L = _newLedger();
    }

    // --- authority is the core's, and it is the same in every shape -----------

    function _refine(uint256 handle, uint256 count, address to, bytes32 tag) internal returns (uint256) {
        address holder = L.ownerOfClass(handle);
        vm.prank(holder);
        return _doRefine(handle, count, to, tag);
    }

    function _terminate(uint256 handle, uint256 count, bytes32 tag) internal returns (uint256) {
        address holder = L.ownerOfClass(handle);
        vm.prank(holder);
        return _doTerminate(handle, count, tag);
    }

    // --- law 1: conservation --------------------------------------------------

    /// Slots are allocated once and never created or destroyed. Stated without
    /// intervals: group the batch's slots by the class each resolves to, and every
    /// class must agree that it has exactly that many members.
    ///
    /// Terminated members are counted too. A departed item is still accounted for
    /// — its class keeps its members and is merely marked as having left — and a
    /// conservation check that quietly dropped them would be checking supply
    /// rather than conservation.
    function test_law1_classesTileTheBatch() public {
        uint256 root = _doMint(12, alice, "GENESIS");
        _assertTiles(root, 12);

        uint256 a = _refine(root, 5, bob, "MOVED");
        _refine(a, 2, alice, "SPLIT");
        _terminate(root, 3, "BROKEN");
        _refine(root, 1, bob, "SOLD");

        _assertTiles(root, 12);
    }

    function test_law1_asecondBatchIsIndependent() public {
        uint256 p = _doMint(6, alice, "GENESIS");
        uint256 q = _doMint(4, bob, "GENESIS");

        _refine(p, 2, bob, "MOVED");
        _refine(q, 1, alice, "MOVED");

        _assertTiles(p, 6);
        _assertTiles(q, 4);
        assertEq(L.roots().length, 2, "the ledger lost a batch");
    }

    // --- law 2: refinement is monotone ---------------------------------------

    /// Classes only shrink, by exactly what left, and no handle ever stops
    /// answering. The cut tree is the record of where everything went.
    function test_law2_classesOnlyShrinkAndHandlesArePermanent() public {
        uint256 root = _doMint(10, alice, "GENESIS");
        assertEq(L.sizeOf(root), 10);

        uint256 a = _refine(root, 4, bob, "MOVED");
        assertEq(L.sizeOf(root), 6, "the remainder did not shrink by exactly what left");
        assertEq(L.sizeOf(a), 4, "the departing class is the wrong size");

        uint256 b = _refine(a, 1, alice, "SOLD");
        assertEq(L.sizeOf(a), 3);
        assertEq(L.sizeOf(b), 1);

        // a full-width occurrence divides nothing
        uint256 same = _refine(root, 6, alice, "STORED");
        assertEq(same, root, "an occurrence that reached everyone still cut the class");
        assertEq(L.sizeOf(root), 6, "a full-width occurrence changed a cardinality");

        assertTrue(L.exists(root) && L.exists(a) && L.exists(b), "a handle disappeared");
        assertEq(L.childrenOf(root).length, 1, "the cut tree lost a branch");
        assertEq(L.childrenOf(a)[0], b, "the cut tree misrecords where members went");
        assertEq(L.childrenOf(b).length, 0);
    }

    // --- law 3: gauge invariance ---------------------------------------------

    /// Which members departed carries no information, so two populations that
    /// differ only in the slots they were handed must be indistinguishable after
    /// the same history. Run one script over two batches and compare structure.
    function test_law3_theSameScriptOnDifferentSlotsIsIndistinguishable() public {
        uint256 p = _doMint(9, alice, "GENESIS");
        uint256 q = _doMint(9, alice, "GENESIS");

        assertTrue(p != q, "two batches share a handle");
        assertEq(_shapeOf(p), _shapeOf(q), "two identical populations were distinguishable at birth");

        _script(p);
        _script(q);

        assertEq(_shapeOf(p), _shapeOf(q), "the same script produced different structure on different slots");
    }

    function _script(uint256 root) internal {
        uint256 a = _refine(root, 6, bob, "MOVED");
        _refine(a, 2, alice, "SPLIT");
        _refine(root, 1, bob, "SOLD");
        _terminate(a, 1, "BROKEN");
    }

    // --- law 4: rigidity is monotone -----------------------------------------

    /// `isRigid` is the domain predicate of every element-level question, and it
    /// is a fixed point: a singleton cannot be divided, so once a slot denotes one
    /// object it does so forever. This is the ERC-721 fragment, and it is exactly
    /// the total part of a partial interface.
    function test_law4_rigidityIsAFixedPointAndBoundsWhatMayBeAsked() public {
        uint256 root = _doMint(4, alice, "GENESIS");
        uint256 anon = _slotAt(root, 0);

        assertFalse(L.isRigid(anon), "a class of four has no rigid members");
        vm.expectRevert();
        L.ownerOf(anon);
        assertEq(L.ownerOfClass(root), alice, "the class must have a holder even when its members have no owner");

        uint256 one = _refine(root, 1, bob, "SOLD");
        uint256 s = _slotIn(root, 4, one);

        assertTrue(L.isRigid(s), "cardinality 1 did not make a slot rigid");
        assertEq(L.ownerOf(s), bob, "a rigid slot answers as an ordinary token");

        // everything that can still happen to it is necessarily full-width
        _refine(one, 1, alice, "SHIPPED");
        assertTrue(L.isRigid(s), "a rigid slot stopped being rigid");
        assertEq(L.sizeOf(one), 1);
        assertEq(L.ownerOf(s), alice, "a full-width occurrence on a singleton is an ordinary transfer");

        // and the class it left is still honestly anonymous
        uint256 stillAnon = _slotIn(root, 4, root);
        assertFalse(L.isRigid(stillAnon), "an unrelated class became rigid");
        vm.expectRevert();
        L.ownerOf(stillAnon);
    }

    // --- law 5: a cut is unobservable to whoever stayed ------------------------

    /// Cardinality belongs to the set; history belongs to the members; a member
    /// cannot observe another member leaving. Under `ILedgerHistory` this is the
    /// byte-identical claim. Without it the check is weaker but still true, and
    /// saying so is better than skipping it.
    function test_law5_aCutLeavesTheRemainderUntouched() public {
        uint256 root = _doMint(10, alice, "GENESIS");
        _refine(root, 2, bob, "MOVED");
        _refine(root, 8, alice, "STORED");

        uint256[] memory slots = new uint256[](10);
        bytes32[] memory before = new bytes32[](10);
        uint256 k;
        for (uint256 i; i < 10; ++i) {
            uint256 s = _slotAt(root, i);
            if (L.classOf(s) != root) continue;
            slots[k] = s;
            before[k] = _sliceOf(s);
            ++k;
        }
        assertEq(k, 8, "the remainder is the wrong size");

        uint256 gone = _refine(root, 3, bob, "SOLD");
        assertEq(L.sizeOf(gone), 3);

        uint256 stayed;
        for (uint256 i; i < k; ++i) {
            if (L.classOf(slots[i]) != root) continue;
            assertEq(_sliceOf(slots[i]), before[i], "a cut was observable to a slot that did not depart");
            ++stayed;
        }
        assertEq(stayed, 5, "the wrong number of slots stayed");
    }

    /// Termination is the sharper case: one member leaving the population must not
    /// modify the nine that remain in any way.
    function test_law5_theDepartureOfOneDoesNotTouchTheOthers() public {
        uint256 root = _doMint(10, alice, "GENESIS");
        _refine(root, 10, alice, "STORED");

        bytes32 before = _sliceOf(_slotAt(root, 0));
        _terminate(root, 1, "BROKEN");

        assertEq(L.sizeOf(root), 9, "the class did not lose a member");
        assertEq(_sliceOf(_slotAt(root, 0)), before, "a death was written into a survivor's record");
    }

    // --- optional: ILedgerHistory --------------------------------------------

    /// A class that departed must not inherit what its parent accrued afterwards.
    /// How that boundary is stored is the implementations' business — a snapshot
    /// index in one, the birth event in the other — and neither shows through here.
    function test_history_aDepartedClassDoesNotInheritLaterParentFacts() public {
        ILedgerHistory H = _history();
        if (address(H) == address(0)) {
            vm.skip(true, "shape does not implement ILedgerHistory");
            return;
        }

        uint256 root = _doMint(10, alice, "GENESIS");
        _refine(root, 10, alice, "EARLY");
        uint256 gone = _refine(root, 4, bob, "DEPARTED");
        _refine(root, 6, alice, "LATE");

        Record[] memory h = H.historyOf(_slotIn(root, 10, gone));
        assertEq(h.length, 3, "a departed class has the wrong history length");
        assertEq(h[0].kind, bytes32("GENESIS"), "history is not oldest-first");
        assertEq(h[1].kind, bytes32("EARLY"));
        assertEq(h[2].kind, bytes32("DEPARTED"), "a departed class saw a later parent fact");
        assertEq(h[2].author, alice, "the record is misattributed");

        Record[] memory p = H.historyOfClass(root);
        assertEq(p.length, 3, "the parent inherited its child's departure");
        assertEq(p[2].kind, bytes32("LATE"), "the parent stopped accruing");
    }

    /// History is total where `ownerOf` is partial, and that asymmetry is the
    /// design: every fact recorded against a class is true of whichever object
    /// ends up bound to any of its slots, so there is nothing to refuse.
    function test_history_answersForSlotsThatAreStillAnonymous() public {
        ILedgerHistory H = _history();
        if (address(H) == address(0)) {
            vm.skip(true, "shape does not implement ILedgerHistory");
            return;
        }

        uint256 root = _doMint(10, alice, "GENESIS");
        _refine(root, 6, bob, "MOVED");

        uint256 anon = _slotIn(root, 10, root);
        assertFalse(L.isRigid(anon));
        vm.expectRevert();
        L.ownerOf(anon);

        assertEq(H.historyOf(anon).length, 1, "history refused, or invented, facts for an anonymous slot");
    }

    // --- optional: ILedgerNames ----------------------------------------------

    /// The whole promise of the interface: a name moves exactly when the class
    /// divides, and never after rigidity.
    function test_names_moveExactlyWhenTheClassDivides() public {
        ILedgerNames N = _names();
        if (address(N) == address(0)) {
            vm.skip(true, "shape does not implement ILedgerNames");
            return;
        }

        uint256 root = _doMint(10, alice, "GENESIS");
        bytes32 n0 = N.nameOf(root);

        _refine(root, 10, alice, "STORED");
        assertEq(N.nameOf(root), n0, "an occurrence that told nobody apart moved an identity");

        uint256 a = _refine(root, 6, bob, "MOVED");
        assertEq(N.nameOf(root), n0, "an occurrence that missed the remainder renamed it");
        assertTrue(N.nameOf(a) != n0, "a class that was told apart kept its old identity");

        uint256 b = _refine(root, 2, bob, "SOLD");
        assertTrue(N.nameOf(b) != N.nameOf(a), "two classes told apart share an identity");
        assertEq(N.nameOf(root), n0, "the remainder was renamed twice over");

        uint256 one = _refine(a, 1, alice, "IDENTIFIED");
        uint256 s = _slotIn(root, 10, one);
        bytes32 frozen = N.elementNameOf(s);
        assertEq(frozen, N.nameOf(one), "an element's name disagrees with its singleton class");

        _refine(one, 1, bob, "SHIPPED");
        assertEq(N.elementNameOf(s), frozen, "a rigid slot was renamed");
    }

    /// Naming and distinguishing are the same act, so a name is answerable for an
    /// element exactly when `ownerOf` is.
    function test_names_areElementLevelOnlyAtCardinalityOne() public {
        ILedgerNames N = _names();
        if (address(N) == address(0)) {
            vm.skip(true, "shape does not implement ILedgerNames");
            return;
        }

        uint256 root = _doMint(4, alice, "GENESIS");
        uint256 anon = _slotAt(root, 0);

        assertFalse(L.isRigid(anon));
        vm.expectRevert();
        N.elementNameOf(anon);

        // the class still has a name; it just is not anyone's
        assertTrue(N.nameOf(root) != bytes32(0));
    }

    // --- helpers, all of them interface-only ---------------------------------

    /// @dev Conservation, without ever asking a class for its interval.
    function _assertTiles(uint256 root, uint256 n) internal view {
        uint256[] memory seen = new uint256[](n);
        uint256[] memory tally = new uint256[](n);
        uint256 k;

        for (uint256 i; i < n; ++i) {
            uint256 h = L.classOf(_slotAt(root, i));
            uint256 j;
            while (j < k && seen[j] != h) {
                ++j;
            }
            if (j == k) {
                seen[k] = h;
                ++k;
            }
            ++tally[j];
        }

        uint256 total;
        for (uint256 j; j < k; ++j) {
            assertEq(tally[j], L.sizeOf(seen[j]), "a class disagrees with the slots that resolve to it");
            total += tally[j];
        }
        assertEq(total, n, "the batch gained or lost members");
    }

    /// @dev Some slot currently in `handle`, found by asking rather than by
    ///      arithmetic — which slot it is carries no information (law 3).
    function _slotIn(uint256 root, uint256 n, uint256 handle) internal view returns (uint256) {
        for (uint256 i; i < n; ++i) {
            uint256 s = _slotAt(root, i);
            if (L.classOf(s) == handle) return s;
        }
        revert("no slot resolves to that class");
    }

    /// @dev Cardinalities and holders down the cut tree, and nothing else. Slot
    ///      numbers are precisely what law 3 says carries no information, so a
    ///      digest that included them would be testing the gauge, not the law.
    function _shapeOf(uint256 handle) internal view returns (bytes32 acc) {
        uint256[] memory kids = L.childrenOf(handle);
        acc = keccak256(abi.encode(L.sizeOf(handle), L.ownerOfClass(handle), kids.length));
        for (uint256 i; i < kids.length; ++i) {
            acc = keccak256(abi.encode(acc, _shapeOf(kids[i])));
        }
    }

    /// @dev Everything a slot can say about itself, including its reconstructed
    ///      history where there is one.
    function _sliceOf(uint256 slot) internal view returns (bytes32) {
        ILedgerHistory H = _history();
        bytes memory hist = address(H) == address(0) ? bytes("") : abi.encode(H.historyOf(slot));
        return keccak256(abi.encode(L.classOf(slot), L.isRigid(slot), hist));
    }
}

/// @dev The class-first shape: an entry point names one class and says how many of
///      its members were touched.
contract LedgerConformanceTest is LedgerConformance {
    Ledger internal ledger;

    function _newLedger() internal override returns (IRefinementLedger) {
        ledger = new Ledger();
        return IRefinementLedger(address(ledger));
    }

    function _doMint(uint256 count, address to, bytes32 tag) internal override returns (uint256) {
        return ledger.mint(count, to, tag, bytes32(0));
    }

    function _doRefine(uint256 handle, uint256 count, address to, bytes32 tag) internal override returns (uint256) {
        return ledger.refine(handle, count, to, tag, bytes32(0));
    }

    function _doTerminate(uint256 handle, uint256 count, bytes32 tag) internal override returns (uint256) {
        return ledger.terminate(handle, count, tag, bytes32(0));
    }

    function _slotAt(uint256 handle, uint256 i) internal pure override returns (uint256) {
        return handle + i;
    }

    function _history() internal view override returns (ILedgerHistory) {
        return ILedgerHistory(address(ledger));
    }

    function _names() internal view override returns (ILedgerNames) {
        return ILedgerNames(address(ledger));
    }
}

/// @dev The event-first shape: an occurrence is stated once and then brought into
///      contact with whatever it reached. Same laws, different arity of speaking —
///      which is why the drivers exist at all.
contract EventLedgerConformanceTest is LedgerConformance {
    EventLedger internal ledger;

    function _newLedger() internal override returns (IRefinementLedger) {
        ledger = new EventLedger();
        return IRefinementLedger(address(ledger));
    }

    function _doMint(uint256 count, address to, bytes32 tag) internal override returns (uint256 handle) {
        (handle,) = ledger.mint(count, to, tag, bytes32(0));
    }

    function _doRefine(uint256 handle, uint256 count, address to, bytes32 tag) internal override returns (uint256) {
        return _occur(tag, handle, count, to, false);
    }

    function _doTerminate(uint256 handle, uint256 count, bytes32 tag) internal override returns (uint256) {
        return _occur(tag, handle, count, address(0), true);
    }

    function _occur(bytes32 tag, uint256 handle, uint256 count, address to, bool ends) private returns (uint256) {
        EventLedger.Touch[] memory t = new EventLedger.Touch[](1);
        t[0] = EventLedger.Touch(handle, count, to, ends);
        (, uint256[] memory subjects) = ledger.occur(tag, bytes32(0), t);
        return subjects[0];
    }

    function _slotAt(uint256 handle, uint256 i) internal pure override returns (uint256) {
        return handle + i;
    }

    function _history() internal view override returns (ILedgerHistory) {
        return ILedgerHistory(address(ledger));
    }

    function _names() internal view override returns (ILedgerNames) {
        return ILedgerNames(address(ledger));
    }
}

/// @dev A ledger that records nothing and names nothing. It implements neither
///      optional interface and obeys all five laws regardless, which is the claim
///      "the core is usable on its own" turned into something that can fail.
contract StructuralLedgerConformanceTest is LedgerConformance {
    StructuralLedger internal ledger;

    function _newLedger() internal override returns (IRefinementLedger) {
        ledger = new StructuralLedger();
        return IRefinementLedger(address(ledger));
    }

    function _doMint(uint256 count, address to, bytes32) internal override returns (uint256) {
        return ledger.mint(count, to);
    }

    function _doRefine(uint256 handle, uint256 count, address to, bytes32) internal override returns (uint256) {
        return ledger.refine(handle, count, to);
    }

    function _doTerminate(uint256 handle, uint256 count, bytes32) internal override returns (uint256) {
        return ledger.terminate(handle, count);
    }

    function _slotAt(uint256 handle, uint256 i) internal pure override returns (uint256) {
        return handle + i;
    }
}
