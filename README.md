# Refinement Ledger

A provenance ledger for things that start out **indistinguishable** and become
**distinguishable** over time, without ever minting or burning a token.

Ten items are produced together. For ten years nobody can tell them apart, and
nobody needs to. Then six move somewhere else — now there are two groups, still
internally indistinguishable. Then three of the six are individually identified —
now there are three unique items and one group of three.

The usual answers both fail:

- **ERC-721 from the start** invents identity that does not exist. Nothing
  distinguishes item #3 from item #7, so any fact recorded against #3 is fiction.
- **ERC-1155** models the fungible phase correctly but has no way to *stop* being
  fungible. Splitting a class means burning one id and minting another, and the
  lineage connecting them lives outside the token model.

This ledger does neither. Ids are allocated once, at genesis, one per item, and
never created or destroyed again. What changes is only **how finely the ledger can
partition them**.

## The model

**Slot.** A pre-allocated id. `mint(10)` allocates ten contiguous slots. A slot is
a *placeholder*, not an item: until its class is a singleton it denotes "some
member of this class", not any particular physical object.

**Class.** A set of slots the ledger currently cannot tell apart, always a
contiguous interval `[lo, hi]`.

**Handle.** A class is named by its lowest slot, `lo`. A handle is stable for the
entire life of its lineage — `lo` never moves, only `hi` shrinks.

**Cut.** When an event touches only some members, the class divides. The members
it touched take the **top** `n` slots and get a new handle; the untouched
remainder keeps `[lo, hi-n]` and keeps its handle.

**Rigidity.** When a class reaches cardinality 1, its single slot is bound to one
physical object, permanently. That slot is now a normal NFT — unique id, single
owner, full history. No migration happened; the class just got small.

### Worked example

```
mint(10)                       class [1..10]  handle 1
6 of them move                 cut(1, 6)  ->  [1..4] handle 1   (untouched)
                                              [5..10] handle 5  (moved)
3 of the 6 are identified      cut(5, 3)  ->  [5..7] handle 5   (untouched)
                                              [8..10] handle 8  (identified)
                               then cut 8 twice more to reach singletons
```

Final partition: `[1..4] [5..7] [8] [9] [10]`. Slots 8, 9 and 10 are rigid — real
NFTs. Slots 1–7 are still honestly anonymous. Nothing was minted or burned after
`mint(10)`.

## Why intervals

Because ids inside a class are interchangeable, the ledger is free to *choose*
which ones depart. It always chooses a contiguous run, so a class is `(lo, hi)`
forever. This is what makes the whole thing cheap:

- a class is two numbers, whatever its cardinality
- a cut is O(1) and touches nothing proportional to the number of members
- conservation is structural — slots are allocated once and never created, so
  supply cannot inflate even under a buggy implementation
- the full history of any slot `k` is the chain of classes whose intervals
  contain `k`, ordered by containment

That last one is the point of the whole design. Provenance for a single item is a
walk up a chain of nested intervals — and it works identically whether the item is
rigid or still sitting anonymously in a class of forty.

## Gauge freedom

Choosing *which* six slots departed looks like fabricating a fact. It isn't:

> **Permuting slots within a class yields an identical ledger.**

The choice carries no information. It is a gauge choice, and it is fixed —
permanently and for exactly one slot — when a class reaches cardinality 1. Every
class-level fact recorded before that point is true of whichever physical object
ends up bound to the slot, so nothing false is ever written.

The gauge policy is fixed by convention so the ledger is canonical: **untouched
stays low, touched goes high.** The reason to prefer it over its inverse is that
an event that did not touch you should not rename you — otherwise dormant stock
would churn identifiers every time an unrelated sibling was sold.

## Cuts are structure, logs are narrative

The single most important separation in the design:

| | what it records | when it grows |
|---|---|---|
| **Cut tree** | intervals, cardinality, conservation | on every division |
| **Log** (per handle) | facts about members | only when something happens *to those members* |

A cut **does not append to the remainder's log**. If one item out of ten is
destroyed, the other nine are not modified in any way — their reconstructed
history is byte-identical before and after. The class changed in cardinality; its
members did not change in history. Cardinality belongs to the set, history belongs
to the members, and a member cannot observe the departure of another member.

This is not just hygiene. It means history length is proportional to what happened
*to you*, not to churn around you: ten items sitting untouched through forty
sibling departures have a log of length one.

The audit trail does not suffer, because interval partition *is* the conservation
proof. That a class of 4 is what remains of 10, and where the other 6 went, is
fully recoverable from the cut tree without polluting anyone's narrative.

### Snapshots

A departing class inherits its parent's log *as it stood at the moment it left*,
and the parent keeps living and appending afterwards. So each class records
`(parent, parentLogLen)` at birth. Without it, an item sold in 2027 would inherit
facts its old class accrued in 2030.

## Laws

1. **Conservation** — structural. Slots are allocated once, never created or
   destroyed. Live classes partition the batch interval exactly.
2. **Refinement** — classes only shrink; handles never disappear; intervals stay
   contiguous.
3. **Gauge invariance** — permuting slots within a class changes nothing
   observable.
4. **Rigidity is monotone** — once a class has cardinality 1, that slot denotes
   one physical object forever.
5. **Cut invariance** — a cut leaves the reconstructed history of every
   non-departing slot byte-identical.

Laws 3 and 5 are the correctness harness; see `test/`.

## Scope

The core is deliberately domain-free. There are no producers, no locations, no
serial numbers, no roles. Facts are opaque `(kind, payload)` pairs, and what they
mean is an implementer's concern. Physical marking — attaching a label or a tag to
a rigid slot — is likewise out of scope: rigidity is structural and automatic,
marking is a claim about the world.

What the ledger enforces is exactly four things: conservation, monotone
refinement, authority (only the holder may divide what it holds), and lineage
integrity. Everything else it merely *records, with attribution*. Keeping that
line visible from the outside is worth more than any amount of on-chain validation
of claims it cannot check.

## Non-goals

**Merging** is deliberately absent. Two classes fusing back into one
indistinguishable pool is a real phenomenon — it is what happens when someone
shuffles the shelves and loses track — but it destroys attribution, turns
provenance from a path into a set of candidate paths, and is the *only* operation
that would fragment an interval. Leaving it out is what keeps a class equal to two
numbers. It cannot be added later without breaking every consumer, and that is a
deliberate trade.

## Docs

- [`docs/SEMANTICS.md`](docs/SEMANTICS.md) — operational semantics, pre- and
  postconditions per operation
