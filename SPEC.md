# priviledge — specification (draft)

Status: draft for discussion. Nothing here is implemented yet. Items marked **(verify)** are
assumptions that must be checked on a real machine before they are relied upon.

This document specifies priviledge itself. How a machine is set up around it (container runtime,
images, terminal, editor, git remotes) is a separate concern, described for one reference
deployment in [SETUP.md](SETUP.md). priviledge depends only on the deployment contract in §4.

## 1. Problem

AI coding agents work best with broad autonomy, but some operations need privileges that should
not be handed to them wholesale: querying production databases, calling cloud APIs, running
consoles on remote hosts, pushing code. Today the choice is roughly all-or-nothing: either the
agent holds the credentials (and can do anything with them, unobserved), or the human becomes a
copy-paste relay, which is slow and error-prone.

priviledge mediates privileged operations: the agent requests, the human approves (or a rule
does), priviledge executes with credentials the agent never sees, the human reviews the output,
and the result goes back to the agent.

## 2. Goals and non-goals

Goals:

- A **real boundary**: an agent that is careless, confused, or actively hostile cannot use
  privileged credentials except through approved requests.
- Low-friction approvals: most requests are reads, arrive in bursts, and should cost one key.
- Output review before results reach the agent.
- Small, POSIX-style, composable; macOS and Linux; minimal and stable dependencies.
- Independent of how the AI workspace is hosted (container, VM, separate OS user).
- Single user, forever.

Non-goals:

- **Protecting production from malicious code that passes code review.** priviledge protects the
  developer's privileged context and mediates direct privileged actions. Code integrity is the job
  of review, CI, branch protection and deploy gates.
- Mediating browser-only surfaces (cloud consoles, dashboards, admin UIs).
- A team or multi-user product.

## 3. Threat model

### Terms

- **AI workspace**: the agent and everything it can influence.
- **Guest**: the isolated environment the AI workspace runs in (a container, a VM, or a separate
  OS user).
- **Privileged side**: the human's own account on the host.
- **Broker**: `priviledge serve`, running on the privileged side.

### Principals

- **AI workspace** (untrusted): the agent **and all development tooling**, including the human's
  editor, LSP servers, tests, dev servers, package installs, git working copies and toolchains.
  The human does their coding *inside* it.
- **Privileged side** (trusted): holds the secrets (cloud credentials, ssh keys, database
  credentials, OS keychain), runs the broker and its approval prompt, holds the credentials for
  pushing and deploying, and controls the guest runtime.

Why the human's tooling lives in the AI workspace: any tool that interprets project files can run
project code. LSP servers load `Gemfile`s, `node_modules` plugins, and virtualenv interpreters.
Dev servers, test runners, installs, build and deploy scripts run it by design. Separating only
the agent from the human would still leave the human constantly running agent-written code with
full privileges. The split must follow *who executes project code*, not *who types*.

### Core rule

> The privileged side never executes, sources, or interprets anything the AI workspace can write:
> not code, not config, not build files, not paths. It handles workspace content only as inert
> data: bytes to display, diff, or transfer.

This rule is generic: it holds for any project, regardless of how vulnerable that project's dev
server, app or build scripts are. Anything that goes wrong inside the AI workspace stays inside it.

The one deliberate exception is **reviewed code at a pinned commit**: deploying it, running a
project's compose file from it, or using a script from it in a resource. That code was written in
the AI workspace, so running it with privileges relies on code review, which is the first
non-goal (§2), not on priviledge.

### The guest is the security principal

Processes inside one guest are not isolated from each other: in a container or VM they share a
kernel and usually a uid; as a separate OS user they share a uid, and same-uid processes can read
each other's memory and files. So **isolation is per guest, never per session**. A rogue agent
session cannot be prevented from using another session's grant in the same guest, reading its
traffic, or acting as it. Consequences:

- **One guest per trust domain.** If two projects (or a trusted model and an experimental one)
  must not impersonate each other, they run in separate guests.
- **Identity comes from the channel, not from anything the guest says.** The broker opens the
  channel into its guest itself (§9), so it knows which guest every request comes from. No token,
  password or TLS is involved, and the guest has nothing to forge. A token scheme would not help
  anyway: whatever an honest client could present, another process in the same guest can obtain.
- Session labels (working directory, pid, agent name) are sent by the client for the human's
  convenience and shown as *claimed*. Nothing security-relevant may depend on them.
