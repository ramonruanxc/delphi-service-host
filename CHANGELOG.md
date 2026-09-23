# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- delphi-concurrent-pool is vendored in `lib/concurrent-pool` (the four units
  this repository uses, plus its licence) instead of pinned as a git submodule,
  so a plain `git clone` or GitHub ZIP builds with no further setup. Copied from
  the same commit the submodule was pinned to, `efef9d6`; `PROVENANCE.md` there
  records it.
- `demo/Newsroom.dpr` needs no configuration on either compiler: Delphi resolves
  every unit through the uses clause, Free Pascal through `{$UNITPATH}`, so
  `fpc demo/Newsroom.dpr` is the whole build. It ends with `Newsroom: OK` or
  `Newsroom: FAILED`, and waits for Enter only when run under the Delphi
  debugger.
- Sources with non-ASCII string literals are saved as UTF-8 with BOM.

### Fixed

- Delphi XE7: the vendored pool's `Ticks` called `TThread.GetTickCount64`, which
  XE7's RTL does not have. It now calls kernel32's `GetTickCount64` on Windows.
  Not yet compiled with Delphi.

## [1.0.0] — 2026-07-30

First release.

### Added

- `TEventBus` — publish/subscribe with two delivery lanes, one for background
  subscribers and one for subscribers that need the main thread. Publishing
  copies the event onto a bounded queue and returns; it never blocks the
  publisher and never raises. A full lane drops and reports rather than stalls.
- `IService`, `IServiceContext` and `TBaseService` — a service gets its name, a
  cancellation token, and a way to publish. It gets no reference to the host and
  none to any other service.
- `TServiceHost` — registers, starts, and stops services, one thread each.
  `Stop` cancels the token, joins the thread, then discards that service's
  pending events from both lanes, in that order.
- `TServiceEvent` with `Datum: Integer` for the common case and
  `Payload: IEventPayload` for everything else. The payload is refcounted, so
  several subscribers can hold the same one and it is freed when the last of
  them lets go.
- A tick that raises is counted and published as an error event; the service
  keeps running and the next tick happens on schedule.
- 59 assertions, a leak gate, and a watchdog that turns an overrun into a named
  failure and exit 2.
- Four negative builds, each removing exactly one protection so CI can prove the
  suite notices: `PROVE_SYNC_PUBLISH`, `PROVE_NO_AFFINITY`, `PROVE_NO_DISCARD`,
  `PROVE_CONST_REGISTER`.
- `demo/Newsroom.dpr` — three services on three threads plus a non-service
  subscriber; stops one service mid-flight and exits non-zero if anything of it
  is heard from afterwards.

### Fixed

Found while building the suite, before any release:

- `TServiceHost.Register` took the service as `const IService`. A const
  interface parameter takes no reference, so a registration refused for a
  duplicate name left a service that nothing owned and nothing freed. It is now
  by value, and `PROVE_CONST_REGISTER` restores the old signature so the leak
  gate can demonstrate the difference.

### Notes

- Pinned to delphi-concurrent-pool as a git submodule, so the commit CI builds
  against is recorded in this repository's history.
- A managed temporary is finalised when its routine returns, not when its
  statement ends (measured, FPC 3.2.2). This is not a leak, but it does mean a
  refcount read at the bottom of the same routine that produced a temporary
  still counts it — which is why the payload ownership test reads its counter
  from the caller.
