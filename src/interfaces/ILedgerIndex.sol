// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title  ILedgerIndex
/// @notice Optional: the ledger can descend from a slot to its live class on
///         chain. Without it, the same answers come from an indexer over the
///         structural LOGs.
interface ILedgerIndex {
    /// @notice The live class `slot` currently belongs to.
    function classOf(uint256 slot) external view returns (uint256 handle);

    /// @notice The classes that have departed from `handle`, in order of departure.
    function childrenOf(uint256 handle) external view returns (uint256[] memory);

    /// @notice The genesis classes this ledger has allocated.
    function roots() external view returns (uint256[] memory);

    /// @notice Whether `slot`'s class is a singleton — whether `slot` denotes one
    ///         object rather than "some member of a class".
    /// @dev    The domain predicate. Every element-level question is answerable
    ///         exactly when this is true.
    function isRigid(uint256 slot) external view returns (bool);
}
