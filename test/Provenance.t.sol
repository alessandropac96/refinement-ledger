// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProvenanceLedger} from "../src/ProvenanceLedger.sol";
import {LedgerEmit} from "../src/extensions/LedgerEmit.sol";
import {LedgerNarrative} from "../src/extensions/LedgerNarrative.sol";
import {LedgerWriter} from "../src/extensions/LedgerWriter.sol";
import {LedgerRigidTokens} from "../src/extensions/LedgerRigidTokens.sol";

/// @dev The lean composition: what it emits, what it commits to, who may write.
///      Nothing here reads a fact back from the contract, because the contract
///      stores none — the assertions are the indexer's job, done by the test.
contract ProvenanceTest is Test {
    ProvenanceLedger internal ledger;

    address internal issuer = address(0x15);
    address internal stranger = address(0x5712);

    bytes32 internal constant RECEIVED = bytes32("RECEIVED");
    bytes32 internal constant SHIPPED = bytes32("SHIPPED");
    bytes32 internal constant TAGGED = bytes32("TAGGED");
    bytes32 internal constant BROKEN = bytes32("BROKEN");

    function setUp() public {
        ledger = new ProvenanceLedger(issuer);
        vm.startPrank(issuer);
    }

    function test_allocationEmitsStructureAndFactAndStoresOneWord() public {
        vm.expectEmit(address(ledger));
        emit LedgerEmit.Minted(1, 12);
        vm.expectEmit(address(ledger));
        emit LedgerNarrative.Logged(1, RECEIVED, bytes32("doc-1"), bytes32("cid-1"));

        uint256 lot = ledger.allocate(12, RECEIVED, bytes32("doc-1"), bytes32("cid-1"));

        assertEq(lot, 1);
        assertEq(ledger.sizeOf(lot), 12);
        assertEq(ledger.nextSlot(), 13);
    }

    function test_partialTouchCutsAndAttributesTheFactToTheDepartingSide() public {
        uint256 lot = ledger.allocate(12, RECEIVED, bytes32("doc-1"), 0);

        vm.expectEmit(address(ledger));
        emit LedgerEmit.Cut(lot, 10, 3);
        vm.expectEmit(address(ledger));
        emit LedgerNarrative.Logged(10, SHIPPED, bytes32("shipment-7"), 0);

        uint256 shipped = ledger.touch(lot, 3, SHIPPED, bytes32("shipment-7"), 0);

        assertEq(shipped, 10);
        assertEq(ledger.sizeOf(lot), 9);
        assertEq(ledger.sizeOf(shipped), 3);
        assertEq(ledger.parentOf(shipped), lot);
    }

    function test_fullWidthTouchCutsNothing() public {
        uint256 lot = ledger.allocate(5, RECEIVED, 0, 0);
        assertEq(ledger.touch(lot, 5, SHIPPED, bytes32("shipment-1"), 0), lot);
        assertEq(ledger.sizeOf(lot), 5);
    }

    function test_identificationIsACutToASingleton() public {
        uint256 lot = ledger.allocate(3, RECEIVED, 0, 0);
        uint256 bottle = ledger.touch(lot, 1, TAGGED, bytes32("nfc-A"), bytes32("cid-A"));

        assertEq(bottle, 3);
        assertEq(ledger.sizeOf(bottle), 1);
        assertEq(ledger.touch(bottle, 1, SHIPPED, bytes32("shipment-2"), 0), bottle, "a singleton is touched in full");
    }

    function test_touchManyLogsOneIdAcrossClasses() public {
        uint256 a = ledger.allocate(4, RECEIVED, 0, 0);
        uint256 b = ledger.allocate(6, RECEIVED, 0, 0);

        ProvenanceLedger.Touch[] memory touches = new ProvenanceLedger.Touch[](2);
        touches[0] = ProvenanceLedger.Touch(a, 4, SHIPPED, bytes32("shipment-9"), 0);
        touches[1] = ProvenanceLedger.Touch(b, 2, SHIPPED, bytes32("shipment-9"), 0);

        vm.expectEmit(address(ledger));
        emit LedgerNarrative.Logged(a, SHIPPED, bytes32("shipment-9"), 0);
        vm.expectEmit(address(ledger));
        emit LedgerNarrative.Logged(9, SHIPPED, bytes32("shipment-9"), 0);

        uint256[] memory subjects = ledger.touchMany(touches);
        assertEq(subjects[0], a);
        assertEq(subjects[1], 9);
    }

    function test_touchManyRejectsNothing() public {
        ProvenanceLedger.Touch[] memory none;
        vm.expectRevert(ProvenanceLedger.NoTouches.selector);
        ledger.touchMany(none);
    }

    function test_terminateFreezesAndLogsAgainstTheDead() public {
        uint256 lot = ledger.allocate(4, RECEIVED, 0, 0);

        vm.expectEmit(address(ledger));
        emit LedgerEmit.Terminated(4);
        vm.expectEmit(address(ledger));
        emit LedgerNarrative.Logged(4, BROKEN, bytes32("adj-3"), 0);

        uint256 dead = ledger.terminate(lot, 1, BROKEN, bytes32("adj-3"), 0);
        assertTrue(ledger.isTerminal(dead));
        assertEq(ledger.sizeOf(lot), 3);
    }

    /// The head is the fold of every fact under the root, in order, including
    /// the handle each was attributed to. An indexer holding the `Logged` events
    /// recomputes it with `fold` and nothing else.
    function test_headIsReproducibleFromTheLogsAlone() public {
        uint256 lot = ledger.allocate(6, RECEIVED, bytes32("doc"), bytes32("cid"));
        uint256 shipped = ledger.touch(lot, 2, SHIPPED, bytes32("ship"), 0);
        ledger.touch(lot, 4, TAGGED, bytes32("tag"), 0);

        bytes32 expected = ledger.fold(bytes32(0), lot, RECEIVED, bytes32("doc"), bytes32("cid"));
        expected = ledger.fold(expected, shipped, SHIPPED, bytes32("ship"), 0);
        expected = ledger.fold(expected, lot, TAGGED, bytes32("tag"), 0);

        assertEq(ledger.headOf(lot), expected);
        assertEq(ledger.headOf(shipped), expected, "one head per lot, whatever the handle asked through");
    }

    function test_headsAreIndependentAcrossLots() public {
        uint256 a = ledger.allocate(2, RECEIVED, bytes32("a"), 0);
        uint256 b = ledger.allocate(2, RECEIVED, bytes32("b"), 0);
        assertTrue(ledger.headOf(a) != ledger.headOf(b));

        bytes32 before = ledger.headOf(a);
        ledger.touch(b, 2, SHIPPED, 0, 0);
        assertEq(ledger.headOf(a), before, "a fact under one lot must not move another's head");
    }

    // --- rigid tokens --------------------------------------------------------

    function test_serialisationMintsATokenToTheCustodian() public {
        uint256 lot = ledger.allocate(3, RECEIVED, 0, 0);
        assertFalse(ledger.isRigid(lot));
        vm.expectRevert(abi.encodeWithSelector(LedgerRigidTokens.NotRigid.selector, lot));
        ledger.ownerOf(lot);

        vm.expectEmit(address(ledger));
        emit LedgerRigidTokens.Transfer(address(0), issuer, 3);
        uint256 bottle = ledger.touch(lot, 1, TAGGED, bytes32("nfc-A"), 0);

        assertTrue(ledger.isRigid(bottle));
        assertEq(ledger.ownerOf(bottle), issuer);
    }

    function test_theLastRemainingMemberIsAlsoAToken() public {
        uint256 lot = ledger.allocate(2, RECEIVED, 0, 0);

        vm.expectEmit(address(ledger));
        emit LedgerRigidTokens.Transfer(address(0), issuer, 2);
        vm.expectEmit(address(ledger));
        emit LedgerRigidTokens.Transfer(address(0), issuer, lot);
        ledger.touch(lot, 1, TAGGED, bytes32("nfc-A"), 0);

        assertTrue(ledger.isRigid(lot), "a remainder of one is identified by elimination");
        assertEq(ledger.ownerOf(lot), issuer);
    }

    function test_aLotOfOneIsATokenAtBirth() public {
        vm.expectEmit(address(ledger));
        emit LedgerRigidTokens.Transfer(address(0), issuer, 1);
        uint256 lot = ledger.allocate(1, RECEIVED, 0, 0);
        assertTrue(ledger.isRigid(lot));
    }

    function test_terminatingATokenBurnsIt() public {
        uint256 lot = ledger.allocate(3, RECEIVED, 0, 0);
        uint256 bottle = ledger.touch(lot, 1, TAGGED, bytes32("nfc-A"), 0);

        vm.expectEmit(address(ledger));
        emit LedgerRigidTokens.Transfer(issuer, address(0), bottle);
        ledger.terminate(bottle, 1, BROKEN, bytes32("adj"), 0);

        assertFalse(ledger.isRigid(bottle));
        vm.expectRevert(abi.encodeWithSelector(LedgerRigidTokens.NotRigid.selector, bottle));
        ledger.ownerOf(bottle);
    }

    function test_slotZeroIsNeverAToken() public view {
        assertFalse(ledger.isRigid(0));
    }

    function test_onlyTheWriterMayWrite() public {
        uint256 lot = ledger.allocate(2, RECEIVED, 0, 0);
        vm.stopPrank();

        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LedgerWriter.NotWriter.selector, stranger));
        ledger.allocate(1, RECEIVED, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(LedgerWriter.NotWriter.selector, stranger));
        ledger.touch(lot, 1, SHIPPED, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(LedgerWriter.NotWriter.selector, stranger));
        ledger.setWriter(stranger);
        vm.stopPrank();

        vm.prank(issuer);
        ledger.setWriter(stranger);
        assertEq(ledger.writer(), stranger);

        vm.prank(stranger);
        assertEq(ledger.touch(lot, 2, SHIPPED, 0, 0), lot);
    }

    function test_writerCannotBeZero() public {
        vm.expectRevert(LedgerWriter.ZeroWriter.selector);
        ledger.setWriter(address(0));
        vm.stopPrank();

        vm.expectRevert(LedgerWriter.ZeroWriter.selector);
        new ProvenanceLedger(address(0));
    }
}
