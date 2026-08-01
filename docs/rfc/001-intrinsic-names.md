# RFC 001 — Intrinsic names for classes

**Status: brainstorm.** Not a specification, and nothing here is committed to.
It records an idea, what it changes about the algebra, and what a spike found
when the cheap half of it was built. Terms used loosely on purpose; the point is
to decide whether the concept is right, not how it would be written.

---

## The question

The algebra represents a real state: a population whose members begin
indistinguishable, follow paths that sometimes coincide and sometimes diverge,
and may — or may not — end up individually distinguishable. The structure is a
partition that only ever refines, and what the ledger holds is the *filtration*:
the tree of distinctions drawn so far.

Every node of that tree needs a name. Today the carrier set of names is an
interval of ℕ fixed at genesis, and a node is named by its lowest element.

**What if the carrier set were the set of paths through the refinement itself?**
A node's name derived from the trajectory that produced it, rather than drawn
from a pool that existed before any trajectory did.

Provenance is the use case that motivated the ledger, but it is one
instantiation. Nothing below depends on it.

---

## Extrinsic and intrinsic naming

An **extrinsic** name is assigned from outside: drawn from a pool, dependent on
allocation order, meaningful only relative to the container that issued it. An
**intrinsic** name is determined by its bearer's own position in the structure.

Today's names are extrinsic. The proposal makes them intrinsic, and the name
space becomes isomorphic to the set of paths in the refinement tree.

Equivalently: **drawing a distinction and creating a name become the same act.**
Today they are separate. Genesis creates ten names; distinctions arrive later
and are matched against names already sitting there waiting for them.

Everything below follows from that one move.

---

## What it gains

### 1. The name locates the node

An intrinsic name determines where in the lattice its bearer sits, and can be
checked against a claimed trajectory without consulting the structure at all.
The name stops being a pointer into state and becomes a statement about shape.

### 2. Nothing nameable is unreal

Today a name exists for every element of the genesis interval from the moment of
genesis. But gauge freedom says which member occupies a given position is
undetermined until cardinality 1 — so the algebra can name things it cannot
distinguish, and the design spends real machinery managing the gap: the gauge
convention, the sealed `_cut`, `ownerOf` reverting below rigidity.

Under intrinsic naming the gap closes. The name space *is* the set of
distinctions actually drawn, because there is nothing else a name could be
computed from. Names and distinguishability become the same lattice, and a
family of subtleties stops existing rather than being managed.

### 3. Cardinality demotes from precondition to attribute

Known-N is not a rule anyone chose. It exists only to size the pool. Remove the
pool and the requirement has no source left.

"How many" then becomes an ordinary attribute of a class — possibly known at
genesis, possibly learned later, possibly never known. Classes of indeterminate
size are not a feature to be added; they are what remains once the constraint
stops applying.

### 4. Canonicity extends past the batch

The algebra already works to be canonical *within* a batch: that is what the
fixed gauge and Law 3 buy. But extrinsic names depend on global allocation
order, so canonicity stops at the batch boundary — allocate two batches in the
other order and every downstream name differs.

Intrinsic names depend only on tree shape. Same distinctions drawn ⇒ same names,
regardless of order, interleaving, or replay. It is the property the algebra
already has, extended to the whole structure instead of one batch of it.

### 5. Naming becomes independent of the instantiation

An extrinsic name means something relative to one container and its counter. An
intrinsic name is a statement about a shape, so two instantiations of the same
algebra that saw the same refinements agree on names — with no shared allocator
and no coordination between them.

---

## What it costs

### Conservation stops being structural

This is the real price and it should be stated without softening. Today the
total cannot inflate *even under a buggy implementation*: intervals tile, and
nothing is allocated after genesis, so conservation is a property of the
representation rather than of the code. Intrinsic names have no such backstop.
Conservation becomes an arithmetic invariant that code maintains — and therefore
one that code can get wrong.

### Under indeterminate cardinality it cannot be bought back

Not a trade to engineer around; a definitional incompatibility. Conservation is
a statement about a fixed total, and with no fixed total there is nothing to
state.

The honest framing is not "indeterminate classes cost us conservation" but:
**conservation is a property of determinate classes.** Indeterminate ones are a
different regime, which keeps monotone refinement and lineage and has nothing
whatever to say about totals. Note that monotone refinement survives even
genuine growth — a member joining an indeterminate class was never in another
class, so nothing already classified un-refines.

