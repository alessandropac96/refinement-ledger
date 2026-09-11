// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RefinementCore} from "../RefinementCore.sol";

/// @title  LedgerRigidTokens
/// @notice The ERC-721 fragment that rigidity carves out: a slot becomes a token
///         the moment its class has one member, and `ownerOf` answers for it.
///
/// @dev    No storage. A singleton class is named by its only slot, so
///         `_intervals[slot].hi == slot` is the whole rigidity test — one cold
///         read, no descent, no index. Serialisation (a cut of one) therefore
///         *is* token creation, and the extension only has to say so:
///         `Transfer(0, custodian, slot)` when either side of a cut reaches
///         cardinality 1, `Transfer(custodian, 0, slot)` when a singleton is
///         terminated.
///
///         Ownership is custodial by construction. `_custodian()` is one address
///         for every token, which is what a platform holding inventory for its
///         customers is. Per-token owners would be a word per bottle; when that
///         becomes the model, it is `LedgerHeld` at cardinality 1, not this.
///
///         Read-only fragment on purpose: no `transferFrom`, no approvals, no
///         `balanceOf`. Marketplaces and wallets that index `Transfer` see mints
///         and burns; nothing here claims the tokens move.
abstract contract LedgerRigidTokens is RefinementCore {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    error NotRigid(uint256 slot);

    function _custodian() internal view virtual returns (address);

    function _afterAllocate(uint256 handle, uint256 hi) internal virtual override {
        super._afterAllocate(handle, hi);
        if (hi == handle) _mintToken(handle);
    }

    function _afterCut(uint256 parent, uint256 subject, uint256 count) internal virtual override {
        super._afterCut(parent, subject, count);
        if (count == 1) _mintToken(subject);
        if (_intervals[parent].hi == parent) _mintToken(parent);
    }

    function _afterTerminate(uint256 subject) internal virtual override {
        super._afterTerminate(subject);
        if (_intervals[subject].hi == subject) emit Transfer(_custodian(), address(0), subject);
    }

    function _mintToken(uint256 slot) internal {
        emit Transfer(address(0), _custodian(), slot);
    }

    /// @notice Whether `slot` denotes one object: its class is a live singleton.
    function isRigid(uint256 slot) public view returns (bool) {
        Interval storage c = _intervals[slot];
        return slot != 0 && c.hi == slot && !c.terminal;
    }

    /// @notice Owner of `slot` as a token. Reverts unless `isRigid(slot)`, as
    ///         ERC-721 requires for a token that does not exist.
    function ownerOf(uint256 slot) external view returns (address) {
        if (!isRigid(slot)) revert NotRigid(slot);
        return _custodian();
    }
}
