// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RefinementLedger} from "./RefinementLedger.sol";
import {LedgerLoggable} from "./extensions/LedgerLoggable.sol";
import {LedgerPathIds} from "./extensions/LedgerPathIds.sol";

/// @title  Ledger
/// @notice A filtered ledger with provenance: the composed, deployable contract.
///
/// @dev    Nothing here is algebra and nothing here is storage. Every function is
///         a structural operation from `RefinementLedger` followed by the fact the
///         caller chose to record — which is exactly the split the hook rule
///         predicts, and the reason these entry points are four lines each.
contract Ledger is LedgerPathIds, LedgerLoggable {
    /// @dev The tax for stacking a second extension: once `_afterCut` reaches
    ///      `Ledger` down two inheritance paths, Solidity makes the composition
    ///      name them both, whatever order the bases are listed in. Pure
    ///      plumbing — `super` walks the chain and every layer still runs.
    function _afterCut(uint256 parent, uint256 subject, uint256 count)
        internal
        override(RefinementLedger, LedgerLoggable)
    {
        super._afterCut(parent, subject, count);
    }

    /// @notice Allocate a fresh batch of `count` indistinguishable slots.
    /// @dev    Permissionless: batches are disjoint and independently owned, so a
    ///         forged batch is only ever someone else's batch. Issuance policy
    ///         belongs in a wrapper over this contract.
    function mint(uint256 count, address to, bytes32 kind, bytes32 payload) external returns (uint256 handle) {
        handle = _allocate(count, to);
        _append(handle, kind, payload);
    }

    /// @notice Record that an event touched `count` members of `handle`, and that
    ///         those members are now held by `to`.
    /// @return subject handle of the class the touched members now belong to
    function refine(uint256 handle, uint256 count, address to, bytes32 kind, bytes32 payload)
        external
        returns (uint256 subject)
    {
        subject = _refine(handle, count, to);
        _append(subject, kind, payload);
    }

    /// @notice Record a fact true of every member of `handle`.
    /// @dev    Changes nothing structural — a full-width event distinguishes
    ///         nobody, so there is no cut to make.
    function record(uint256 handle, bytes32 kind, bytes32 payload) external {
        _requireLiveHolder(handle);
        _append(handle, kind, payload);
    }

    /// @notice Remove `count` members from the population, recording why.
    function terminate(uint256 handle, uint256 count, bytes32 kind, bytes32 payload)
        external
        returns (uint256 subject)
    {
        subject = _terminate(handle, count);
        _append(subject, kind, payload);
    }
}
