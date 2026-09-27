# priviledge — design (draft)

Status: draft proposal. Nothing here is implemented yet. Items marked **(verify)** are assumptions
that must be checked on a real machine before they are relied upon.

This document describes **how** priviledge is built to meet [SPEC.md](SPEC.md). The spec is the
contract; anything here can change as long as the spec still holds. Terms (AI workspace, guest,
profile, privileged side, broker, client) are as defined in [SPEC.md §3](SPEC.md#3-threat-model).

## 1. Processes

One program, `priviledge`, with subcommands:

| Subcommand | Runs on | Role |
|---|---|---|
| `serve <profile> <name>` | privileged side | The broker for one guest: reads the configuration, resolves the profile, opens the channel into the guest and supervises the relay, runs resources, hosts the approval prompt on its terminal, writes the audit log |
| `relay` | guest | Started by the broker through `guest_exec`, never by hand. Listens on a Unix socket inside the guest and forwards between clients and the broker |
| `list`, `describe`, `request`, `wait`, `retrieve`, `pending`, `cancel` | guest | The client (SPEC.md §6). Each call connects to the relay's socket |

**One broker per guest.** Each broker has one channel, so every message it receives belongs to
that guest, and each guest gets its own approval pane. The guest is identified everywhere
(prompt, audit log) as `<profile>/<name>`.

**One request at a time.** The broker runs requests sequentially in arrival order (SPEC.md §7).
A request's states:

```
queued ─▶ awaiting-approval ─▶ running ─▶ awaiting-release ─▶ settled ─▶ (retrieved: discarded)
```

- `awaiting-approval` is skipped when `confirm_request = false`, `awaiting-release` when
  `confirm_output = false` (or the human answered `Y`). Checkers, later, run on entering
  `awaiting-approval`.
- **settled** is one of `done`, `failed` (the resource exited non-zero), `denied` (at approval or
  release) or `dropped` (the connection was lost before `running`).
- `cancel` discards a request in `queued` or `awaiting-approval`; afterwards its id is unknown.

Resources run as child processes of the broker, in their own session without a controlling
terminal, with stdin, stdout and stderr connected to the request. They can't prompt on, or write
to, the approval pane. The broker collects stdout as the result and stderr for the pane and the
log (SPEC.md §8, the resource contract).

## 2. Configuration resolution

At start, `serve <profile> <name>`:

1. Loads `config.toml` (SPEC.md §8) after checking ownership and permissions.
2. Substitutes `{profile}` and `{name}` in the profile's `guest_exec`. `name` must match
   `[A-Za-z0-9][A-Za-z0-9._-]*`, so it cannot alter the command's shape.
3. Builds the guest's resource table from the profile's `resources` table: each entry's resource
   definition plus that entry's `confirm_request`/`confirm_output` (default `true`). An entry for
   an undefined resource, or `confirm_request = false` on a resource with `write_credential`, is
   a start-up error.
4. Refuses to start if the profile has no resources: such a guest has nothing to request, so
   there is nothing to broker.

`list` and `describe` answer from this table only; a request for anything else is an invalid
request (exit 253).

## 3. Channel and relay

```
privileged side                               guest trusted/shop
┌──────────────┐  guest_exec                  ┌──────────────────────────────┐
│ priviledge   │  (docker exec -i             │ priviledge relay             │
│ serve        │   aiws-trusted-shop          │   listens on a Unix socket   │
│ trusted shop │ ────── priviledge relay) ──▶ │   in the guest               │
│              │ ◀───── stdin/stdout ───────▶ │                          ▲   │
└──────────────┘                              │ priviledge request ... ──┘   │
                                              └──────────────────────────────┘
```

**Why this shape.** In a normal client-server setup the host listens, the guest dials in, and the
host must then authenticate the caller: tokens, TLS, or kernel peer credentials. Peer credentials
only work when the guest is a separate OS user, and on macOS a host Unix socket can't even be
mounted into a container, because sockets don't cross the hypervisor. The relay reverses who
connects: the broker dials *into* the guest with a command only it controls, so it knows who is on
the other end because it chose the destination. This meets SPEC.md §3's identity requirement with
no secrets and no host listener. Replacing the relay binary gains a guest nothing: whatever speaks
on this guest's channel *is* this guest.

- On start, the broker runs the resolved `guest_exec` followed by `priviledge relay`, and keeps
  that process's stdin and stdout as the channel. Nothing listens on the host.
- The channel process is started in a new session with no controlling terminal (`setsid`), and
  its stderr is captured rather than inherited. Otherwise, with a `guest_exec` like `sudo -u`, a
  guest process would share the approval pane's terminal and could inject input into it or write
  escape sequences to it. Captured stderr is shown in the pane escaped, like all guest text.
- The relay runs as whichever user `guest_exec` lands on, and clients must run as that same user
  to reach its socket. With `docker exec -i` that is the image's default user; a command that
  switches user (e.g. `-u 0`) would create a socket the guest's normal user cannot use.
- The relay listens on `~/.local/state/priviledge/relay.sock` (directory mode 0700). The path
  deliberately ignores `$XDG_STATE_HOME` and `$XDG_RUNTIME_DIR`, which can be set in some sessions
  and not in others (an interactive shell versus `guest_exec`); it depends only on the home
  directory, so the relay and the clients always agree. `$PRIVILEDGE_SOCKET` overrides it, and
  then must be set for every process in the guest (e.g. in the image's environment). Unix socket
  paths are limited to about 100 bytes (103 on macOS, 107 on Linux); the relay fails with a clear
  message if the path is longer.
- Everything arriving on the channel is untrusted input from that guest. The broker validates
  every message and never trusts a claim of identity in it.

## 4. Handshake and liveness

- **Handshake.** The first line in each direction is a `hello` carrying the protocol version. The
  guest's copy of priviledge is independent of the broker's (SPEC.md §3), so versions will drift;
  on a mismatch the broker reports it in its pane and closes the channel, and the relay answers
  clients with an "incompatible broker" error until it exits.
- **Heartbeat.** The broker sends a `ping` periodically (default every 10 s) and the relay answers
  `pong`. Liveness does not rely on end-of-file on the channel: runtimes don't guarantee that an
  exec'd process sees its stdin close when the calling side dies, and they can't always kill it.
  - The relay exits when it hasn't heard from the broker for a few intervals (default 30 s), or
    on end-of-file.
  - The broker treats a missing `pong` the same way as the channel ending: it kills the channel
    process and restarts it with backoff.
- **Takeover.** A relay starting on a socket that is already served by a live relay takes over:
  it replaces the socket. The old relay checks on every heartbeat that the socket path is still
  its own (same inode); once it isn't, it tells its broker it was taken over and exits, and that
  broker reports "another broker took over this guest" in its pane instead of reconnecting. An
  orphaned relay with no broker exits when its heartbeat lapses. On exit a relay removes the
  socket only if it is still its own. Refusing instead would let an orphaned relay lock a
  restarted broker out of its guest. Takeover grants nothing to the guest: any process in it could
  already answer on the socket, and results are only as trustworthy to clients as the guest
  itself (SPEC.md §3).

## 5. Requests, results and channel loss

Requests live in the broker's memory, keyed by id; ids are not reused. A settled request keeps
its result until a `retrieve` completes: the client sends `retrieved` after writing the last byte
to its stdout without error, and only then does the broker discard the result (SPEC.md §6). A
`retrieve` that ends early (broken pipe, killed client) leaves the result in place.

When the channel ends, the broker marks the guest offline and applies the rules in SPEC.md §6:
requests that have not started become `dropped` (exit 249 on `retrieve`); requests that are
running, awaiting release or settled are kept and flagged "not retrieved". It then restarts the
channel with backoff. When the relay's stdin closes or its heartbeat lapses, it removes its socket
and exits, so clients fail fast with "broker not connected" (exit 254). A broker restart loses the
in-memory requests; the audit log (§8) is the record.

## 6. Framing

- **Client ↔ relay:** newline-delimited JSON, one command per connection. The client sends one
  message (`list`, `describe`, `request`, `wait`, `retrieve`, `pending`, `cancel`) and reads
  events until the connection closes: `accepted` (with the id), `settled`, `chunk`, `result`,
  `error`. For `retrieve` the client answers the final `result` with `retrieved` once its stdout
  is written.
- **Relay ↔ broker:** the same messages over the channel, each line wrapped with a connection id
  assigned by the relay: `{"conn": 7, "msg": {...}}`, plus `{"conn": 7, "close": true}`. This
  multiplexes concurrent clients over one channel. The relay does not interpret messages; it only
  wraps and unwraps them.
- **Byte payloads are streamed in chunks.** The request payload travels from the client, and the
  result back to it, as `chunk` messages (`{"chunk": "<base64>"}`, at most 64 KiB of data each),
  followed by a final message without payload (`end` from the client, `result` from the broker).
  Base64 keeps binary content safe. Chunking keeps one large result from blocking the other
  connections sharing the channel, and bounds line length.
- **Line limit.** A line longer than 1 MiB is a protocol error: the relay drops that client's
  connection, and the broker drops that connection id. Neither needs unbounded buffers.

## 7. Other transports

A host-side TCP listener is a possible later transport for hosts that offer networking but no
`guest_exec`. It would need a per-guest secret to identify callers and protection against other
guests on the same network sniffing or spoofing it (network isolation or TLS). Not planned.

## 8. Files

- Config and state follow the **XDG Base Directory** spec on the privileged side:
  `$XDG_CONFIG_HOME/priviledge` (config, SPEC.md §8), `$XDG_STATE_HOME/priviledge` (audit logs).
- Audit log: `$XDG_STATE_HOME/priviledge/<profile>-<name>.jsonl`, one JSON line per request step,
  each carrying the request id (SPEC.md §9).
- Review temp files (SPEC.md §7) and human-resource answer files (SPEC.md §8) are created in a
  privileged-owned directory with mode 0700 and removed after use.

## 9. Technology

- **Language: Python**, with a **pinned runtime shipped via uv** (a uv-managed interpreter, or a
  bundle via shiv/pex), so there is no dependency on the stock system Python and no version matrix
  to support.
- Standard library only at runtime: `socket`, `selectors`, `subprocess`, `json`, `csv`, `base64`,
  `argparse`, `tomllib`, `hashlib`, `shlex`. No third-party runtime dependencies. Formatting in
  the inline prompt is stdlib-only (SPEC.md §7's review-surface rule); anything richer is the
  external pager or editor.
- **Rust is a deliberate later option, not now.** priviledge's untrusted input is JSON over the
  channel (stdlib `json`, memory-safe) that is mostly passed through to subprocesses; the
  security-critical logic is process and permission handling, not parsing. A Rust rewrite fits as
  a "once the design stops changing" step.

## 10. Session resources (backlog)

A sketch for SPEC.md §8's session resources: the broker holds the process on a pty, the human sees
it start in the approval pane and completes any interactive authentication there, each approved
snippet is written to the session followed by a sentinel, and output is captured up to the
sentinel. It also needs handling for output interleaved with prompts, keepalive, and
cancellation. Local clients such as psql would run confined, per SPEC.md §8's input
rules. Details are open (§12).

## 11. First iterations

Iterations are short and each one is usable; what comes after is chosen when the previous one
ships (SPEC.md §10).

1. **Environment** ([SETUP.md](SETUP.md)): the guest runtime, the profile images, one `trusted`
   guest, egress for it, the tmux layout, and the verification checklist. Building the rest
   *inside* the real boundary surfaces the true frictions instead of guessing them.
2. **Core loop, minimal:** `serve` with configuration resolution, the channel and relay, one exec
   resource, `request`/`wait`/`retrieve` and the sequential prompt with both confirmations.
   Against a local dev database.
3. **Core loop, complete:** `list`, `describe`, `pending`, `cancel`, output review with the
   external pager and editor, the audit log, a read-only cloud resource.
4. **Git and deploy flow** (SETUP.md): clean clones, the `ext::` remote, push and deploy from a
   reviewed commit.
5. **Human resources**, then the rest of the backlog in the order decided at the time.

## 12. Open questions

- Whether a request payload needs a total size cap (lines are already bounded, §6).
- Heartbeat and timeout defaults (10 s / 30 s) are guesses to tune in use.
- **(verify)** what the relay sees when `serve` is killed hard, per runtime (end-of-file or
  nothing). The heartbeat covers both, but it tells us how long orphans linger.
- Session resources: sentinel robustness, prompt noise, long-running statements, cancellation.
