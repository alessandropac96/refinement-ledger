// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RefinementLedger} from "../RefinementLedger.sol";
import {ILedgerHistory, Record} from "../interfaces/ILedgerHistory.sol";
import {ILedgerNames} from "../interfaces/ILedgerNames.sol";

/// @title  LedgerEvents
/// @notice Events as first-class citizens, and classes as what events induce.
///
/// @dev    The inversion. In `LedgerLoggable` the partition is primitive and
///         facts are rows hanging off its nodes. Here an event is a thing with
///         an identity, and a class is characterised by which events reached it.
///
///         Two ideas the concept insists on, and they are different:
///
///         - `_touched[h]` is the **full history**: every event that reached
///           this class, whether or not it told anyone apart.
///         - `_birthEvent[h]` is the **discriminant**: the single event that set
///           this class apart from what it used to be grouped with. The chain of
///           discriminants root-to-here is the identity.
///
///         Identity is the discriminating quotient of history, not history. An
///         event that touches every member of a class changes what is known
///         about it and changes nothing about who it is — a uniform change to a
///         device for telling things apart is not observable. So a full-width
///         event appends to `_touched` and never writes `_birthEvent`, and the
///         name does not move.
///
///         Two consequences worth noticing, because both were work before:
///
///         - **Rigidity freezes identity.** A singleton cannot be cut, so it can
///           never gain another discriminant. Its name is final. Law 4 stops
///           being an invariant to maintain and becomes a theorem.
///         - **The snapshot index is gone.** `LedgerLoggable` had to record how
///           long the parent's log was at the moment a child departed, so the
///           child would not inherit facts its parent accrued later. Events are
///           ordered and carry their own identity, so a child's birth event *is*
///           that cutoff. The bookkeeping existed only because facts had no
///           identity of their own.
///
///         Naming and history are one layer here, where they were two. Under the
///         old shape a name was derived from the cut path — our serialisation.
///         Here it is derived from the events themselves, so `LedgerLoggable`
///         and `LedgerPathIds` collapse into this contract.
abstract contract LedgerEvents is RefinementLedger, ILedgerHistory, ILedgerNames {
    /// @dev An occurrence, stored in the same `Record` the class-first shape logs
    ///      facts in. The record was never where the two differed: what is new
    ///      here is that it is held once, in one array, with an identity of its
    ///      own, rather than copied under each handle it concerns.
    ///
    ///      Ids are sequential on purpose. A class's identity is structural and
    ///      should not depend on order, but an event's identity *is* its
    ///      occurrence, and occurrences are genuinely ordered.
    ///
    ///      Event id is index + 1, so 0 reads as "no event".
    Record[] internal _events;

    /// @dev handle => every event that reached this class, ascending.
    mapping(uint256 => uint256[]) internal _touched;

    /// @dev handle => the event that set this class apart. Never overwritten.
    mapping(uint256 => uint256) internal _birthEvent;

    bytes32 internal constant NAME_TAG = keccak256("RefinementLedger.identity.v0");

    event Occurred(uint256 indexed id, bytes32 indexed kind, bytes32 payload, address indexed author);
    event Reached(uint256 indexed id, uint256 indexed handle, uint256 count, bool discriminated);

    error NoSuchEvent(uint256 id);

    // --- writing -------------------------------------------------------------

    /// @dev One occurrence, one identity, however many classes it goes on to
    ///      reach. This is the whole point of the layer.
    function _newEvent(bytes32 kind, bytes32 payload) internal returns (uint256 id) {
        _events.push(Record({kind: kind, payload: payload, at: uint64(block.timestamp), author: msg.sender}));
        id = _events.length;
        emit Occurred(id, kind, payload, msg.sender);
    }

    /// @dev Bring event `id` into contact with `count` members of `handle`.
    ///
    ///      The two writes below are the concept in four lines: history always,
    ///      identity only when the event actually told someone apart.
    function _reach(uint256 id, uint256 handle, uint256 count, address to, bool ends)
        internal
        returns (uint256 subject)
    {
        subject = ends ? _terminate(handle, count) : _refine(handle, count, to);

        bool discriminated = subject != handle;
        if (discriminated) _birthEvent[subject] = id;
        _touched[subject].push(id);

        emit Reached(id, subject, count, discriminated);
    }

    /// @dev Genesis. A batch is not exempt from having a cause.
    function _reachFresh(uint256 id, uint256 handle) internal {
        _birthEvent[handle] = id;
        _touched[handle].push(id);
        emit Reached(id, handle, sizeOf(handle), true);
    }

    // --- identity ------------------------------------------------------------

    /// @notice The events that set this class apart, root-first.
    /// @dev    Strictly shorter than its history whenever any event reached it
    ///         full-width. That gap is the difference between what happened to
    ///         you and who you are.
    function discriminantsOf(uint256 handle) public view returns (uint256[] memory chain) {
        if (!exists(handle)) revert NoSuchClass(handle);

        uint256 depth;
        uint256 cur = handle;
        while (true) {
            ++depth;
            uint256 p = _intervals[cur].parent;
            if (p == 0) break;
            cur = p;
        }

        chain = new uint256[](depth);
        cur = handle;
        for (uint256 i = depth; i > 0; --i) {
            chain[i - 1] = _birthEvent[cur];
            cur = _intervals[cur].parent;
        }
    }

    /// @notice The identity of a class: a fold over what set it apart.
    /// @dev    Moves exactly when a discriminant is added, which is exactly when
    ///         an event divided this class. Frozen forever once rigid.
    function nameOf(uint256 handle) public view override returns (bytes32 name) {
        return nameFromDiscriminants(discriminantsOf(handle));
    }

    /// @notice The identity of `slot` as an element.
    /// @dev    Reverts unless the slot is rigid, for the reason `ownerOf` does:
    ///         below cardinality 1 there is no element to name, only a class.
    ///
    ///         Frozen at the moment it first becomes answerable, which is the
    ///         property the class-first shape has to maintain and this one gets
    ///         for free: a singleton cannot be cut, so it can never gain another
    ///         discriminant.
    function elementNameOf(uint256 slot) external view override returns (bytes32) {
        uint256 h = classOf(slot);
        if (sizeOf(h) != 1) revert NotRigid(slot);
        return nameOf(h);
    }

    /// @notice Recompute an identity from the events that produced it.
    /// @dev    `view` only for the chain binding; no class state is read. What a
    ///         root should bind to is still open — see RFC 001.
    function nameFromDiscriminants(uint256[] memory chain) public view returns (bytes32 name) {
        name = keccak256(abi.encode(NAME_TAG, block.chainid, address(this)));
        for (uint256 i; i < chain.length; ++i) {
            name = keccak256(abi.encode(name, chain[i]));
        }
    }

    function birthEventOf(uint256 handle) external view returns (uint256) {
        return _birthEvent[handle];
    }

    // --- history -------------------------------------------------------------

    function eventCount() external view returns (uint256) {
        return _events.length;
    }

    function eventAt(uint256 id) public view returns (Record memory) {
        if (id == 0 || id > _events.length) revert NoSuchEvent(id);
        return _events[id - 1];
    }

    /// @notice Raw event ids that reached this class while it was this class.
    function touchesOf(uint256 handle) external view returns (uint256[] memory) {
        return _touched[handle];
    }

    /// @notice Everything that ever happened to the members of `handle`.
    /// @dev    Walks ancestors, taking from each only what happened before this
    ///         branch departed. The cutoff is the branch's own birth event: no
    ///         separate snapshot is stored, because an ordered identity already
    ///         is one.
    function historyOfClass(uint256 handle) public view override returns (Record[] memory out) {
        if (!exists(handle)) revert NoSuchClass(handle);

        uint256 total;
        uint256 cur = handle;
        uint256 cutoff = type(uint256).max;
        while (true) {
            total += _inheritedCount(cur, cutoff);
            uint256 p = _intervals[cur].parent;
            if (p == 0) break;
            cutoff = _birthEvent[cur];
            cur = p;
        }

        out = new Record[](total);
        uint256 end = total;
        cur = handle;
        cutoff = type(uint256).max;
        while (true) {
            uint256 n = _inheritedCount(cur, cutoff);
            uint256[] storage t = _touched[cur];
            for (uint256 i = n; i > 0; --i) {
                out[--end] = _events[t[i - 1] - 1];
            }
            uint256 p = _intervals[cur].parent;
            if (p == 0) break;
            cutoff = _birthEvent[cur];
            cur = p;
        }
    }

    function historyOf(uint256 slot) external view override returns (Record[] memory) {
        return historyOfClass(classOf(slot));
    }

    /// @dev `_touched` is ascending, so what a departing branch inherits is a
    ///      prefix, and its length is all we need.
    function _inheritedCount(uint256 handle, uint256 cutoff) internal view returns (uint256 n) {
        uint256[] storage t = _touched[handle];
        uint256 len = t.length;
        while (n < len && t[n] < cutoff) {
            ++n;
        }
    }
}
