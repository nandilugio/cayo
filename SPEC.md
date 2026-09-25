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

- **AI workspace** (untrusted): the agent **and all development tooling**, including the human's
  editor, LSP servers, tests, dev servers, package installs, git working copies and toolchains.
  The human does their coding *inside* the AI workspace, over ssh. The OS user is `aiws` in this
  document.
- **Privileged** (trusted): the human's own account. It holds the secrets (cloud credentials, ssh
  keys, database credentials, OS keychain), runs the priviledge broker and its approval prompt,
  holds clean clones for push and deploy, and manages Docker.

Why the human's tooling lives in the AI workspace: any tool that interprets project files can run
project code. LSP servers load `Gemfile`s, `node_modules` plugins, and virtualenv interpreters.
Dev servers, test runners, installs, build and deploy scripts run it by design. Separating only
the agent's uid from the human's would still leave the human constantly running agent-written
code with full privileges. The split must follow *who executes project code*, not *who types*.

### The uid is the security principal

Two processes running as the **same uid** are not isolated from each other by the OS: same-uid
processes can read each other's memory and files and signal each other. So **isolation is per
uid, never per session**. A rogue agent session cannot be prevented from using another same-uid
session's grant, reading its socket traffic, or acting as it — they are one principal to the
kernel. Consequences:

- **One AI-workspace uid per trust domain.** If two projects (or a trusted model and an
  experimental one) must not impersonate each other, they get separate uids (`aiws-a`, `aiws-b`),
  and typically **one broker per uid** (§5, §11), each with its own socket and approval pane.
- The broker authenticates every caller by **kernel-provided peer credentials** (§11), which
  give the uid unspoofably. Grants (auto-approve windows, etc.) are keyed to the uid.
- Session labels in the approval UI are a convenience for the human, **never a security
  boundary**. Nothing security-relevant may depend on distinguishing sessions within a uid.

