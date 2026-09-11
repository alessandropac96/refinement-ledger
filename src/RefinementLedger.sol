// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RefinementCore} from "./RefinementCore.sol";
import {LedgerEmit} from "./extensions/LedgerEmit.sol";
import {LedgerHeld} from "./extensions/LedgerHeld.sol";
import {LedgerIndex} from "./extensions/LedgerIndex.sol";
import {IRefinementLedger} from "./interfaces/IRefinementLedger.sol";

/// @title  RefinementLedger
/// @notice The classic shape: an observable, held, indexed refinement ledger.
///
/// @dev    Once the whole algebra, now a composition. `RefinementCore` is the
///         partition; this contract adds the three things every earlier
///         composition assumed — structural LOGs, a holder per class, and on-chain
///         descent from slot to class — and keeps the surface that `Ledger`,
///         `EventLedger` and their tests were written against: the `Class` view
///         struct, `_allocate(count, to)`, `_refine`, `_terminate`, `ownerOf`.
///
///         What it costs over the bare core is exactly what those three buy:
///         two words per allocation and three per cut for the index, one word per
///         class for the holder. A composition that reads through an indexer and
///         writes through a single role uses the core directly — see
///         `ProvenanceLedger`.
abstract contract RefinementLedger is LedgerEmit, LedgerHeld, LedgerIndex, IRefinementLedger {
    /// @dev The representation the earlier core exposed, assembled on read.
    struct Class {
        uint256 hi;
        uint256 birthHi;
        uint256 parent;
        address owner;
        bool terminal;
    }

    error NotRigid(uint256 slot);

    // --- hook plumbing -------------------------------------------------------

    function _afterAllocate(uint256 handle, uint256 hi)
        internal
        virtual
        override(RefinementCore, LedgerEmit, LedgerIndex)
    {
        super._afterAllocate(handle, hi);
    }

    function _afterCut(uint256 parent, uint256 subject, uint256 count)
        internal
        virtual
        override(RefinementCore, LedgerEmit, LedgerIndex)
    {
        super._afterCut(parent, subject, count);
    }

    function _afterTerminate(uint256 subject) internal virtual override(RefinementCore, LedgerEmit) {
        super._afterTerminate(subject);
    }

    function _terminate(uint256 handle, uint256 count)
        internal
        virtual
        override(RefinementCore, LedgerHeld)
        returns (uint256 subject)
    {
        return super._terminate(handle, count);
    }

    // --- queries -------------------------------------------------------------

    function classAt(uint256 handle) external view returns (Class memory) {
        Interval storage c = _existing(handle);
        return Class({
            hi: c.hi,
            birthHi: _birthHi[handle],
            parent: c.parent,
            owner: _holders[handle],
            terminal: c.terminal
        });
    }

    /// @notice Owner of `slot` as an item.
    /// @dev    Reverts unless the slot is rigid. A non-rigid slot has no owner as
    ///         an item: it is one anonymous member of a class, and "who owns slot
    ///         3" has no answer that is not fiction. Ask `ownerOfClass` for an
    ///         answer about the set.
    function ownerOf(uint256 slot) external view override returns (address) {
        uint256 h = classOf(slot);
        if (_intervals[h].hi != h) revert NotRigid(slot);
        return _holders[h];
    }
}
