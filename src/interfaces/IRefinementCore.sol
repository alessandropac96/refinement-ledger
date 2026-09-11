// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title  IRefinementCore
/// @notice What the bare algebra can answer, before any extension is attached.
///
/// @dev    Total, class-level, and free of interval mechanics: cardinality and
///         lineage are what a class *is*; `hi` and the slot counter are how one
///         core represents it. Element-level questions (`classOf`, `isRigid`,
///         `ownerOf`) need an index or a holder and live on their extensions'
///         interfaces.
interface IRefinementCore {
    /// @notice Whether `handle` names a class this ledger has ever created.
    function exists(uint256 handle) external view returns (bool);

    /// @notice How many members `handle` currently has. Reverts if it does not exist.
    function sizeOf(uint256 handle) external view returns (uint256);

    /// @notice The class `handle` departed from; 0 for a genesis class.
    function parentOf(uint256 handle) external view returns (uint256);

    /// @notice Whether the members of `handle` have left the population.
    function isTerminal(uint256 handle) external view returns (bool);

    /// @notice The genesis class `handle` descends from.
    function rootOf(uint256 handle) external view returns (uint256);
}
