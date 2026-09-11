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
4. **Occurrence identity is caller-supplied `bytes32`.** The contract stores nothing per occurrence and cannot notice a resubmission. Idempotency is owned by the backend: cmless `inventory.provenance_chain_operations` (queued → submitted → confirmed → failed) is the record of what has been sent, and the listener consults it before submitting. A contract-side nonce would be a word per operation (≈22k) spent on a question the backend already answers.
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
 ├─ LedgerRigidTokens     ERC-721 fragment: Transfer on serialisation/termination, ownerOf for singletons; no storage
 ├─ LedgerLoggable        (existing) stored Fact rows + snapshot; readable history
 ├─ LedgerEvents          (existing) stored occurrences, discriminants, names
 └─ LedgerPathIds         (existing) intrinsic names from the cut path

RefinementLedger  = Core + Emit + Held + Index        (classic abstract; old API: Class view struct, _allocate(count,to), _refine, ownerOf)
Ledger            = RefinementLedger + PathIds + Loggable   (unchanged API)
EventLedger       = RefinementLedger + Events               (unchanged API)
ProvenanceLedger  = Core + Emit + Narrative + Commit + RigidTokens + Writer   (lean Crcles composition)
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

### LedgerRigidTokens

Serialisation (`NFCTagApplied`) is a cut of one, and a singleton class is named by its only slot. So `isRigid(slot)` is `_intervals[slot].hi == slot && !terminal` — one cold read, no index — and `ownerOf(slot)` needs nothing stored. The extension emits `Transfer(0, custodian, slot)` when either side of a cut reaches cardinality 1 (the departing bottle, and the last remaining member when a lot is down to one), `Transfer(custodian, 0, slot)` when a singleton is terminated, and answers `ownerOf` with the custodian. Read-only fragment: no `transferFrom`, no approvals, no `balanceOf`. Per-bottle owners would be `LedgerHeld` at cardinality 1, a word per bottle, when the model stops being custodial.

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
| `allocate(1)` / `allocate(12)` / `allocate(60)` | 81.3k / 81.7k / 81.7k | 60.3k / 60.7k / 60.7k | 37.7k |
| `touch` full-width on a lot | 36.0k | 15.0k | 11.7k |
| `touch` full-width on a serialised bottle (depth 1) | 40.7k | 19.7k | — |
| `touch` cutting 1 of 11 (serialisation, incl. `Transfer`) | 68.9k | 47.9k | 39.4k (no `Transfer`) |
| `touch` cutting 1 at depth 4 | 77.8k | 56.8k | — |
| `terminate` 1 of 11 (incl. mint + burn `Transfer`) | 72.7k | 51.7k | — |
| `touchMany`: serialise 11 bottles of one lot | 372.0k | 351.0k (33.8k / bottle) | — |
| classic `RefinementLedger` core `mint(12)` | 127.3k | 106.3k | |
| classic `Ledger.mint(12)` / `record` / cutting `refine` | 219.2k / 84.0k / 247.3k | 198.2k / 63.0k / 226.3k | |

What the pieces cost: `LedgerCommit` is one fresh word per lot (+23k on `allocate`) and one dirty write per fact (+3.3k on a full-width touch, +6k on a cut including the parent walk). `LedgerRigidTokens` is one `Transfer` LOG per serialisation (+2.4k) and two when a singleton is terminated (+4.6k). Depth adds one cold SLOAD (≈2.2k) per level to every fact, because `rootOf` walks.

### Crurated, measured the same way

`Crurated_Smart_Contracts_fork` at `af61c74`, forge 1.2.3, solc 0.8.30, optimizer 200 runs, `--isolate`, through the ERC-1967 proxy, `reason = ""`:

| Transaction | N = 1 | N = 6 | N = 12 | N = 60 |
|---|---:|---:|---:|---:|
| `mint(N)`, 46-char CIDs | 135.0k | 601.6k | 1,157.0k | 5,600.5k |
| `mint(12)`, 7-char test CIDs | | | 616.8k | |
| `migrate(12)` with 3 statuses each | | | 1,321.1k | |
| `update(N)`, one status each | 43.8k | 69.3k | 100.9k | 352.0k |

Fits within 0.3%: `mint(N) = 42.3k + 92.6k·N` with production CIDs (`47.9k·N` with test CIDs); `update(N) = 38.6k + 5.2k·N`. A 32-byte `reason` adds ≈700 per status. The earlier 50,239/token figure was the test-CID marginal; the production-CID estimate of +44k/token is confirmed (+44.7k measured).

### The grid

N bottles in one lot, M lot-wide facts, fraction f serialised (one batched transaction), K facts per serialised bottle (one batched transaction per fact). Comparator: same transaction shape on Crurated — one `mint`, one batched `update` per fact, serialisation as a status — using the fitted functions above.

