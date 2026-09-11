// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RefinementCore} from "../RefinementCore.sol";
import {ILedgerIndex} from "../interfaces/ILedgerIndex.sol";

/// @title  LedgerIndex
/// @notice Answers "which class is slot `s` in" on chain.
///
/// @dev    The core stores only upward pointers. Descending from a slot to its
///         live class needs the downward index (`_children`), the batch roots and
///         each class's high bound at birth — two fresh words per allocation and
///         three per cut. Every one of them exists for reads: an indexer
///         reconstructs the same answer from `LedgerEmit` alone, so compositions
///         that never ask on chain leave this out.
abstract contract LedgerIndex is RefinementCore, ILedgerIndex {
    mapping(uint256 => uint256[]) internal _children;
    mapping(uint256 => uint256) internal _birthHi;
    uint256[] internal _roots;

    error NoSuchSlot(uint256 slot);

    function _afterAllocate(uint256 handle, uint256 hi) internal virtual override {
        super._afterAllocate(handle, hi);
        _roots.push(handle);
        _birthHi[handle] = hi;
    }

    function _afterCut(uint256 parent, uint256 subject, uint256 count) internal virtual override {
        super._afterCut(parent, subject, count);
        _children[parent].push(subject);
        _birthHi[subject] = _intervals[subject].hi;
    }

    // --- queries -------------------------------------------------------------

    /// @notice High slot at birth; fixed, bounds the cut subtree.
    function birthHiOf(uint256 handle) public view returns (uint256) {
        _existing(handle);
        return _birthHi[handle];
    }

    function childrenOf(uint256 handle) external view override returns (uint256[] memory) {
        return _children[handle];
    }

    function roots() external view override returns (uint256[] memory) {
        return _roots;
    }

    /// @notice The live class containing `slot`.
    /// @dev    Descends the cut tree. O(depth) levels, each scanning that class's
    ///         cut list — a convenience view, not a hot path.
    function classOf(uint256 slot) public view override returns (uint256 handle) {
        handle = _rootOf(slot);

        while (true) {
            if (slot <= _intervals[handle].hi) return handle;

            uint256[] storage kids = _children[handle];
            uint256 next;
            for (uint256 i; i < kids.length; ++i) {
                uint256 k = kids[i];
                if (k <= slot && slot <= _birthHi[k]) {
                    next = k;
                    break;
                }
            }
            // Children exactly tile (hi, birthHi], so a slot in range always
            // resolves. Unreachable unless an invariant has been violated.
            if (next == 0) revert NoSuchSlot(slot);
            handle = next;
        }
    }

    /// @notice True when `slot`'s class has cardinality 1.
    function isRigid(uint256 slot) public view override returns (bool) {
        uint256 h = classOf(slot);
        return _intervals[h].hi == h;
    }

    /// @dev Largest batch root <= slot. `_roots` is ascending because allocation
    ///      goes upward, so this is a plain binary search.
    function _rootOf(uint256 slot) internal view returns (uint256) {
        if (slot == 0 || slot >= nextSlot) revert NoSuchSlot(slot);

        uint256 lo;
        uint256 hi = _roots.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (_roots[mid] <= slot) lo = mid + 1;
            else hi = mid;
        }
        if (lo == 0) revert NoSuchSlot(slot);
        return _roots[lo - 1];
    }
}
