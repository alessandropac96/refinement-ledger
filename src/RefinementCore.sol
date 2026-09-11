// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRefinementCore} from "./interfaces/IRefinementCore.sol";

/// @title  RefinementCore
/// @notice The algebra and nothing else: a partition of pre-allocated slots that
///         only ever refines.
///
///         Slots are allocated once, one per item. A class is a contiguous
///         interval `[lo, hi]` named by its lowest slot. When an event touches
///         only some members, the class cuts: the touched members take the top
///         slots and get a new handle, the untouched remainder keeps `lo`. A class
///         of cardinality 1 is rigid — its slot denotes one physical object.
///
/// @dev    Stores one word per class and one counter, and observes nothing: no
///         events, no authority, no index, no history. Every one of those is a
///         way of treating the data, and belongs to an extension attached through
///         the three hooks. A composition that wants none of them pays for none.
///
///         `uint120` is a packing choice, not a capacity one. Slot ids are dense
///         because `nextSlot` hands them out contiguously, so 2^120 is
///         unreachable; what the width buys is `hi`, `parent` and `terminal` in
///         one storage word.
abstract contract RefinementCore is IRefinementCore {
    /// @param hi       current high slot; `lo` is the mapping key and never moves
    /// @param parent   handle this class departed from; 0 for a genesis class
    /// @param terminal members left the population; the interval is frozen
    struct Interval {
        uint120 hi;
        uint120 parent;
        bool terminal;
    }

    /// @notice Next unallocated slot. Slot 0 is never allocated, so handle 0 is
    ///         an unambiguous "no parent" sentinel and `hi == 0` means "no class".
    uint256 public nextSlot = 1;

    mapping(uint256 => Interval) internal _intervals;

    error NoSuchClass(uint256 handle);
    error ClassTerminal(uint256 handle);
    error BadCount(uint256 handle, uint256 count);
    error SlotOverflow();

    // --- structure -----------------------------------------------------------

    /// @dev Allocates a fresh class of `count` slots. The only operation that
    ///      introduces slots, which is why conservation is structural.
    function _allocate(uint256 count) internal returns (uint256 handle) {
        if (count == 0) revert BadCount(0, count);

        handle = nextSlot;
        uint256 hi = handle + count - 1;
        if (hi > type(uint120).max) revert SlotOverflow();
        nextSlot = hi + 1;

        _intervals[handle].hi = uint120(hi);

        _afterAllocate(handle, hi);
    }

    /// @dev Applies an event that touched `count` members of `handle`. Cuts only
    ///      when the event did not touch everyone; a full-width touch
    ///      distinguishes nothing, changes nothing, and fires no hook.
    function _touch(uint256 handle, uint256 count) internal returns (uint256 subject) {
        Interval storage c = _live(handle);

        uint256 n = c.hi - handle + 1;
        if (count == 0 || count > n) revert BadCount(handle, count);

        subject = count == n ? handle : _cut(handle, count);
    }

    /// @dev Removes `count` members from the population. Termination is a touched
    ///      event, so dead slots go high within their class. Terminal classes keep
    ///      their interval: compaction would destroy the conservation proof.
    function _terminate(uint256 handle, uint256 count) internal virtual returns (uint256 subject) {
        subject = _touch(handle, count);
        _intervals[subject].terminal = true;

        _afterTerminate(subject);
    }

    /// @dev The gauge choice: the touched members are always the top `count`
    ///      slots. Which particular slots depart carries no information, so fixing
    ///      the policy makes the ledger canonical. Untouched stays low so that an
    ///      event which did not touch you cannot rename you.
    ///
    ///      Deliberately NOT virtual. A child that could redefine which slots
    ///      depart would silently destroy Laws 1 and 3. Children react to cuts via
    ///      `_afterCut`; they never get to define one.
    function _cut(uint256 handle, uint256 count) internal returns (uint256 subject) {
        Interval storage c = _intervals[handle];
        uint256 hi = c.hi;
        subject = hi - count + 1;

        _intervals[subject] = Interval({hi: uint120(hi), parent: uint120(handle), terminal: false});
        c.hi = uint120(subject - 1);

        _afterCut(handle, subject, count);
    }

    // --- hooks ---------------------------------------------------------------

    /// @dev Runs at the end of `_allocate`. Override and call `super`.
    function _afterAllocate(uint256 handle, uint256 hi) internal virtual {}

    /// @dev Runs inside `_cut`, atomically with the interval surgery. For whatever
    ///      must be true the instant a class divides; never for caller intent.
    function _afterCut(uint256 parent, uint256 subject, uint256 count) internal virtual {}

    /// @dev Runs at the end of `_terminate`, after the class is frozen.
    function _afterTerminate(uint256 subject) internal virtual {}

    // --- guards --------------------------------------------------------------

    function _live(uint256 handle) internal view returns (Interval storage c) {
        c = _intervals[handle];
        if (c.hi == 0) revert NoSuchClass(handle);
        if (c.terminal) revert ClassTerminal(handle);
    }

    function _existing(uint256 handle) internal view returns (Interval storage c) {
        c = _intervals[handle];
        if (c.hi == 0) revert NoSuchClass(handle);
    }

    // --- queries -------------------------------------------------------------

    function exists(uint256 handle) public view override returns (bool) {
        return _intervals[handle].hi != 0;
    }

    function sizeOf(uint256 handle) public view override returns (uint256) {
        return _existing(handle).hi - handle + 1;
    }

    /// @dev Representation, not interface: how this core stores a class. Kept
    ///      public for extensions and views; deliberately absent from
    ///      `IRefinementCore`, which speaks in cardinalities.
    function hiOf(uint256 handle) public view returns (uint256) {
        return _existing(handle).hi;
    }

    function parentOf(uint256 handle) public view override returns (uint256) {
        return _existing(handle).parent;
    }

    function isTerminal(uint256 handle) public view override returns (bool) {
        return _existing(handle).terminal;
    }

    /// @notice The genesis class `handle` descends from.
    /// @dev    Walks the parent chain; reads one word per level and stores
    ///         nothing. Depth is the number of cuts on this class's ancestry.
    function rootOf(uint256 handle) public view override returns (uint256 root) {
        root = handle;
        uint256 p = _existing(root).parent;
        while (p != 0) {
            root = p;
            p = _intervals[root].parent;
        }
    }
}
