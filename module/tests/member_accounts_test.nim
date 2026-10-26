## A member's own accounts, disclosed to the room (exo-1f9), and a lez-msig set up with them.
##
##   1. Alice discloses a fresh account and her paying account; Bob and Carol read them, each
##      proved by its own key and named by its LEZ address;
##   2. what does not count: another member's key disclosed as one's own, a proof made for
##      another room, a disclosure in someone's name they did not author;
##   3. a retracted account is no longer offered, and the next fresh one takes a new label;
##   4. a lez-msig whose ceremony picks Bob's disclosed account: it counts as Bob's join, Bob's
##      client does not join again, the config holds that key, and Bob's approval (signed with
##      it, found by his own client) is one the driver counts; a key Bob never disclosed is
##      refused at open;
##   5. a proposal of Bob's names that account as its proposer.

import std/[json, tables, sequtils, strutils, options]
import stint
import ../src/log/log
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/crypto/account_labels
import ../src/drivers/driver
import ../src/drivers/lez_msig
import ../src/intents/materialization
import ../src/lez/msig
import ../src/lez/tx as leztx
import ../src/coordination/[session, authorship, member_accounts, msig_room]
import ./probes/live_room

const Chain = "lez:local"
var r = newRoom3("/muster/1/member-accounts/proto")
let sessions = @[r.alice, r.bob, r.carol]
let kss = @[Keystore(aliceKs), Keystore(bobKs), Keystore(room3CarolKs)]
proc pollAll() =
  for s in sessions: s.poll()
proc idOf(ks: Keystore): string = hexOf(ks.encIdentity().toBytes()).toLowerAscii()
let alice = idOf(aliceKs)
let bob = idOf(bobKs)
let carol = idOf(room3CarolKs)

# ── 1. disclose, and every member reads it ─────────────────────────────────────
let fresh = discloseAccount(r.alice, aliceKs, nextFreeLabel(aliceKs, r.alice.roomEvents(), r.topic), Chain, "savings")
let payer = discloseAccount(r.alice, aliceKs, PayerLabel, Chain, "paying")
pollAll()
block:
  let seen = memberAccounts(r.bob.roomEvents(), r.topic)
  doAssert seen.len == 2, $seen.len
  let sv = seen.filterIt(it.name == "savings")[0]
  doAssert sv.member == alice and sv.key == aliceKs.lezMemberKey(AccountLabelPrefix & "0")
  doAssert sv.address == publicAccountId(sv.key) and sv.id == hexOf(sv.address)
  doAssert seen.filterIt(it.name == "paying")[0].key == aliceKs.lezMemberKey(PayerLabel), "the paying account"
  doAssert memberAccounts(r.carol.roomEvents(), r.topic).mapIt(it.id) == seen.mapIt(it.id), "every member folds the same list"
  doAssert accountJson(sv, bob)["base58"].getStr().len > 30 and not accountJson(sv, bob)["mine"].getBool()
  doAssert ownLabelOf(aliceKs, fresh.key) == some(AccountLabelPrefix & "0"), "Alice's client finds the label; the room never sees it"
  doAssert ownLabelOf(bobKs, fresh.key).isNone
echo "1. Alice disclosed two accounts; each is proved by its own key and read by every member OK"

# ── 2. what does not count ─────────────────────────────────────────────────────
block:
  # Carol claims Alice's account as hers: the proof binds Alice's identity, so it fails
  let stolen = parseJson(r.alice.roomEvents().filterIt(it.key == "member/" & alice & "/account/" & fresh.id)[0].value)
  stolen.delete(AuthorSigField)
  r.carol.publishAuthored(room3CarolKs, Event(key: "member/" & carol & "/account/" & fresh.id, value: $stolen))
  # Carol proves her own key, but for another room
  let ck = room3CarolKs.lezMemberKey(PayerLabel)
  let other = room3CarolKs.lezMemberSign(PayerLabel, proofMsg("/muster/1/elsewhere/proto", carol, Chain, KindLezKey, ck))
  r.carol.publishAuthored(room3CarolKs, Event(key: "member/" & carol & "/account/" & hexOf(publicAccountId(ck)),
    value: $(%*{"chain": Chain, "kind": KindLezKey, "key": hexOf(ck), "proof": hexOf(other)})))
  # Bob posts a valid-looking disclosure in Carol's name without her signature
  let bk = bobKs.lezMemberKey(PayerLabel)
  r.bob.publish(Event(key: "member/" & carol & "/account/" & hexOf(publicAccountId(bk)),
    value: $(%*{"chain": Chain, "kind": KindLezKey, "key": hexOf(bk),
                "proof": hexOf(bobKs.lezMemberSign(PayerLabel, proofMsg(r.topic, carol, Chain, KindLezKey, bk)))})))
  pollAll()
  let seen = memberAccounts(r.alice.roomEvents(), r.topic)
  doAssert seen.len == 2 and seen.allIt(it.member == alice), $seen.mapIt(it.member)
  doAssert accountsOf(r.alice.roomEvents(), r.topic, carol).len == 0
