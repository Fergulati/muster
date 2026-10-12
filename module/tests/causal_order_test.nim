## Causal order (C1, exo-024; docs/design/causal-parents.md §3): `after`, the heads a
## publisher had seen, orders views without touching identity or state.
##   1. `after` is not in the id: two copies that differ only there are one event
##   2. with no `after` anywhere, causalOrder IS canonicalOrder
##   3. causalOrder follows `after`: roots that name what they followed come out in that order
##   4. one variant per id, chosen by content: any arrival order and duplication of the
##      same variant set gives the same order and keeps the same `after` (invariant 4)
##   5. a soft edge never closes a cycle, and every event is emitted
##   6. canonicalOrder (what every fold reads) ignores `after` entirely
## Pure Nim.

import std/[algorithm, random, sequtils, sets, tables]
import ../src/log/log

proc ev(key: string, parents: seq[EventId] = @[], after: seq[EventId] = @[]): Event =
  Event(parents: parents, key: key, value: "v", after: after)
proc ids(es: seq[Event]): seq[EventId] = es.mapIt(eventId(it))
proc keys(es: seq[Event]): seq[string] = es.mapIt(it.key)

block:
  let a = ev("a")
  let a2 = ev("a", after = @[eventId(ev("x"))])
  doAssert eventId(a) == eventId(a2), "after is not part of the id"
  var log: Log
  log.ingest(a); log.ingest(a2)
  doAssert log.allEvents().len == 1
  echo "1. after is outside identity: copies that differ only there are one event OK"

block:
  var r = initRand(7)
  for trial in 0 ..< 50:
    var es: seq[Event]
    for i in 0 ..< 12:
      var ps: seq[EventId]
      if es.len > 0 and r.rand(1) == 1: ps.add eventId(es[r.rand(es.len - 1)])
      es.add ev("k" & $trial & "-" & $i, ps)
    doAssert causalOrder(es).ids == canonicalOrder(es).ids
  echo "2. with no after anywhere, causalOrder is canonicalOrder OK"

block:
  # five roots, each naming the one before it in `after`: canonical order is content-id
  # order, causal order is the order they were published
  var es: seq[Event]
  for i in 0 ..< 5:
    es.add ev("step" & $i, after = (if i > 0: @[eventId(es[^1])] else: @[]))
  doAssert causalOrder(es.reversed()).keys == @["step0", "step1", "step2", "step3", "step4"]
  doAssert canonicalOrder(es).keys != causalOrder(es).keys, "the fixture must differ from id order to mean anything"
  # concurrency: two events after the same head, neither after the other, tie by id
  let h = ev("head")
  let x = ev("x", after = @[eventId(h)]); let y = ev("y", after = @[eventId(h)])
  let o = causalOrder(@[y, x, h])
  doAssert o[0].key == "head" and o[1 .. 2].ids == @[x, y].ids.sorted()
  echo "3. causalOrder follows after; concurrent events tie by content id OK"

block:
  let h1 = ev("h1"); let h2 = ev("h2"); let h3 = ev("h3")
  let p = ev("p", after = @[eventId(h1)])
  let pB = ev("p", after = @[eventId(h2)])          # the same event, re-published elsewhere
  let pC = ev("p", after = @[eventId(h3), eventId(h1)])
  let base = @[h1, h2, h3, p, pB, pC]
  let want = causalOrder(base)
  var keptAfter: seq[EventId]
  for e in want: (if e.key == "p": keptAfter = e.after)
  var r = initRand(11)
  for trial in 0 ..< 60:
    var s = base
    for _ in 0 .. r.rand(4): s.add base[r.rand(base.len - 1)]   # duplicates
    r.shuffle(s)
    let got = causalOrder(s)
    doAssert got.ids == want.ids
    for e in got: (if e.key == "p": doAssert e.after == keptAfter, "the same variant wins whatever arrives first")
    var log: Log
    for e in s: log.ingest(e)
    for e in log.allEvents(): (if e.key == "p": doAssert e.after == keptAfter, "the log keeps the same variant")
  echo "4. one variant per id, chosen by content; order and kept after converge (inv 4) OK"

