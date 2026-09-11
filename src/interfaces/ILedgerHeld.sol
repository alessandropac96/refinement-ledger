// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title  ILedgerHeld
/// @notice Optional: classes have holders.
interface ILedgerHeld {
    /// @notice Who holds the class as a set.
    /// @dev    Always answerable, unlike `ownerOf`. A class of forty has a holder
    ///         even though none of its members has an owner.
    function ownerOfClass(uint256 handle) external view returns (address);
}
