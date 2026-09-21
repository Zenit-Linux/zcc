import std/osproc
import std/cpuinfo as cpuinfomod
import options as zccopts

proc jobCount*(cfg: zccopts.Config): int =
  if cfg.jobs > 0: cfg.jobs
  else: max(1, cpuinfomod.countProcessors())

type CompileJob* = object
  input*: string
  args*: seq[string]    ## pełne argumenty wywołania "zcc -c ..." dla tego pliku

type JobResult* = object
  input*: string
  exitCode*: int

## Uruchamia joby z limitem współbieżności `maxJobs`. Zwraca wyniki w
## kolejności zakończenia (nie w kolejności wejściowej) - wołający, jeśli
## potrzebuje oryginalnej kolejności, powinien sortować po `input`.
proc runParallel*(jobs: seq[CompileJob], selfExe: string, maxJobs: int): seq[JobResult] =
  result = @[]
  var pending = jobs
  var running: seq[tuple[process: Process, input: string]] = @[]

  proc reapOne() =
    # Prosta strategia: czekamy na pierwszy proces w kolejce startu.
    # TODO(wydajność): docelowo poll po wszystkich (np. przez
    # peekExitCode w pętli) zamiast blokować na najstarszym - na razie
    # prostota > maksymalna przepustowość.
    if running.len == 0: return
    let (p, input) = running[0]
    let code = p.waitForExit()
    result.add JobResult(input: input, exitCode: code)
    p.close()
    running.delete(0)

  while pending.len > 0 or running.len > 0:
    while running.len < maxJobs and pending.len > 0:
      let job = pending[0]
      pending.delete(0)
      let p = startProcess(selfExe, args = job.args, options = {poParentStreams})
      running.add (p, job.input)
    if running.len > 0:
      reapOne()

proc allSucceeded*(results: seq[JobResult]): bool =
  for r in results:
    if r.exitCode != 0: return false
  true
