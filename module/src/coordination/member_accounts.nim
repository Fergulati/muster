## A member's own accounts, disclosed to the room (exo-1f9). A member puts an account their
## muster keystore holds in front of the room, so others can use it wherever an account of
## theirs is needed: first as their approval key when the room sets up a lez-msig.
##
##   member/<who>/account/<id>            the disclosure, author-signed by <who>: chain, kind,
##                                        key, address, an optional name, and a proof
##   member/<who>/account/<id>/retract    <who> takes it back
##
## The proof is the account key's own signature over (room, <who>, chain, kind, key): the key
## says it is this member's, in this room. So no one can disclose another member's key as
## their own, or carry a disclosure into another room. Author-signing says the member wrote
## it. A disclosure is read only over the room's authentic view (roomEvents), and every view
## here is a fold over it (invariant 4). What the room learns about a member is what that
## member disclosed (invariant 9).
##
## Kinds: `lez-key`, a LEZ public account whose key is a BIP-340 key in the member's
## keystore (its address is the LEZ account id of the key). The keystore label is never
## disclosed: the owner's client finds it by deriving its candidate labels (`ownLabelOf`).

import std/[json, strutils, tables, options, sequtils]
import ../log/log
import ../dcbor/dcbor
import ../hashing/hash_input
import ../crypto/keystore
import ../crypto/account_labels
import ../crypto/curve25519        # EncIdentity.toBytes
import ../lez/msig
import ../lez/tx as leztx
import ./session
import ./authorship

const
  AccountDomain* = "muster.member-account.v1"
  KindLezKey* = "lez-key"

type MemberAccount* = object
  member*: string                ## the disclosing member's room identity (hex)
  id*: string                    ## the address, hex (the event key's last part)
  chain*, kind*, name*: string
  key*: seq[byte]                ## x-only public key
  address*: seq[byte]

proc hx(b: openArray[byte]): string = hexOf(b)
proc unhx(s: string): seq[byte] =
  var h = s.strip().toLowerAscii()
  if h.startsWith("0x"): h = h[2 .. ^1]
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))

proc proofMsg*(room, who, chain, kind: string, key: openArray[byte]): array[32, byte] =
  ## What the account key signs: a domain-separated hash-input record (invariant 5).
  let d = digest(hashInput(AccountDomain, @[("room", cbText(room)), ("member", cbText(who.toLowerAscii())),
                                            ("chain", cbText(chain)), ("kind", cbText(kind)),
                                            ("key", cbBytes(@key))]))
  for i in 0 ..< 32: result[i] = d[i]

proc addressOf*(kind: string, key: seq[byte]): seq[byte] =
  case kind
  of KindLezKey: publicAccountId(key)
  else: raise newException(ValueError, "unknown account kind " & kind)

proc memberAccounts*(events: seq[Event], room: string): seq[MemberAccount] =
  ## Every account a member disclosed and has not retracted, in the room's canonical order
  ## (the same for every member, whatever order the events arrived in). One whose proof
  ## does not verify, whose address is not its key's, or whose key another member disclosed
  ## first, is not counted.
  var retracted: seq[string]
  for e in events:
    let p = e.key.split('/')
    if p.len == 5 and p[0] == "member" and p[2] == "account" and p[4] == "retract":
      retracted.add p[1].toLowerAscii() & "/" & p[3].toLowerAscii()
  var seenKey = initTable[string, string]()     # key hex -> the member who disclosed it first
  for e in canonicalOrder(events):
    let p = e.key.split('/')
    if p.len != 4 or p[0] != "member" or p[2] != "account": continue
    let who = p[1].toLowerAscii()
    let id = p[3].toLowerAscii()
    if who & "/" & id in retracted: continue
    try:
      let j = parseJson(e.value)
      let kind = j{"kind"}.getStr()
      let chain = j{"chain"}.getStr()
      let key = unhx(j{"key"}.getStr())
      if key.len != 32 or chain.len == 0 or hx(addressOf(kind, key)) != id: continue
      let m = proofMsg(room, who, chain, kind, key)
      if not verifySig(key, m, unhx(j{"proof"}.getStr())): continue
      let k = hx(key)
      if k in seenKey and seenKey[k] != who: continue
      seenKey[k] = who
      if result.anyIt(it.member == who and it.id == id): continue
      result.add MemberAccount(member: who, id: id, chain: chain, kind: kind, name: j{"name"}.getStr(),
                               key: key, address: unhx(id))
    except CatchableError: discard

proc accountsOf*(events: seq[Event], room, who: string, kind = "", chain = ""): seq[MemberAccount] =
  for a in memberAccounts(events, room):
    if a.member == who.toLowerAscii() and (kind.len == 0 or a.kind == kind) and (chain.len == 0 or a.chain == chain):
      result.add a

proc hasAccount*(events: seq[Event], room, who: string, key: seq[byte], kind = KindLezKey): bool =
  ## Whether `who` disclosed `key` (of `kind`) in this room and still stands by it.
  for a in accountsOf(events, room, who, kind): (if a.key == key: return true)

proc ownLabelOf*(ks: Keystore, key: seq[byte]): Option[string] =
  ## The keystore label holding `key` among this member's account labels; none when this
  ## keystore holds no such key.
  labelAmong(ks, @[key])

proc nextFreeLabel*(ks: Keystore, events: seq[Event], room: string): string =
  ## A fresh account's label: the first lez-account/<n> whose key this member has not
  ## disclosed in this room.
  let me = hx(ks.encIdentity().toBytes()).toLowerAscii()
  let mine = accountsOf(events, room, me).mapIt(hx(it.key))
  for i in 0 ..< MaxAccountLabels:
    let l = AccountLabelPrefix & $i
    if hx(ks.lezMemberKey(l)) notin mine: return l
  raise newException(ValueError, "every account label is in use in this room")

proc discloseAccount*(s: CoordinationSession, ks: Keystore, label, chain: string, name = "",
                      kind = KindLezKey): MemberAccount =
  ## Disclose the account under `label` to the room, proved by its own key and author-signed.
  let me = hx(ks.encIdentity().toBytes()).toLowerAscii()
  let key = ks.lezMemberKey(label)
  let address = addressOf(kind, key)
  let sig = ks.lezMemberSign(label, proofMsg(s.topic, me, chain, kind, key))
  s.publishAuthored(ks, Event(key: "member/" & me & "/account/" & hx(address), value: $(%*{
    "chain": chain, "kind": kind, "key": hx(key), "name": name, "proof": hx(sig)})))
  MemberAccount(member: me, id: hx(address), chain: chain, kind: kind, name: name, key: key, address: address)

proc retractAccount*(s: CoordinationSession, ks: Keystore, id: string) =
  let me = hx(ks.encIdentity().toBytes()).toLowerAscii()
  s.publishAuthored(ks, Event(key: "member/" & me & "/account/" & id.toLowerAscii() & "/retract", value: "{}"))

proc accountJson*(a: MemberAccount, me: string): JsonNode =
  result = %*{"member": a.member, "mine": a.member == me.toLowerAscii(), "id": a.id, "chain": a.chain,
              "kind": a.kind, "name": a.name, "key": hx(a.key)}
  if a.kind == KindLezKey: result["base58"] = %accountIdToBase58(a.address)