echo "2. another member's key, a proof for another room, a disclosure its member did not author: none counts OK"

# ── 3. retract ─────────────────────────────────────────────────────────────────
retractAccount(r.alice, aliceKs, payer.id)
pollAll()
doAssert memberAccounts(r.bob.roomEvents(), r.topic).mapIt(it.id) == @[fresh.id], "the paying account is taken back"
doAssert nextFreeLabel(aliceKs, r.alice.roomEvents(), r.topic) == AccountLabelPrefix & "1"
echo "3. a retracted account is no longer offered; the next fresh account takes a new label OK"

# ── 4. a lez-msig set up with Bob's disclosed account ──────────────────────────
let bobAcct = discloseAccount(r.bob, bobKs, nextFreeLabel(bobKs, r.bob.roomEvents(), r.topic), Chain, "bob's")
pollAll()
proc fill(x: byte): seq[byte] = (result = newSeq[byte](32); for i in 0 ..< 32: result[i] = x)
proc unhexKey(s: string): seq[byte] =
  for i in 0 ..< s.len div 2: result.add byte(parseHexInt(s[2*i .. 2*i+1]))
let program = fill(0x11)
let zone = fill(0x2e)
let members = kss.mapIt((id: idOf(it), roles: RoleAll, weight: 1'u16))
block:
  var wrong = initTable[string, string]()
  wrong[bob] = hexOf(bobKs.lezMemberKey(AccountLabelPrefix & "7"))     # a key Bob never disclosed
  var refused = false
  try: discard msigOpen(r.alice, aliceKs, Chain, program, zone, members, 2, 0, true, accounts = wrong)
  except ValueError: refused = true
  doAssert refused, "an account the member did not disclose is refused"
var picks = initTable[string, string]()
picks[bob] = hexOf(bobAcct.key)
let ck = msigOpen(r.alice, aliceKs, Chain, program, zone, members, 2, 0, true, accounts = picks)
pollAll()
doAssert joinInvited(r.alice, aliceKs) == 1 and joinInvited(r.carol, room3CarolKs) == 1
doAssert joinInvited(r.bob, bobKs) == 0, "Bob's picked account is his join"
pollAll()
let cer = ceremonyOf(r.alice.roomEvents(), r.topic, ck).get
doAssert cer.ready and cer.keys[bob] == hexOf(bobAcct.key) and cer.fromAccount[bob] == bobAcct.id
let config = configOf(cer)
doAssert config.members[1].key == bobAcct.key, "Bob's slot holds his disclosed account"
doAssert config.members[0].key == aliceKs.lezMemberKey(msigLabel(unhexKey(ck))), "Alice joined with a key derived for it"
let acct = LezMsigAccount(chain: Chain, program: program, createKey: unhexKey(ck), zone: zone,
                          address: multisigPublic(program, unhexKey(ck)), accountId: Chain & ":x", epoch: 0, config: config)
doAssert myMsigLabel(bobKs, acct) == AccountLabelPrefix & "0", "Bob's client finds his account's label"
doAssert myMsigLabel(aliceKs, acct) == msigLabel(acct.createKey), "Alice's is the key derived for this multisig"
let drv = newLezMsigDriver(acct)
let p = MsigProposal(multisig: acct.address, zone: zone, epoch: 0, nonce: 0,
                     action: MsigAction(kind: akTransfer, to: fill(0x0e), amount: 5.u128),
                     expiresMs: 1_900_000_000_000'u64, proposer: aliceKs.lezMemberKey(myMsigLabel(aliceKs, acct)))
let e = effectFromJson(lezMsigEffect(p))
let m = canonicalize(drv, e)
var dg: array[32, byte]
let sig = drv.signInApp(e, bobKs, dg)
doAssert sig.handled and drv.identifyContributor(m, Contribution(bytes: sig.contribution)) == ContributorPrefix & hexOf(bobAcct.key),
  "Bob's approval, signed with his disclosed account, counts"
echo "4. a lez-msig set up with Bob's disclosed account: his join, the config's key, an approval the driver counts OK"

# ── 5. Bob proposes with it ────────────────────────────────────────────────────
block:
  let st = MsigState(zone: zone, epoch: 0, config: config, consumed: newSeq[byte](32))
  let bp = newMsigProposal(r.bob.roomEvents(), bobKs, drv, st, MsigAction(kind: akTransfer, to: fill(0x0e), amount: 1.u128),
                           1_900_000_000_000'u64)
  doAssert bp.proposer == bobAcct.key
echo "5. Bob's proposal names his disclosed account as its proposer OK"

echo "member_accounts_test: all passed"
