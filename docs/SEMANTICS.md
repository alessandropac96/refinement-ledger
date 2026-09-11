# Operational semantics

Notation. A class is written `[lo, hi]`. Its handle is `lo`. Its cardinality is
`|h| = hi - lo + 1`, always `>= 1`. `log(h)` is the fact list of handle `h`.
`L(h)` is `|log(h)|`.

## State

```
nextSlot : uint                       -- next unallocated slot, starts at 1
classes  : handle -> Class            -- Class { hi, birthHi, parent, parentLogLen, owner, terminal }
logs     : handle -> Fact[]           -- append-only
children : handle -> handle[]         -- cuts spawned by this class, in creation order
roots    : handle[]                   -- batch roots, ascending
```

A class's `lo` is its key, so it is never stored. `birthHi` is fixed at birth and
`hi <= birthHi` forever. `parent == 0` marks a genesis class; slot `0` is never
allocated, so `0` is an unambiguous sentinel.

`Fact` is `(kind, payload, at, author)`. `kind` and `payload` are opaque to the
core.

## Derived

```
exists(h)     := classes[h].birthHi != 0
size(h)       := classes[h].hi - h + 1
rigid(h)      := size(h) == 1
live(h)       := exists(h) && !classes[h].terminal
```

## Operations

### `mint(count, to, kind, payload) -> h`

Allocates a fresh batch. The only operation that introduces slots.

```
pre    count > 0
       to != 0

post   h = nextSlot@pre
       nextSlot = nextSlot@pre + count
       classes[h] = { hi: h+count-1, birthHi: h+count-1, parent: 0,
                      parentLogLen: 0, owner: to, terminal: false }
       log(h) = [ (kind, payload, now, msg.sender) ]
       roots += [h]
```

Permissionless by design. Batches are disjoint and independently owned, so a
forged batch is only ever someone else's batch. Issuance policy is a deployment
concern, not a core one.

### `refine(h, count, to, kind, payload) -> s`

The single refinement primitive. Records that an event touched `count` members of
`h`, and that those members are now held by `to`.

```
pre    live(h)
       msg.sender == classes[h].owner
       0 < count <= size(h)
       to != 0
```

Two cases.

**`count == size(h)`** — the event touched every member, so nothing is
distinguished and no cut occurs:

```
post   s = h
       classes[h].hi unchanged
       classes[h].owner = to
       log(h) = log(h)@pre ++ [ (kind, payload, now, msg.sender) ]
```

**`count < size(h)`** — the touched members depart. They take the top `count`
slots; the untouched remainder keeps the handle and is not modified:

```
post   s = classes[h].hi@pre - count + 1
       classes[s] = { hi: classes[h].hi@pre, birthHi: classes[h].hi@pre,
                      parent: h, parentLogLen: L(h)@pre,
                      owner: to, terminal: false }
       log(s) = [ (kind, payload, now, msg.sender) ]
       classes[h].hi = classes[h].hi@pre - count
       classes[h].owner unchanged
       log(h) unchanged                     -- Law 5
       children[h] += [s]
```

Note `log(h)` is untouched in the cut case. The remainder's cardinality changed;
its members' history did not. Cardinality is read from the cut tree, never from
the log.

`to == classes[h].owner` is legal and means "divide without transferring" — a
distinguishing event that is not a change of custody.

### `record(h, kind, payload)`

Sugar for `refine(h, size(h), classes[h].owner, kind, payload)`. An observation
true of every member, changing nothing structural.

### `terminate(h, count, kind, payload) -> s`

`count` members leave the population.

```
pre    live(h)
       msg.sender == classes[h].owner
       0 < count <= size(h)

post   count == size(h):  s = h,  classes[h].terminal = true
                          log(h) = log(h)@pre ++ [ (kind, payload, now, msg.sender) ]

       count <  size(h):  cut exactly as in refine, with to = classes[h].owner
                          classes[s].terminal = true
                          log(h) unchanged
```

