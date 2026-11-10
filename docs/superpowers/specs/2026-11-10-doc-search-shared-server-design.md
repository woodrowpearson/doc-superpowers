# doc-search shared server — design

**Status:** draft 2026-11-10, for the developer's approval · **Scope:** `search/` (doc-search) only ·
**Releases:** one minor release; consumers adopt it through their plugin pin.

## What this decides

doc-search runs one server per repository per host, not one per session. Each session's `serve`
becomes a small proxy that forwards its stdio to that server over a private local socket. The
shared server also unloads worktrees that nobody has queried for a while. Anything that stops the
shared path falls back to today's behaviour: one server inside the session's own process.

## Why: the measured cost

Measured on an Apple Silicon laptop with 16 GB, on 2026-11-10, with `footprint -p`. The repository
was a large consumer project, and the measured build is release 3.13.0.

- 17 doc-search processes held 17.6 GB. Swap stood at 24.9 of 25.6 GB, and simulator boots failed.
- Six servers for that one project held 1.9 to 3.2 GB each, 15.4 GB in all. Three of the 3.2 GB
  servers served the same worktree, the main checkout.

A controlled run of one server, loading one worktree's indexes from a valid cache, gave these
footprints:

| Stage | Footprint |
|---|---|
| Imports (`mcp`, `pydantic`) | 73 MB |
| `Runtime` built: config, corpus, cloud leg | 128 MB |
| Docs and code indexes of one worktree loaded (11 s) | 1,563 MB |
| A second worktree loaded (an incremental rebuild), at its peak | 4,077 MB |
| Two worktrees resident | 3,226 MB |

`tracemalloc` split one worktree's 1.43 GB this way:

- Dense vectors and the keyword index's arrays (BM25): 547 MB. The docs index holds 210,664 chunks and the code index
  152,853, each chunk a 256-float vector.
- semble `Chunk` objects (text, paths) parsed from `chunks.json`: 459 MB.
- The keyword index's term lists: 103 MB.
- The static model: 62 MB.

The load itself peaked at 3.3 GB traced. The encoder plays no part: that project uses semble's
static model.

The cause is duplication. `IndexPool` keeps up to two worktrees per process (`max_worktrees=2`,
3.2 GB). Every session runs its own process, and sessions that share a worktree each load it again.

## Design

### Units

| Unit | File | Job |
|---|---|---|
| Proxy | `search/src/doc_search/shared.py` | `serve`'s entry. Standard library only. Finds or starts the shared server, then pipes stdio to it. Falls back to in-process. |
| Daemon | `search/src/doc_search/daemon.py` | Holds one `Runtime` core and serves one MCP session per connection. Exits when idle. |
| Key | `shared.py` | Names the daemon a session may share: socket, locks and log paths. |
| Pool unload | `engines.py` | Drops worktrees idle past a limit, and returns freed memory to the OS. |
| Runtime split | `server.py` | Separates what sessions share (config, pool, searcher, tools, cloud leg) from what each has (its default worktree). |

### Which sessions share a daemon: the key

Two sessions share a daemon only when a separate server of each would behave the same. The key is a
SHA-256, cut to 16 hex characters, over:

- the launch worktree's top (today's `Runtime(cwd)`);
- the bytes of its `docs/search/config.json`;
- doc-search's version, the path of its package, and its modules' sizes and times (a source checkout's
  edit changes no version);
- `sys.executable` (the venv, and with it the installed extras);
- the environment variables that change behaviour: `DOC_SEARCH_*` (but not `DOC_SEARCH_CLIENT_CWD`),
  `SEMBLE_*`, `HF_*`, `GOOGLE_*`, `CLOUDSDK_*` and `GIT_*`, and `HOME` and `XDG_CACHE_HOME`, under which
  the caches live.

The daemon computes the key again from its own launch worktree, config and environment. If they no
longer match, as when the config changed after the proxy read it, it exits.

The Claude desktop app starts every session's project servers in the main checkout. So all its
sessions on one repository share one daemon, whichever worktree each works in. A config edit, another
plugin version or another environment gets a daemon of its own. The old one exits once its last
session leaves. Version skew between a launcher and a daemon cannot arise by construction.

