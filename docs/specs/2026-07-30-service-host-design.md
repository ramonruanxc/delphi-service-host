# delphi-service-host — design

2026-07-30

## The problem

Several long-lived background services running at once, each doing its own work
on its own schedule, some of them needing to react to what the others find.

The obvious construction — give each service a reference to the ones it cares
about — fails in four predictable ways:

1. **Shutdown order becomes load-bearing.** B holds a reference to A. Stop A
   first and B is holding something dead; stop B first and A is publishing into
   nothing. Neither order is wrong in general, which means the correct order is
   a property of the current set of services and changes when it changes.
2. **Callbacks land on the wrong thread.** A's worker thread calls into B, so
   B's code runs on A's thread, and whether that is safe depends on what B
   touches. If B touches a control, it is a crash that reproduces once a week.
3. **A stopped service is still heard from.** "Stopped" usually means the loop
   exited. Work it already dispatched is still in flight.
4. **Nobody owns what is passed.** A hands B a pointer. If B frees it and C also
   got it, C reads freed memory. If nobody frees it, it leaks. The distinction
   is a convention, and conventions are not checkable.

The prior art here is a service manager in a personal project: nineteen
registered services, a listener mechanism with three flavours of callback, and
years of production use. It solved 1 and 2 by hand and left 3 and 4 to
discipline. This is the same shape with those two answered structurally.

## Shape

```
  service A ──┐                     ┌── subscriber (background lane)
  service B ──┼──> TEventBus ──────>┤
  service C ──┘    (two lanes)      └── subscriber (main-thread lane)
     │
     └── each on its own thread, via TServiceHost
```

Nothing on the left holds a reference to anything on the right. `TEventBus` is
the only channel, and it knows neither end: a subscription is a filter and a
method pointer.

### Publishing

`Publish` copies the event onto a bounded queue and returns. It does not block,
does not raise, and does not run any subscriber. A full lane drops the event and
counts it.

Dropping is a choice, and it is the right one here: the alternative is that a
slow subscriber applies backpressure to a service that has nothing to do with
it. A dropped event is visible in `Dropped`; a stalled service is visible only
as "the app feels sluggish sometimes".

### Two lanes

A subscriber declares its thread once, at `Subscribe`:

- `saBackground` — runs on the dispatcher
- `saMainThread` — runs where VCL work is legal

This is the one thing the bus does that a plain observer list does not, and it
is the thing that makes the pattern usable from a GUI without every subscriber
re-deriving the answer.

### Stopping

Three steps, in order:

1. **Cancel** the token — the loop leaves before its next tick
2. **Join** the thread — after this the service cannot publish again
3. **Discard** its pending events from both lanes

Step 3 is what makes "stopped" total rather than probabilistic. Without it, a
service reported as stopped is still audible for as long as its backlog takes to
drain. `PROVE_NO_DISCARD` removes it, and two assertions fail.

### Ownership of the payload

`TServiceEvent.Payload` is `IEventPayload`, an interface. Three subscribers can
each hold the same payload; the publisher lets go the moment `Publish` returns;
the object is freed when the last holder lets go. Nobody is appointed its owner
and nobody needs to be.

This replaces the raw `Pointer` of the original, where the same value went to
every listener and the freeing convention was documentation.

## Proving it

Every guarantee has a **negative build**: a define that removes exactly that
protection. CI compiles each one and requires it to fail. A test suite that
passes against a deliberately broken build is not testing what its names claim.

| Define | Removes | Detected by |
|---|---|---|
| `PROVE_SYNC_PUBLISH` | queued delivery — subscribers run on the publisher's thread | latency assertions |
| `PROVE_NO_AFFINITY` | the main-thread lane | ThreadID assertions |
| `PROVE_NO_DISCARD` | step 3 of Stop | "nothing arrives afterwards" |
| `PROVE_CONST_REGISTER` | ownership of a refused registration | the leak gate only |

Each negative build needs its own `-FU` directory. Free Pascal does not treat a
changed `-d` define as a reason to recompile, so sharing one silently reuses the
protected units and the check proves nothing.

`PROVE_CONST_REGISTER` is the one that justifies having a leak gate separate
from the assertions. With it defined, all 59 assertions pass and the process
exits 0 — the only symptom is unfreed memory. Its CI step therefore asserts the
inverse of the others: the run must succeed *and* heaptrc must report a leak.

## Measurements

Recorded here because the probe programs were deleted once they had answered.
All on FPC 3.2.2, i386-win32.

### A `const` interface parameter takes no reference

Known before this project — the same defect had already been found and fixed in
delphi-concurrent-pool's `Submit` — and it recurred here in `Register`.

`Host.Register(TTickerService.Create('same', 50))` with a duplicate name: the
inline-created service is refused, `Register` raises, and with a `const`
parameter no reference was ever taken, so nothing frees it. heaptrc: **1 unfreed
block, 36 bytes**, traced to the call site.

By value, the parameter owns a reference for the length of the call and releases
it on the way out, including while an exception unwinds. After the change:
**3397 allocated, 3397 freed**.

### A managed temporary lives until its routine returns

This one cost more time than it should have, because the first three probes
measured it wrong and appeared to show a leak that did not exist.

The question: is a temporary — a record containing an interface, produced by a
function call and used directly — finalised at the end of its *statement* or at
the end of its *routine*?

A probe that creates the temporary and then reads the refcount **inside the same
routine**, many statements later, reads 1. The same counter read **after that
routine returns** reads 0.

```
  measured INSIDE, after many more statements    alive=1
  measured AFTER the routine returned            alive=0

  => temporaries are finalised at ROUTINE exit, not statement exit.
```

So: not a leak. But an ownership test written as one long routine, reading its
counter at the bottom, is asking "does anyone hold it, other than this stack
frame?" — which is not the question it appears to ask, and it reports a number
one too high. `TestPayloadOwnership` puts its body in a separate routine and
reads the counter from the caller for exactly this reason, with the reason
written next to it.

Three earlier probes reported "LEAKED" for four different construction shapes.
All four were the same measurement error. The corrected probe, with the body in
its own routine, reports **0 of 7 leaked** across every shape tested: record
result read as a temporary, record result assigned first, interface result
compared directly, interface result assigned first, method called on an
interface temporary, Boolean accessor, and two record-returning calls in one
`and`-expression.

Delphi could not be measured: Community Edition refuses command-line
compilation, so the suite is verified there by building in the IDE.

## Boundaries

**Not distributed.** One process. Cross-process work belongs to
[delphi-ipc](https://github.com/ramonruanxc/delphi-ipc).

**Not persistent.** Events are in-memory. A dropped event is gone; there is no
replay and no durable log.

**Not a priority queue.** Events are delivered in publication order within a
lane. Two lanes exist for thread affinity, not for importance.

**Not dynamic.** Registration happens before `StartAll`. Services are not added
at runtime, because the interesting failure modes of doing so are not covered by
any test here and an untested capability is worse than an absent one.
