# Lean core: the algebra alone, everything else an extension

- **Date**: 2026-09-11
- **Status**: approved design, implemented on branch `lean-core`
- **Supersedes nothing**: `Ledger` and `EventLedger` keep their public API and tests

## Problem

`RefinementLedger` at `27fc4c6` stores more than the algebra needs. Per allocation it writes a three-slot `Class`, pushes to `_roots`, and stores a holder; per cut it writes three fresh slots and pushes to `_children`; the narrative extensions store every fact as rows. Measured: `mint(10)` 141k, cutting `refine` 152–169k, `Ledger.record` 81k, against Crurated's emit-only `update` at 13k. Each of those slots serves an on-chain *read* (`classOf`, `historyOf`, `ownerOf`), not the correctness of the partition.

## Decisions taken

1. **Base = algebra only, no observability.** The base stores `nextSlot` and one packed slot per class. It emits nothing, checks no authority, keeps no index. Emitting, holding, indexing and narrating are extensions.
2. **Slot width `uint120`.** `hi` and `parent` share one slot with `terminal` (248 bits). Slot ids are dense (`nextSlot` hands them out contiguously), so width is a packing choice, not a capacity limit; 2^120 removes the question. Public ABI stays `uint256`.
3. **Holders are an extension.** Authorization is not interval algebra. `LedgerHeld` adds `holder`, the `NotHolder` check, and `Held`.
4. **Occurrence identity is caller-supplied `bytes32`.** The contract stores nothing per occurrence; replay protection is the caller's (cmless `provenance_chain_operations`) or an optional nonce extension.
5. **`Ledger` and `EventLedger` are conformance targets.** They are re-expressed as compositions of the new pieces; their tests and `Conformance.t.sol` stay green unchanged.
6. **Commitment at root granularity.** One `bytes32` head per genesis class, folded on every log. Verification replays one lot's LOGs. Per-class heads would add a fresh slot per cut and erase the gain.

## Architecture

```
RefinementCore            algebra: nextSlot, Interval{hi,parent,terminal}, _allocate/_touch/_terminate/_cut, hooks
 ├─ LedgerEmit            LOGs Minted/Cut/Terminated from hooks
 ├─ LedgerHeld            holder per class, holder-gated _allocate(count,to)/_refine/_terminate, Held
 ├─ LedgerIndex           _roots, _children, birthHi → classOf/isRigid/roots/childrenOf (on-chain descent)
 ├─ LedgerNarrative       LOG-only facts: Logged(handle, kind, id, payload); _afterLog hook
 ├─ LedgerCommit          per-root bytes32 head folded in _afterLog; headOf(handle)
 ├─ LedgerWriter          single writer role; onlyWriter
 ├─ LedgerLoggable        (existing) stored Fact rows + snapshot; readable history
 ├─ LedgerEvents          (existing) stored occurrences, discriminants, names
 └─ LedgerPathIds         (existing) intrinsic names from the cut path

RefinementLedger  = Core + Emit + Held + Index        (classic abstract; old API: Class view struct, _allocate(count,to), _refine, ownerOf)
Ledger            = RefinementLedger + PathIds + Loggable   (unchanged API)
EventLedger       = RefinementLedger + Events               (unchanged API)
ProvenanceLedger  = Core + Emit + Writer + Narrative + Commit   (lean Crcles composition)
```

### RefinementCore

```solidity
struct Interval { uint120 hi; uint120 parent; bool terminal; }
uint256 public nextSlot = 1;
mapping(uint256 => Interval) internal _intervals;

function _allocate(uint256 count) internal returns (uint256 handle);          // → _afterAllocate(handle, hi)
function _touch(uint256 handle, uint256 count) internal returns (uint256 subject); // cut iff count < size → _afterCut(parent, subject, count)
function _terminate(uint256 handle, uint256 count) internal virtual returns (uint256 subject); // _touch, then terminal → _afterTerminate(subject)
function _cut(uint256 handle, uint256 count) internal returns (uint256 subject); // not virtual: the gauge is sealed
function _live(uint256 handle) internal view returns (Interval storage);

exists, sizeOf, hiOf, parentOf, isTerminal, rootOf(handle)   // views; rootOf walks parents, no storage
errors NoSuchClass, ClassTerminal, BadCount, SlotOverflow
```

