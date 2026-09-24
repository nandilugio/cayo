# priviledge — specification (draft)

Status: draft for discussion. Nothing here is implemented yet. Items marked **(verify)** are
assumptions that must be checked on a real machine before they are relied upon.

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
- Single user, forever.

Non-goals:

- **Protecting production from malicious code that passes code review.** priviledge protects the
  developer's privileged context and mediates direct privileged actions. Code integrity is the job
  of review, CI, branch protection and deploy gates.
- Mediating browser-only surfaces (cloud consoles, dashboards, admin UIs).
- A team or multi-user product.

## 3. Threat model

### Principals

The machine is split into two principals, each a separate OS user:

- **Workspace** (untrusted): the agent **and all development tooling**, including the human's
  editor, LSP servers, tests, dev servers, package installs, git working copies and toolchains.
  The human does their coding *inside* the workspace, over ssh.
- **Privileged** (trusted): the human's own account. It holds the secrets (cloud credentials, ssh
  keys, database credentials, OS keychain), runs the priviledge broker and its approval prompt,
  holds clean clones for push and deploy, and manages Docker.

Why the human's tooling lives in the workspace: any tool that interprets project files can run
project code. LSP servers load `Gemfile`s, `node_modules` plugins, and virtualenv interpreters.
Dev servers, test runners, installs, build and deploy scripts run it by design. Separating only
the agent's uid from the human's would still leave the human constantly running agent-written
code with full privileges. The split must follow *who executes project code*, not *who types*.

### Core rule

> The privileged principal never executes, sources, or interprets anything the workspace can
> write — not code, not config, not build files, not paths. It treats workspace content as
> inert data only (bytes to display, diff, or transfer).

This rule is generic: it holds for any project, regardless of how vulnerable that project's dev
server, app or build scripts are. Anything that goes wrong inside the workspace stays inside it.

### What the boundary protects

- Secrets in the privileged account (keychain, `~/.aws`, `~/.ssh`, database credentials, browser
  sessions, other projects, personal files).
- Unmediated privileged actions: an agent running cloud CLIs with the human's credentials, or
  pushing against instructions, becomes structurally impossible rather than a matter of
  obedience.

### Residual risks (accepted or mitigated elsewhere)

- Malicious code that passes review (non-goal, see above).
- Anything the workspace can reach over the network with credentials it legitimately holds or
  finds lying in its own tree. **Secrets must not live in workspace-readable locations** (see §10).
- Local dev services (Docker containers) are reachable by the workspace; they hold dev data only.
- The human being misled by what the agent shows them. Mitigated by rendering request and output
  content safely (§6) and by keeping approvals specific.

## 4. Capability placement

Every privileged capability is placed by one rule:

> **Credentials define capability; priviledge rules define convenience.**

