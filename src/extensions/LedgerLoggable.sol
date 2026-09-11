// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RefinementLedger} from "../RefinementLedger.sol";
import {ILedgerHistory, Record} from "../interfaces/ILedgerHistory.sol";

/// @title  LedgerLoggable
/// @notice Attaches provenance to a filtered ledger: an append-only log of facts
///         per handle, and history reconstruction for any slot.
///
/// @dev    Facts are not part of the algebra. A filtration divides classes; it has
///         no opinion on *why*. This extension supplies the why, and is the only
///         place `kind`/`payload` exist.
///
///         The design rule the core states abstractly, made concrete here:
///
///         - the **snapshot** is an invariant, so it lives in `_afterCut`. A
///           concrete contract that forgot to take it would produce silently
///           wrong history rather than a loud failure.
///         - the **fact** is caller intent, so `_append` is called explicitly by
///           the entry point, never by a hook.
abstract contract LedgerLoggable is RefinementLedger, ILedgerHistory {
    /// @dev A fact hangs off a handle and has no existence apart from it. The
    ///      record itself is `ILedgerHistory.Record`, shared with the event-first
    ///      shape: `kind` and `payload` are opaque in both, and what they mean is
    ///      a concrete implementation's concern. This layer only guarantees
    ///      attribution and ordering.
    mapping(uint256 => Record[]) internal _logs;

    /// @dev Length of the parent's log at the moment this class departed. Keyed by
    ///      the departing handle. Lives here rather than in `Class` because it is
    ///      meaningless without a log.
    mapping(uint256 => uint256) internal _parentLogLen;

    event Logged(uint256 indexed handle, uint256 index, bytes32 indexed kind, bytes32 payload, address author);
    event Snapshot(uint256 indexed parent, uint256 indexed subject, uint256 parentLogLen);

    /// @dev Freezes the departing class's view of its parent's log at the moment
    ///      it left, atomically with the cut. Without it, a class that departed in
    ///      2027 would inherit facts its parent accrued in 2030.
    function _afterCut(uint256 parent, uint256 subject, uint256 count) internal virtual override {
        super._afterCut(parent, subject, count);

        uint256 len = _logs[parent].length;
        _parentLogLen[subject] = len;
        emit Snapshot(parent, subject, len);
    }

    /// @dev Deliberately has no liveness check: `terminate` records the reason a
    ///      class left the population onto the class it just froze. Callers that
    ///      need one — `record` — check separately.
    function _append(uint256 handle, bytes32 kind, bytes32 payload) internal {
        Record[] storage l = _logs[handle];
        l.push(Record({kind: kind, payload: payload, at: uint64(block.timestamp), author: msg.sender}));
        emit Logged(handle, l.length - 1, kind, payload, msg.sender);
    }

    // --- queries -------------------------------------------------------------

    function logLengthOf(uint256 handle) external view returns (uint256) {
        return _logs[handle].length;
    }

    function parentLogLenOf(uint256 handle) external view returns (uint256) {
        return _parentLogLen[handle];
    }

    /// @notice Full history of one item, genesis first.
    /// @dev    Works identically whether the slot is rigid or still anonymous in a
    ///         class of forty.
    function historyOf(uint256 slot) external view override returns (Record[] memory) {
        return historyOfClass(classOf(slot));
    }

    /// @notice Full history of a class, genesis first.
    /// @dev    Walks the parent chain taking each ancestor's log truncated to the
    ///         snapshot the child recorded at birth.
    function historyOfClass(uint256 handle) public view override returns (Record[] memory out) {
        if (!exists(handle)) revert NoSuchClass(handle);

        uint256 total;
        uint256 cur = handle;
        uint256 take = _logs[handle].length;
        while (true) {
            total += take;
            uint256 p = _intervals[cur].parent;
            if (p == 0) break;
            take = _parentLogLen[cur];
            cur = p;
        }

        out = new Record[](total);
        uint256 end = total;
        cur = handle;
        take = _logs[handle].length;
        while (true) {
            Record[] storage l = _logs[cur];
            for (uint256 i = take; i > 0; --i) {
                out[--end] = l[i - 1];
            }
            uint256 p = _intervals[cur].parent;
            if (p == 0) break;
            take = _parentLogLen[cur];
            cur = p;
        }
    }
}