Existence is `hi != 0` (slot 0 is never allocated). A full-width touch changes no state and fires no hook; the entry point that called it records whatever it wants. `_cut` keeps the sealed gauge: departing members take the top `count` slots.

### Hooks

`_afterAllocate(handle, hi)`, `_afterCut(parent, subject, count)`, `_afterTerminate(subject)`. Invariants that must hold the instant a class divides live in `_afterCut` (index entry, birthHi). Choices (holder of the child, which fact) live in entry points.

### LedgerNarrative and LedgerCommit

```solidity
event Logged(uint256 indexed handle, bytes32 indexed kind, bytes32 indexed id, bytes32 payload);
function _log(uint256 handle, bytes32 kind, bytes32 id, bytes32 payload) internal;  // emit, then _afterLog(...)

mapping(uint256 => bytes32) internal _heads;   // root → head
head' = keccak256(abi.encode(head, handle, kind, id, payload))
function headOf(uint256 handle) external view returns (bytes32);  // head of handle's root
```

The metadata pointer travels as `payload` (a CIDv0 is a sha-256 digest behind a fixed `0x1220` prefix). Nothing per fact is stored.

### ProvenanceLedger (lean Crcles composition)

```solidity
allocate(count, kind, id, payload) → handle          onlyWriter
touch(handle, count, kind, id, payload) → subject    onlyWriter; count == size records, count < size cuts
touchMany(Touch[] touches, kind, id, payload)        onlyWriter; one occurrence, many classes, same id
terminate(handle, count, kind, id, payload) → subject
```

Reads: `exists`, `sizeOf`, `parentOf`, `isTerminal`, `rootOf`, `headOf`, `nextSlot`. No `classOf`, no history, no holders: the indexer reconstructs the partition from `Minted`/`Cut`/`Terminated` and the narrative from `Logged`; `headOf` anchors it.

## Gas expectations (opcode estimates, to be confirmed by `test/Gas.t.sol`)

| Operation | Writes | Estimate |
|---|---|---:|
| `allocate(N)` | `nextSlot` dirty, one fresh `Interval`, LOGs | 30–50k, flat in N |
| full-width `touch` | one SLOAD, LOG, head dirty write | ≈ 10k |
| cutting `touch` | fresh child `Interval`, parent dirty, LOGs, head dirty | ≈ 35–55k |
| `terminate` | dirty write, LOGs, head | ≈ 12k |

Reference (measured): Crurated `_createToken` + 1155 balance ≈ 50k/token with 7-byte test CIDs, ≈ 94k/token with production 46-byte CIDs; each status ≈ 6k. Break-even against a *lean* per-bottle contract depends on shared events M and identified fraction f, not on N alone; the benchmark reports the grid.

## Testing

- All existing suites unchanged and green (`Laws`, `Ledger`, `EventLedger`, `PathIds`, `Invariants`, `Extension`, `Conformance`).
- `test/Core.t.sol`: laws on a bare core harness (tiling, permanence, gauge, terminal, overflow, hooks fire once each).
- `test/Provenance.t.sol`: writer gating, LOGs (`expectEmit`), head reproducible off-chain, `touchMany`, terminate.
- `test/Gas.t.sol`: named per-operation tests for `--gas-report`, plus a grid over N, M, f, K logged as a table, with the classic `StructuralLedger` as calibration.

## Out of scope

ERC-721 facade for rigid slots, pause/upgrade, nonce extension, event-id sequencing. Each is an extension or a deployment concern; none changes the base.
