// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RefinementCore} from "../RefinementCore.sol";
import {ILedgerHeld} from "../interfaces/ILedgerHeld.sol";

/// @title  LedgerHeld
/// @notice Gives every class a holder, and lets only the holder touch it.
///
/// @dev    Authorization is not interval algebra: the partition is equally
///         well-defined whoever is allowed to cut it. This layer adds the one
///         word per class that authority needs and the entry-level operations
///         that consult it. A composition gated by a single writer instead
///         (`LedgerWriter`) does not include it and pays nothing for holders.
///
///         Who holds the departing side is caller intent, so it is set by the
///         entry-level operations here, not by a hook. Who held a class when it
///         left the population is part of the record, so `_terminate` keeps it.
abstract contract LedgerHeld is RefinementCore, ILedgerHeld {
    mapping(uint256 => address) internal _holders;

    event Held(uint256 indexed handle, address indexed owner);

    error NotHolder(uint256 handle, address caller);
    error ZeroHolder();

    function _allocate(uint256 count, address to) internal returns (uint256 handle) {
        if (to == address(0)) revert ZeroHolder();
        handle = _allocate(count);
        _setHolder(handle, to);
    }

    /// @dev Applies an event that touched `count` members and leaves them held by
    ///      `to`. Cuts only when the event did not touch everyone.
    function _refine(uint256 handle, uint256 count, address to) internal returns (uint256 subject) {
        _requireLiveHolder(handle);
        if (to == address(0)) revert ZeroHolder();

        subject = _touch(handle, count);
        _setHolder(subject, to);
    }

    function _terminate(uint256 handle, uint256 count) internal virtual override returns (uint256 subject) {
        _requireLiveHolder(handle);
        address holder = _holders[handle];

        subject = super._terminate(handle, count);
        if (subject != handle) _setHolder(subject, holder);
    }

    function _setHolder(uint256 handle, address to) internal {
        if (_holders[handle] != to) {
            _holders[handle] = to;
            emit Held(handle, to);
        }
    }

    function _requireLiveHolder(uint256 handle) internal view returns (Interval storage c) {
        c = _live(handle);
        if (msg.sender != _holders[handle]) revert NotHolder(handle, msg.sender);
    }

    /// @notice Who holds the class as a set. Always answerable, unlike `ownerOf`.
    function ownerOfClass(uint256 handle) external view override returns (address) {
        _existing(handle);
        return _holders[handle];
    }
}
