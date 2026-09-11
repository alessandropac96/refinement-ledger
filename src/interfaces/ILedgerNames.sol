// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title  ILedgerNames
/// @notice Optional: this ledger can name a class by something other than the
///         slot it was allocated.
///
/// @dev    What a conforming implementation promises is exactly this, and it is
///         deliberately weaker than either implementation actually delivers:
///
///         1. `nameOf(handle)` is stable while the class is stable.
///         2. It moves for a class **exactly when that class divides** — never
///            for a class an occurrence did not divide, and never for the
///            remainder side of a division. (Law 5 and law 3 together: an event
///            that did not tell you apart must not rename you, and a uniform
///            change to a device for telling things apart is not observable.)
///         3. Once a class is rigid it can never divide again, so its name is
///            final. Law 4 stops being an invariant to maintain and becomes a
///            theorem about names.
///         4. A name denotes a **class**, not an element. It becomes an element's
///            name at cardinality 1, and not before.
///
///         What is deliberately **not** promised is where the name comes from,
///         and the two implementations genuinely disagree:
///
///         - `LedgerPathIds` folds ordinals — the class's position in the
///           refinement. Pure shape, so the same trajectory yields the same name
///           on any chain, and a name is checkable by anyone holding the root name
///           and the path, with no access to storage.
///         - `LedgerEvents` folds the ids of the events that did the dividing.
///           Ids are sequential, so the name depends on what else the ledger was
///           doing at the time. That is not canonical past a single deployment.
///
///         Pinning the stronger property here would have quietly ruled out the
///         event-first shape, and ruling out one of the two candidates is not a
///         thing an interface written to compare them should do. The gap is real
///         and is open — see docs/rfc/001-intrinsic-names.md.
interface ILedgerNames {
    /// @notice The name of a class.
    /// @dev    Reverts for a handle that does not exist.
    function nameOf(uint256 handle) external view returns (bytes32);

    /// @notice The name of `slot` as an element.
    /// @dev    Reverts unless `isRigid(slot)`, for the reason `ownerOf` does:
    ///         below cardinality 1 there is no element to name, only a class.
    ///         Naming and distinguishing are the same act.
    function elementNameOf(uint256 slot) external view returns (bytes32);
}
