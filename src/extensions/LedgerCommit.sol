// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LedgerNarrative} from "./LedgerNarrative.sol";

/// @title  LedgerCommit
/// @notice One word per genesis class that commits to every fact ever logged
///         under it.
///
/// @dev    The anchor a LOG-only narrative lacks. Anyone holding the `Logged`
///         events of a batch can refold them and compare with `headOf`; a
///         history that does not refold to the head has been tampered with or is
///         incomplete. The contract itself never reads the facts back.
///
///         Root granularity, deliberately. A head per class would have to be
///         copied into the child on every cut — a fresh word each time, which is
///         most of what a cut costs. A head per root is one dirty write per fact
///         regardless of how the batch has been divided, and verification replays
///         one lot's LOGs, which is bounded by the lot.
///
///         The fold includes `handle`, so the commitment covers *where* each fact
///         was attributed, not only what was said. Together with the sealed
///         gauge, that pins the structure a history claims.
abstract contract LedgerCommit is LedgerNarrative {
    mapping(uint256 => bytes32) internal _heads;

    function _afterLog(uint256 handle, bytes32 kind, bytes32 id, bytes32 payload) internal virtual override {
        super._afterLog(handle, kind, id, payload);
        uint256 root = rootOf(handle);
        _heads[root] = fold(_heads[root], handle, kind, id, payload);
    }

    /// @notice One step of the commitment, exposed so a verifier can refold a
    ///         history off chain or on.
    function fold(bytes32 head, uint256 handle, bytes32 kind, bytes32 id, bytes32 payload)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(head, handle, kind, id, payload));
    }

    /// @notice Commitment over every fact logged under `handle`'s genesis class.
    function headOf(uint256 handle) external view returns (bytes32) {
        return _heads[rootOf(handle)];
    }
}
