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
touchMany(Touch[] touches)                           onlyWriter; Touch{handle,count,kind,id,payload}; the batching primitive
terminate(handle, count, kind, id, payload) → subject
```

Reads: `exists`, `sizeOf`, `hiOf`, `parentOf`, `isTerminal`, `rootOf`, `headOf`, `fold`, `nextSlot`, `writer`. No `classOf`, no history, no holders: the indexer reconstructs the partition from `Minted`/`Cut`/`Terminated` and the narrative from `Logged`; `headOf` anchors it.

`touchMany` carries identity per touch rather than one shared `id`, because the batching the caller actually needs is "settle these queued operations in one transaction" — one occurrence across many classes is the special case where the ids repeat. Intrinsic cost is paid once and the lot's head is warm after the first touch, which is what makes per-bottle identification and per-bottle facts affordable.

## Gas, measured

`forge test --isolate --match-contract GasTest -vv`, forge 1.2.3, solc 0.8.24, optimizer 10k runs. Isolation runs every call as its own transaction, so figures are full transactions: 21k intrinsic + calldata + execution. "exec" strips the intrinsic.

| Transaction | total | exec | without `LedgerCommit` (exec) |
|---|---:|---:|---:|
| `allocate(1)` / `allocate(12)` / `allocate(60)` | 79.2k / 81.7k / 81.7k | 58.2k / 60.7k / 60.7k | 37.7k |
| `touch` full-width on a lot | 36.0k | 15.0k | 11.7k |
| `touch` full-width on an identified bottle (depth 1) | 40.7k | 19.7k | — |
| `touch` cutting 1 of 11 | 66.5k | 45.5k | 39.4k |
| `touch` cutting 1 at depth 4 | 75.4k | 54.4k | — |
| `terminate` 1 of 11 | 68.1k | 47.1k | — |
| `touchMany`: identify 11 bottles of one lot | 346.6k | 325.6k (31.5k / bottle) | — |
| classic `RefinementLedger` core `mint(12)` | 127.3k | 106.3k | |
| classic `Ledger.mint(12)` / `record` / cutting `refine` | 219.2k / 84.0k / 247.3k | 198.2k / 63.0k / 226.3k | |

What the commitment costs: one fresh word per lot (+23k on `allocate`), one dirty write per fact (+3.3k on a full-width touch, +6k on a cut including the parent walk). Depth adds one cold SLOAD (≈2.2k) per level to every fact, because `rootOf` walks.

### The grid

N bottles in one lot, M lot-wide facts, fraction f identified (one batched transaction), K facts per identified bottle (one batched transaction per fact). Comparator: same transaction shape on Crurated `af61c74` — one `migrate` for the lot, one batched `update` per fact, identification as a status — using per-token marginals measured there (`migrate` 50,239 with 7-byte test CIDs, `update` 6,135) and the production-CID estimate (+44,200/token for 46-byte CIDs). Those are constants applied to a model, not runs of that contract.

| N | M | f | K | ledger total | per bottle | Crurated test-CID | Crurated prod-CID |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | 0 | 100% | 0 | 118.9k | 118.9k | 98.4k | 142.6k |
| 1 | 3 | 100% | 4 | 375.8k | 375.8k | 288.3k | 332.5k |
| 6 | 0 | 100% | 0 | 275.0k | 45.8k | 380.2k | 645.4k |
| 6 | 3 | 100% | 4 | 685.8k | 114.3k | 784.9k | 1,050.1k |
| 12 | 0 | 0% | 0 | 81.7k | 6.8k | 623.9k | 1,154.3k |
| 12 | 3 | 0% | 0 | 189.7k | 15.8k | 907.7k | 1,438.1k |
| 12 | 0 | 100% | 0 | 459.3k | 38.3k | 718.5k | 1,248.9k |
| 12 | 3 | 100% | 0 | 567.4k | 47.3k | 1,002.3k | 1,532.7k |
| 12 | 3 | 100% | 4 | 1,056.6k | 88.1k | 1,380.8k | 1,911.2k |
| 12 | 3 | 50% | 4 | 721.8k | 60.2k | 1,196.8k | 1,727.2k |
| 60 | 0 | 100% | 0 | 1,936.8k | 32.3k | 3,424.4k | 6,076.4k |
| 60 | 3 | 100% | 0 | 2,046.1k | 34.1k | 4,591.7k | 7,243.7k |
| 60 | 3 | 100% | 4 | 4,056.7k | 67.6k | 6,148.1k | 8,800.1k |
| 60 | 3 | 50% | 4 | 2,232.6k | 37.2k | 5,227.9k | 7,879.9k |
| 60 | 3 | 0% | 0 | 189.8k | 3.2k | 4,202.6k | 6,854.6k |

Reading it:

- **N = 1 loses.** A lot of one pays the lot fixed cost (allocate + commitment head ≈ 82k) for one bottle. The algebra is for populations.
- **From N = 6 the ledger wins in every row**, against test-CID Crurated by 12–40% and against production-CID Crurated by 2–3×. The gain comes from not paying per-bottle storage at mint; bottles never identified cost ≈ 0 marginal (the 60-bottle, 0%-identified row is 3.2k per bottle).
- **Identification is where per-bottle storage is paid**: 31.5k per bottle batched, the fresh `Interval` word plus LOGs. That is the one cost that scales with f·N and it is 40–65% of what Crurated pays per token at mint.
- **Per-bottle facts after identification are the weak row**: ≈10k each batched versus the comparator's 6.1k marginal, because each touches a cold word and walks to the root. K-heavy, fully identified lots narrow the gap (60/3/100%/4 is a 34% win, not 2×). If Crcles' per-bottle event volume grows well past four per bottle, this row is the one to revisit.
- Every ledger figure includes intrinsic and calldata; the comparator's per-token marginals were measured under `--gas-report`, which amortises both. The comparison is therefore conservative for the ledger by a few k per transaction.

## Testing

- All existing suites unchanged and green (`Laws`, `Ledger`, `EventLedger`, `PathIds`, `Invariants`, `Extension`, `Conformance`).
- `test/Core.t.sol`: laws on a bare core harness (tiling, permanence, gauge, terminal, overflow, hooks fire once each).
- `test/Provenance.t.sol`: writer gating, LOGs (`expectEmit`), head reproducible off-chain, `touchMany`, terminate.
- `test/Gas.t.sol`: per-transaction costs and the N × M × f × K grid, run under `--isolate` (skips otherwise), with the classic core and `Ledger` measured the same way as calibration. `vm.cool` was tried first and rejected: it re-cools access but prices SSTORE against the in-transaction original value, under-counting rewrites by ~2.8k each.

## Out of scope

ERC-721 facade for rigid slots, pause/upgrade, nonce extension, event-id sequencing. Each is an extension or a deployment concern; none changes the base.