### Where the files live

- macOS: the user's temporary directory (`getconf DARWIN_USER_TEMP_DIR`, else `$TMPDIR`) + `doc-search/`.
  A session with a `TMPDIR` of its own still finds the shared server.
- Linux: `$XDG_RUNTIME_DIR/doc-search/`, else `/tmp/doc-search-<uid>/`.

Each daemon has `<key>.sock` (mode 0600), `<key>.alive` (its life lock), `<key>.start` (the start
lock) and `<key>.log`. The proxy refuses the shared path, and runs in-process, when:

- the directory is not owned by the user, or is open to others;
- the socket path is too long for `AF_UNIX` (104 bytes on macOS).

### Starting and finding the daemon

The proxy:

1. Connects to `<key>.sock`. On success, it goes to *Hello*.
2. Otherwise it takes `<key>.start` (`flock`, blocking, at most 60 s) and tries to connect again.
   Another proxy may have just started the daemon.
3. Still no connection: it tries `<key>.alive` without blocking.
   - If it gets the lock, no daemon is alive. The proxy lets the lock go and removes a stale
     `<key>.sock`. It then starts the daemon detached (`start_new_session`, stdin from
     `/dev/null`, output to `<key>.log`). The daemon runs as `python -P -m doc_search.entry`, so the
     repository's top, its working directory, can never shadow a module.
   - If the lock is held, a daemon is starting. The proxy waits for it.
4. It polls the socket until it connects, at most 60 s. Then it lets `<key>.start` go.

The daemon takes `<key>.alive` first, without blocking and before it imports the server, and holds it
for life. If another daemon holds
it, it exits. It then removes any old socket and listens before it builds the `Runtime`, so proxies
queue in the backlog during that 5 to 10 s.

A crash releases `<key>.alive` in the kernel. The next proxy finds the stale socket refused and the
lock free, and starts a new daemon. So a stale socket never blocks anyone.

### Hello

Before any MCP traffic, the proxy sends one JSON line:
`{"doc_search_proxy": 1, "key": "<key>", "client_cwd": "<dir>"}`. `client_cwd` is the session's
`DOC_SEARCH_CLIENT_CWD`. The daemon answers `{"doc_search_daemon": 1, "key": "<key>", "version": "<v>"}`.
If the key or the protocol differs, the proxy closes the connection and runs in-process.

### Serving a connection