| N | M | f | K | ledger total | per bottle | Crurated test-CID | Crurated prod-CID |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | 0 | 100% | 0 | 121.1k | 121.1k | 134.0k | 178.7k |
| 1 | 3 | 100% | 4 | 378.2k | 378.2k | 440.6k | 485.3k |
| 6 | 0 | 100% | 0 | 288.9k | 48.1k | 399.5k | 667.7k |
| 6 | 3 | 100% | 4 | 699.8k | 116.6k | 888.1k | 1,156.3k |
| 12 | 0 | 0% | 0 | 81.8k | 6.8k | 617.1k | 1,153.5k |
| 12 | 3 | 0% | 0 | 189.9k | 15.8k | 920.1k | 1,456.5k |
| 12 | 0 | 100% | 0 | 487.1k | 40.6k | 718.1k | 1,254.5k |
| 12 | 3 | 100% | 0 | 595.3k | 49.6k | 1,021.1k | 1,557.5k |
| 12 | 3 | 100% | 4 | 1,084.6k | 90.4k | 1,425.1k | 1,961.5k |
| 12 | 3 | 50% | 4 | 736.1k | 61.3k | 1,269.1k | 1,805.5k |
| 60 | 0 | 100% | 0 | 2,076.5k | 34.6k | 3,266.9k | 5,948.9k |
| 60 | 3 | 100% | 0 | 2,185.8k | 36.4k | 4,318.7k | 7,000.7k |
| 60 | 3 | 100% | 4 | 4,196.5k | 69.9k | 5,721.1k | 8,403.1k |
| 60 | 3 | 50% | 4 | 2,302.8k | 38.4k | 4,941.1k | 7,623.1k |
| 60 | 3 | 0% | 0 | 190.0k | 3.2k | 3,968.1k | 6,650.1k |

These rows are illustrative shapes, not Crcles data. Reading them:

- **The ledger wins every row**, by 10–27% against test-CID Crurated at N ≤ 6 and by 1.5–3× against production-CID Crurated from N = 6. Both contracts pay a ~40k fixed cost per transaction, so N = 1 is close and the population is where the gap opens.
- **Bottles never serialised cost ≈ 0 marginal** (60 bottles, 0% serialised: 3.2k per bottle). The gain comes from not paying per-bottle storage at mint.
- **Serialisation is where per-bottle storage is paid**: 33.8k per bottle batched (fresh `Interval`, `Cut`, `Logged`, `Transfer`). It is 36% of Crurated's production-CID cost per token at mint, and it is only paid for bottles that are actually tagged.
- **Per-bottle facts after serialisation are the weakest row**: ≈10k each batched versus Crurated's 5.2k marginal, because each touches a cold word and walks to the root. K-heavy, fully serialised lots narrow the gap (60/3/100%/4 is 1.4× against test CIDs, 2× against production). If Crcles' per-bottle event volume grows well past four per bottle, this is the row to revisit.

### Computing the figures for real Crcles data

The grid is a sum of measured transactions, so any N, M, f, K can be priced without re-running anything, using the per-transaction figures above:

```
ledger(N, M, f, K) = 81.7k                                  allocate, flat in N
                   + M × 36.0k                              one lot-wide fact per transaction
                   + [fN > 0] × (21k + 33.8k × fN)          serialise fN bottles in one transaction
                   + K × (21k + ≈10k × fN)                  one batched per-bottle fact per transaction

crurated(N, M, f, K) = 42.3k + 92.6k × N                    mint, production CIDs (47.9k with test CIDs)
                     + M × (38.6k + 5.2k × N)               one batched update per lot-wide fact
                     + [fN > 0] × (1 + K) × (38.6k + 5.2k × fN)   tagging + per-bottle facts as updates
```

To get N, f and the event mix from production rather than from these examples: N is the lot size at `allocate` (the `eligible_roots` / `touched_eligible_root_count` query in the handoff's Step 0 gate gives the distribution over inbound batches); f is the share of a lot that reaches `NFCTagApplied` before the lot is exhausted; M is the count of lot-wide event kinds in the catalogue that fire before serialisation (receipt, storage moves, shipments of whole lots); K is the count of kinds that fire per serialised bottle afterwards. Substitute, or add a `_row(N, M, f, K)` line to `test_gas_grid` and run under `--isolate` for a measured figure. The per-bottle fact term is the one approximation in the formula (it depends on lot depth); the test measures it exactly.

## Testing

- All existing suites unchanged and green (`Laws`, `Ledger`, `EventLedger`, `PathIds`, `Invariants`, `Extension`, `Conformance`).
- `test/Core.t.sol`: laws on a bare core harness (tiling, permanence, gauge, terminal, overflow, hooks fire once each).
- `test/Provenance.t.sol`: writer gating, LOGs (`expectEmit`), head reproducible off-chain, `touchMany`, terminate, `Transfer` on serialisation / burn on termination, `ownerOf` and `isRigid`.
- `test/Gas.t.sol`: per-transaction costs and the N × M × f × K grid, run under `--isolate` (skips otherwise), with the classic core and `Ledger` measured the same way as calibration. `vm.cool` was tried first and rejected: it re-cools access but prices SSTORE against the in-transaction original value, under-counting rewrites by ~2.8k each.

## Out of scope

Transferable tokens (`transferFrom`, approvals, `balanceOf`), per-bottle owners, pause/upgrade, contract-side replay protection, event-id sequencing. Each is an extension or a deployment or backend concern; none changes the base.