Terminal classes are frozen: they cannot be refined, recorded, or terminated
again. They keep their interval and their owner — the interval because
conservation is structural and compaction would break it, the owner because who
held an item when it left the population is part of the record.

Since termination is a "touched" event, dead slots go high within their class.
Live supply is therefore a union of intervals, **not** a prefix of the batch —
`[1..10]` cut to `[1..4] [5..10]` and then `[3..4]` terminated leaves live
`[1..2] ∪ [5..10]`. Do not build supply queries on a prefix assumption; the live
count is maintained, not derived.

## Queries

### `classOf(slot) -> h`

The live class containing `slot`. Descends the cut tree:

```
h := largest root <= slot            -- binary search over `roots`
loop:
  if slot <= classes[h].hi: return h
  h := the unique c in children[h] with c <= slot <= classes[c].birthHi
```

Terminates in `depth(slot)` steps. Each step scans `children[h]`, so this is a
convenience view, not a hot path — indexers should reconstruct the partition from
events.

### `historyOf(slot) -> Fact[]`

`historyOfClass(classOf(slot))`.

### `historyOfClass(h) -> Fact[]`

Walks the parent chain, taking each ancestor's log **truncated to the snapshot the
child recorded at birth**, and concatenates genesis-first:

```
take := L(h)
cur  := h
segments := []
loop:
  segments = [(cur, take)] ++ segments
  if classes[cur].parent == 0: break
  take = classes[cur].parentLogLen
  cur  = classes[cur].parent
```

The truncation is what keeps a class that departed in 2027 from inheriting facts
its parent accrued in 2030.

### `ownerOf(slot)`

Reverts unless `classOf(slot)` is rigid; otherwise returns that class's owner.

This is the whole misuse defence, and it costs nothing. A non-rigid slot has no
owner *as an item* — it is one anonymous member of a class, and the question
"who owns slot 3" has no answer that is not fiction. Ask `ownerOfClass` instead
and get an answer about the set.

Reverting here is also standard-conformant rather than deviant: ERC-721 already
requires `ownerOf` to revert for tokens that do not exist, and a slot that is not
yet rigid does not exist *as a token*. A facade may therefore emit
`Transfer(0, owner, slot)` at the moment of rigidification and present a perfectly
ordinary NFT to the outside world, while the core still never mints or burns.

## Invariants

Checked in `test/`:

| | statement |
|---|---|
| I1 | `nextSlot` only increases, and only in `mint` |
| I2 | for every class, `h <= hi <= birthHi`, so `size(h) >= 1` |
| I3 | `classes[h].hi` is non-increasing; `h` and `birthHi` never change |
| I4 | for every class, `children[h]` intervals are disjoint and exactly tile `(hi, birthHi]` |
| I5 | live classes of a batch partition `[root, root+count-1]` exactly, with no gap and no overlap |
| I6 | handles are never destroyed and never reused |
| I7 | once `rigid(h)`, always `rigid(h)` |
| I8 | a cut leaves `historyOf(k)` byte-identical for every non-departing `k` |
| I9 | permuting slots within a class yields an observationally identical ledger |

I8 and I9 are Laws 5 and 3. I9 is not expressible as a runtime assertion — it is a
statement about the implementation, discharged by the fixed gauge policy
(untouched low, touched high) plus the absence of any operation that can name an
individual member of a non-rigid class.

## Layout

The `classes` record above is the classic composition's view. It is realised in
layers, split along the line the semantics already draw between structure and
narrative:

