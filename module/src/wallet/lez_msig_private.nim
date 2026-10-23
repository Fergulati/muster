## A private lez-msig's chain seam (exo-efa, docs/design/lez-msig.md §6). The multisig is a
## group-owned private PDA: its state is a note only its members read, and each transaction is
## a privacy-preserving one that LEZ's own prover makes (`MsigProver`, the lez_msig_module).
##
## `MsigPrivate` is the public seam with three differences, so the settlement's rules (the
## approvals, the epoch, the nonce, the time lock) are the same code for both postures:
##   * `readMsig` reads the latest note, which the room carries sealed (msig_room.latestNote);
##   * `sendOp` hands the program's instruction to the prover, which proves it over that note
##     and sends it; the answer is a job ("job:<id>"), because a proof takes minutes;
##   * `included` follows the job, then the transaction. Once the chain includes it, the new
##     note becomes the state and `onNote` hands it to the host, which seals it into the room.
## A deposit (`fund`) is a native transfer from this member's public LEZ account into the
## vault: the prover proves it, the keystore signs its hash, and the prover sends it. No key
## leaves the keystore, and the group secret goes only to the prover, for the job.

import std/[json, options, strutils, tables]
import stint
import ../lez/msig
import ../lez/tx as leztx     # LezShard
import ../crypto/keystore
import ./types
import ./lez_multisig_live        # LezRpc
import ./lez_msig_chain
import ./msig_prover

type
  PrivJob = object
    n: int                        ## the note this transaction makes
    fund: bool
    scan: bool                    ## a read of the newest note from the chain, sending nothing
    txHash, failed: string
    post: seq[byte]
    applied: bool

  MsigPrivate* = ref object of MsigLive
    prover*: MsigProver
    rpcUrl*: string
    gms*, createKey*: seq[byte]
    note*: seq[byte]              ## the latest note (lee_core Account, borsh); empty before Create
    noteN*: int                   ## its number; -1 before Create
    onNote*: proc(n: int, note: seq[byte], hash: string) {.closure.}
    jobs: Table[string, PrivJob]

proc newMsigPrivate*(rpc: LezRpc, rpcUrl: string, ks: Keystore, chain: string, program: seq[byte],
                     payerLabel: string, prover: MsigProver, gms, createKey: seq[byte]): MsigPrivate =
  MsigPrivate(rpc: rpc, rpcUrl: rpcUrl, ks: ks, chain: chain, program: program, payerLabel: payerLabel,
              prover: prover, gms: gms, createKey: createKey, noteN: -1)

proc learn*(c: MsigPrivate, n: int, note: seq[byte]) =
  ## A note the room carries; the newest one is the state.
  if n > c.noteN and note.len > 0:
    c.note = note
    c.noteN = n

proc unz(h: string): seq[byte] =
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))

proc request(c: MsigPrivate, mode: string): JsonNode =
  %*{"mode": mode, "rpc": c.rpcUrl, "program": hexOf(c.program), "gms": hexOf(c.gms),
     "createKey": hexOf(c.createKey), "pre": (if c.note.len > 0: %hexOf(c.note) else: newJNull())}

proc derive*(c: MsigPrivate): seq[byte] =
  ## The multisig's private PDA, which only a holder of the group secret can derive.
  let a = c.prover.derive(c.request("derive"))
  if a.hasKey("error"): raise newException(WalletError, "the prover could not derive it: " & a{"detail"}.getStr())
  unz(a["account"].getStr())

method readMsig*(c: MsigPrivate, account: seq[byte]): MsigRead =
  result.height = c.rpc.lastBlockId()
  if c.note.len == 0: return
  let n = decodeNote(c.note)
  let st = noteState(n, c.program)
  if st.isSome:
    result.found = true
    result.state = st.get
  result.balance = noteBalance(n)

proc submitted(c: MsigPrivate, a: JsonNode, fund: bool): MsigSent =
  if a.hasKey("error"): return MsigSent(ok: false, error: a{"error"}.getStr() & ": " & a{"detail"}.getStr())
  let id = "job:" & a{"job"}.getStr()
  c.jobs[id] = PrivJob(n: c.noteN + 1, fund: fund)
  MsigSent(ok: true, hash: id)

proc sendOp*(c: MsigPrivate, op: seq[byte]): MsigSent =
  ## The program's instruction (msig_core::Instruction, borsh), proved over the latest note.
  var r = c.request("exec")
  r["op"] = %hexOf(op)
  c.submitted(c.prover.submit(r), fund = false)

