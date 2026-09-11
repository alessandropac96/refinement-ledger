// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRefinementLedger} from "./interfaces/IRefinementLedger.sol";

/// @title  RefinementLedger
/// @notice A filtered ledger: a partition of pre-allocated slots that only ever
///         refines, with no mint or burn after genesis.
///
///         Slots are allocated once, one per item. A `class` is a set of slots
///         the ledger cannot currently tell apart, always a contiguous interval
///         `[lo, hi]`, named by its lowest slot. When an event touches only some
///         members, the class cuts: the touched members take the top slots and
///         get a new handle, the untouched remainder keeps `lo` and is not
///         modified. A class of cardinality 1 is rigid — its slot denotes one
///         physical object forever, and is an ordinary NFT.
///
/// @dev    This contract is the algebra and nothing else. It knows intervals,
///         holders and conservation; it does not know *why* a class divided.
///         Reasons — facts, provenance, attribution — live in extensions, which
///         attach through `_afterAllocate` and `_afterCut`.
///
///         Abstract on purpose: it has no public API. See `Ledger.sol` for the
///         composed, deployable contract.
///
///         It does have a read surface, and that one is shared: `IRefinementLedger`
///         is what any ledger of this kind answers, whatever it records and however
///         its callers speak. `classAt` and the `Class` struct below are
///         deliberately not part of it — they are how *this* core represents a
///         class, not what a class is.
///
///         See docs/SEMANTICS.md for pre- and postconditions.
abstract contract RefinementLedger is IRefinementLedger {
    /// @param hi      current high slot; `lo` is the mapping key and never moves
    /// @param birthHi high slot at birth; fixed, bounds the cut subtree
    /// @param parent  handle this class departed from; 0 for a genesis class
    struct Class {
        uint256 hi;
        uint256 birthHi;
        uint256 parent;
        address owner;
        bool terminal;
    }

    /// @notice Next unallocated slot. Slot 0 is never allocated, so handle 0 is
    ///         an unambiguous "no parent" sentinel.
    uint256 public nextSlot = 1;

    mapping(uint256 => Class) internal _classes;
    mapping(uint256 => uint256[]) internal _children;
    uint256[] internal _roots;

    event Minted(uint256 indexed handle, uint256 hi, address indexed owner);
    event Cut(uint256 indexed parent, uint256 indexed subject, uint256 count);
    event Held(uint256 indexed handle, address indexed owner);
    event Terminated(uint256 indexed handle);

    error NoSuchClass(uint256 handle);
    error NoSuchSlot(uint256 slot);
    error ClassTerminal(uint256 handle);
    error NotHolder(uint256 handle, address caller);
    error BadCount(uint256 handle, uint256 count);
    error ZeroHolder();
    error NotRigid(uint256 slot);

    // --- structure -----------------------------------------------------------

    /// @dev Allocates a fresh batch. The only operation that introduces slots,
    ///      which is why conservation is structural rather than arithmetic.
    function _allocate(uint256 count, address to) internal returns (uint256 handle) {
        if (count == 0) revert BadCount(0, count);
        if (to == address(0)) revert ZeroHolder();

        handle = nextSlot;
        uint256 hi = handle + count - 1;
        nextSlot = hi + 1;

        Class storage c = _classes[handle];
        c.hi = hi;
        c.birthHi = hi;
        c.owner = to;

        emit Minted(handle, hi, to);
        emit Held(handle, to);

        _afterAllocate(handle, hi);
    }

    /// @dev Applies an event that touched `count` members and leaves them held by
    ///      `to`. Cuts only when the event did not touch everyone; a full-width
    ///      event distinguishes nothing and so changes nothing structural.
    function _refine(uint256 handle, uint256 count, address to) internal returns (uint256 subject) {
        Class storage c = _live(handle);
        if (msg.sender != c.owner) revert NotHolder(handle, msg.sender);
        if (to == address(0)) revert ZeroHolder();

        uint256 n = c.hi - handle + 1;
        if (count == 0 || count > n) revert BadCount(handle, count);

        subject = count == n ? handle : _cut(handle, count);
        _setHolder(subject, to);
    }

    /// @dev Removes `count` members from the population. Termination is a
    ///      "touched" event, so dead slots go high within their class. Terminal
    ///      classes keep their interval — compaction would destroy the structural
    ///      conservation proof — and keep their holder, because who held an item
    ///      when it left the population is part of the record.
    function _terminate(uint256 handle, uint256 count) internal returns (uint256 subject) {
        subject = _refine(handle, count, _live(handle).owner);

        _classes[subject].terminal = true;
        emit Terminated(subject);
    }

    /// @dev The gauge choice: the touched members are always the top `count`
    ///      slots. Which particular slots depart carries no information — any
    ///      within-class permutation yields an identical ledger — so fixing the
    ///      policy makes the ledger canonical. Untouched stays low so that an
    ///      event which did not touch you cannot rename you.
    ///
    ///      Requires `count < size(handle)`, so `subject > handle` and the
    ///      remainder keeps at least one member. `subject` is strictly below every
    ///      handle this class has spawned before, so it cannot collide.
    ///
    ///      Deliberately NOT virtual. A child that could redefine which slots
    ///      depart would silently destroy Laws 1 and 3, and nothing downstream
    ///      would notice until two indexers disagreed. Children react to cuts via
    ///      `_afterCut`; they never get to define one.
    function _cut(uint256 handle, uint256 count) internal returns (uint256 subject) {
        Class storage c = _classes[handle];
        uint256 hi = c.hi;
        subject = hi - count + 1;

        Class storage s = _classes[subject];
        s.hi = hi;
        s.birthHi = hi;
        s.parent = handle;

        c.hi = subject - 1;

        emit Cut(handle, subject, count);

        _afterCut(handle, subject, count);
    }

    function _setHolder(uint256 handle, address to) internal {
        Class storage c = _classes[handle];
        if (c.owner != to) {
            c.owner = to;
            emit Held(handle, to);
        }
    }

    // --- hooks ---------------------------------------------------------------

    /// @dev Runs at the end of `_allocate`. Override and call `super` to attach
    ///      per-batch bookkeeping.
    function _afterAllocate(uint256 handle, uint256 hi) internal virtual {
        hi; // unused by the core; extensions may need it
        _roots.push(handle);
    }

    /// @dev Runs inside `_cut`, atomically with the interval surgery.
    ///
    ///      For whatever must be true the instant a class divides — the downward
    ///      index here, the log snapshot in `LedgerLoggable`. Deliberately not the
    ///      place for caller intent: who receives the departing class and what
    ///      fact is recorded are choices, and belong in the entry point. If it
    ///      would be a bug for a caller to forget it, it goes here; if it is a
    ///      choice, it does not.
    function _afterCut(uint256 parent, uint256 subject, uint256 count) internal virtual {
        count; // unused by the core; extensions may need it
        _children[parent].push(subject);
    }

    // --- guards --------------------------------------------------------------

    function _live(uint256 handle) internal view returns (Class storage c) {
        c = _classes[handle];
        if (c.birthHi == 0) revert NoSuchClass(handle);
        if (c.terminal) revert ClassTerminal(handle);
    }

    function _requireLiveHolder(uint256 handle) internal view returns (Class storage c) {
        c = _live(handle);
        if (msg.sender != c.owner) revert NotHolder(handle, msg.sender);
    }

    // --- queries -------------------------------------------------------------

    function classAt(uint256 handle) external view returns (Class memory) {
        if (_classes[handle].birthHi == 0) revert NoSuchClass(handle);
        return _classes[handle];
    }

    function exists(uint256 handle) public view override returns (bool) {
        return _classes[handle].birthHi != 0;
    }

    function sizeOf(uint256 handle) public view override returns (uint256) {
        Class storage c = _classes[handle];
        if (c.birthHi == 0) revert NoSuchClass(handle);
        return c.hi - handle + 1;
    }

    function ownerOfClass(uint256 handle) external view override returns (address) {
        Class storage c = _classes[handle];
        if (c.birthHi == 0) revert NoSuchClass(handle);
        return c.owner;
    }

    function childrenOf(uint256 handle) external view override returns (uint256[] memory) {
        return _children[handle];
    }

    function roots() external view override returns (uint256[] memory) {
        return _roots;
    }

    /// @notice The live class containing `slot`.
    /// @dev    Descends the cut tree. O(depth) levels, each scanning that class's
    ///         cut list — a convenience view, not a hot path. Indexers should
    ///         reconstruct the partition from `Cut` events instead.
    function classOf(uint256 slot) public view override returns (uint256 handle) {
        handle = _rootOf(slot);

        while (true) {
            Class storage c = _classes[handle];
            if (slot <= c.hi) return handle;

            uint256[] storage kids = _children[handle];
            uint256 next;
            for (uint256 i; i < kids.length; ++i) {
                uint256 k = kids[i];
                if (k <= slot && slot <= _classes[k].birthHi) {
                    next = k;
                    break;
                }
            }
            // Children exactly tile (hi, birthHi], so a slot in range always
            // resolves. Unreachable unless an invariant has been violated.
            if (next == 0) revert NoSuchSlot(slot);
            handle = next;
        }
    }

    /// @notice True when `slot`'s class has cardinality 1 — the slot denotes one
    ///         physical object and is, from here on, an ordinary NFT.
    function isRigid(uint256 slot) external view override returns (bool) {
        uint256 h = classOf(slot);
        return _classes[h].hi == h;
    }

    /// @notice Owner of `slot` as an item.
    /// @dev    Reverts unless the slot is rigid. A non-rigid slot has no owner as
    ///         an item: it is one anonymous member of a class, and "who owns slot
    ///         3" has no answer that is not fiction. Ask `ownerOfClass` for an
    ///         answer about the set.
    ///
    ///         Reverting is standard-conformant rather than deviant — ERC-721
    ///         already requires `ownerOf` to revert for tokens that do not exist,
    ///         and a slot that is not yet rigid does not exist as a token.
    function ownerOf(uint256 slot) external view override returns (address) {
        uint256 h = classOf(slot);
        Class storage c = _classes[h];
        if (c.hi != h) revert NotRigid(slot);
        return c.owner;
    }

    /// @dev Largest batch root <= slot. `_roots` is ascending because `_allocate`
    ///      allocates upward, so this is a plain binary search.
    function _rootOf(uint256 slot) internal view returns (uint256) {
        if (slot == 0 || slot >= nextSlot) revert NoSuchSlot(slot);

        uint256 lo;
        uint256 hi = _roots.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (_roots[mid] <= slot) lo = mid + 1;
            else hi = mid;
        }
        if (lo == 0) revert NoSuchSlot(slot);
        return _roots[lo - 1];
    }
}