A capability may be granted **natively** to the workspace (a token in the agent's own
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
| Git upstream read | Native, read-only token | Push is never native (§8) |
| Git push | Privileged only, from a clean clone | Feeds the deploy pipeline |
| PR/CI read (code host) | Native, read-only token | |
| Error tracker read | Native, read-only token | Errors may contain PII; acceptable |
| Issue tracker read | Native if a read-only token exists **(verify)** | Otherwise a resource |
| Issue tracker write | Resource | Low blast radius; could default to auto-approve |
| Team chat (any) | Resource or not at all | Even reads are high-impact |
| Prod DB, read-only role | Resource, auto-approve eligible | Role enforces read-only |
| Prod DB, read-write | Resource, always ask | |
| Cloud CLI | Resources per credential | e.g. a read-only policy vs an admin one |
| Consoles and shells on remote hosts | Session resources, always ask | Full power once inside |

Hosted OAuth connectors (e.g. claude.ai integrations) request whatever scopes the connector
defines, often including write. Treat them as full grants unless their scopes are confirmed.

## 5. Components

One program, `priviledge`, with subcommands. Python 3.11+, standard library only.

- `priviledge serve` (privileged): the broker. Holds the registry, runs resources, and hosts the
  **approval prompt on its own terminal**. Run it in a dedicated privileged tmux pane.
- `priviledge list`, `priviledge describe <resource>` (workspace): discovery.
- `priviledge run <resource> ...` (workspace): submit a request, wait, print the result.
- `priviledge wait <id>` (workspace): resume waiting on a pending request.
- `priviledge mcp` (workspace): stdio MCP adapter over the same socket. It exposes only
  `tools/list` and `tools/call`.

The broker is installed from a privileged-owned source (for example a clean clone at a reviewed
tag). It must never run from a workspace-writable copy. This matters because priviledge itself
will be developed in a workspace.

## 6. Requests and approval

### Agent side

```sh
priviledge list
priviledge run prod-db-ro -r "count overdue orders by region" <<'SQL'
SELECT region, count(*) FROM orders WHERE status = 'open' GROUP BY region
SQL
priviledge run aws-readonly -r "find restarts" -- logs filter-log-events --log-group-name ...
priviledge run prod-db-ro -o counts.csv -r "..." < query.sql   # the client writes the file
```

- Parameters travel **by value**: the payload on stdin, arguments after `--`, and named
  parameters as `-p key=value`. A file the agent wants to use (a `.sql` or a Ruby script) is read
  by the *client* and sent as content. The broker never opens workspace paths.
- Outputs travel **over the socket**. `-o file` is written by the client, as the workspace user.
  The broker never writes into workspace paths, because a privileged process writing to a path
  the workspace controls can be redirected elsewhere through links.
- Exit status mirrors the resource's exit status. Denials exit non-zero with the human's message
  on stderr.
- `run` waits a bounded time (default 90 s) and then prints a request id and exits with a
  distinct "pending" status. The agent continues with `priviledge wait <id>`. This matters because
  agent shell tools have hard timeouts (Claude Code's Bash tool: 2 min default, 10 min max).

### Human side

The approval prompt is line-oriented, like `git add -p`:

```
[12] ws · ~/src/shop-app · prod-db-ro
     reason: count overdue orders by region
     SELECT region, count(*) FROM orders WHERE status = 'open' GROUP BY region
run? [y]es [n]o(+msg) [e]dit [v]iew [?]
[12] exit 0 · 214 lines · 6.1 KB · 1.4 s
     region,count
     eu-west,412
     ... (first/last lines)
release? [y]es [n]o(+msg) [v]iew [e]dit/redact
```

- A bell is emitted on each new request (tmux flags the window). An optional `on_request` hook
  runs a command for richer notifications.
- Requests are queued FIFO. `y` on a burst can be followed by `a` ("approve the rest from this
  resource for N minutes"), but only on auto-approve-eligible resources.
- **All agent-supplied text is rendered with control characters escaped.** Requests and outputs
  must not be able to move the cursor, hide lines, restyle the prompt, or send queries to the
  terminal.
- `edit` opens content in `$PRIVILEDGE_EDITOR` (default `vi`, or `nvim --clean`), never in the
  human's full editor configuration with plugins and LSP.
- `view` pipes through `less` without `-R`.

### Review modes (per resource)

- `request`: approve before running; output is released automatically.
- `output`: run automatically; approve before releasing the output.
- `both` (the default): approve before running and before releasing.
- `none`: only for auto-approve-eligible resources.

## 7. Resources

### Registry

`~/.config/priviledge/resources.toml` (privileged, mode 0600). The broker refuses to start if the
config, the resources directory, or any resource executable is group- or world-writable, or not
owned by the privileged user.

```toml
[prod-db-ro]
description = "Production Postgres (read-only role). Bound queries on large tables by time."
kind = "exec"
run = "~/.config/priviledge/resources/prod-db-ro"
input = "stdin"            # payload = SQL text
review = "request"
approve = "ask"            # or "auto" (allowed only with credential = "read-only")
credential = "read-only"   # declared by the human; documents what the credential enforces

[prod-console]
description = "Django shell on a production console task. Full write access."
kind = "session"
start = "~/.config/priviledge/resources/prod-console"
dialect = "irb"
review = "both"
approve = "ask"
```

### Exec resources

A resource is an executable owned by the privileged user. It receives the payload on stdin,
named parameters as `PRIVILEDGE_P_<NAME>` environment variables, and extra arguments as argv. It
fetches its own secrets with whatever the OS provides:

```sh
#!/bin/sh
# prod-db-ro
PGPASSWORD=$(security find-generic-password -s prod-db-ro -w) \
  exec psql "host=... user=app_ro dbname=..." -X -v ON_ERROR_STOP=1 --csv -f -
```

Linux equivalents: `secret-tool lookup ...`, `pass show ...`, `op read ...`.

Resource executables must reference only privileged-owned files. For example, a repo's
`bin/console` is used from a privileged clean clone at a reviewed commit, never from the
workspace tree.

### Session resources

Long-lived interactive processes: psql, a Django shell reached through a cloud exec
shell, a remote ssh shell. These are essential in practice, because they have slow
start-up, loaded state, and interactive authentication at start.

- The broker starts the process on a pty. The human sees it start in the approval pane and
  completes any interactive authentication there.
- Each approved snippet is written to the session followed by a dialect-specific sentinel
  (`\echo`, `puts`, `print`, `echo`). Output is captured up to the sentinel.
- Keepalive is per dialect. Sessions can be listed, restarted and closed from the approval
  prompt.
- Tabular output is requested on stdout (for example `\copy (...) TO STDOUT WITH CSV HEADER`),
  replacing today's client-side `\copy ... TO '<file>'`.

Design details (sentinel robustness, output that interleaves with prompts, timeouts) are left to
the implementation iteration.

## 8. Git and deploy flow

- The workspace clone's `origin` is the upstream with a **read-only** token. Fetch and pull work;
  push is rejected by the server.
- Each repo has a **privileged clean clone** with two remotes: `origin` (upstream, read-write key)
  and `ws` (`ws:src/<repo>`, over ssh to the workspace).
- Review and push, without checking anything out:

  ```sh
  git fetch ws feature-x
  git log -p origin/develop..ws/feature-x
  git push origin ws/feature-x:feature-x
  ```

  Fetching over ssh runs git on the workspace side as the workspace user. The privileged side
  only receives pack data, the same trust model as fetching from any remote.
- Deploys and infrastructure changes (`cap`, `tofu`, etc.) run from the clean clone, checked out
  at the reviewed commit. This does execute repo code with privileges, which is inherent. The
  guarantee is integrity: *what runs is exactly what was reviewed*.

## 9. Docker

- The Docker socket is root-equivalent. Only the privileged user can reach it.
- Compose runs from the clean clone at a reviewed commit, so that review covers mounts,
  privileges and build contexts. A small privileged-owned override binds published ports to
  `127.0.0.1`.
- The workspace reaches services over localhost TCP (`psql -h localhost`),
  not `docker exec`.
- Docker Desktop's file sharing should be limited to the paths the compose files mount
  **(verify)** the defaults on the machine.

## 10. Prerequisites and hygiene

- The privileged home is not traversable by the workspace (`chmod 700 ~`). On macOS every local
  user is in the `staff` group and home directories are group-traversable by default
  **(verify)**. Check from the workspace that `ls /Users/<me>` fails.
- No secrets in workspace-readable trees. Move personal env files, credential notes and backups
  out of the repos into the privileged home. Tracked secrets are a team issue: rotation and
  removal.
- The workspace gets its own copy of the human's global gitignore. Otherwise personal files that
  are ignored only by the privileged user's global ignore become committable.
- Dev databases that matter are protected by snapshots or credentials. The workspace can reach
  them.

## 11. Protocol

- A Unix domain socket in a privileged-owned directory that the workspace can traverse but not
  write to. The directory is group `priviledge`, mode 0750. The socket is group `priviledge`,
  mode 0660. The workspace user is a member of the group.
  - macOS default: `/Users/Shared/priviledge/`.
  - Linux default: a configurable directory such as `/var/lib/priviledge/`.
- The broker checks the peer uid on each connection against an allow-list: `SO_PEERCRED` on
  Linux, `LOCAL_PEERCRED` on macOS.
- Newline-delimited JSON, one request per connection. Simple enough to forward over ssh later
  (for example a workspace on another host or a VM).
- There is no approval socket in v1: approval happens only on `serve`'s terminal. A privileged-only
  approval socket (mode 0700) for scripting (`pending`, `approve`, `deny`) can come later.
- Audit log: JSON lines in the privileged state directory, one entry per request. It records the
  request, reason, peer, decisions and timestamps, output size and a hash of the output. Output
  bodies are not logged by default.

## 12. Recommended environment (macOS, with Linux notes)

This is an example setup for the workflow above. The commands change system configuration, so
the human reviews and runs them.

### 12.1 Workspace user

```sh
# macOS
sudo sysadminctl -addUser ws -fullName "priviledge workspace" -password -
sudo dscl . create /Users/ws IsHidden 1
sudo dseditgroup -o create priviledge
sudo dseditgroup -o edit -a ws -t user priviledge
chmod 700 ~                      # privileged home, not traversable by ws

# Linux
sudo useradd -m -s /bin/zsh ws
sudo groupadd priviledge && sudo usermod -aG priviledge ws
chmod 700 ~
```

### 12.2 ssh to localhost (the only way into the workspace)

Panes enter the workspace with `ssh`, not `su`. ssh gives each session its own pty owned by the
workspace, so nothing running there shares a terminal device with the privileged shell.

Enable Remote Login (macOS: System Settings → General → Sharing → Remote Login, allowed for `ws`
only). Then add `/etc/ssh/sshd_config.d/100-priviledge.conf`:

```
AllowUsers ws@127.0.0.1 ws@::1
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowAgentForwarding no
AllowTcpForwarding no
AllowStreamLocalForwarding no
X11Forwarding no
PermitTunnel no
```

On macOS, sshd is started by launchd on all interfaces, and `ListenAddress` may be ignored
**(verify)**. `AllowUsers ...@127.0.0.1` still restricts logins to loopback.

Use a dedicated key, separate from any upstream key:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/id_ws -N ''
# as ws, in ~ws/.ssh/authorized_keys:
#   restrict,pty ssh-ed25519 AAAA... privileged-to-ws
```

Privileged `~/.ssh/config`:

```
Host ws
  HostName 127.0.0.1
  User ws
  IdentityFile ~/.ssh/id_ws
  IdentitiesOnly yes
  ForwardAgent no
  ForwardX11 no
  ClearAllForwardings yes
  RequestTTY yes
```

There is never a key or password path from the workspace into the privileged account.

### 12.3 Terminal and tmux (privileged)

The tmux server runs as the privileged user inside the terminal. Workspace processes cannot reach it:
its socket directory is per-user and mode 0700.

A terminal that denies clipboard reads, Ghostty for example:

```
clipboard-read = deny
clipboard-write = allow
```

The workspace can set the clipboard through OSC 52, which replaces `pbcopy`. Reads stay denied,
because the clipboard often holds secrets.

`~/.tmux.conf`:

```
set -g set-clipboard on
set -g monitor-bell on
set -g bell-action other
```

A per-project layout:

```sh
# ~/bin/pp-shop
tmux new-window -n shop   'ssh ws -t "cd src/shop-app && exec \$SHELL -l"'   # nvim
tmux split-window -h      'ssh ws -t "cd src/shop-app && exec claude"'        # agent
tmux split-window -v      'ssh ws -t "cd src/shop-app && exec \$SHELL -l"'   # tests, servers
```

Plus one privileged window per machine:

- `priviledge serve` (the approval prompt; its bell marks the window).
- A shell in the clean clones, for review, push, deploy and compose.

### 12.4 Editor and LSP (workspace)

- nvim, its plugins and every LSP server run as `ws`: ruby-lsp, typescript-language-server,
  basedpyright/pyright, lua_ls, and so on. A plugin manager and mason.nvim install into `~ws`.
- nvim configuration is a copy or a clone of the human's dotfiles in `~ws`. It is never a
  symlink into the privileged home, which ws cannot read anyway.
- VS Code, optionally, via Remote-SSH to `ws`, so its extensions and LSP servers run as ws.
- The privileged user does not open workspace repos in a full editor. For review use
  `git diff`, `git show` and `less`, in the clean clone.

### 12.5 Toolchains (workspace)

- `ws` owns its own toolchains, for example with mise: Python, Node, Java, Go.
  Project-specific installs (pip, npm, uv) all happen as ws.
- Homebrew stays owned by the privileged user. ws may run brew-installed binaries but cannot
  install. This direction is safe for the privileged side.
- The privileged `PATH` never includes workspace-writable directories.

### 12.6 Repositories and agent (workspace)

- Repos live under `~ws/src/`, owned by ws. Moving existing checkouts changes their paths, so
  tool state keyed by path (for example Claude Code's per-project memory) must be carried over.
- git: identity, a copy of the global gitignore, and read-only upstream tokens.
- Claude Code runs as ws with its own login and the copied global instructions and memories. Its
  permission allow-list includes `Bash(priviledge list)`, `Bash(priviledge describe:*)`,
  `Bash(priviledge run:*)` and `Bash(priviledge wait:*)`. Optionally register `priviledge mcp`.
- Native read-only tokens (§4) live in ws's environment or config.

### 12.7 Verification checklist (run as ws)

- `ls /Users/<me>` fails. `cat ~<me>/.aws/credentials` fails.
- `ssh <me>@localhost` is refused.
- `docker ps` fails (no socket access).
- `git push` to upstream is rejected by the server.
- `priviledge list` works. Stopping `priviledge serve` makes `run` fail fast with a clear message.

## 13. Technology

- Python 3.11+ (`tomllib`), standard library only: `socket`, `selectors`, `subprocess`, `pty`,
  `json`, `argparse`, `tomllib`, `hashlib`, `shlex`.
- No third-party runtime dependencies. MCP support is limited to the stable tools subset.

## 14. Iteration plan

1. **Core loop:** the broker, exec resources, the line-oriented approval prompt with output
   review, `run`/`wait`/`list`, and the audit log. Try it first against a local dev database and
   a read-only cloud command.
2. **Environment:** set up the workspace user, ssh, tmux and nvim on the real machine, and work
   through the verification checklist. This can run in parallel with (1).
3. **Sessions:** psql first, then a Django shell through a cloud exec shell.
4. **Ergonomics:** the MCP adapter, burst approvals, notification hook, and `pending`/`approve`
   over a privileged approval socket.
5. **More resources:** SaaS write resources (issue tracker, team chat) and git/deploy helpers.

## 15. Open questions

- Which SaaS tokens can actually be scoped read-only (trackers, code hosts, chat) **(verify)**.
- Session design details: sentinels, prompt noise, long-running statements, cancellation.
- Output size limits and truncation policy (typical results are KB; occasional dumps of 10 MB or
  more).
- Whether burst approvals ("approve the rest for N minutes") are needed from day one.
- Linux specifics: the socket directory under systemd, and socket-activated sshd on some
  distributions honouring `ListenAddress` differently **(verify)**.
- Migrating existing checkouts and per-path tool state into the workspace.
