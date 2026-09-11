// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice One attributed thing that happened.
///
/// @dev    File-level on purpose. `LedgerLoggable.Fact` and `LedgerEvents.Event`
///         were already field-for-field identical, and two identical structs
///         declared in two contracts are two types as far as an interface is
///         concerned — so nothing could be shared until they were one.
///
///         Collapsing them loses nothing, because their difference was never in
///         the record. A fact hangs off a handle and has no existence apart from
///         it; an event has an identity of its own and is *reached by* handles.
///         That is a difference in ownership and in what a caller may say, and it
///         stays in the implementations where it belongs.
struct Record {
    bytes32 kind;
    bytes32 payload;
    uint64 at;
    address author;
}

/// @title  ILedgerHistory
/// @notice Optional: this ledger can say what happened to a population.
///
/// @dev    Optional in ERC-721's sense — a core that implements none of this is
///         inert, not broken. `StructuralLedger` in the tests is exactly that: a
///         ledger that only wants monotone refinement, records nothing, and is a
///         first-class instance of `IRefinementLedger` anyway.
///
///         What conformance buys is the guarantee stated in `historyOf`: cut
///         invariance. A consumer can rely on it without knowing whether the
///         implementation reconstructs history from snapshot indices or from the
///         ordering of events.
interface ILedgerHistory {
    /// @notice Everything that ever happened to the members of `handle`, oldest
    ///         first, including what happened before they were told apart.
    /// @dev    Reverts for a handle that does not exist.
    function historyOfClass(uint256 handle) external view returns (Record[] memory);

    /// @notice Everything that ever happened to `slot`, oldest first.
    ///
    /// @dev    Total, unlike the element-level queries on `IRefinementLedger`, and
    ///         that asymmetry is the point. `ownerOf` must refuse a non-rigid slot
    ///         because naming one member's owner out of forty is fiction — but
    ///         every fact in a non-rigid slot's history is true of whichever object
    ///         ends up bound to it, so there is nothing to refuse.
    ///
    ///         **Cut invariance (law 5).** A cut must leave this byte-identical
    ///         for every slot that did not depart. Cardinality belongs to the set;
    ///         history belongs to the members; a member cannot observe another
    ///         member leaving.
    function historyOf(uint256 slot) external view returns (Record[] memory);
}
