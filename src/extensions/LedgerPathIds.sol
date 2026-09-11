// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RefinementLedger} from "../RefinementLedger.sol";
import {ILedgerNames} from "../interfaces/ILedgerNames.sol";

/// @title  LedgerPathIds
/// @notice Intrinsic names for classes: a name derived from the class's own
///         trajectory through the refinement, rather than drawn from the slot
///         space allocated at genesis.
///
/// @dev    **A spike, not a proposal.** Its point is that intrinsic naming is
///         already latent in the representation we have: the trajectory is on
///         chain as the parent chain, so a name computed from it needs no change
///         to the algebra, no added state, and no new operations. Every function
///         here is a view or a pure. Nothing writes.
///
///         What that buys is separability. The naming question and the
///         cardinality question arrive together — drop the pre-allocated pool
///         and `lo` stops being available as a name — but they are not actually
///         entangled. Names can be intrinsic while cardinality stays determinate
///         and conservation stays structural. Whether to give that up is then an
///         isolated decision rather than a bundled consequence.
///
///         Two properties carry over unchanged, and both are forced:
///
///         - a name denotes a **class**, not an element. Members of a class
///           share a trajectory, so they share a name; it becomes an element's
///           name exactly at cardinality 1. Same rule `ownerOf` enforces.
///         - the **remainder keeps its name**. Only the departing side is
///           renamed, because renaming both would let an event that touched some
///           members rename the untouched ones. That is Law 5, and it is why
///           `nameOf` is a fold over the departures only: a class nothing ever
///           happened to keeps the root's name forever, which is correct — since
///           nothing distinguishes it, nothing should name it apart.
///
///         The concrete construction — folding with keccak, binding the root to
///         chain and address, ignoring cardinality at the point of divergence —
///         is deliberately arbitrary. It exists so there is something runnable.
///         See docs/rfc/001-intrinsic-names.md.
abstract contract LedgerPathIds is RefinementLedger, ILedgerNames {
    /// @dev Domain separator, so a name cannot be confused with a digest of
    ///      anything else this contract might one day hash.
    bytes32 internal constant ROOT_TAG = keccak256("RefinementLedger.intrinsicName.v0");

    /// @notice The genesis class `handle` descends from.
    function rootOfClass(uint256 handle) public view returns (uint256 root) {
        if (!exists(handle)) revert NoSuchClass(handle);

        root = handle;
        uint256 p = _intervals[root].parent;
        while (p != 0) {
            root = p;
            p = _intervals[root].parent;
        }
    }

    /// @notice The divergences that produced `handle`, root-first.
    /// @dev    Each entry is the class's index among its parent's departures.
    ///         Indices are stable forever: `_children` is append-only.
    ///
    ///         An untouched class has an empty path — it never departed from
    ///         anything, so there is nothing to say about it.
    function pathOf(uint256 handle) public view returns (uint256[] memory ordinals) {
        if (!exists(handle)) revert NoSuchClass(handle);

        uint256 depth;
        uint256 cur = handle;
        while (_intervals[cur].parent != 0) {
            ++depth;
            cur = _intervals[cur].parent;
        }

        ordinals = new uint256[](depth);
        cur = handle;
        for (uint256 i = depth; i > 0; --i) {
            uint256 p = _intervals[cur].parent;
            ordinals[i - 1] = _ordinalOf(p, cur);
            cur = p;
        }
    }

    /// @notice Name of a genesis class.
    /// @dev    The one place the instantiation leaks in. Everything below a root
    ///         is pure shape; the root has no shape to be derived from, so it has
    ///         to be bound to something. What it should be bound to is an open
    ///         question — see the RFC.
    function rootNameOf(uint256 root) public view returns (bytes32) {
        if (!exists(root)) revert NoSuchClass(root);
        return keccak256(abi.encode(ROOT_TAG, block.chainid, address(this), root));
    }

    /// @notice Fold a trajectory into a name.
    /// @dev    `pure`: this is the whole claim. A name can be checked by anyone
    ///         holding the root name and the path, with no access to the ledger's
    ///         state — the name is a statement about shape rather than a pointer
    ///         into storage.
    function nameFromPath(bytes32 rootName, uint256[] memory ordinals) public pure returns (bytes32 name) {
        name = rootName;
        for (uint256 i; i < ordinals.length; ++i) {
            name = keccak256(abi.encode(name, ordinals[i]));
        }
    }

    /// @notice Intrinsic name of a class.
    function nameOf(uint256 handle) public view override returns (bytes32) {
        return nameFromPath(rootNameOf(rootOfClass(handle)), pathOf(handle));
    }

    /// @notice Intrinsic name of the class currently containing `slot`.
    /// @dev    Not the name of the slot. Until the class is a singleton this is
    ///         shared with every other member, which is the point.
    function nameOfSlot(uint256 slot) external view returns (bytes32) {
        return nameOf(classOf(slot));
    }

    /// @notice Intrinsic name of `slot` as an element.
    /// @dev    Reverts unless the slot is rigid, for the same reason `ownerOf`
    ///         does: below cardinality 1 there is no element to name, only a
    ///         class. Naming and distinguishing are the same act.
    function elementNameOf(uint256 slot) external view override returns (bytes32) {
        uint256 h = classOf(slot);
        if (sizeOf(h) != 1) revert NotRigid(slot);
        return nameOf(h);
    }

    /// @dev Index of `child` among `parent`'s departures.
    function _ordinalOf(uint256 parent, uint256 child) internal view returns (uint256) {
        uint256[] storage kids = _children[parent];
        for (uint256 i; i < kids.length; ++i) {
            if (kids[i] == child) return i;
        }
        // A class's parent always lists it. Unreachable unless the downward
        // index and the parent pointer have gone out of step.
        revert NoSuchClass(child);
    }
}
