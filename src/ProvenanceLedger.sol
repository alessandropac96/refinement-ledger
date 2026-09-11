// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RefinementCore} from "./RefinementCore.sol";
import {LedgerEmit} from "./extensions/LedgerEmit.sol";
import {LedgerNarrative} from "./extensions/LedgerNarrative.sol";
import {LedgerCommit} from "./extensions/LedgerCommit.sol";
import {LedgerWriter} from "./extensions/LedgerWriter.sol";

/// @title  ProvenanceLedger
/// @notice The lean composition for a custodial issuer: the algebra, structural
///         LOGs, LOG-only facts, one commitment per lot, one writer.
///
/// @dev    Everything a provenance record needs to be complete and verifiable,
///         and nothing that exists only to be read back on chain. Storage per
///         operation: one word for an allocation whatever the lot size, one word
///         for a cut, a dirty write for a fact. The partition, the narrative and
///         each slot's history are reconstructed by an indexer from `Minted`,
///         `Cut`, `Terminated` and `Logged`, and checked against `headOf`.
///
///         `id` is the caller's identity for the occurrence — the same across
///         every class one physical event reached. `payload` is a 32-byte pointer
///         or digest (a CIDv0 is a sha-256 digest behind a fixed prefix). Neither
///         is stored.
///
///         Holders are absent by design: every class stays in the issuer's
///         custody, so per-class ownership would be a word per class spent on a
///         question with one answer. Add `LedgerHeld` when that stops being true.
contract ProvenanceLedger is LedgerEmit, LedgerCommit, LedgerWriter {
    /// @param handle  class the occurrence reached
    /// @param count   how many of its members — `count == size` records without cutting
    /// @param kind    what happened
    /// @param id      the occurrence's identity; repeat it across touches that
    ///                are one physical event
    /// @param payload 32-byte pointer or digest
    struct Touch {
        uint256 handle;
        uint256 count;
        bytes32 kind;
        bytes32 id;
        bytes32 payload;
    }

    error NoTouches();

    constructor(address initialWriter) LedgerWriter(initialWriter) {}

    // --- hook plumbing: two bases reach the core, Solidity wants both named ---

    function _afterAllocate(uint256 handle, uint256 hi) internal override(RefinementCore, LedgerEmit) {
        super._afterAllocate(handle, hi);
    }

    function _afterCut(uint256 parent, uint256 subject, uint256 count) internal override(RefinementCore, LedgerEmit) {
        super._afterCut(parent, subject, count);
    }

    function _afterTerminate(uint256 subject) internal override(RefinementCore, LedgerEmit) {
        super._afterTerminate(subject);
    }

    /// @notice Allocate a lot of `count` indistinguishable slots and record why.
    function allocate(uint256 count, bytes32 kind, bytes32 id, bytes32 payload)
        external
        onlyWriter
        returns (uint256 handle)
    {
        handle = _allocate(count);
        _log(handle, kind, id, payload);
    }

    /// @notice One occurrence reached `count` members of `handle`.
    /// @dev    Cuts when `count < sizeOf(handle)`; otherwise records against the
    ///         class as it stands. A rigid class can only ever be touched in full.
    /// @return subject the class the touched members now belong to
    function touch(uint256 handle, uint256 count, bytes32 kind, bytes32 id, bytes32 payload)
        external
        onlyWriter
        returns (uint256 subject)
    {
        subject = _touch(handle, count);
        _log(subject, kind, id, payload);
    }

    /// @notice Many touches in one transaction: one occurrence reaching several
    ///         classes (same `id`), or several occurrences settled together.
    /// @dev    The batching primitive. Intrinsic transaction cost is paid once and
    ///         the lot's head is warm after the first touch, so per-bottle facts
    ///         on one lot cost a fraction of what they cost alone.
    function touchMany(Touch[] calldata touches) external onlyWriter returns (uint256[] memory subjects) {
        uint256 n = touches.length;
        if (n == 0) revert NoTouches();

        subjects = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            Touch calldata t = touches[i];
            subjects[i] = _touch(t.handle, t.count);
            _log(subjects[i], t.kind, t.id, t.payload);
        }
    }

    /// @notice `count` members of `handle` left the population; record why.
    function terminate(uint256 handle, uint256 count, bytes32 kind, bytes32 id, bytes32 payload)
        external
        onlyWriter
        returns (uint256 subject)
    {
        subject = _terminate(handle, count);
        _log(subject, kind, id, payload);
    }
}
