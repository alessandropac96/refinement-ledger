// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RefinementCore} from "../RefinementCore.sol";

/// @title  LedgerNarrative
/// @notice Provenance as LOGs: a fact is emitted against a class and stored
///         nowhere.
///
/// @dev    The class-first shape (`LedgerLoggable`) stores every fact as rows so
///         that `historyOf` can be answered on chain. This layer keeps the same
///         attribution — a fact hangs off the class it is true of — and leaves
///         the reading to the indexer, which already has the cut tree from
///         `LedgerEmit`. History reconstruction is then: a slot's facts are the
///         `Logged` events of its class and of every ancestor, each ancestor
///         truncated at the block position of the `Cut` that created the branch.
///         No snapshot needs to be stored, because block order already is one.
///
///         `id` is the occurrence's identity and is supplied by the caller. One
///         physical event that reached several classes is logged once per class
///         with the same `id`, which is how the indexer recognises it as one
///         occurrence. The contract stores nothing for it and cannot notice a
///         replay; that is the caller's contract or a nonce extension's.
abstract contract LedgerNarrative is RefinementCore {
    event Logged(uint256 indexed handle, bytes32 indexed kind, bytes32 indexed id, bytes32 payload);

    function _log(uint256 handle, bytes32 kind, bytes32 id, bytes32 payload) internal {
        emit Logged(handle, kind, id, payload);
        _afterLog(handle, kind, id, payload);
    }

    /// @dev Runs after every fact. For layers that want to fold facts into
    ///      something stored — a commitment — without storing the facts.
    function _afterLog(uint256 handle, bytes32 kind, bytes32 id, bytes32 payload) internal virtual {}
}