This also means no session token scheme would help: whatever an honest client could present to
prove its identity, a same-uid process can obtain the same way. And a local Unix socket needs no
TLS: the kernel authenticates the peer uid, filesystem permissions keep other uids out, and
within a uid TLS would protect nothing (a same-uid process can read the client's keys).

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
- Local dev services (Docker containers) are reachable by the AI workspace; they hold dev data
  only.
- The human being misled by what the agent shows them. Mitigated by rendering request and output
  content safely (§6) and by keeping approvals specific.

## 4. Capability placement

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

One program, `priviledge`, with subcommands. Python, shipped with a pinned runtime (§13).

- `priviledge serve` (privileged): the broker. Holds the registry, runs resources, and hosts the
  **approval prompt on its own terminal**. Run it in a dedicated privileged tmux pane. One broker
  per AI-workspace uid (§3); each listens on its own socket and has its own approval pane.
- `priviledge list`, `priviledge describe <resource>` (AI workspace): discovery.
- `priviledge run <resource> ...` (AI workspace): submit a request, wait, print the result.
- `priviledge wait <id>` (AI workspace): resume waiting on a pending request.

The broker is installed from a privileged-owned source (for example a clean clone at a reviewed
tag). It must never run from a workspace-writable copy. This matters because priviledge itself
will be developed in an AI workspace.

**MCP adapter — deferred.** A `priviledge mcp` stdio adapter (exposing only `tools/list` and
`tools/call` over the same socket) is possible but not in v1. The CLI is POSIX-composable
(`priviledge run ... | grep ...`), works in every agent, and keeps the surface small and free of
MCP spec churn. Add the adapter only for a client that allows MCP but not shell, or that needs
richer per-resource parameter schemas.

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
- Outputs travel **over the socket**. `-o file` is written by the client, as the `aiws` user.
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
[12] aiws · ~/src/shop-app · prod-db-ro
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
- The inline prompt shows escaped plain text with stdlib-only formatting (JSON pretty-printed,
  CSV aligned). No highlighter dependency in priviledge itself.
- `view` writes the content to a privileged-owned temp file (extension from the resource's
  `syntax` / `output_syntax` hint, §7) and opens `$PRIVILEDGE_REVIEW_PAGER` (default `less`
  without `-R`). `edit` does the same with `$PRIVILEDGE_REVIEW_EDITOR` (default `vi`). Both can
  point at the same minimal nvim, the pager in read-only mode:
  `nvim -R -u ~/.config/priviledge/review.lua`.

### The review editor runs as privileged over hostile content

Whatever reviews a priviledge request or output runs as the **privileged** user over
**agent-authored** text, which is exactly the content the core rule (§3) says privileged tools
must not interpret. A painful review is itself a risk, because that is where rogue code slips
past a tired reviewer, so the review surface should be comfortable **and** minimal:

- **No LSP, ever.** LSP servers execute project code; that breaches the boundary outright.
- **Treesitter is a smaller but nonzero risk:** parsers are in-process C libraries parsing
  untrusted input and have had memory-safety bugs, though they do not execute project code.
  Acceptable for highlighting **if** the review config is privileged-owned and plugin-free so the
  workspace cannot alter it. Omit it if you want to be strict about the raw approval payload.
- **Default:** a minimal privileged-owned nvim config (syntax colouring via vim syntax or
  treesitter, git navigation, no plugins that execute, no LSP), or plain `less`. Syntax
  colouring and formatting matter: they make a sneaked-in change easier to spot.
- **Diff review before push is a separate, lower-hostility moment** (you are judging code, not
  handling an active payload). See §8 for the two-pass review.

### Confirmation flags (per resource)

Two independent booleans, so there are no mode names to remember:

- `confirm_request` (default `true`): approve before the resource runs.
- `confirm_output` (default `true`): approve before the output is released to the agent.

Auto-approve is both `false`, and the broker **only permits that when `credential = "read-only"`**
(§4). Any other combination is allowed.

## 7. Resources

### Registry

`$XDG_CONFIG_HOME/priviledge/resources.toml` (privileged, mode 0600), i.e. `~/.config/priviledge/`
by default. The broker refuses to start if the config, the resources directory, or any resource
executable is group- or world-writable, or not owned by the privileged user.

```toml
[prod-db-ro]
description = "Production Postgres (read-only role). Bound queries on large tables by time."
run = "~/.config/priviledge/resources/prod-db-ro"
input = "stdin"            # payload = SQL text
syntax = "sql"             # review hint for the request payload
output_syntax = "csv"      # review hint for the output
credential = "read-only"   # declared by the human; documents what the credential enforces
confirm_request = false    # auto-approve the run (allowed: credential is read-only)
confirm_output = false     # and auto-release the output

[prod-db-rw]
description = "Production Postgres (read-write role). Always ask."
run = "~/.config/priviledge/resources/prod-db-rw"
input = "stdin"
syntax = "sql"
output_syntax = "csv"
credential = "read-write"
# confirm_request and confirm_output default to true
```

All v1 resources are `exec` (one-shot executables). Long-lived `session` resources are v2 (§7).

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

### Session resources (v2)

Long-lived interactive processes: psql, a Django shell reached through a cloud exec
shell, a remote ssh shell. Essential in practice (slow start-up, loaded state,
interactive auth at start) but materially more complex than exec resources — the broker holds a
pty, frames each approved snippet against a sentinel, handles output interleaved with prompts,
and manages keepalive and cancellation. Deferred to v2 to keep the v1 core small. In v1 the same
work is done with repeated exec requests (each `psql` invocation is one request), which is
slower but simple and safe.

## 8. Git and deploy flow

- The AI-workspace clone's `origin` is the upstream with a **read-only** token. Fetch and pull
  work; push is rejected by the server. Push is never native to the workspace (§4).
- Each repo has a **privileged clean clone** with two remotes: `origin` (upstream, read-write key)
  and `aiws` (`aiws:src/<repo>`, over ssh to the workspace).
- The privileged side **pulls from** the workspace; the workspace pushes nowhere with credentials.
  Review and push, without checking anything out:

  ```sh
  git fetch aiws feature-x
  git log -p origin/develop..aiws/feature-x
  git push origin aiws/feature-x:feature-x
  ```

  Fetching over ssh runs git on the workspace side as the `aiws` user. The privileged side only
  receives pack data (inert until checked out), the same trust model as fetching from any remote,
  and `git fetch` does not run the remote's hooks.
- **Never run git (or a git GUI) as privileged against the workspace's working tree.** git
  executes things named in repo config (`core.fsmonitor` and others), and that config is
  agent-writable. Privileged git runs only in the clean clone.
- **Two-pass review:**
  1. *Comprehension pass* in the AI workspace, with full nvim and LSP navigation. Comfortable,
     but not authoritative: the review tooling there is agent-controlled (git diff drivers and
     textconv, pagers, editor plugins can render something other than the commit's content).
     Matching SHAs afterwards only proves the commit identity, not what was displayed.
  2. *Authoritative pass* on the privileged side over the fetched objects, in a git tool that
     does not run project code: **Sublime Merge** (syntax-highlighted; its regex-based
     highlighting is the same small parsing risk as treesitter), or `git` + `delta` + `less`.
     This pass is quick because the change is already understood; it checks that the change is
     what was reviewed and catches anything new.
- Deploys and infrastructure changes (`cap`, `tofu`, etc.) run from the clean clone, checked out
  at the reviewed commit. This does execute repo code with privileges, which is inherent. The
  guarantee is integrity: *what runs is exactly what was reviewed*.

## 9. Docker

- The Docker socket is root-equivalent. Only the privileged user can reach it.
- Compose runs from the clean clone at a reviewed commit, so that review covers mounts,
  privileges and build contexts. A small privileged-owned override binds published ports to
  `127.0.0.1`.
- The AI workspace reaches services over localhost TCP (`psql -h localhost`),
  not `docker exec`.
- Docker Desktop's file sharing should be limited to the paths the compose files mount
  **(verify)** the defaults on the machine.

## 10. Prerequisites and hygiene

- **The privileged home is not traversable by `aiws`.** Since `aiws` is not in the privileged user's
  group (it is only ever "other"), removing others' access is enough: `chmod o-rwx ~` (or
  `chmod 750 ~`). Verify with the checklist (`ls /Users/<me>` fails from `aiws`), which also
  settles the macOS home ACL (the `+` in `ls -le ~`) **(verify)** — the ACL must not grant
  `everyone`. The repos live under `~aiws` anyway; what matters is that the *privileged* home is
  closed.
- No secrets in workspace-readable trees. Move personal env files, credential notes and backups
  out of the repos into the privileged home. Tracked secrets are a team issue: rotation and
  removal.
- The workspace gets its own copy of the human's global gitignore. Otherwise personal files that
  are ignored only by the privileged user's global ignore become committable.
- Dev databases that matter are protected by snapshots or credentials. The AI workspace can reach
  them.

## 11. Protocol

- Config, state and data follow the **XDG Base Directory** spec: `$XDG_CONFIG_HOME/priviledge`
  (config, §7), `$XDG_STATE_HOME/priviledge` (audit log), `$XDG_DATA_HOME/priviledge`. These are
  privileged-private.
- The **socket** cannot live in `$XDG_RUNTIME_DIR` (that is per-user, mode 0700, so `aiws` could
  not reach it). It goes in a shared, privileged-owned directory the workspace can traverse but
  not write to: directory group `priviledge` mode 0750, socket group `priviledge` mode 0660, `aiws`
  a member of the group.
  - macOS default: `/Users/Shared/priviledge/`.
  - Linux default: a configurable directory such as `/var/lib/priviledge/` (or a systemd
    `RuntimeDirectory`).
  - With one broker per uid (§3), each broker owns a distinct socket file in this directory.
- **Peer authentication.** On each connection the broker reads the caller's **kernel-provided
  peer credentials** and checks the uid against an allow-list. These are filled in by the kernel,
  so the client cannot forge them:
  - Linux: `getsockopt(SO_PEERCRED)` → pid, uid, gid.
  - macOS/BSD: `getsockopt(LOCAL_PEERCRED)` → uid + groups (no pid); `LOCAL_PEERPID` → pid.
  - This authenticates the **uid** (the security principal, §3). It does not and cannot
    distinguish sessions within a uid; nothing security-relevant depends on that.
- Newline-delimited JSON, one request per connection. No TLS (§3). Simple enough to forward over
  ssh later (a workspace on another host or a VM).
- There is no approval socket in v1: approval happens only on `serve`'s terminal. A privileged-only
  approval socket (mode 0700) for scripting (`pending`, `approve`, `deny`) can come later.
- Audit log: JSON lines in the privileged state directory, one entry per request. It records the
  request, reason, peer uid, decisions and timestamps, output size and a hash of the output.
  Output bodies are not logged by default.

## 12. Recommended environment (macOS, with Linux notes)

This is an example setup for the workflow above. The commands change system configuration, so
the human reviews and runs them.

### 12.0 Isolation tiers (pick one per machine)

The priviledge design is identical across all three; only how the AI workspace is hosted changes:

- **`su`/`sudo -u aiws` (weakest, no sshd).** Simplest, but on macOS `su` does not allocate a new
  controlling tty, so the workspace shell shares the privileged pane's terminal device — a path
  back up. Acceptable only if you do not want to run sshd. Documented, not recommended.
- **ssh to loopback (recommended).** Each pane is a fresh, workspace-owned pty; nothing shared
  with the privileged shell. Costs running sshd bound to loopback. This is what §12.2 sets up.
- **VM (strongest).** A Linux VM (Lima, OrbStack, UTM) with the broker socket forwarded in. A
  hypervisor boundary beats a uid boundary, the workspace can own Docker inside it, and the same
  setup works on a Linux host. Costs editing over Remote-SSH into the VM. Choose this when you
  want more than uid isolation or do not want sshd on the host.

### 12.1 AI-workspace user

```sh
# macOS
sudo sysadminctl -addUser aiws -fullName "AI workspace" -password -
sudo dscl . create /Users/aiws IsHidden 1
sudo dseditgroup -o create priviledge
sudo dseditgroup -o edit -a aiws -t user priviledge
chmod o-rwx ~                    # privileged home closed to aiws (aiws is not in the staff group)

# Linux
sudo useradd -m -s /bin/zsh aiws
sudo groupadd priviledge && sudo usermod -aG priviledge aiws
chmod o-rwx ~
```

For per-project isolation (§3), repeat with `aiws-<project>` users; each gets its own broker.

### 12.2 ssh to localhost (the only way into the AI workspace)

Panes enter the workspace with `ssh`, not `su`. ssh gives each session its own pty owned by the
workspace user, so nothing running there shares a terminal device with the privileged shell.

Enable Remote Login (macOS: System Settings → General → Sharing → Remote Login, allowed for `aiws`
only). Then add `/etc/ssh/sshd_config.d/100-priviledge.conf`:

```
AllowUsers aiws@127.0.0.1 aiws@::1
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
ssh-keygen -t ed25519 -f ~/.ssh/id_aiws -N ''
# as aiws, in ~aiws/.ssh/authorized_keys:
#   restrict,pty ssh-ed25519 AAAA... privileged-to-aiws
```

Privileged `~/.ssh/config`:

```
Host aiws
  HostName 127.0.0.1
  User aiws
  IdentityFile ~/.ssh/id_aiws
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
tmux new-window -n shop   'ssh aiws -t "cd src/shop-app && exec \$SHELL -l"'   # nvim
tmux split-window -h      'ssh aiws -t "cd src/shop-app && exec claude"'        # agent
tmux split-window -v      'ssh aiws -t "cd src/shop-app && exec \$SHELL -l"'   # tests, servers
```

Plus one privileged window per machine:

- `priviledge serve` (the approval prompt; its bell marks the window).
- A shell in the clean clones, for review, push, deploy and compose.

### 12.4 Editor and LSP (AI workspace)

- nvim, its plugins and every LSP server run as `aiws`: ruby-lsp, typescript-language-server,
  basedpyright/pyright, lua_ls, and so on. A plugin manager and mason.nvim install into `~aiws`.
- nvim configuration is a copy or a clone of the human's dotfiles in `~aiws`. It is never a
  symlink into the privileged home, which aiws cannot read anyway.
- VS Code, optionally, via Remote-SSH to `aiws`, so its extensions and LSP servers run as aiws.
- The privileged user does not open workspace repos in a full editor or LSP. Diff review follows
  the two-pass model in §8. This is distinct from the minimal `$PRIVILEDGE_REVIEW_PAGER` /
  `$PRIVILEDGE_REVIEW_EDITOR` used to inspect a priviledge request/output payload (§6).

### 12.5 Toolchains (AI workspace)

- `aiws` owns its own toolchains, for example with mise: Python, Node, Java, Go.
  Project-specific installs (pip, npm, uv) all happen as aiws.
- The privileged `PATH` never includes workspace-writable directories.
- **Homebrew.** `aiws` may *run* the privileged user's brew-installed binaries read-only, which
  is safe. Installs needed by the workspace are done by the human from a privileged pane, or
  `aiws` uses its own brew prefix or mise-managed tools.
  - Sharing one brew across the human's own trusted accounts with an alias like
    `brew='sudo -Hu <owner> brew'` is fine between those accounts.
  - **It must never be set up for `aiws`.** sudo authenticates the *caller*, so the rule would be
    protected only by aiws's own password and sudo's cached timestamp, both reachable by other
    aiws processes (same-uid processes are not isolated, §3). And running brew as the owner with
    agent-influenced inputs (formulae are Ruby; taps, local formula files, Brewfiles) is
    equivalent to a shell as the owner.

### 12.6 Repositories and agent (AI workspace)

- Repos live under `~aiws/src/`, owned by aiws, cloned fresh (no migration of existing checkouts).
  Per-path tool state (Claude Code per-project memory, `mise trust`, `direnv allow`) simply
  re-initialises under the new paths in `aiws`.
- git: identity, a copy of the global gitignore, and read-only upstream tokens.
- Claude Code runs as aiws with its own login and the copied global instructions and memories. Its
  permission allow-list includes `Bash(priviledge list)`, `Bash(priviledge describe:*)`,
  `Bash(priviledge run:*)` and `Bash(priviledge wait:*)`.
- Native read-only tokens (§4) live in aiws's environment or config.

### 12.7 Verification checklist (run as aiws)

- `ls /Users/<me>` fails. `cat ~<me>/.aws/credentials` fails.
- `ssh <me>@localhost` is refused.
- `docker ps` fails (no socket access).
- `git push` to upstream is rejected by the server.
- `priviledge list` works. Stopping `priviledge serve` makes `run` fail fast with a clear message.

## 13. Technology

- **Language: Python**, with a **pinned runtime shipped via uv** (a uv-managed interpreter, or a
  bundle via shiv/pex), so there is no dependency on the stock system Python and no version
  matrix to support. This removes the earlier `tomllib`/3.11 concern (stock macOS python3 is 3.9)
  while keeping Python's fast iteration, which matters while the UX is still moving.
- Standard library only at runtime: `socket`, `selectors`, `subprocess`, `pty`, `json`,
  `argparse`, `tomllib`, `hashlib`, `shlex`, plus a small `ctypes`/`struct` `getsockopt` for peer
  credentials (§11). No third-party runtime dependencies.
- **Rust is a deliberate later option, not now.** For a security tool the "memory-safe, single
  static binary" argument is attractive, but priviledge's untrusted input is JSON over the socket
  (stdlib `json`, memory-safe) that is mostly passed through to subprocesses; the security-critical
  logic is process, permission and peer-credential handling, not parsing. So Rust's safety edge is
  small here and would slow iteration. A Rust rewrite fits naturally as a "once the design stops
  changing" step, consistent with the project's stop-churning goal.

## 14. Iteration plan

1. **Environment first.** Set up the AI-workspace user, ssh (or the chosen isolation tier), tmux,
   nvim/LSP and toolchains on the real machine, and pass the §12.7 checklist. Building the rest
   *inside* the real boundary surfaces the true frictions (timeouts, round-trips, approval bursts)
   instead of guessing them.
2. **Core loop:** the broker, exec resources, the line-oriented approval prompt with the two
   confirmation flags and output review, `run`/`wait`/`list`, peer-uid auth, and the audit log.
   Try it against a local dev database and a read-only cloud command.
3. **Git and deploy flow:** the privileged clean clone, fetch-from-workspace, read-only upstream
   token, push and deploy from a reviewed commit.
4. **Sessions (v2):** psql first, then a Django shell through a cloud exec shell.
5. **Ergonomics and more resources:** notification hook, burst approvals, a privileged approval
   socket (`pending`/`approve`), SaaS write resources (issue tracker, team chat), and optionally the MCP
   adapter if a client needs it.

## 15. Open questions

- Which SaaS tokens can actually be scoped read-only (trackers, code hosts, chat) **(verify)**.
- Session (v2) design details: sentinels, prompt noise, long-running statements, cancellation.
- Output display: head/tail preview size in the approval; whether any cap is ever needed (typical
  results are KB, occasional dumps 10 MB+). No enforced limit in v1.
- macOS specifics **(verify)**: launchd-started sshd and `ListenAddress`; the home-directory ACL;
  Docker Desktop's default file-sharing paths; `su` pty behaviour on the installed version.
- Linux specifics **(verify)**: socket directory under systemd (`RuntimeDirectory`); sshd
  `ListenAddress` under socket activation.