### The finite known candidate set is lost

With a pool, the set of names a class can ever resolve to is known in advance
and small. With intrinsic names it is unknowable until the trajectory completes.
Whether that matters is entirely a property of the use case rather than of the
algebra — which is exactly why it should not drive this decision.

---

## What the concept forces

Three consequences that are not choices.

**It names classes, not elements.** Members of a class share a trajectory, so
they share a name. An intrinsic name becomes an *element's* name exactly at
cardinality 1 — the same boundary `ownerOf` already enforces. This is a change
of coordinates on classes; it adds nothing at the element level.

**The remainder keeps its name.** When a class divides, only the departing side
is renamed. Renaming both would mean an event that touched some members renamed
the untouched ones, which is precisely what Law 5 forbids. So the concept is
forced to mirror what the current representation already does with `lo`. A class
nothing ever happened to keeps the root's name forever — correct, since nothing
distinguishes it.

**Rigidity is still not an event.** A node exists from the moment it is cut, so
when its cardinality reaches 1 there is nothing to create. Rigidity remains a
property that becomes true, not an operation that fires. The worry that
intrinsic naming smuggles minting back in does not hold.

---

## What the spike found

`src/extensions/LedgerPathIds.sol` and `test/PathIds.t.sol`.

**Intrinsic naming is already latent in the representation.** The trajectory is
on chain today as the parent chain, so a name computed from it needs no change
to the algebra, no added state, and no new operations. The extension is views
and one `pure` fold. `RefinementLedger.sol` was not touched, and all 35
pre-existing tests pass unmodified.

The only edit outside the new files was inheritance plumbing in `Ledger.sol`:
with two extensions in play, `_afterCut` reaches the composition down two paths
and Solidity requires it to name both. Unavoidable and inert, but worth knowing
it is the standing cost of a third extension too.

**The consequence that matters: the two questions are separable.** They arrive
together — drop the pre-allocated pool and `lo` stops being available as a name
— which makes it look as though intrinsic naming requires giving up determinate
cardinality. It does not. Names can be intrinsic while cardinality stays
determinate and conservation stays structural. Whether to give *that* up is then
an isolated decision about conservation, on its own merits, rather than
something arriving bundled with a naming change.

The tests target the concepts rather than the construction, so they should
survive a change of mechanics:

| test | concept |
|---|---|
| `test_aNameIsVerifiableWithoutTheLedger` | a name is a statement about shape, recomputable with no ledger access |
| `test_remainderKeepsItsNameWhenASiblingDeparts` | Law 5, at the level of names |
| `test_anUntouchedClassKeepsTheRootName` | no trajectory, no distinct name |
| `test_namesFollowShapeNotAllocationOrder` | canonicity past the batch (gain 4) |
| `test_aNameIsAnElementNameOnlyAtCardinalityOne` | names classes, not elements |
| `test_siblingsAreNamedApart` | distinct distinctions get distinct names |

---

## Mechanics, deferred

How a name is actually computed — folding with a hash versus carrying the path,
whether cardinality at the point of divergence is bound in, how roots are
distinguished, storage and cost — is downstream of whether the concept holds,
and each option has genuine tradeoffs deserving their own discussion.

The spike folds `keccak256(name, ordinal)` along the departures and binds the
root to chain id and contract address. That choice exists so there is something
runnable. **It is not a recommendation**, and one seam in it is already visible:
binding the root to the contract address is what stops two instantiations
agreeing on names outright, which is why gain 4 is demonstrated against a shared
root rather than end-to-end. What a root ought to be bound to is open.

---

## Open questions

1. **Which flavour of indeterminate?** Unknown-but-fixed and determined later;
   genuinely growing; or indeterminate-then-sealable. Deliberately unresolved.
2. Is losing structural conservation acceptable for determinate classes too, or
   should those keep intervals and only indeterminate ones take intrinsic names?
3. If names are only ever computed, do they belong in the contract at all, or
   outside it? The spike puts them in to make them testable. That is not an
   argument that they ship there.
4. Would a second core reuse the existing extensions unchanged? The friction is
   the handle type. Note the answer; do **not** reshape the current core for a
   contract that may never exist.
