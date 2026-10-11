## The room map's projection (epic exo-dde, docs/design/room-map.md §4): the room as
## nodes and edges, folded from the log. It adds no truth of its own. It joins the folds
## that already exist — logProvenance (who placed each entry, on what guarantee),
## reduceFlow (who could see what, and where it left), reduceIntentViews (each
## intent's state), reduceAccounts and the membership events — into one graph a view
## can draw and replay.
##
## Rules it keeps:
##  * Every node and edge carries the canonical position (`seq`) it appears at, so a
##    view replays reduce(log[0..k]) by filtering on seq ≤ k and never computes state.
##  * Nodes are keyed by content id (an entry), intent id, CAIP-10 or member identity —
##    never by seq, which shifts when an earlier-sorting event arrives (exo-ef1).
##  * Structure, never content: kinds, actors, states, fields and observers. No message
##    body, effect, material or chain reference travels here.
##  * An actor is named only where the log proves it: an author-signed kind's author
##    (authorship.nim), a driver-counted approval's signer, a binding's verified link.
##    An entry the fold refused (an uncounted approval, a substitute proposal) stays in
##    the graph, unattributed and marked so (invariant 9).
##  * Nothing here is per-viewer but `viewer` and `readFrom`: two members' graphs of the
##    same log differ only there. The input is what the viewer's client could open, so a
##    later joiner's graph holds nothing from before its admission (invariant 7, F-16).
##
## The input must be the authenticated log (`roomEvents`), as for every other fold.

import std/[json, strutils, tables, sets, algorithm]
import ../log/log
import ../intents/disclosure
import ./intents
import ./flow
import ./accounts
import ./attest

type
  GraphNode* = object
    id*: string         ## "e:<cid>" entry · "m:<hex>" member · "k:<key>" signer key ·
                        ## "i:<id>" intent · "a:<caip10>" account · "c:<cid>" ceremony ·
                        ## "o:<observer>" outside observer · "o:outside" the world a read came from
    kind*: string       ## entry · member · signer · intent · account · ceremony · observer · outside
    seq*: int           ## the canonical position it first appears at; -1 = before the log
    epoch*: int         ## the membership epoch it appears in (-1 = unknown)
    attrs*: JsonNode

  GraphEdge* = object
    src*, dst*: string
    kind*: string       ## parent · authored · bound · proposed · approved · declined · part ·
                        ## input · disclosed · joined · leaves · enters
    seq*: int
    attrs*: JsonNode

  RoomEpoch* = object
    epoch*: int
    fromSeq*: int       ## the admission that opened it (0 for the founding epoch)
    admitted*: string   ## the joiner's member id ("" for the founding epoch)

  RoomGraph* = object
    viewer*: string     ## this instance's member id (lowercase hex)
    readFrom*: int      ## the first epoch this instance holds (0 for a founder)
    seqMax*: int        ## the last canonical position (-1 for an empty log)
    epochs*: seq[RoomEpoch]
    nodes*: seq[GraphNode]
    edges*: seq[GraphEdge]

const AuthorSigned = ["message", "decline", "material", "account", "join", "part-settled",
                      "part-confirmed", "proposer"]
  ## kinds whose author signed the event (authorship.nim): the room may name them

proc norm(s: string): string =
  result = s.toLowerAscii()
  if result.startsWith("0x") and result.len == 130: result = result[2 .. ^1]   # a 0x-prefixed member id

proc rawKind(p: seq[string]): string =
  ## A short kind for an entry the provenance fold does not describe.
  if p.len == 0: return "entry"
  case p[0]
  of "intent": (if p.len >= 3: p[2] else: "intent")
  of "account": "account"
  of "frost": (if p.len >= 3: p[2] else: "ceremony")
  of "membership": (if p.len >= 3: p[2] else: "membership")
  else: p[0]

