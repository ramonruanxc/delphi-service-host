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
Every copied file is byte-identical to upstream.

## Local patches

None.