- Grants (allowed resources, auto-approval) are per guest.
- Anything configured inside the guest (the agent's permission settings, its instructions) is
  convenience, not a security control. The boundary is the guest itself.

### What the boundary protects

- Secrets on the privileged side (keychain, `~/.aws`, `~/.ssh`, database credentials, browser
  sessions, other projects, personal files).
- Unmediated privileged actions: an agent running cloud CLIs with the human's credentials, or
  pushing against instructions, becomes structurally impossible rather than a matter of
  obedience.

### Residual risks (accepted or mitigated elsewhere)

- Malicious code that passes review (non-goal).
- Anything the AI workspace can reach over the network with credentials it legitimately holds or
  finds in its own files. Secrets must not be placed in the guest.
- Network services the guest can reach: dev services (which hold dev data only) and, depending on
  the deployment, services listening on the host (see SETUP.md).
- Escape from the guest through a runtime or kernel vulnerability. The strength of this boundary
  is a deployment choice.
- The human being misled by what the agent shows them. Mitigated by rendering request and output
  content safely (§7) and by keeping approvals specific.

## 4. Deployment contract

priviledge assumes the deployment guarantees the following. Everything else about the setup is
free to change.

1. **Separation.** The AI workspace cannot read or write the privileged side's secrets, priviledge's
   configuration, or its state.
2. **A channel command.** The privileged side has a command that starts a process inside a given
   guest with its stdin and stdout connected to the caller, for example `docker exec -i <name>`,
   `container exec -i <name>`, `ssh <host>`, or `sudo -u <user>`. The broker uses it to start the
   relay (§9).
3. **No path back.** The guest has no way to act as the privileged side: no sudo to it, no
   credentials for it, no access to the guest runtime's control socket, no shared terminal
   device.
4. **One guest per trust domain** (§3).

## 5. Capability placement

Every privileged capability is placed by one rule:

> **Credentials define capability; priviledge rules define convenience.**

A capability may be granted **natively** to the AI workspace (a token in the agent's own
environment) only if both hold:

1. The service enforces the scope server-side (a read-only token, a read-only DB role), so no
   priviledge logic stands between the agent and misuse.
2. The confidentiality impact of that scope is acceptable if fully exercised.

Everything else is a **priviledge resource**, with one resource per credential. Classifying
requests by content ("this SQL is a read") is never the security boundary; it may only drive
auto-approval on resources whose credential is already limited.

Initial placement (to be confirmed per service):

| Capability | Placement | Notes |
|---|---|---|
| Git upstream read | Native, read-only token | |
| Git push | Privileged side only | Feeds the deploy pipeline; never native, never a resource |
| PR/CI read (code host) | Native, read-only token | |
| Error tracker read | Native, read-only token | Errors may contain PII; acceptable |
| Issue tracker read | Native if a read-only token exists **(verify)** | Otherwise a resource |
| Issue tracker write | Resource | Low blast radius |
| Team chat (any) | Resource or not at all | Even reads are high-impact |
| Prod DB, read-only role | Resource, auto-approve eligible | Role enforces read-only |
| Prod DB, read-write | Resource, always ask | |
| Cloud CLI | Resources per credential | e.g. a read-only policy vs an admin one |
| Consoles and shells on remote hosts | Session resources (v2), always ask | Full power once inside |

Hosted OAuth connectors (e.g. claude.ai integrations) request whatever scopes the connector
defines, often including write. Treat them as full grants unless their scopes are confirmed.

## 6. Components

One program, `priviledge`, with subcommands. Python, shipped with a pinned runtime (§10).

Privileged side:

- `priviledge serve <guest>`: the broker for one guest. Holds the configuration, starts and
  supervises the relay in the guest, runs resources, and hosts the **approval prompt on its own
  terminal**. One broker per guest, typically in that project's tmux window.

Guest side:

- `priviledge relay`: started by the broker through the channel command, never by hand. Listens on
  a Unix socket inside the guest and forwards requests over the channel (§9).
- `priviledge list`, `priviledge describe <resource>`: discovery. `describe` shows the resource's
  description, whether it takes a payload or extra arguments, its declared parameters, and whether
  it is auto-approved.
- `priviledge run <resource> ...`: submit a request, wait, print the result.
- `priviledge wait <id>`: resume waiting on a pending request.

The broker is installed from a privileged-owned source (for example a clean clone at a reviewed
tag). It must never run from a copy the AI workspace can write. This matters because priviledge
itself will be developed in an AI workspace. The guest-side copy can be anything: whatever runs
there speaks for that guest by definition.

**MCP adapter: deferred.** A `priviledge mcp` stdio adapter (exposing only `tools/list` and
`tools/call`) is possible but not in v1. The CLI is POSIX-composable (`priviledge run ... | grep`),
works in every agent, and keeps the surface small and free of MCP spec churn. Add the adapter only
if a client needs it and it shows value over its cost.

## 7. Requests and approval

### Agent side

```sh
priviledge list
priviledge run prod-db-ro -r "count overdue orders by region" <<'SQL'
SELECT region, count(*) FROM orders WHERE status = 'open' GROUP BY region
SQL
priviledge run aws-readonly -r "find restarts" -- logs filter-log-events --log-group-name ...
priviledge run prod-db-ro -o counts.csv -r "..." < query.sql   # the client writes the file
```

- `-r <reason>` is required. It is shown to the human and written to the audit log.
- Inputs travel **by value**: the payload on stdin, extra arguments after `--`, named parameters
  as `-p key=value`, each only if the resource declares it (§8). A file the agent wants to use
  (a `.sql` or a Ruby script) is read by the *client* and sent as content. The broker never opens
  workspace paths.
- Outputs travel **over the channel**. `-o file` is written by the client, inside the guest. The
  broker never writes into workspace paths.
- `run` waits a bounded time (default 90 s). This matters because agent shell tools have hard
  timeouts (Claude Code's Bash tool: 2 min default, 10 min max). If the request is still pending,
  `run` prints its id and exits; the agent continues with `priviledge wait <id>`.
- Exit status: the resource's own exit status when it ran. Otherwise the `sysexits` codes, each
  with a message on stderr: 75 (`EX_TEMPFAIL`) still pending, 77 (`EX_NOPERM`) denied, with the
  human's message, 69 (`EX_UNAVAILABLE`) broker not connected. A resource that itself exits with
  one of these codes is disambiguated by the stderr message.
- If the human edited the request, the result says so and includes the version that ran. If the
  human redacted the output, the result says so.

### Human side

The approval prompt is line-oriented, like `git add -p`:

```
[12] aiws-shop · claimed: ~/src/shop-app, claude · prod-db-ro
     reason: count overdue orders by region
     SELECT region, count(*) FROM orders WHERE status = 'open' GROUP BY region
run? [y]es [n]o(+msg) [e]dit [v]iew [?]
[12] exit 0 · 214 lines · 6.1 KB · 1.4 s
     region,count
     eu-west,412
     ... (first/last lines)
release? [y]es [n]o(+msg) [v]iew [e]dit/redact
```

- The guest name comes from the channel and is authoritative. Everything the client sends
  (labels, reason) is shown as claimed.
- Prompts are answered one at a time, in arrival order. Approved requests run concurrently; their
  release prompts join the same queue.
- Requests that need no confirmation still get a one-line entry in the pane, so the human sees
  everything that runs.
- A bell is emitted on each new prompt (tmux flags the window). An optional `on_request` hook
  runs a command for richer notifications.
- **All agent-supplied text is rendered with control characters escaped.** Requests and outputs
  must not be able to move the cursor, hide lines, restyle the prompt, or send queries to the
  terminal.
- The inline prompt shows escaped plain text with stdlib-only formatting (JSON pretty-printed,
  CSV aligned). No highlighter dependency in priviledge itself.
- `view` writes the content to a privileged-owned temp file (extension from the resource's
  `syntax` / `output_syntax`, §8) and opens `$PRIVILEDGE_REVIEW_PAGER` (default `less`, without
  `-R`). `edit` does the same with `$PRIVILEDGE_REVIEW_EDITOR` (default `vi`). Both can point at
  the same minimal nvim, the pager in read-only mode: `nvim -R -u ~/.config/priviledge/review.lua`.
- Output is not size-limited in v1. The prompt shows size and a head/tail preview; `view` shows
  all of it.

### Review surfaces run as privileged over hostile content

Whatever displays a request or output runs on the **privileged side** over **agent-authored**
text, exactly the content the core rule says privileged tools must not interpret. A painful
review is itself a risk, because that is where a sneaked-in change gets past a tired reviewer, so
the review surface should be comfortable **and** minimal:

- **No LSP, ever.** LSP servers execute project code.
- **Syntax highlighting is a small, accepted risk.** Highlighters (vim syntax, treesitter) are
  in-process parsers of untrusted input and have had memory-safety bugs, but they do not execute
  project code. Acceptable when the review config is privileged-owned and plugin-free, so the AI
  workspace cannot alter it.
- **Recommended:** a minimal privileged-owned nvim config with syntax colouring, no plugins that
  execute, and no LSP.

## 8. Configuration and resources

### Configuration file

`$XDG_CONFIG_HOME/priviledge/config.toml` (privileged-owned, mode 0600), i.e. `~/.config/priviledge/`
by default. The broker refuses to start if the config, the resources directory, or any resource
executable is group- or world-writable, or not owned by the privileged user. A leading `~` in paths
is expanded.

```toml
[guests.aiws-shop]
channel = ["docker", "exec", "-i", "aiws-shop"]   # the deployment's channel command (§4)
resources = ["prod-db-ro", "prod-db-rw", "aws-readonly"]

[resources.prod-db-ro]
description = "Production Postgres (read-only role). Bound queries on large tables by time."
run = "~/.config/priviledge/resources/prod-db-ro"
input = "stdin"            # takes a payload: the SQL
syntax = "sql"
output_syntax = "csv"
credential = "read-only"
confirm_request = false    # auto-approve (allowed: credential is read-only)
confirm_output = false     # and auto-release the output

[resources.prod-db-rw]
description = "Production Postgres (read-write role). Always ask."
run = "~/.config/priviledge/resources/prod-db-rw"
input = "stdin"
syntax = "sql"
output_syntax = "csv"
credential = "read-write"

[resources.aws-readonly]
description = "AWS CLI with the read-only role. Pass the aws arguments after --."
run = "~/.config/priviledge/resources/aws-readonly"
args = true
output_syntax = "json"
credential = "read-only"
confirm_request = false
```

### Guest fields

| Field | Meaning |
|---|---|
| `channel` | The channel command (§4), as an argv list. The broker appends `priviledge relay` |
| `resources` | The resources this guest may list and request. Others don't exist for it |

### Resource fields

| Field | Meaning |
|---|---|
| `description` | Shown to the agent by `list`/`describe` and to the human in the prompt |
| `run` | The privileged-owned executable |
| `input` | `"stdin"` if the resource takes a payload. Omitted: no payload accepted |
| `args` | `true` if extra arguments after `--` are passed as argv. Default `false` |
| `params` | Table of named parameters and their descriptions. Undeclared parameters are rejected |
| `syntax`, `output_syntax` | Review hints: the file extension used for `view`/`edit` |
| `credential` | `"read-only"` or `"read-write"`: the human's declaration of what the credential enforces |
| `confirm_request` | Default `true`: approve before running. `false` is only allowed with `credential = "read-only"` |
| `confirm_output` | Default `true`: approve before the output is released. `false` releases it unreviewed |

`confirm_request = false` on a read-write resource would let writes run unapproved, which is why
it is tied to the credential. Releasing output unreviewed is a confidentiality choice and is
allowed for any resource.

### Exec resources (v1)

A resource is an executable owned by the privileged user. It is run directly, never through a
shell. It receives the payload on stdin, declared parameters as `PRIVILEDGE_P_<NAME>` environment
variables, and, if `args = true`, the extra arguments as argv. The agent cannot set any other part
of its environment. It fetches its own secrets with whatever the OS provides:

```sh
#!/bin/sh
# prod-db-ro
PGPASSWORD=$(security find-generic-password -s prod-db-ro -w) \
  exec psql "host=... user=app_ro dbname=..." -X -v ON_ERROR_STOP=1 --csv -f -
```

```sh
#!/bin/sh
# aws-readonly: any aws command, bounded by the read-only role
exec aws --profile readonly "$@"
```

Linux equivalents for secrets: `secret-tool lookup ...`, `pass show ...`, `op read ...`.

What the arguments can do is bounded by the credential, which is why the credential, not
argument filtering, is the boundary. `args = true` on a broad credential should come with
`confirm_request = true`.

Resource executables must reference only privileged-owned files. A script taken from a project
(for example a repo's `bin/console`) is used from a privileged clean clone at a reviewed
commit (§3, the exception to the core rule), never from the AI workspace.

### Session resources (v2)

Long-lived interactive processes: psql, a Django shell reached through a cloud exec
shell, a remote ssh shell. Essential in practice (slow start-up, loaded state,
interactive auth at start) but materially more complex than exec resources: the broker holds a
pty, frames each approved snippet against a sentinel, handles output interleaved with prompts,
and manages keepalive and cancellation. Deferred to v2. In v1 the same work is done with repeated
exec requests (each `psql` invocation is one request), which is slower but simple and safe.

## 9. Protocol

```
privileged side                                  guest "aiws-shop"
┌──────────────┐  channel command            ┌──────────────────────────┐
│ priviledge    │  (docker exec -i aiws-shop  │ priviledge relay          │
│ serve        │ ────── priviledge relay) ──▶ │   listens on a Unix      │
│ aiws-shop    │ ◀───── stdin/stdout ──────▶ │   socket in the guest    │
└──────────────┘                             │          ▲               │
                                             │ priviledge run ... ───────┘
                                             └──────────────────────────┘
```

### Channel and relay

- On start, `serve <guest>` runs the guest's `channel` command followed by `priviledge relay`, and
  keeps that process's stdin and stdout as the channel. Nothing listens on the host.
- The relay listens on `$PRIVILEDGE_SOCKET`, default `$XDG_STATE_HOME/priviledge/relay.sock` (i.e.
  `~/.local/state/priviledge/relay.sock`, directory mode 0700). The default depends only on the
  home directory, so the relay and the clients agree on it however each was started.
- The relay removes a stale socket file at start. If another relay answers on the socket, it
  refuses to start, and `serve` reports that a broker is already connected to this guest.
- If the channel ends (guest stopped, relay killed), the broker marks the guest offline, fails its
  pending requests, and restarts the channel with backoff. When the relay's stdin closes (broker
  gone), it removes its socket and exits, so clients fail fast.
- Everything arriving on the channel is untrusted input from that guest. The broker validates
  every message and never trusts a claim of identity in it.

### Framing

- **Client ↔ relay:** newline-delimited JSON, one request per connection. The client sends one
  message (`run`, `wait`, `list`, `describe`) and reads event messages (`pending`, `result`,
  `error`) until the connection closes. A client that disconnects does not cancel its request.
- **Relay ↔ broker:** newline-delimited JSON over the channel, each line wrapping one message with
  a connection id assigned by the relay: `{"conn": 7, "msg": {...}}`, plus `{"conn": 7, "close":
  true}`. This multiplexes concurrent clients over one channel.
- Byte payloads (stdin, stdout, stderr) are base64-encoded fields, so binary content is safe.

### Other transports

A host-side TCP listener is a possible later transport for hosts that offer networking but no
channel command. It would need a per-guest secret to identify callers and protection against
other guests on the same network sniffing or spoofing it (network isolation or TLS). Not in v1.

### Files and logs

- Config and state follow the **XDG Base Directory** spec on the privileged side:
  `$XDG_CONFIG_HOME/priviledge` (config, §8), `$XDG_STATE_HOME/priviledge` (audit logs).
- There is no approval socket in v1: approval happens only on `serve`'s terminal. A privileged-only
  approval socket for scripting (`pending`, `approve`, `deny`) can come later.
- Audit log: `$XDG_STATE_HOME/priviledge/<guest>.jsonl`, one entry per request: guest, claimed
  labels, reason, request (and the edited version, if any), decisions and timestamps, exit status,
  output size and a hash of the output. Output bodies are not logged by default.

## 10. Technology

- **Language: Python**, with a **pinned runtime shipped via uv** (a uv-managed interpreter, or a
  bundle via shiv/pex), so there is no dependency on the stock system Python and no version matrix
  to support.
- Standard library only at runtime: `socket`, `selectors`, `subprocess`, `json`, `base64`,
  `argparse`, `tomllib`, `hashlib`, `shlex`. No third-party runtime dependencies.
- **Rust is a deliberate later option, not now.** priviledge's untrusted input is JSON over the
  channel (stdlib `json`, memory-safe) that is mostly passed through to subprocesses; the
  security-critical logic is process and permission handling, not parsing. A Rust rewrite fits as
  a "once the design stops changing" step.

## 11. Iteration plan

1. **Environment first** ([SETUP.md](SETUP.md)): the guest runtime, the base image, one project
   guest, the tmux layout, and the verification checklist. Building the rest *inside* the real
   boundary surfaces the true frictions (timeouts, round-trips, approval bursts) instead of
   guessing them.
2. **Core loop:** `serve` with the channel and relay, exec resources, the approval prompt with the
   confirmation flags and output review, `run`/`wait`/`list`/`describe`, and the audit log. Try
   it against a local dev database and a read-only cloud command.
3. **Git and deploy flow** (SETUP.md): clean clones, the `ext::` remote, push and deploy from a
   reviewed commit.
4. **Sessions (v2):** psql first, then a Django shell through a cloud exec shell.
5. **Ergonomics and more resources:** notification hook, burst approvals ("approve the rest from
   this resource for N minutes", read-only resources only), a privileged approval socket, SaaS
   write resources (issue tracker, team chat), and the MCP adapter if a client needs it.

## 12. Open questions

- Which SaaS tokens can actually be scoped read-only (trackers, code hosts, chat) **(verify)**.
- Cancelling a running request from the approval prompt, and whether resources need a timeout.
- Session (v2) design details: sentinels, prompt noise, long-running statements, cancellation.
- Head/tail preview size in the approval prompt.
- Whether a guest-side message size limit is needed to keep a misbehaving guest from exhausting
  the broker.