proc reduceRoomGraph*(events: seq[Event], driverFor: DriverFor, founders: seq[string],
                      viewer: string, sealedIn = initTable[string, int]()): RoomGraph =
  ## `sealedIn` is the session's record of which epoch's key opened each event
  ## (CoordinationSession.sealedIn). An entry's epoch comes from it; only an event it does
  ## not name falls back to the admissions before it in canonical order, which is right
  ## only for a log whose events carry their parents.
  let ordered = canonicalOrder(events)
  result.viewer = norm(viewer)
  result.seqMax = ordered.len - 1
  var nodeAt = initTable[string, int]()
  var edgeSeen = initHashSet[string]()
  var g = addr result
  proc addNode(id, kind: string, seq, epoch: int, attrs: JsonNode = newJObject()) =
    if id in nodeAt: return
    nodeAt[id] = g.nodes.len
    g.nodes.add GraphNode(id: id, kind: kind, seq: seq, epoch: epoch, attrs: attrs)
  proc addEdge(src, dst, kind: string, seq: int, attrs: JsonNode = newJObject()) =
    let k = src & "|" & dst & "|" & kind & "|" & $seq
    if k in edgeSeen: return
    edgeSeen.incl k
    g.edges.add GraphEdge(src: src, dst: dst, kind: kind, seq: seq, attrs: attrs)

  # ── members and epochs ──────────────────────────────────────────────────────
  var members = initHashSet[string]()
  var sortedFounders: seq[string]
  for f in founders: sortedFounders.add norm(f)
  sortedFounders.sort()
  for f in sortedFounders:
    members.incl f
    addNode("m:" & f, "member", -1, 0, %*{"joined": 0})
  result.epochs.add RoomEpoch(epoch: 0, fromSeq: 0, admitted: "")
  var epochAt = newSeq[int](ordered.len)
  var epoch = 0
  for i, e in ordered:
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "membership" and p[2] == "admit":
      var ep = epoch
      try: ep = max(epoch, parseInt(p[1]))
      except ValueError: discard
      epoch = ep
      let who = norm(p[3])
      if ep > result.epochs[^1].epoch: result.epochs.add RoomEpoch(epoch: ep, fromSeq: i, admitted: who)
      if who notin members:
        members.incl who
        addNode("m:" & who, "member", i, ep, %*{"joined": ep})
      if who == result.viewer: result.readFrom = ep
    epochAt[i] = sealedIn.getOrDefault(eventId(e), epoch)
  # an admission names its joiner, but what that member did before is not in THIS
  # graph unless this client could open it — so readFrom is simply the viewer's own
  # admission epoch, read from the log it holds

  proc actor(account: string, seq: int, signed: bool): string =
    ## The node an attributed entry hangs from: a member, or an authorization key
    ## (an approval's signer that no verified binding ties to a member yet).
    let a = norm(account)
    if a.len == 0: return ""
    if a in members: return "m:" & a
    if a.startsWith("ed:") and a.len == 67:
      # a room-key approval names the member's Ed25519 key, the first half of the member's
      # identity (ed25519 ++ x25519): the driver verified that key signed, so it is them
      for m in members:
        if m.len == 128 and m.startsWith(a[3 .. ^1]): return "m:" & m
    if signed:
      # an author-signed event proves a room identity even if the roster missed it
      members.incl a
      addNode("m:" & a, "member", seq, epochAt[max(0, seq)], %*{"joined": -1})
      return "m:" & a
    addNode("k:" & a, "signer", seq, epochAt[max(0, seq)], newJObject())
    "k:" & a

  # ── entries: every event the client holds, attributed where the log proves it ──
  let prov = logProvenance(events, driverFor)
  var provAt = initTable[int, LogProvItem]()
  for it in prov: provAt[it.seq] = it
  var idAt = initTable[EventId, string]()
  for i, e in ordered: idAt[eventId(e)] = "e:" & eventId(e)
  for i, e in ordered:
    let p = e.key.split('/')
    let id = idAt[eventId(e)]
    var attrs = newJObject()
    var author = ""
    var basis = "sealed"
    if i in provAt:
      let it = provAt[i]
      attrs["kind"] = %it.kind
      attrs["cls"] = %($it.cls)
      attrs["counted"] = %true
      attrs["guarantee"] = %it.guarantee
      if it.intentId.len > 0: attrs["intent"] = %it.intentId
      if it.attestation.len > 0: attrs["attestation"] = %it.attestation
      case it.kind
      of "sig": (basis = "driver-verified"; author = it.account)
      of "attest", "binding": (basis = "key-signed"; author = it.account)
      of "admit": attrs["subject"] = %("m:" & norm(it.account))   # who was admitted; no author
      else:
        if it.kind in AuthorSigned and it.account.len > 0: (basis = "author-signed"; author = it.account)
    else:
      let k = rawKind(p)
      attrs["kind"] = %k
      attrs["counted"] = %false
      if p.len >= 2 and p[0] == "intent": attrs["intent"] = %p[1]
      # author-signed kinds outside the provenance fold: the author is proven by authorship
      if p.len == 4 and p[0] == "account" and p[2] == "disclose": (basis = "author-signed"; author = p[3])
      elif p.len >= 4 and p[0] == "frost" and p[2] == "join": (basis = "author-signed"; author = p[3])
      elif p.len >= 4 and p[0] == "intent" and p[2] == "proposer":
        basis = "author-signed"; author = p[3]; attrs["counted"] = %true
    attrs["basis"] = %basis
    addNode(id, "entry", i, epochAt[i], attrs)
    for par in e.parents:
      if par in idAt: addEdge(idAt[par], id, "parent", i)
    if author.len > 0:
      let a = actor(author, i, basis == "author-signed")
      if a.len > 0:
        attrs["account"] = %a
        addEdge(a, id, "authored", i, %*{"basis": basis})

  # ── signer keys tied to members by a verified binding (F-14) ─────────────────
  for i, e in ordered:
    let bl = bindingLink(e)
    if not bl.ok: continue
    let m = norm(bl.member)
    if m notin members: continue        # a binding to no one this room admitted names no one
    let k = actor(bl.who, i, false)
    if k.startsWith("k:"): addEdge("m:" & m, k, "bound", i)

  # ── intents ──────────────────────────────────────────────────────────────────
  var firstSeq = initTable[string, int]()
  for i, e in ordered:
    let p = e.key.split('/')
    if p.len >= 3 and p[0] == "intent" and p[1] notin firstSeq: firstSeq[p[1]] = i
  for v in reduceIntentViews(events, driverFor):
    if v.effectJson.len == 0: continue
    let s = firstSeq.getOrDefault(v.id, -1)
    var parts = newJArray()
    for pv in v.parts:
      parts.add %*{"part": pv.part, "settled": pv.settled, "confirmed": pv.confirmed}
    addNode("i:" & v.id, "intent", s, (if s >= 0: epochAt[s] else: -1), %*{
      "state": v.state, "family": v.policy.split('@')[0], "threshold": v.threshold,
      "approvals": v.approvals, "rounds": v.rounds, "round": v.round, "declines": v.declines,
      "committed": v.committed, "unattested": v.unattested, "parts": parts})
  for it in prov:
    if it.intentId.len == 0 or "i:" & it.intentId notin nodeAt: continue
    let dst = "i:" & it.intentId
    let entry = "e:" & eventId(ordered[it.seq])
    case it.kind
    of "propose", "policy", "context", "read":
      addEdge(entry, dst, "input", it.seq, %*{"cls": $it.cls, "kind": it.kind})
      if it.kind == "read": addEdge("o:outside", dst, "enters", it.seq, %*{"kind": "read"})
    of "sig":
      let a = actor(it.account, it.seq, false)
      if a.len > 0: addEdge(a, dst, "approved", it.seq, %*{"attestation": it.attestation})
    of "decline":
      let a = actor(it.account, it.seq, true)
      if a.len > 0: addEdge(a, dst, "declined", it.seq)
    of "part-settled", "part-confirmed":
      let a = actor(it.account, it.seq, true)
      if a.len > 0: addEdge(a, dst, "part", it.seq, %*{"step": it.kind[5 .. ^1]})
      if it.kind == "part-confirmed": addEdge("o:outside", dst, "enters", it.seq, %*{"kind": it.kind})
    of "final":
      addEdge("o:outside", dst, "enters", it.seq, %*{"kind": "final"})
    else: discard
  for i, e in ordered:   # who proposed, by their signed claim (exo-770)
    let p = e.key.split('/')
    if p.len == 4 and p[0] == "intent" and p[2] == "proposer" and "i:" & p[1] in nodeAt:
      let a = actor(p[3], i, true)
      if a.len > 0: addEdge(a, "i:" & p[1], "proposed", i)

  # ── accounts disclosed into the room, and key ceremonies ─────────────────────
  for a in reduceAccounts(events):
    for i, e in ordered:
      let p = e.key.split('/')
      if p.len != 4 or p[0] != "account" or p[2] != "disclose" or p[1] != a.id: continue
      addNode("a:" & a.id, "account", i, epochAt[i], %*{"family": a.family, "chain": a.chain,
        "threshold": a.threshold, "signers": a.signers.len, "conflict": a.conflict})
      let m = actor(p[3], i, true)
      if m.len > 0: addEdge(m, "a:" & a.id, "disclosed", i)
  for i, e in ordered:
    let p = e.key.split('/')
    if p.len < 3 or p[0] != "frost": continue
    addNode("c:" & p[1], "ceremony", i, epochAt[i], newJObject())
    if p[2] == "join" and p.len >= 4:
      let m = actor(p[3], i, true)
      if m.len > 0: addEdge(m, "c:" & p[1], "joined", i)

  # ── what left, and to whom (reduceFlow, outside rows only) ───────────────────
  addNode("o:" & $obStoreNode, "observer", -1, 0, newJObject())   # every envelope reaches it (FS-9)
  var leaves = initOrderedTable[string, tuple[src, obs: string, seq: int, fields: seq[string], declared: bool]]()
  for r in reduceFlow(events, driverFor, founders):
    if r.to in {obRoomMember, obStoreNode} or r.intentId.len == 0: continue
    if "i:" & r.intentId notin nodeAt: continue
    let k = r.intentId & "|" & $r.to & "|" & $r.seq
    if k notin leaves: leaves[k] = ("i:" & r.intentId, "o:" & $r.to, r.seq, @[], r.declared)
    if r.field notin leaves[k].fields: leaves[k].fields.add r.field
  for _, l in leaves:
    addNode(l.obs, "observer", l.seq, epochAt[l.seq], newJObject())
    var fs = l.fields
    fs.sort()
    addEdge(l.src, l.obs, "leaves", l.seq, %*{"fields": fs, "declared": l.declared})
  var outsideAt = -1
  for e in result.edges:
    if e.src == "o:outside" and (outsideAt < 0 or e.seq < outsideAt): outsideAt = e.seq
  if outsideAt >= 0: addNode("o:outside", "outside", outsideAt, epochAt[outsideAt], newJObject())

  # a stable order for the wire: nodes by (seq, id), edges by (seq, src, dst, kind)
  result.nodes.sort(proc (a, b: GraphNode): int = cmp((a.seq, a.id), (b.seq, b.id)))
  result.edges.sort(proc (a, b: GraphEdge): int = cmp((a.seq, a.src, a.dst, a.kind), (b.seq, b.src, b.dst, b.kind)))

proc toJson*(g: RoomGraph): JsonNode =
  var nodes = newJArray()
  for n in g.nodes:
    nodes.add %*{"id": n.id, "kind": n.kind, "seq": n.seq, "epoch": n.epoch, "attrs": n.attrs}
  var edges = newJArray()
  for e in g.edges:
    edges.add %*{"src": e.src, "dst": e.dst, "kind": e.kind, "seq": e.seq, "attrs": e.attrs}
  var epochs = newJArray()
  for ep in g.epochs:
    epochs.add %*{"epoch": ep.epoch, "fromSeq": ep.fromSeq, "admitted": ep.admitted}
  %*{"viewer": g.viewer, "readFrom": g.readFrom, "seqMax": g.seqMax, "epochs": epochs,
     "nodes": nodes, "edges": edges}
