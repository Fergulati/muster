## The keystore labels a member's own LEZ account keys live under (exo-1f9). A member's room
## disclosures never name a label: the member's client finds the label holding a key by
## deriving these candidates, so state stays "log + keys" (invariant 4).
##   lez-member/0       the member's own paying account: it sends and pays their fees
##   lez-account/<n>    a fresh account, one per disclosure that asks for a new one

import std/options
import ./keystore

const
  PayerLabel* = "lez-member/0"
  AccountLabelPrefix* = "lez-account/"
  MaxAccountLabels* = 64

proc candidateLabels*(): seq[string] =
  ## Every label a disclosed account may live under, the paying account first.
  result.add PayerLabel
  for i in 0 ..< MaxAccountLabels: result.add AccountLabelPrefix & $i

proc labelAmong*(ks: Keystore, keys: seq[seq[byte]], extra: seq[string] = @[]): Option[string] =
  ## The first label, of `extra` and then the candidates, whose key is one of `keys`; none when
  ## this keystore holds none of them.
  for l in extra & candidateLabels():
    if ks.lezMemberKey(l) in keys: return some(l)
