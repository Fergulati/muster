## Timers for the backend, on the Qt main thread: `after(ms, fn)` runs `fn` once, and
## `every(ms, fn)` runs `fn` every `ms` while it returns true. One QTimer drives all
## of them, so a closure never has to outlive a QTimer it was connected to (the C++
## backend used QTimer::singleShot and a QTimer per loop). Resolution is the tick,
## 20 ms, well under anything the backend schedules (1 s and up).
##
## Also `barrier(n, fn)`: a completion counter, for "do these n async calls, then fn".

import std/[monotimes, times]
import seaqt/[qtimer]

type
  Job = object
    due: MonoTime
    period: int                     ## > 0: repeat every `period` ms while fn returns true
    fn: proc (): bool {.closure.}

var
  jobs: seq[Job]
  ticker: QTimer
  started = false

proc runDue() =
  let now = getMonoTime()
  var due: seq[Job]
  var i = 0
  while i < jobs.len:
    if jobs[i].due <= now:
      due.add jobs[i]
      jobs.del(i)
    else:
      inc i
  for j in due:
    var again = false
    try: again = j.fn()
    except CatchableError as e:
      try: stderr.writeLine "[muster_ui] a scheduled step raised: " & e.msg
      except IOError: discard
    if again and j.period > 0:
      jobs.add Job(due: getMonoTime() + initDuration(milliseconds = j.period),
                   period: j.period, fn: j.fn)

proc ensureTicker() =
  if not started:
    started = true
    ticker = QTimer.create()
    ticker.setInterval(20)
    # seaqt's slots are `raises: []`: nothing may unwind into Qt's C++ frames
    ticker.onTimeout(proc () {.closure, raises: [].} =
      try: runDue()
      except Exception: discard)
    ticker.start()

proc after*(ms: int, fn: proc () {.closure.}) =
  ## Run `fn` once, `ms` from now, on the main thread.
  ensureTicker()
  jobs.add Job(due: getMonoTime() + initDuration(milliseconds = ms), period: 0,
               fn: proc (): bool = fn(); false)

proc every*(ms: int, fn: proc (): bool {.closure.}) =
  ## Run `fn` every `ms`, the first time `ms` from now, until it returns false.
  ensureTicker()
  jobs.add Job(due: getMonoTime() + initDuration(milliseconds = ms), period: ms, fn: fn)

proc barrier*(n: int, fn: proc () {.closure.}): proc () {.closure.} =
  ## A proc to call once per finished step; the n-th call runs `fn`.
  var left = n
  result = proc () =
    dec left
    if left == 0: fn()
