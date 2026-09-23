# Provenance

Vendored copy of the parts of **delphi-concurrent-pool** that this repository
compiles. It is here so that a plain `git clone` or a GitHub ZIP builds with no
submodule, package manager or search-path setup.

**Do not edit these files here.** To update, re-copy them from upstream at the
new commit, re-apply the local patches listed below (or drop the ones upstream
has absorbed), and update this file.

| | |
|---|---|
| Upstream | https://github.com/ramonruanxc/delphi-concurrent-pool |
| Source commit | `efef9d6ac9337d9e597feaf454e28474c99658d3` |
| Previously | the git submodule `vendor/delphi-concurrent-pool`, pinned to that same commit |
| Licence | MIT, see `LICENSE` in this directory |

## Copied files

| Here | Upstream path |
|---|---|
| `ConcurrentPool.Types.pas` | `src/ConcurrentPool.Types.pas` |
| `ConcurrentPool.Atomic.pas` | `src/ConcurrentPool.Atomic.pas` |
| `ConcurrentPool.Queue.pas` | `src/ConcurrentPool.Queue.pas` |
| `ConcurrentPool.Worker.pas` | `src/ConcurrentPool.Worker.pas` |
| `LICENSE` | `LICENSE` |

`ConcurrentPool.Pool.pas` is not used by this repository and is not copied.
`ConcurrentPool.Queue.pas` and `ConcurrentPool.Worker.pas` are byte-identical to
upstream.

## Local patches

Both are Delphi-only. The Free Pascal code paths are unchanged.

1. `ConcurrentPool.Types.pas` — `Ticks` no longer calls `TThread.GetTickCount64`
   on Delphi for Windows, because that method is not in Delphi XE7's RTL. It
   calls kernel32's `GetTickCount64` directly (the same monotonic clock, present
   since Windows Vista). Non-Windows Delphi targets keep the upstream call.
2. `ConcurrentPool.Atomic.pas` — saved as UTF-8 **with BOM**. One assertion
   message contains a non-ASCII character, and without a BOM Delphi reads the
   file in the system ANSI code page.
