// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title  LedgerWriter
/// @notice A single account may write. The smallest authority model that makes a
///         composition deployable.
///
/// @dev    Independent of the core on purpose: it gates entry points, not
///         structural operations, so it composes with or without `LedgerHeld`.
///         A custodial issuer that keeps every class in its own custody needs
///         exactly this and nothing per class.
abstract contract LedgerWriter {
    address public writer;

    event WriterChanged(address indexed previous, address indexed current);

    error NotWriter(address caller);
    error ZeroWriter();

    constructor(address initialWriter) {
        _setWriter(initialWriter);
    }

    modifier onlyWriter() {
        if (msg.sender != writer) revert NotWriter(msg.sender);
        _;
    }

    function setWriter(address next) external onlyWriter {
        _setWriter(next);
    }

    function _setWriter(address next) internal {
        if (next == address(0)) revert ZeroWriter();
        emit WriterChanged(writer, next);
        writer = next;
    }
}
