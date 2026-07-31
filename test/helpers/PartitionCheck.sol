// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RefinementLedger} from "../../src/RefinementLedger.sol";

/// @dev Shared check for Laws 1 and 2. Walks the cut tree of a batch and asserts
///      that its classes tile the batch interval exactly — no gap, no overlap, no
///      class of cardinality zero, nothing outside the allocated range.
///
///      This single assertion is the conservation proof: because slots are
///      allocated once and intervals only ever subdivide, tiling is equivalent to
///      "no item was invented and none went missing".
abstract contract PartitionCheck is Test {
    uint256 internal constant MAX_CLASSES = 512;

    function _collect(RefinementLedger l, uint256 root) internal view returns (uint256[] memory out) {
        uint256[] memory stack = new uint256[](MAX_CLASSES);
        uint256[] memory found = new uint256[](MAX_CLASSES);
        uint256 sp;
        uint256 n;

        stack[sp++] = root;
        while (sp > 0) {
            uint256 h = stack[--sp];
            found[n++] = h;
            uint256[] memory kids = l.childrenOf(h);
            for (uint256 i; i < kids.length; ++i) {
                stack[sp++] = kids[i];
            }
        }

        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = found[i];
        }
    }

    function _sort(uint256[] memory a) internal pure {
        for (uint256 i = 1; i < a.length; ++i) {
            uint256 v = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > v) {
                a[j] = a[j - 1];
                --j;
            }
            a[j] = v;
        }
    }

    function assertTiles(RefinementLedger l, uint256 root, uint256 size) internal view {
        uint256[] memory hs = _collect(l, root);
        _sort(hs);

        uint256 expect = root;
        for (uint256 i; i < hs.length; ++i) {
            assertEq(hs[i], expect, "gap or overlap in the partition");
            uint256 hi = l.classAt(hs[i]).hi;
            assertGe(hi, hs[i], "class with cardinality below 1");
            expect = hi + 1;
        }
        assertEq(expect, root + size, "partition does not cover the batch exactly");
    }

    /// @dev Structural digest of a batch: every class interval and its terminal
    ///      flag. Two ledgers driven by the same counts must agree on this
    ///      regardless of who called, when, or where things were sent.
    function partitionDigest(RefinementLedger l, uint256 root) internal view returns (bytes32) {
        uint256[] memory hs = _collect(l, root);
        _sort(hs);

        bytes memory acc;
        for (uint256 i; i < hs.length; ++i) {
            RefinementLedger.Class memory c = l.classAt(hs[i]);
            acc = abi.encodePacked(acc, hs[i], c.hi, c.terminal);
        }
        return keccak256(acc);
    }
}
