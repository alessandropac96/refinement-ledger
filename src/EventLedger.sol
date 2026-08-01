// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LedgerEvents} from "./extensions/LedgerEvents.sol";

/// @title  EventLedger
/// @notice A filtered ledger in which events, not classes, are the primitives.
///
/// @dev    Draft. Sits beside `Ledger.sol` rather than replacing it, so the two
///         shapes can be compared.
///
///         The difference that matters is in `occur`. In `Ledger`, an entry
///         point names one class and says how many of *its* members were
///         touched — so a caller describing something that reached three classes
///         has to decompose it along the ledger's current partition first, and
///         the result is three unrelated facts. Here an occurrence is stated
///         once and then brought into contact with whatever it reached. The
///         partition follows; it is not a precondition for speaking.
contract EventLedger is LedgerEvents {
    /// @param handle class the event reached
    /// @param count  how many of its members — `count == size` means it reached
    ///               all of them, told nobody apart, and moves no identity
    /// @param to     holder afterwards; ignored when `ends`
    /// @param ends   the touched members leave the population
    struct Touch {
        uint256 handle;
        uint256 count;
        address to;
        bool ends;
    }

    error NoTouches();
    error RepeatedTouch(uint256 handle);

    /// @notice Allocate a batch, and record what caused it.
    function mint(uint256 count, address to, bytes32 kind, bytes32 payload)
        external
        returns (uint256 handle, uint256 id)
    {
        id = _newEvent(kind, payload);
        handle = _allocate(count, to);
        _reachFresh(id, handle);
    }

    /// @notice One occurrence, reaching any number of classes, atomically.
    /// @return id       the event's identity — the same for every class it met
    /// @return subjects per touch, the class its members now belong to
    ///
    /// @dev    Authority is still per class: `_refine` requires the caller hold
    ///         each one. So an occurrence spanning classes with different
    ///         holders cannot be stated in a single transaction, which the world
    ///         is under no obligation to respect. Unresolved.
    function occur(bytes32 kind, bytes32 payload, Touch[] calldata touches)
        external
        returns (uint256 id, uint256[] memory subjects)
    {
        uint256 n = touches.length;
        if (n == 0) revert NoTouches();
        _requireDistinct(touches);

        id = _newEvent(kind, payload);

        subjects = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            Touch calldata t = touches[i];
            subjects[i] = _reach(id, t.handle, t.count, t.to, t.ends);
        }
    }

    /// @dev One event may not reach the same class twice.
    ///
    ///      Not a convenience check. Identity is the chain of discriminants, so
    ///      two classes cut out of one parent by one event would have identical
    ///      chains and therefore the same name. Splitting 10 into 6/3/1 with a
    ///      single occurrence needs the event to distinguish the roles it played
    ///      — which is the open question of whether "discriminating" is binary,
    ///      surfacing as a collision. Forbidden here rather than papered over.
    function _requireDistinct(Touch[] calldata touches) internal pure {
        uint256 n = touches.length;
        for (uint256 i; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (touches[i].handle == touches[j].handle) revert RepeatedTouch(touches[i].handle);
            }
        }
    }
}
