// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RefinementLedger} from "../src/RefinementLedger.sol";
import {LedgerLoggable} from "../src/extensions/LedgerLoggable.sol";
import {Ledger} from "../src/Ledger.sol";
import {PartitionCheck} from "./helpers/PartitionCheck.sol";

/// @dev Drives one batch through arbitrary sequences of refine / terminate /
///      record, always acting as the current holder so that authority is
///      satisfied and the fuzzer explores structure rather than access control.
contract Handler is Test {
    Ledger public ledger;
    uint256 public root;
    uint256 public batchSize;

    uint256[] public handles;
    uint256[] public rigidSeen;
    mapping(uint256 => bool) public everRigid;

    constructor(Ledger l, uint256 n) {
        ledger = l;
        batchSize = n;
        root = l.mint(n, _actor(0), bytes32("GENESIS"), 0);
        handles.push(root);
    }

    function handlesLength() external view returns (uint256) {
        return handles.length;
    }

    function rigidSeenLength() external view returns (uint256) {
        return rigidSeen.length;
    }

    function refine(uint256 hSeed, uint256 countSeed, uint256 toSeed) external {
        (uint256 h, RefinementLedger.Class memory c, bool ok) = _pick(hSeed);
        if (!ok) return;

        uint256 count = (countSeed % (c.hi - h + 1)) + 1;
        vm.prank(c.owner);
        uint256 s = ledger.refine(h, count, _actor(toSeed), bytes32("REFINE"), 0);

        if (s != h) handles.push(s);
        _noteRigid(h);
        _noteRigid(s);
    }

    function terminate(uint256 hSeed, uint256 countSeed) external {
        (uint256 h, RefinementLedger.Class memory c, bool ok) = _pick(hSeed);
        if (!ok) return;

        uint256 count = (countSeed % (c.hi - h + 1)) + 1;
        vm.prank(c.owner);
        uint256 s = ledger.terminate(h, count, bytes32("TERMINATE"), 0);

        if (s != h) handles.push(s);
        _noteRigid(h);
        _noteRigid(s);
    }

    function record(uint256 hSeed) external {
        (uint256 h, RefinementLedger.Class memory c, bool ok) = _pick(hSeed);
        if (!ok) return;

        vm.prank(c.owner);
        ledger.record(h, bytes32("RECORD"), 0);
    }

    function _pick(uint256 seed) internal view returns (uint256 h, RefinementLedger.Class memory c, bool ok) {
        h = handles[seed % handles.length];
        c = ledger.classAt(h);
        ok = !c.terminal;
    }

    function _noteRigid(uint256 h) internal {
        if (ledger.classAt(h).hi == h && !everRigid[h]) {
            everRigid[h] = true;
            rigidSeen.push(h);
        }
    }

    function _actor(uint256 seed) internal pure returns (address) {
        return address(uint160(0xA1 + (seed % 3)));
    }
}

contract InvariantsTest is PartitionCheck {
    uint256 internal constant BATCH = 12;

    Ledger internal ledger;
    Handler internal handler;

    function setUp() public {
        ledger = new Ledger();
        handler = new Handler(ledger, BATCH);
        targetContract(address(handler));
    }

    /// Laws 1 and 2. Classes tile the batch exactly, whatever was done to it.
    function invariant_partitionTiles() public view {
        assertTiles(ledger, handler.root(), BATCH);
    }

    /// Law 1, stated at the supply level: nothing after genesis moves the slot
    /// counter, so items cannot be invented or destroyed.
    function invariant_supplyIsFixedAfterGenesis() public view {
        assertEq(ledger.nextSlot(), handler.root() + BATCH, "slots were created or destroyed after genesis");
    }

    /// Law 4. Once a class reached cardinality 1 it must never grow again.
    function invariant_rigidityIsMonotone() public view {
        uint256 n = handler.rigidSeenLength();
        for (uint256 i; i < n; ++i) {
            assertEq(ledger.sizeOf(handler.rigidSeen(i)), 1, "a rigid class grew again");
        }
    }

    /// Every slot resolves to a class that actually contains it — the query
    /// counterpart of contiguity.
    function invariant_everySlotResolves() public view {
        uint256 root = handler.root();
        for (uint256 k = root; k < root + BATCH; ++k) {
            uint256 h = ledger.classOf(k);
            assertLe(h, k, "classOf returned a class above the slot");
            assertGe(ledger.classAt(h).hi, k, "classOf returned a class below the slot");
        }
    }

    /// Handles are never destroyed: everything the handler ever saw still exists.
    function invariant_handlesArePermanent() public view {
        uint256 n = handler.handlesLength();
        for (uint256 i; i < n; ++i) {
            assertTrue(ledger.exists(handler.handles(i)), "a handle disappeared");
        }
    }
}
