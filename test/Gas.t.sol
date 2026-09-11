// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ProvenanceLedger} from "../src/ProvenanceLedger.sol";
import {Ledger} from "../src/Ledger.sol";
import {StructuralLedger} from "./Extension.t.sol";
import {LedgerEmit} from "../src/extensions/LedgerEmit.sol";
import {LedgerNarrative} from "../src/extensions/LedgerNarrative.sol";
import {LedgerWriter} from "../src/extensions/LedgerWriter.sol";

/// @dev The lean composition minus the commitment, to price `LedgerCommit` alone.
contract LogOnlyLedger is LedgerEmit, LedgerNarrative, LedgerWriter {
    constructor(address w) LedgerWriter(w) {}

    function allocate(uint256 count, bytes32 kind, bytes32 id, bytes32 payload)
        external
        onlyWriter
        returns (uint256 h)
    {
        h = _allocate(count);
        _log(h, kind, id, payload);
    }

    function touch(uint256 handle, uint256 count, bytes32 kind, bytes32 id, bytes32 payload)
        external
        onlyWriter
        returns (uint256 s)
    {
        s = _touch(handle, count);
        _log(s, kind, id, payload);
    }
}

/// @title  Gas benchmark for the lean composition
/// @notice Run with `forge test --isolate --match-contract GasTest -vv`.
///
/// @dev    Isolation makes every top-level call from this contract its own
///         transaction, so each figure is a full transaction as a user would pay
///         it: 21,000 intrinsic, calldata, cold account, cold slots, and SSTORE
///         priced against committed state. The tests refuse to run without it,
///         because same-transaction measurement silently under-counts rewrites
///         of slots touched earlier in the test. Without the flag they skip.
///
///         The grid models a lot of N bottles: allocated in one transaction,
///         receiving M lot-wide facts (one transaction each), then a fraction f
///         identified in one batched transaction (one cut each), then K facts
///         per identified bottle (one batched transaction per fact). The
///         Crurated comparator uses the same transaction shape — one `migrate`
///         for the lot, one batched `update` per fact — with per-token marginals
///         measured at `af61c74` (`migrate` 50,239/token with 7-byte test CIDs,
///         `update` 6,135/token) plus the production CID estimate (46-byte CIDs
///         are three string slots: +44,200/token). Those are constants, not runs
///         of that contract; identification there is an ordinary status update.
contract GasTest is Test {
    ProvenanceLedger internal ledger;
    LogOnlyLedger internal noCommit;
    StructuralLedger internal classicCore;
    Ledger internal classicLedger;

    address internal issuer = address(0x15);

    uint256 internal lot;
    uint256 internal deepLot;
    uint256 internal bottle;

    uint256 internal constant INTRINSIC = 21_000;
    uint256 internal constant CRURATED_MINT_TEST_CID = 50_239;
    uint256 internal constant CRURATED_MINT_PROD_CID = 94_439;
    uint256 internal constant CRURATED_STATUS = 6_135;

    function setUp() public {
        ledger = new ProvenanceLedger(issuer);
        noCommit = new LogOnlyLedger(issuer);
        classicCore = new StructuralLedger();
        classicLedger = new Ledger();

        vm.startPrank(issuer);
        lot = ledger.allocate(12, "R", "doc", "cid");
        deepLot = ledger.allocate(12, "R", "doc", "cid");
        for (uint256 i; i < 4; ++i) {
            deepLot = ledger.touch(deepLot, ledger.sizeOf(deepLot) - 1, "S", bytes32(i), 0);
        }
        bottle = ledger.touch(lot, 1, "T", "nfc", 0);

        noCommit.allocate(12, "R", "doc", "cid");
        classicCore.mint(12, issuer);
        classicLedger.mint(12, issuer, "R", "cid");
        vm.stopPrank();
    }

    // --- one transaction each ------------------------------------------------

    function test_gas_allocate() public {
        _requireIsolation();
        _report("allocate(1)             ", _tx(abi.encodeCall(ledger.allocate, (1, "R", "d", "c"))));
        _report("allocate(12)            ", _tx(abi.encodeCall(ledger.allocate, (12, "R", "d", "c"))));
        _report("allocate(60)            ", _tx(abi.encodeCall(ledger.allocate, (60, "R", "d", "c"))));
    }

    function test_gas_touch() public {
        _requireIsolation();
        _report("touch full-width (lot)  ", _tx(abi.encodeCall(ledger.touch, (lot, 11, "S", "s", 0))));
        _report("touch full-width (bottle)", _tx(abi.encodeCall(ledger.touch, (bottle, 1, "E", "e", 0))));
        _report("cut 1 of 11             ", _tx(abi.encodeCall(ledger.touch, (lot, 1, "T", "nfc", 0))));
        _report("cut 1 at depth 4        ", _tx(abi.encodeCall(ledger.touch, (deepLot, 1, "T", "nfc", 0))));
        _report("terminate 1 of 11       ", _tx(abi.encodeCall(ledger.terminate, (lot, 1, "B", "adj", 0))));
    }

    function test_gas_touchManyOnOneLot() public {
        _requireIsolation();
        ProvenanceLedger.Touch[] memory t = new ProvenanceLedger.Touch[](11);
        for (uint256 i; i < 11; ++i) {
            t[i] = ProvenanceLedger.Touch(lot, 1, "T", bytes32(i), 0);
        }
        uint256 g = _tx(abi.encodeCall(ledger.touchMany, (t)));
        _report("identify 11 in one tx   ", g);
        console2.log("                            per bottle", g / 11);
    }

    function test_gas_withoutCommit() public {
        _requireIsolation();
        _report(
            "no-commit allocate(12)  ",
            _gasOn(address(noCommit), abi.encodeCall(noCommit.allocate, (12, "R", "d", "c")))
        );
        _report(
            "no-commit touch full    ", _gasOn(address(noCommit), abi.encodeCall(noCommit.touch, (1, 12, "S", "s", 0)))
        );
        _report(
            "no-commit cut 1 of 12   ", _gasOn(address(noCommit), abi.encodeCall(noCommit.touch, (1, 1, "T", "n", 0)))
        );
    }

    /// The classic core and the classic composition under the same method.
    function test_gas_calibrationClassic() public {
        _requireIsolation();
        _report(
            "classic core mint(12)   ", _gasOn(address(classicCore), abi.encodeCall(classicCore.mint, (12, issuer)))
        );
        _report(
            "classic Ledger mint(12) ",
            _gasOn(address(classicLedger), abi.encodeCall(classicLedger.mint, (12, issuer, "R", "c")))
        );
        _report(
            "classic Ledger record   ",
            _gasOn(address(classicLedger), abi.encodeCall(classicLedger.record, (1, "S", 0)))
        );
        _report(
            "classic Ledger cut 1/12 ",
            _gasOn(address(classicLedger), abi.encodeCall(classicLedger.refine, (1, 1, issuer, "T", 0)))
        );
    }

    // --- the grid ------------------------------------------------------------

    function test_gas_grid() public {
        _requireIsolation();
        console2.log("  N  M  f%  K |  ledger total | per bottle | crurated test-CID | crurated prod-CID");
        _row(1, 0, 100, 0);
        _row(1, 3, 100, 4);
        _row(6, 0, 100, 0);
        _row(6, 3, 100, 4);
        _row(12, 0, 0, 0);
        _row(12, 3, 0, 0);
        _row(12, 0, 100, 0);
        _row(12, 3, 100, 0);
        _row(12, 3, 100, 4);
        _row(12, 3, 50, 4);
        _row(60, 0, 100, 0);
        _row(60, 3, 100, 0);
        _row(60, 3, 100, 4);
        _row(60, 3, 50, 4);
        _row(60, 3, 0, 0);
    }

    function _row(uint256 n, uint256 m, uint256 fPct, uint256 k) internal {
        uint256 total = _scenario(n, m, fPct, k);
        (uint256 crTest, uint256 crProd) = _crurated(n, m, fPct, k);
        string memory shape = string.concat(
            _pad(vm.toString(n), 3),
            " ",
            _pad(vm.toString(m), 2),
            " ",
            _pad(vm.toString(fPct), 3),
            " ",
            _pad(vm.toString(k), 2)
        );
        string memory ours = string.concat(_pad(vm.toString(total), 13), " | ", _pad(vm.toString(total / n), 10));
        string memory theirs = string.concat(_pad(vm.toString(crTest), 17), " | ", vm.toString(crProd));
        console2.log(string.concat(shape, " | ", ours, " | ", theirs));
    }

    /// Same transaction shape on the comparator: one `migrate` for the lot, one
    /// batched `update` per fact, identification as a status update.
    function _crurated(uint256 n, uint256 m, uint256 fPct, uint256 k)
        internal
        pure
        returns (uint256 test, uint256 prod)
    {
        uint256 identified = n * fPct / 100;
        uint256 txs = 1 + m + (identified > 0 ? 1 + k : 0);
        test = txs * INTRINSIC + n * CRURATED_MINT_TEST_CID + CRURATED_STATUS * (n * m + identified * (1 + k));
        prod = test + n * (CRURATED_MINT_PROD_CID - CRURATED_MINT_TEST_CID);
    }

    /// One lot through its life, one transaction per step, batched where the
    /// world batches.
    function _scenario(uint256 n, uint256 m, uint256 fPct, uint256 k) internal returns (uint256 total) {
        total += _tx(abi.encodeCall(ledger.allocate, (n, "R", "doc", "cid")));
        uint256 h = ledger.nextSlot() - n;

        for (uint256 i; i < m; ++i) {
            total += _tx(abi.encodeCall(ledger.touch, (h, n, "S", bytes32(i), 0)));
        }

        uint256 identified = n * fPct / 100;
        if (identified == 0) return total;

        ProvenanceLedger.Touch[] memory ident = new ProvenanceLedger.Touch[](identified);
        for (uint256 i; i < identified; ++i) {
            ident[i] = ProvenanceLedger.Touch(h, 1, "T", bytes32(i), 0);
        }
        (uint256 g, bytes memory ret) = _txOn(address(ledger), abi.encodeCall(ledger.touchMany, (ident)));
        total += g;
        uint256[] memory bottles = abi.decode(ret, (uint256[]));

        for (uint256 j; j < k; ++j) {
            ProvenanceLedger.Touch[] memory facts = new ProvenanceLedger.Touch[](identified);
            for (uint256 i; i < identified; ++i) {
                facts[i] = ProvenanceLedger.Touch(bottles[i], 1, "E", bytes32(j), 0);
            }
            total += _tx(abi.encodeCall(ledger.touchMany, (facts)));
        }
    }

    // --- measurement ---------------------------------------------------------

    function _tx(bytes memory call) internal returns (uint256) {
        return _gasOn(address(ledger), call);
    }

    function _txOn(address target, bytes memory call) internal returns (uint256 used, bytes memory ret) {
        vm.prank(issuer);
        uint256 before = gasleft();
        bool ok;
        (ok, ret) = target.call(call);
        used = before - gasleft();
        require(ok, "measured call reverted");
    }

    /// A view call costs under 3k in-transaction and over 21k as a transaction.
    /// Skipped rather than failed, so the ordinary suite stays green.
    function _requireIsolation() internal {
        uint256 before = gasleft();
        (bool ok,) = address(ledger).call(abi.encodeCall(ledger.nextSlot, ()));
        bool isolated = ok && before - gasleft() > INTRINSIC;
        if (!isolated) console2.log("skipped: run with `forge test --isolate --match-contract GasTest -vv`");
        vm.skip(!isolated);
    }

    function _report(string memory label, uint256 total) internal pure {
        console2.log(label, total, "  exec ~", total - INTRINSIC);
    }

    function _gasOn(address target, bytes memory call) internal returns (uint256 used) {
        (used,) = _txOn(target, call);
    }

    function _pad(string memory s, uint256 width) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        while (b.length < width) {
            b = abi.encodePacked(" ", b);
        }
        return string(b);
    }
}
