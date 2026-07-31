// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title  RefinementLedger
/// @notice Provenance for things that start out indistinguishable and become
///         distinguishable, without ever minting or burning after genesis.
///
///         Slots are allocated once, one per item. A `class` is a set of slots
///         the ledger cannot currently tell apart, always a contiguous interval
///         `[lo, hi]`, named by its lowest slot. When an event touches only some
///         members, the class cuts: the touched members take the top slots and
///         get a new handle, the untouched remainder keeps `lo` and is not
///         modified. A class of cardinality 1 is rigid — its slot denotes one
///         physical object forever, and is an ordinary NFT.
///
/// @dev    Two structures, deliberately separate. The cut tree records intervals
///         and therefore cardinality and conservation. The per-handle log records
///         facts about members and grows only when something happens to those
///         members. A cut never appends to the remainder's log: the set changed
///         cardinality, its members did not change history.
///
///         See docs/SEMANTICS.md for pre- and postconditions.
contract RefinementLedger {
    /// @param hi           current high slot; `lo` is the mapping key and never moves
    /// @param birthHi      high slot at birth; fixed, bounds the cut subtree
    /// @param parent       handle this class departed from; 0 for a genesis class
    /// @param parentLogLen length of the parent's log at the moment of departure
    struct Class {
        uint256 hi;
        uint256 birthHi;
        uint256 parent;
        uint256 parentLogLen;
        address owner;
        bool terminal;
    }

    /// @dev `kind` and `payload` are opaque to the core. What they mean is an
    ///      implementer's concern; the core only guarantees attribution.
    struct Fact {
        bytes32 kind;
        bytes32 payload;
        uint64 at;
        address author;
    }

    /// @notice Next unallocated slot. Slot 0 is never allocated, so handle 0 is
    ///         an unambiguous "no parent" sentinel.
    uint256 public nextSlot = 1;

    mapping(uint256 => Class) internal _classes;
    mapping(uint256 => Fact[]) internal _logs;
    mapping(uint256 => uint256[]) internal _children;
    uint256[] internal _roots;

    event Minted(uint256 indexed handle, uint256 hi, address indexed owner);
    event Cut(uint256 indexed parent, uint256 indexed subject, uint256 count, uint256 parentLogLen);
    event Held(uint256 indexed handle, address indexed owner);
    event Logged(uint256 indexed handle, uint256 index, bytes32 indexed kind, bytes32 payload, address author);
    event Terminated(uint256 indexed handle);

    error NoSuchClass(uint256 handle);
    error NoSuchSlot(uint256 slot);
    error ClassTerminal(uint256 handle);
    error NotHolder(uint256 handle, address caller);
    error BadCount(uint256 handle, uint256 count);
    error ZeroHolder();
    error NotRigid(uint256 slot);

    // --- mutation ------------------------------------------------------------

    /// @notice Allocate a fresh batch of `count` indistinguishable slots.
    /// @dev    The only operation that introduces slots, which is why conservation
    ///         is structural rather than arithmetic. Permissionless: batches are
    ///         disjoint and independently owned, so a forged batch is only ever
    ///         someone else's batch. Issuance policy belongs in a wrapper.
    function mint(uint256 count, address to, bytes32 kind, bytes32 payload) external returns (uint256 handle) {
        if (count == 0) revert BadCount(0, count);
        if (to == address(0)) revert ZeroHolder();

        handle = nextSlot;
        uint256 hi = handle + count - 1;
        nextSlot = hi + 1;

        Class storage c = _classes[handle];
        c.hi = hi;
        c.birthHi = hi;
        c.owner = to;
        _roots.push(handle);

        emit Minted(handle, hi, to);
        emit Held(handle, to);
        _append(handle, kind, payload);
    }

    /// @notice Record that an event touched `count` members of `handle`, and that
    ///         those members are now held by `to`.
    /// @dev    The single refinement primitive. If `count == size(handle)` the
    ///         event touched everyone, nothing is distinguished and no cut occurs.
    ///         Otherwise the touched members depart with a new handle and the
    ///         remainder is left strictly alone. Passing the current owner as `to`
    ///         means "divide without transferring".
    /// @return subject handle of the class the touched members now belong to
    function refine(uint256 handle, uint256 count, address to, bytes32 kind, bytes32 payload)
        external
        returns (uint256 subject)
    {
        Class storage c = _live(handle);
        if (msg.sender != c.owner) revert NotHolder(handle, msg.sender);
        if (to == address(0)) revert ZeroHolder();

        uint256 n = c.hi - handle + 1;
        if (count == 0 || count > n) revert BadCount(handle, count);

        if (count == n) {
            subject = handle;
            if (c.owner != to) {
                c.owner = to;
                emit Held(handle, to);
            }
        } else {
            subject = _cut(handle, c, count, to);
        }

        _append(subject, kind, payload);
    }

    /// @notice Record a fact true of every member of `handle`.
    /// @dev    Changes nothing structural. Sugar for a full-width `refine` that
    ///         keeps the current holder.
    function record(uint256 handle, bytes32 kind, bytes32 payload) external {
        Class storage c = _live(handle);
        if (msg.sender != c.owner) revert NotHolder(handle, msg.sender);
        _append(handle, kind, payload);
    }

    /// @notice Remove `count` members from the population.
    /// @dev    Termination is a "touched" event, so dead slots go high within
    ///         their class. Terminal classes are frozen but keep their interval —
    ///         compaction would destroy the structural conservation proof — and
    ///         keep their owner, because who held an item when it left the
    ///         population is part of the record.
    function terminate(uint256 handle, uint256 count, bytes32 kind, bytes32 payload)
        external
        returns (uint256 subject)
    {
        Class storage c = _live(handle);
        if (msg.sender != c.owner) revert NotHolder(handle, msg.sender);

        uint256 n = c.hi - handle + 1;
        if (count == 0 || count > n) revert BadCount(handle, count);

        subject = count == n ? handle : _cut(handle, c, count, c.owner);

        _append(subject, kind, payload);
        _classes[subject].terminal = true;
        emit Terminated(subject);
    }

    // --- internal ------------------------------------------------------------

    /// @dev The gauge choice: the touched members are always the top `count`
    ///      slots. Which particular slots depart carries no information — any
    ///      within-class permutation yields an identical ledger — so fixing the
    ///      policy makes the ledger canonical. Untouched stays low so that an
    ///      event which did not touch you cannot rename you.
    ///
    ///      Requires `count < size(handle)`, so `subject > handle` and the
    ///      remainder keeps at least one member. `subject` is strictly below every
    ///      handle this class has spawned before, so it cannot collide.
    function _cut(uint256 handle, Class storage c, uint256 count, address to) internal returns (uint256 subject) {
        uint256 hi = c.hi;
        subject = hi - count + 1;

        Class storage s = _classes[subject];
        s.hi = hi;
        s.birthHi = hi;
        s.parent = handle;
        s.parentLogLen = _logs[handle].length;
        s.owner = to;

        c.hi = subject - 1;
        _children[handle].push(subject);

        emit Cut(handle, subject, count, s.parentLogLen);
        emit Held(subject, to);
    }

    function _append(uint256 handle, bytes32 kind, bytes32 payload) internal {
        Fact[] storage l = _logs[handle];
        l.push(Fact({kind: kind, payload: payload, at: uint64(block.timestamp), author: msg.sender}));
        emit Logged(handle, l.length - 1, kind, payload, msg.sender);
    }

    function _live(uint256 handle) internal view returns (Class storage c) {
        c = _classes[handle];
        if (c.birthHi == 0) revert NoSuchClass(handle);
        if (c.terminal) revert ClassTerminal(handle);
    }

    // --- queries -------------------------------------------------------------

    function classAt(uint256 handle) external view returns (Class memory) {
        if (_classes[handle].birthHi == 0) revert NoSuchClass(handle);
        return _classes[handle];
    }

    function exists(uint256 handle) public view returns (bool) {
        return _classes[handle].birthHi != 0;
    }

    function sizeOf(uint256 handle) public view returns (uint256) {
        Class storage c = _classes[handle];
        if (c.birthHi == 0) revert NoSuchClass(handle);
        return c.hi - handle + 1;
    }

    function ownerOfClass(uint256 handle) external view returns (address) {
        Class storage c = _classes[handle];
        if (c.birthHi == 0) revert NoSuchClass(handle);
        return c.owner;
    }

    function childrenOf(uint256 handle) external view returns (uint256[] memory) {
        return _children[handle];
    }

    function roots() external view returns (uint256[] memory) {
        return _roots;
    }

    function logLengthOf(uint256 handle) external view returns (uint256) {
        return _logs[handle].length;
    }

    /// @notice The live class containing `slot`.
    /// @dev    Descends the cut tree. O(depth) levels, each scanning that class's
    ///         cut list — a convenience view, not a hot path. Indexers should
    ///         reconstruct the partition from `Cut` events instead.
    function classOf(uint256 slot) public view returns (uint256 handle) {
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
    function isRigid(uint256 slot) external view returns (bool) {
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
    function ownerOf(uint256 slot) external view returns (address) {
        uint256 h = classOf(slot);
        Class storage c = _classes[h];
        if (c.hi != h) revert NotRigid(slot);
        return c.owner;
    }

    /// @notice Full history of one item, genesis first.
    /// @dev    Works identically whether the slot is rigid or still anonymous in a
    ///         class of forty.
    function historyOf(uint256 slot) external view returns (Fact[] memory) {
        return historyOfClass(classOf(slot));
    }

    /// @notice Full history of a class, genesis first.
    /// @dev    Walks the parent chain taking each ancestor's log truncated to the
    ///         snapshot the child recorded at birth. The truncation is what keeps
    ///         a class that departed in 2027 from inheriting facts its parent
    ///         accrued in 2030.
    function historyOfClass(uint256 handle) public view returns (Fact[] memory out) {
        if (_classes[handle].birthHi == 0) revert NoSuchClass(handle);

        uint256 total;
        uint256 cur = handle;
        uint256 take = _logs[handle].length;
        while (true) {
            total += take;
            uint256 p = _classes[cur].parent;
            if (p == 0) break;
            take = _classes[cur].parentLogLen;
            cur = p;
        }

        out = new Fact[](total);
        uint256 end = total;
        cur = handle;
        take = _logs[handle].length;
        while (true) {
            Fact[] storage l = _logs[cur];
            for (uint256 i = take; i > 0; --i) {
                out[--end] = l[i - 1];
            }
            uint256 p = _classes[cur].parent;
            if (p == 0) break;
            take = _classes[cur].parentLogLen;
            cur = p;
        }
    }

    /// @dev Largest batch root <= slot. `_roots` is ascending because `mint`
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
