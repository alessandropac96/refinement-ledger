// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RefinementCore} from "../RefinementCore.sol";

/// @title  LedgerEmit
/// @notice Makes the partition observable: one LOG per structural transition.
///
/// @dev    Enough for an indexer to reconstruct every class interval, the whole
///         cut tree and the terminal set without reading storage. Compositions
///         that answer `classOf` on chain add `LedgerIndex`; those that only need
///         the chain as a record stop here.
abstract contract LedgerEmit is RefinementCore {
    event Minted(uint256 indexed handle, uint256 hi);
    event Cut(uint256 indexed parent, uint256 indexed subject, uint256 count);
    event Terminated(uint256 indexed handle);

    function _afterAllocate(uint256 handle, uint256 hi) internal virtual override {
        super._afterAllocate(handle, hi);
        emit Minted(handle, hi);
    }

    function _afterCut(uint256 parent, uint256 subject, uint256 count) internal virtual override {
        super._afterCut(parent, subject, count);
        emit Cut(parent, subject, count);
    }

    function _afterTerminate(uint256 subject) internal virtual override {
        super._afterTerminate(subject);
        emit Terminated(subject);
    }
}