block:
  # a and b each claim to follow the other: one soft edge must go, deterministically
  let a0 = ev("a"); let b0 = ev("b")
  let a = ev("a", after = @[eventId(b0)]); let b = ev("b", after = @[eventId(a0)])
  let o1 = causalOrder(@[a, b]); let o2 = causalOrder(@[b, a])
  doAssert o1.len == 2 and o1.ids == o2.ids
  # a forward edge: x is y's parent, and a copy of x claims to follow y
  let x = ev("x"); let y = ev("y", parents = @[eventId(x)])
  let xFwd = ev("x", after = @[eventId(y)])
  let o = causalOrder(@[y, xFwd])
  doAssert o.keys == @["x", "y"], "a parent stays before its child; the forward soft edge is skipped"
  # nothing is ever dropped, even in a dense tangle of contradicting claims
  var es: seq[Event]
  var r = initRand(3)
  var plain: seq[Event]
  for i in 0 ..< 15: plain.add ev("t" & $i)
  for i in 0 ..< 15:
    var af: seq[EventId]
    for _ in 0 ..< 3: af.add eventId(plain[r.rand(14)])
    es.add ev("t" & $i, after = af)
  doAssert causalOrder(es).len == 15
  echo "5. a soft edge never closes a cycle; every event is emitted OK"

block:
  let h = ev("h")
  var es: seq[Event]
  for i in 0 ..< 6: es.add ev("e" & $i, after = @[eventId(h)])
  let stripped = (es & @[h]).mapIt(Event(parents: it.parents, key: it.key, value: it.value))
  doAssert canonicalOrder(es & @[h]).ids == canonicalOrder(stripped).ids
  doAssert reduce(es & @[h]).stateDigest == reduce(stripped).stateDigest
  echo "6. canonicalOrder and reduce ignore after entirely OK"

block:
  # the eventId memo (G7) returns exactly the uncached digest, and never conflates inputs
  # that differ only in where one field ends and the next begins
  let tricky = @[
    Event(key: "a:1b", value: "c"), Event(key: "a", value: "1bc"), Event(key: "a:", value: "1b:c"),
    Event(parents: @["p:q"], key: "k", value: "v"), Event(parents: @["p", "q"], key: "k", value: "v"),
    Event(parents: @[], key: "1:p:qk", value: "v")]
  var seen: seq[EventId]
  for e in tricky:
    doAssert eventId(e) == eventIdUncached(e)
    doAssert eventId(e) == eventId(e)          # a second, memoized call
    doAssert eventId(e) notin seen, "two different events share an id: " & e.key
    seen.add eventId(e)
  echo "7. the eventId memo returns the exact digest and never conflates inputs OK"

block:
  # exo-53d: canonicalOrder's min-heap gives exactly the order the original re-sort did
  proc reference(events: seq[Event]): seq[EventId] =
    ## the algorithm as it was before the heap, verbatim in its ordering rule
    var byId = initTable[EventId, Event]()
    for e in events: byId[eventId(e)] = e
    var indeg = initTable[EventId, int]()
    var children = initTable[EventId, seq[EventId]]()
    for id in byId.keys: (indeg[id] = 0; children[id] = @[])
    for id, e in byId:
      for p in e.parents:
        if p in byId: (indeg[id] = indeg[id] + 1; children[p].add id)
    var ready: seq[EventId]
    for id in byId.keys: (if indeg[id] == 0: ready.add id)
    while ready.len > 0:
      sort(ready)
      let id = ready[0]
      ready.delete(0)
      result.add id
      var unblocked = children[id]
      sort(unblocked)
      for c in unblocked:
        indeg[c] = indeg[c] - 1
        if indeg[c] == 0: ready.add c
  var r = initRand(53)
  for trial in 0 ..< 200:
    var es: seq[Event]
    for i in 0 ..< r.rand(1 .. 40):
      var ps: seq[EventId]
      for _ in 0 ..< r.rand(0 .. 3):
        if es.len > 0: ps.add eventId(es[r.rand(es.len - 1)])
      if r.rand(9) == 0: ps.add "absent-" & $i          # a parent this log does not hold
      es.add ev("h" & $trial & "-" & $i, ps)
    var s = es
    for _ in 0 .. r.rand(5): s.add es[r.rand(es.len - 1)]
    r.shuffle(s)
    doAssert canonicalOrder(s).ids == reference(s), "trial " & $trial
  echo "8. canonicalOrder's heap gives exactly the original order OK"

echo "causal_order_test: all OK"