| file | holds | depends on |
|---|---|---|
| `src/RefinementCore.sol` | the algebra: `nextSlot`, one packed `Interval { hi, parent, terminal }` per class, cuts, gauge, the five laws | nothing |
| `src/extensions/LedgerEmit.sol` | `Minted` / `Cut` / `Terminated` LOGs | the core |
| `src/extensions/LedgerHeld.sol` | `owner`, holder-gated `_allocate(count, to)` / `_refine` / `_terminate`, `Held` | the core |
| `src/extensions/LedgerIndex.sol` | `birthHi`, `children`, `roots`, `classOf`, `isRigid` | the core |
| `src/RefinementLedger.sol` | Core + Emit + Held + Index: `Class`, `classAt`, `ownerOf` | the three |
| `src/extensions/LedgerLoggable.sol` | facts: `Fact`, per-handle logs, snapshots, history reconstruction | `RefinementLedger` |
| `src/Ledger.sol` | the composed, deployable contract | all of it |

The core is `abstract` and knows nothing about `kind`, `payload`, `Fact`, owners,
or which slot a class was born with. A filtration divides classes; it has no
opinion on *why* or *for whom*, and every law in this document holds with every
layer removed — `test/Core.t.sol` runs them against the bare core, and
`test/Extension.t.sol` carries the worked example through the classic
composition with no provenance attached.

Compositions that read through an indexer rather than on chain drop `LedgerIndex`
and `LedgerHeld` altogether; `src/ProvenanceLedger.sol` is one, and
`docs/superpowers/specs/2026-09-11-lean-core-design.md` measures what that saves.

The entry points in `Ledger.sol` are four lines each, and every one of them has
the same shape: a structural operation, then the fact the caller chose to record.
That is not a coincidence of style — it is the hook rule below, read off the
finished code.

## Extension seams

The structural operations are internal (`_allocate(count)`, `_touch`,
`_terminate`, `_cut`) and every public entry point is a thin wrapper over them, so
a composition can present a different API without reimplementing the algebra.

Three hooks, all `virtual`, all expected to call `super`:

| hook | runs | for |
|---|---|---|
| `_afterAllocate(handle, hi)` | end of `_allocate` | per-batch bookkeeping — the root index, the `Minted` LOG |
| `_afterCut(parent, subject, count)` | inside `_cut`, atomically with the interval surgery | whatever must be true the instant a class divides — the downward index and `birthHi` (`LedgerIndex`), the log snapshot (`LedgerLoggable`), the `Cut` LOG |
| `_afterTerminate(subject)` | end of `_terminate`, after the class is frozen | the `Terminated` LOG |

A full-width touch changes no state and fires no hook; the entry point that
called it records whatever it wants.

Each layer overrides, calls `super` first, then does its own work, so by the time
a hook body runs everything below it has already been written. `LedgerLoggable`
relies on this: it reads `_logs[parent].length` knowing the interval surgery is
complete.

The rule for what belongs in a hook:

> If it would be a **bug** for a caller to forget it, it goes in the hook. If it
> is a **choice**, it belongs in the entry point.

The log snapshot is the clearest case. It must be atomic with the cut, because a
concrete contract that forgot to take it would produce silently wrong history
rather than a loud failure. By contrast, who receives the departing class and what
fact gets recorded are caller intent, and live in `refine`.

### `_cut` is not virtual, on purpose

The gauge arithmetic — touched members take the top `count` slots, the remainder
keeps `lo` — is a semantic boundary, not an extension point. A child able to
redefine which slots depart would destroy Law 3 and, with it, canonical form, and
nothing downstream would notice until two indexers disagreed about the same batch.
Children react to cuts; they do not define them.

The same applies to conservation: interval subdivision and `nextSlot` monotonicity
are sealed.

## What is deliberately absent

- **merge / fuse** — see the README. It is the only operation that would fragment
  an interval.
- **compaction of terminal intervals** — buys nothing once fragmentation is
  impossible, and would destroy the structural conservation proof.
- **marking** — binding an external identifier to a rigid slot is a claim about
  the physical world. Rigidity is structural and automatic; marking is not, and
  belongs in a layer above.
- **authority in the core** — the core enforces nothing about who may divide
  what. `LedgerHeld` adds "only the holder"; `LedgerWriter` adds "only one
  account". Any richer policy is another extension or a wrapper.