The daemon builds the shared core once. For each connection it makes a per-session view that holds
its default worktree, chosen from `client_cwd` by today's `_default_worktree`. It also builds an
`MCPServer` over that view, and runs `lowlevel_server.run(read, write, …)` over the connection's
newline-delimited JSON. On hello it warms that session's default worktree (`pool.get(default,
wait_s=0)`), as `serve` does today. Tool jobs keep running on worker threads; the pool is already
thread-safe.

`status` adds one line: the mode (`shared, pid N, K sessions` or `in-process`) and the resident
worktrees.

### Memory policy

| Setting | Default | Meaning |
|---|---|---|
| `DOC_SEARCH_MAX_WORKTREES` | 3 shared, 2 in-process | Worktrees kept resident (least recently used goes first, as today). |
| `DOC_SEARCH_IDLE_UNLOAD_S` | 900 | A worktree not asked for in this long is dropped, unless it is building. `0` turns it off. |
| `DOC_SEARCH_DAEMON_IDLE_S` | 600 | A daemon with no session for this long exits. |

These are environment variables, not config keys: memory belongs to the host, not the repository.
They enter the key, so sessions with other limits do not share.

After an eviction or an unload, the pool runs `gc.collect()` and gives the freed heap back to the OS:
`malloc_zone_pressure_relief(NULL, 0)` on macOS, `malloc_trim(0)` on glibc. Without that, freed pages
stay in the footprint. A query for an unloaded worktree reloads it from semble's cache, which took
11 s in the measurement, inside `wait_s` (20 s).

### The daemon's life and crashes

- **Idle exit.** With no session for `DOC_SEARCH_DAEMON_IDLE_S`, and no build running, the daemon stops
  listening, removes its socket and exits. A proxy that connected in that moment reads end-of-file
  before the hello, and tries again (three times), which starts a new daemon.
- **One session's failure.** The daemon logs it and closes that connection. The other sessions go on.
- **Crash or kill.** The proxy tracks the client's requests still awaiting an answer, and remembers
  the `initialize` request and the `notifications/initialized` notification. When the connection
  drops:
  1. It answers each pending request with a JSON-RPC error: `doc-search: the shared server
     stopped; retry the call`. A request that a cancellation notice withdrew is not answered. A line
     cut short by the loss is never forwarded.
  2. It reconnects, starting a daemon if needed: three tries with a 1 s, 2 s and 4 s backoff.
  3. It replays `initialize` under an id of its own and drops that answer. It then replays
     `notifications/initialized`. When the client's own `initialize` is still waiting (the daemon died
     while it started), the proxy sends that one again under its id, and the client gets its answer.
  The MCP client keeps its session and sees one failed call.
- **No daemon after the retries.** The proxy starts `doc-search serve --in-process` as a child and
  replays the handshake to it in the same way. A failure before the first connection needs no
  replay: the proxy `exec`s the in-process server and drops out of the path.

### When the shared path is off

- `DOC_SEARCH_SHARED=0`: always in-process. `DOC_SEARCH_SHARED=1`: shared even where the default
  is in-process.
- Cloud sessions (`CLAUDE_CODE_REMOTE` set): in-process by default. A container runs one session,
  so there is nothing to share, and a detached process should not outlive it.
- No `AF_UNIX` or `fcntl` (Windows): in-process.
- `doc-search serve --in-process`: today's server, with one change: it unloads idle worktrees too
  (`DOC_SEARCH_IDLE_UNLOAD_S`).

`check`, `gate`, `query`, `index`, `status` and `eval` on the command line stay in-process. The
launcher (`scripts/search/launch.sh`) does not change: `serve` still execs `uv run … doc-search serve`.

## What does not change

- Search results and every tool's text, except `status`'s new line.
- semble's cache layout, the build line, build locks and the transformer lane. One daemon makes them
  work within one process again.
- The config schema.

## Testing

- **Unit (pytest, no network):**
  - The key: each input changes it, and `DOC_SEARCH_CLIENT_CWD` does not.
  - The path checks: ownership, mode and length.
  - The start protocol, against a stale socket file and against a held life lock.
  - A hello mismatch, which runs in-process.
  - Idle unload on the injected clock, which keeps a building entry.
  - The memory-relief call, a no-op where it is unavailable.
  - The proxy's pending-request tracking and replay, over in-memory streams.
- **Process tests (`slow`):** a fixture repository with the fake engines.
  - Two proxies get one daemon pid, and each `status` names its own default worktree.
  - `kill -9` of the daemon fails one in-flight call, and the next call succeeds.
  - Idle exit removes the socket.
  - `CLAUDE_CODE_REMOTE=1` and `DOC_SEARCH_SHARED=0` run in-process.
  - A config edit gets a second daemon.
- **Measurement (by hand, not CI):** `search/scripts/measure-shared.py` starts N clients, in both
  modes, against one repository. It sums `footprint` (macOS) or PSS (Linux) and reports N = 1, 3 and 6.
  The numbers go into the commit body and `references/search.md` → *Hardware and performance*.

## Documentation

- `references/search.md`: *Modes* (shared and in-process), *Hardware and performance*
  (the numbers, the three variables), *Troubleshooting* (the log, `DOC_SEARCH_SHARED=0`, a stale
  socket).
- The `engines.py` header: one daemon per repository, and idle unload.
- `scripts/help/search.txt`, if its lines name the server's process model.
- `CLAUDE.md`: the `search/` row's module list and the pytest count.

## Left for later

- Sharing index data across worktrees: one base index plus each worktree's changed files. Worktrees
  are near-copies, so this would cut the cost of each resident worktree. It changes ranking, though,
  and reaches into semble's internals.
- Memory-mapped vectors and lazily read chunk text: about 350 MB and 460 MB of each worktree's
  1.43 GB. This needs a loader of semble's cache format outside semble.
