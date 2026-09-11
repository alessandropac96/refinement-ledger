// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title  IRefinementLedger
/// @notice The read surface every refinement ledger has, whatever it records and
///         however its callers speak.
///
/// @dev    The common parent, and an interface on purpose: an abstract contract
///         would bring storage and linearisation with it, which is exactly what
///         forces the `_afterCut` plumbing in `Ledger`.
///
///         Two rules decide what is in here.
///
///         **Reads, not writes.** Implementations agree on what is true of a
///         population and disagree on how a caller states an occurrence — one
///         class at a time in `Ledger`, one occurrence across many classes in
///         `EventLedger`. That disagreement is each shape's thesis, so unifying
///         the write side would erase the thing the two shapes exist to compare.
///         It is the line ERC-721 already draws: `transferFrom` is conserved and
///         standard, `_mint` is where meaning enters and is left to the deployer.
///
///         **No interval mechanics.** `classAt`, `hi`, `birthHi` and the slot
///         counter are deliberately absent. They are how *this* core represents a
///         class, not what a class is, and every consumer that touches them is a
///         consumer that breaks if a core is ever built without a pre-allocated
///         pool. Handles are opaque here; nothing may assume a handle is a slot.
///
///         Queries come in two kinds and the difference is load-bearing:
///
///         - **class-level** queries are total. Every live class has a size, a
///           holder and a set of departures.
///         - **element-level** queries are partial. Below cardinality 1 a slot is
///           one anonymous member of a class, and "who owns slot 3" has no answer
///           that is not fiction — so `ownerOf` reverts. `isRigid` is not a
///           convenience view: it is the domain predicate of that partiality, and
///           ERC-721 is precisely the total fragment it carves out.
///
///         Errors and events stay in the implementations. An interface that
///         declared them would collide with the core that already does.
interface IRefinementLedger {
    // --- class level: total ---------------------------------------------------

    /// @notice Whether `handle` names a class this ledger has ever created.
    function exists(uint256 handle) external view returns (bool);

    /// @notice How many members `handle` currently has.
    /// @dev    Reverts for a handle that does not exist. Cardinality is the only
    ///         thing a consumer needs from the representation, which is why it is
    ///         here and the interval it is computed from is not.
    function sizeOf(uint256 handle) external view returns (uint256);

    /// @notice Who holds the class as a set.
    /// @dev    Always answerable, unlike `ownerOf`. A class of forty has a holder
    ///         even though none of its members has an owner.
    function ownerOfClass(uint256 handle) external view returns (address);

    /// @notice The live class `slot` currently belongs to.
    function classOf(uint256 slot) external view returns (uint256 handle);

    /// @notice The classes that have departed from `handle`, in order of
    ///         departure.
    function childrenOf(uint256 handle) external view returns (uint256[] memory);

    /// @notice The genesis classes this ledger has allocated.
    function roots() external view returns (uint256[] memory);

    // --- element level: partial ----------------------------------------------

    /// @notice Whether `slot`'s class is a singleton — whether `slot` denotes one
    ///         object rather than "some member of a class".
    /// @dev    The domain predicate. Every element-level question is answerable
    ///         exactly when this is true.
    function isRigid(uint256 slot) external view returns (bool);

    /// @notice Owner of `slot` as an item.
    /// @dev    Reverts unless `isRigid(slot)`. Standard-conformant rather than
    ///         deviant: ERC-721 already requires `ownerOf` to revert for tokens
    ///         that do not exist, and a slot that is not yet rigid does not exist
    ///         as a token.
    function ownerOf(uint256 slot) external view returns (address);
}