proc recover*(c: MsigPrivate, fromBlock = 1'u64): MsigSent =
  ## Read the newest note from the chain, for when the member whose transaction landed went
  ## away before sealing its note into the room (exo-abc): the prover decrypts every private
  ## action from `fromBlock` on with the group's viewing key. Followed like any job; once done
  ## its note becomes the state and `onNote` hands it to the room. Sends nothing.
  var r = c.request("scan")
  r["from"] = % $fromBlock
  let a = c.prover.submit(r)
  if a.hasKey("error"): return MsigSent(ok: false, error: a{"error"}.getStr() & ": " & a{"detail"}.getStr())
  let id = "job:" & a{"job"}.getStr()
  c.jobs[id] = PrivJob(n: c.noteN + 1, scan: true)
  MsigSent(ok: true, hash: id)

proc fund*(c: MsigPrivate, amount: UInt128): MsigSent =
  ## A deposit into the vault from this member's own public LEZ account.
  if c.note.len == 0: return MsigSent(ok: false, error: "the multisig is not created yet")
  var r = c.request("fund")
  try: r["payerNonce"] = % $c.rpc.getAccount(c.payer()).nonce
  except CatchableError as e: return MsigSent(ok: false, error: "could not read the payer's nonce: " & e.msg)
  r["payerKey"] = %hexOf(c.ks.lezMemberKey(c.payerLabel))
  r["amount"] = % $amount
  c.submitted(c.prover.submit(r), fund = true)

method sendMsig*(c: MsigPrivate, shards: seq[LezShard], instruction: seq[byte]): MsigSent =
  MsigSent(ok: false, error: "a private multisig sends through its prover (sendOp)")

proc failure*(c: MsigPrivate, hash: string): string =
  ## Why a job failed ("" while it has not): the program's refusal at proving time, or the
  ## sequencer's.
  c.jobs.getOrDefault(hash).failed

proc txHashOf*(c: MsigPrivate, hash: string): string = c.jobs.getOrDefault(hash).txHash

method included*(c: MsigPrivate, hash: string): bool =
  ## A job counts as included once its transaction is, or once it failed (the caller asks
  ## `failure`, and judges the rest by the state it reads, as for a public transaction).
  if not hash.startsWith("job:"): return procCall MsigLive(c).included(hash)
  if hash notin c.jobs: return false
  var j = c.jobs[hash]
  if j.failed.len > 0 or (j.scan and j.applied): return true
  if j.txHash.len == 0:
    let id = hash[4 .. ^1]
    let a = c.prover.job(id)
    case a{"state"}.getStr()
    of "proving": return false
    of "done":
      j.post = unz(a{"post"}.getStr())
      if j.scan:
        # nothing was sent: the note the chain holds, or none newer than the room's
        c.prover.forget(id)
        j.applied = true
        c.jobs[hash] = j
        if a{"found"}.getBool() and j.post.len > 0 and j.post != c.note:
          c.learn(max(j.n, c.noteN + 1), j.post)
          if c.onNote != nil: c.onNote(c.noteN, j.post, a{"hash"}.getStr())
        return true
      if j.fund:
        var h: array[32, byte]
        let sign = unz(a{"sign"}.getStr())
        if sign.len != 32:
          j.failed = "the prover gave no message to sign"
        else:
          for i in 0 ..< 32: h[i] = sign[i]
          let sent = c.prover.send(%*{"rpc": c.rpcUrl, "message": a["message"], "proof": a["proof"],
            "witnesses": [{"signature": hexOf(c.ks.lezMemberSign(c.payerLabel, h)),
                           "publicKey": hexOf(c.ks.lezMemberKey(c.payerLabel))}]})
          if sent.hasKey("error"): j.failed = sent{"error"}.getStr() & ": " & sent{"detail"}.getStr()
          else: j.txHash = sent{"hash"}.getStr()
      else:
        j.txHash = a{"hash"}.getStr()
      c.prover.forget(id)
    else:
      j.failed = a{"error"}.getStr("failed") & ": " & a{"detail"}.getStr()
    c.jobs[hash] = j
    if j.failed.len > 0: return true
  var known = false
  try: known = c.rpc.getTransaction(j.txHash).known
  except CatchableError: return false
  if not known: return false
  if not j.applied:
    j.applied = true
    c.jobs[hash] = j
    c.learn(j.n, j.post)
    if c.onNote != nil: c.onNote(j.n, j.post, j.txHash)
  true
