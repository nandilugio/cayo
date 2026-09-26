# priviledge — product specification (draft)

Status: draft for discussion. Nothing here is implemented yet. Items marked **(verify)** are
assumptions that must be checked on a real machine before they are relied upon.

This document specifies **what** priviledge is and does: its purpose, security model, and the
interfaces the agent and the human use. Two other documents cover the rest:

- [DESIGN.md](DESIGN.md): **how** it is built. Processes, protocol, technology, implementation
  plan. It can change without changing this document.
- [SETUP.md](SETUP.md): one reference deployment around it (container runtime, images, terminal,
  editor, git remotes, egress). priviledge depends only on the deployment contract in §4.

## 1. Problem

AI coding agents work best with broad autonomy, but some operations need privileges that should
not be handed to them wholesale: querying production databases, calling cloud APIs, running
consoles on remote hosts, pushing code. The choice is roughly all-or-nothing: either the agent
holds the credentials (and can do anything with them, unobserved), or the human runs every
privileged command by hand and pastes the result back, which is slow and error-prone.

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
- Network egress control. It is part of a guest's risk profile (§3) and the deployment provides
  it (§4); priviledge may later act as its approval backend (§10).
- A team or multi-user product.

## 3. Threat model

### Terms

- **AI workspace**: the agent and everything it can influence.
- **Guest**: the isolated environment the AI workspace runs in (a container, a VM, or a separate
  OS user). A guest is an instance of a **profile** (below).
- **Privileged side**: the human's own account on the host.
- **Broker**: the part of priviledge on the privileged side that receives requests, asks the human,
  and runs resources.

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
- **The broker must know which guest a request comes from without relying on anything the guest
  says.** No token, password or claim sent by the guest may serve as its identity; the guest must
  have nothing to forge. (DESIGN.md §2 achieves this by having the broker open the connection into
  the guest itself.) A token scheme would not help anyway: whatever an honest client could present,
  another process in the same guest can obtain.
- Session labels (working directory, pid, agent name) are sent by the client for the human's
  convenience and shown as *claimed*. Nothing security-relevant may depend on them.
- What a guest may request, and with how much confirmation, is fixed by its profile (§8).
- Anything configured inside the guest (the agent's permission settings, its instructions) is
  convenience, not a security control. The boundary is the guest itself.

### Task risk and profiles

Prompt injection is unsolved: an agent that reads text an attacker controls may follow
instructions in it, and no filter reliably prevents that. The more capable the agent, the more it
can do with one injected instruction. So the design assumes the agent *will* eventually act on
hostile input, and limits what that can reach. The widely used framing is Meta's *Agents Rule of
Two* (and Willison's *lethal trifecta*, the same idea): an agent session has three risk properties,
and holding all three at once is unsafe unless a human approves the third.

- **A. Processes untrustworthy input**: text or code an attacker may have written. Public issue
  trackers, pull requests, arbitrary web pages, dependency sources, hostile samples.
- **B. Has access to sensitive systems or private data**: credentials in the guest, priviledge
  resources it may request, private source.
- **C. Changes state or communicates externally**. Two parts, both C:
  - **C-state**: writes to anything outside the guest: pushes, PR comments, ticket edits, prod
    writes.
  - **C-egress**: the ability to send data out of the guest at all. With unrestricted egress, any
    leak needs nothing but `curl`.

**Rule:** a guest may hold at most two of A, B and C outright. When a task needs all three, the
third goes through a human step (priviledge approval for C-state, a human-carried transfer for
egress) or is removed. The guest's **profile** is the concrete choice of B and C for a given
level of A. Profiles are named in the configuration (§8); a deployment implements each one as a
guest shape (image, mounted credentials, egress policy). The reference set:

| Profile | A: input | B: sensitive reach | C-state | C-egress |
|---|---|---|---|---|
| `trusted` | The human's own projects and vetted sources | Read-only resources may auto-approve; read-write resources ask | Through priviledge, asked | Allow-list |
| `public` | Open-source work: public issues, PRs, general web | Read-only resources only, every request asks | Through priviledge, asked | Allow-list |
| `hostile-web` | Content that may target automated readers | **Nothing**: no credentials, no resources | None | Broad, needed by the task; nothing worth leaking |
| `hostile-sample` | Samples, exploits, CTF material | Nothing | None | **None** |

Two consequences worth stating:

- **Open-source work is not the safe middle.** Reading strangers' text (A), holding credentials
  to one's own repos (B) and pushing or commenting (C) is the full set in one session by default;
  `public` breaks it by keeping every write behind approval and no write credential in the guest.
- **Hostile content is handled by removing B, not by trusting filters.** For `hostile-web` the
  task needs broad egress, so the guest holds nothing worth taking. For samples, egress goes too.

The same project may need guests of different profiles: developing it in `trusted`, triaging its
public tracker in `public`.

### priviledge's own code

- The broker is installed from a privileged-owned source (for example a clean clone at a reviewed
  tag). It must never run from a copy the AI workspace can write. This matters because priviledge
  itself will be developed in an AI workspace.
- The guest-side client is untrusted like everything else in the guest. Its version and integrity
  don't matter: whatever runs there speaks for that guest by definition.

### What the boundary protects

- Secrets on the privileged side (keychain, `~/.aws`, `~/.ssh`, database credentials, browser
  sessions, other projects, personal files).
- Unmediated privileged actions: an agent running cloud CLIs with the human's credentials, or
  pushing against instructions, becomes structurally impossible rather than a matter of
  obedience.

### Residual risks (accepted or mitigated elsewhere)

- Malicious code that passes review (non-goal).
- A resource executable that runs its input on the host, or lets it pick or reveal a credential.
  The executables are the human's; §8 states what they must guarantee.
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
   `container exec -i <name>`, `ssh <host>`, or `sudo -u <user>`. priviledge uses it to reach the
   guest (DESIGN.md §2).
3. **No path back.** The guest has no way to act as the privileged side: no sudo to it, no
   credentials for it, no access to the guest runtime's control socket, no shared terminal
   device.
4. **One guest per trust domain** (§3).
5. **Profiles are real.** A guest of a given profile holds only the credentials its profile
   allows (§3), and its egress is restricted to what the profile allows, denied by default where
   the profile says so. priviledge cannot check this; the deployment guarantees it.

## 5. Capability placement

Every privileged capability is placed by one rule:

> **Credentials define capability; priviledge rules define convenience.**

There are two ways to give the AI workspace a capability:

- **A priviledge resource** (§8). The credential stays on the privileged side; the agent invokes it
  through `priviledge run`. Each profile decides whether it asks or auto-approves, and whether the
  output is reviewed. Every use is audited.
- **A native grant**: a token in the agent's own environment. Nothing stands between the agent
  and the token, so this is only acceptable when both hold:
  1. The service enforces the scope server-side (a read-only token, a read-only DB role).
  2. The confidentiality impact of that scope is acceptable if fully exercised, in every profile
     the token is present in.

**Prefer a resource for anything a command-line tool can do**, even read-only and even
auto-approved: the credential never enters the guest, so it cannot leak; the resource is
configured once and each profile sets its own confirmation; and its use is logged. A resource
with auto-approval still exposes the *data* it returns to the guest, so condition 2 applies to
it as well. Native grants remain for tools that cannot go through `priviledge run`, such as git's
credential for `fetch` and `pull`.

Classifying requests by content ("this SQL is a read") is never the security boundary; it may only
drive auto-approval on resources whose credential is already limited.

Initial placement (to be confirmed per service):

| Capability | Placement | Notes |
|---|---|---|
| Git upstream read | Native, read-only token | git needs it non-interactively; a credential helper calling priviledge is possible later |
| Git push | Privileged side only | Feeds the deploy pipeline; never native, never a resource |
| PR/CI read (code host) | Resource, read-only token, auto-approve eligible | |
| Error tracker read | Resource, read-only token, auto-approve eligible | Errors may contain PII: condition 2 per profile |
| Issue tracker read | Resource, read-only token if one exists **(verify)** | |
| Issue tracker write | Resource, always ask | Low blast radius |
| Team chat (any) | Resource, always ask, or not at all | Even reads are high-impact |
| Prod DB, read-only role | Resource, auto-approve eligible | Role enforces read-only; bound query cost (§8) |
| Prod DB, read-write | Resource, always ask | |
| Cloud CLI | Resources per credential | e.g. a read-only policy vs an admin one |
| Consoles and shells on remote hosts | Session resources (later, §10), always ask | Full power once inside |

Hosted OAuth connectors (e.g. claude.ai integrations) request whatever scopes the connector
defines, often including write. Treat them as full grants unless their scopes are confirmed.

## 6. Agent interface

One program, `priviledge`. The agent uses these subcommands inside the guest:

- `priviledge list`: the resources this guest may request.
- `priviledge describe <resource>`: its description, whether it takes a payload or extra
  arguments, its declared parameters, and whether it is auto-approved for this guest.
- `priviledge run <resource> ...`: submit a request, wait, print the result.
- `priviledge wait <id>`: resume waiting on a pending request.

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
- Outputs are returned to the client. `-o file` is written by the client, inside the guest. The
  broker never writes into workspace paths.
- `run` and `wait` wait a bounded time (default 90 s). This matters because agent shell tools have
  hard timeouts (Claude Code's Bash tool: 2 min default, 10 min max). If the request is still
  pending, they print its id and exit; the agent continues with `priviledge wait <id>`. A client
  that exits or disconnects does not cancel its request.
- A result is kept until a client has received it in full. `wait` on an unknown or
  already-delivered id fails.
- Exit status: the resource's own exit status when it ran and its output was released. Otherwise
  the `sysexits` codes, each with a message on stderr: 75 (`EX_TEMPFAIL`) still pending, 77
  (`EX_NOPERM`) denied, either the request or the release of its output, with the human's message,
  69 (`EX_UNAVAILABLE`) broker not connected, 64 (`EX_USAGE`) invalid request (unknown resource,
  undeclared input, unknown or delivered id). A resource that itself exits with one of these codes
  is disambiguated by the stderr message.
- If the human edited the request, the result says so and includes the version that ran. If the
  human redacted the output, the result says so.

**When the broker connection is lost** (guest restarted, broker stopped):

- Requests still **awaiting approval** fail without running.
- Requests that are **running, awaiting release, or finished but undelivered** may already have
  had effects (a write on a read-write resource). They are kept, flagged to the human as "not
  delivered", and the agent can still fetch them with `wait <id>` once the connection is back.
- If the broker itself restarts, outstanding requests are lost. The audit log (§9) records how far
  each one got.

## 7. Approval

Each guest has its own approval prompt, on the terminal where the human runs
`priviledge serve <profile> <name>`, typically in that project's tmux window. The prompt is
line-oriented, like `git add -p`:

```
[12] trusted/shop · claimed: ~/src/shop-app, claude · prod-db-ro
     reason: count overdue orders by region
     SELECT region, count(*) FROM orders WHERE status = 'open' GROUP BY region
run? [y]es [n]o(+msg) [e]dit [v]iew [?]
[12] exit 0 · 214 lines · 6.1 KB · 1.4 s
     region,count
     eu-west,412
     ... (first/last lines)
release? [y]es [n]o(+msg) [v]iew [e]dit/redact
```

- The guest (`profile/name`) is established by the broker and is authoritative. Everything the
  client sends (labels, reason) is shown as claimed.
- Prompts are answered one at a time, in arrival order. Approved requests run concurrently; their
  release prompts join the same queue.
- Requests that need no confirmation still get a one-line entry in the pane, so the human sees
  everything that runs.
- A bell is emitted on each new prompt (tmux flags the window).
- **All agent-supplied text is rendered with control characters escaped.** Requests and outputs
  must not be able to move the cursor, hide lines, restyle the prompt, or send queries to the
  terminal.
- The inline prompt shows escaped plain text with simple formatting (JSON pretty-printed, CSV
  aligned).
- `view` opens the content in `$PRIVILEDGE_REVIEW_PAGER`, from a privileged-owned temp file whose
  extension comes from the resource's `syntax` / `output_syntax` (§8). `edit` does the same with
  `$PRIVILEDGE_REVIEW_EDITOR`. Both are argv strings, run without a shell.
  - Default pager: `less` without `-R` and with input preprocessing disabled (`--no-lessopen`).
    Many systems set `LESSOPEN` to a lesspipe script that runs other programs over the file.
  - Default editor: `vi`.
  - Both can point at the same minimal nvim, the pager in read-only mode:
    `env NVIM_APPNAME=priviledge-review nvim -R`. `NVIM_APPNAME` gives it its own config and plugin
    directories (`~/.config/priviledge-review/`). `-u <file>` alone is not enough: nvim still loads
    plugins from the human's normal config and data directories.
- Output is not size-limited. The prompt shows size and a head/tail preview; `view` shows all of
  it.

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
- **Recommended:** a minimal privileged-owned nvim config with syntax colouring, modelines off
  (`nomodeline`), no plugins that execute, and no LSP.

## 8. Configuration, profiles and resources

### Configuration file

`$XDG_CONFIG_HOME/priviledge/config.toml` (privileged-owned, mode 0600), i.e.
`~/.config/priviledge/` by default. The broker refuses to start if the config, the resources
directory, or any resource executable is group- or world-writable, or not owned by the privileged
user. A leading `~` in paths is expanded.

The file declares **resources** (what exists) and **profiles** (who may use what, with how much
confirmation). Guests are not in the file: a guest is an instance of a profile, created by the
deployment and named when the broker starts (`priviledge serve <profile> <name>`).

```toml
[resource-defaults]
confirm_request = true
confirm_output = true

[resources.prod-db-ro]
description = "Production Postgres (read-only role). Bound queries on large tables by time."
run = "~/.config/priviledge/resources/prod-db-ro"
input = "stdin"            # takes a payload: the SQL
syntax = "sql"
output_syntax = "csv"
credential = "read-only"

[resources.prod-db-rw]
description = "Production Postgres (read-write role)."
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

[profiles.trusted]
channel = ["docker", "exec", "-i", "aiws-{profile}-{name}"]
resources = ["prod-db-ro", "prod-db-rw", "aws-readonly"]
[profiles.trusted.resource-overrides.prod-db-ro]
confirm_request = false    # allowed: the resource's credential is read-only
confirm_output = false
[profiles.trusted.resource-overrides.aws-readonly]
confirm_request = false

[profiles.public]
channel = ["docker", "exec", "-i", "aiws-{profile}-{name}"]
resources = ["prod-db-ro", "aws-readonly"]
# no overrides: every request and every output is confirmed

[profiles.hostile-web]
resources = []             # no broker is needed for such guests

[profiles.hostile-sample]
resources = []
```

### Resolution

The settings that apply to a resource in a guest are, in order: `[resource-defaults]`, then the
guest's profile `resource-overrides` for that resource. Scalars override; there is nothing to
merge deeper. The broker validates the merged result at start:

- `confirm_request = false` is only allowed when the resource's `credential = "read-only"`.
  Otherwise writes would run unapproved. Releasing output unreviewed is a confidentiality choice
  and is allowed for any resource.
- An override for a resource the profile does not list is an error.
- `channel` must contain `{name}` (and may contain `{profile}`), so that two guests of one profile
  cannot resolve to the same channel.

### Profile fields

| Field | Meaning |
|---|---|
| `channel` | The channel command (§4) as an argv list, with `{profile}` and `{name}` substituted. Required for any profile with resources |
| `resources` | The resources guests of this profile may list and request. Others don't exist for them |
| `resource-overrides.<resource>` | `confirm_request` / `confirm_output` for that resource in this profile |

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

`confirm_request` and `confirm_output` (default `true`: approve before running / before releasing
the output) are set in `[resource-defaults]` and per profile, never on the resource itself:
whether to trust a resource unattended is a property of the profile, not of the resource.

### Exec resources

A resource is an executable owned by the privileged user. It is executed directly (never through
`sh -c`). It receives the payload on stdin, declared parameters as `PRIVILEDGE_P_<NAME>` environment
variables, and, if `args = true`, the extra arguments as argv. The agent cannot set any other part
of its environment. It fetches its own secrets with whatever the OS provides (macOS `security`,
Linux `secret-tool`, `pass`, `op read`, ...).

Resource executables must reference only privileged-owned files. A script taken from a project
(for example a repo's `bin/console`) is used from a privileged clean clone at a reviewed
commit (§3, the exception to the core rule), never from the AI workspace.

### Resources run agent input on the privileged side

A resource runs on the privileged side, and its payload, parameters and arguments are written by
the agent. So the executable is exactly the kind of program the core rule (§3) is about, and it
must hold three properties. These protect the host and the credential itself; they don't classify
requests as reads or writes, so they don't conflict with §5.

1. **Nothing in the input runs on the host.** Many clients interpret part of their input
   locally, and handing them agent input directly gives the agent a shell as the privileged user:
   - psql's meta-commands: `\!` runs a shell command, `\o |cmd` and `\copy ... TO PROGRAM` pipe to
     one, `\i`, `\o file` and `\w` read and write host files. `-c` doesn't help: a single
     meta-command is accepted there too.
   - Database shells that embed a scripting runtime run any input as code in that runtime.
   - Local interpreters generally: `python`, `node`, `sh`, a local `manage.py shell`.

   Either use a client that only forwards the input to the service (for SQL, a short script built
   on a database driver: it reads the query, sends it, writes CSV), or confine the tool: run it in
   a disposable container that holds only this resource's credential and mounts nothing from the
   host. A console that runs remotely (a Django shell on a cloud task, reached through
   `bin/console`) executes its input on the remote side, which is the resource's purpose.
2. **The input can't select another credential or configuration.** Pin them in the executable,
   so that none of the human's other credentials are reachable: for example
   `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` pointing at files holding only this
   resource's profile, since otherwise `--profile admin` in the arguments would pick the admin
   credential.
3. **The input can't make the tool reveal its credential.** A leaked credential becomes a native
   grant (§5) that bypasses approval and the audit log. For example, `aws configure get` and
   `aws configure export-credentials` print it, and a confined psql told to `\connect` to another
   host sends it the password. With `args = true`, allow-list the subcommands in the executable.
   Output review is a backstop only when `confirm_output = true`.

```sh
#!/bin/sh
# aws-readonly: aws with only the read-only profile reachable, and no `configure`.
# Global options may precede the subcommand, so check every argument.
for a in "$@"; do
  [ "$a" = configure ] && { echo "aws configure is not allowed" >&2; exit 77; }
done
export AWS_CONFIG_FILE=~/.config/priviledge/aws/readonly.config
export AWS_SHARED_CREDENTIALS_FILE=~/.config/priviledge/aws/readonly.credentials
exec aws "$@"
```

```sh
#!/bin/sh
# prod-db-ro: `sqlquery` is the human's driver-based script: SQL in on stdin, CSV out.
PGPASSWORD=$(security find-generic-password -s prod-db-ro -w) \
  exec ~/.config/priviledge/bin/sqlquery "host=... user=app_ro dbname=... options='-c statement_timeout=60s'"
```

**Read-only is not harmless on a primary database.** A read-only role can't write, but an
auto-approved query can still load production. Bound the cost with a role-level or connection
`statement_timeout`, as above.

`args = true` on a broad credential should come with `confirm_request = true` in every profile.

### Session resources (later)

Long-lived interactive processes: psql, a Django shell reached through a cloud exec
shell, a remote ssh shell. Essential in practice (slow start-up, loaded state,
interactive auth at start). Each approved snippet runs in the same live session and returns its
output. The same three properties apply: a local psql session would have to be
confined, while a remote console runs its input remotely. Until session resources exist, the same
work is done with repeated exec requests (each query is one request), which is slower but simple
and safe.

## 9. Audit log

Every request is recorded on the privileged side, one log per guest: request id, guest
(`profile/name`), claimed labels, reason, the request (and the edited version, if any),
decisions, timestamps, exit status, output size and a hash of the output. Output bodies are not
logged by default. Each step of a request (received, decided, started, finished, released,
delivered) is recorded as it happens, so a crash leaves a record of how far every request got.

## 10. Scope

**v1:** exec resources; profiles; `list`, `describe`, `run`, `wait`; the approval prompt with both
confirmation flags and output review; the audit log.

**Later**, in rough order:

- Session resources (§8).
- A notification hook (`on_request`: run a command for richer notifications than the bell).
- Burst approvals: "approve the rest from this resource for N minutes", read-only resources only.
- A privileged-only approval interface for scripting (`pending`, `approve`, `deny`).
- SaaS write resources (issue tracker, team chat).
- **Egress approval**: the deployment's egress proxy asks priviledge before allowing a new host,
  so the human approves domains the way they approve requests.
- A git credential helper backed by priviledge, removing the last native token (§5).
- An MCP adapter (`priviledge mcp`, exposing only `tools/list` and `tools/call`), only if a client
  needs it and it shows value over its cost. The CLI is POSIX-composable
  (`priviledge run ... | grep`), works in every agent, and keeps the surface small and free of MCP
  spec churn.

## 11. Open questions

- Which SaaS tokens can actually be scoped read-only (trackers, code hosts, chat) **(verify)**.
- Cancelling a running request from the approval prompt, and whether resources need a timeout.
- Head/tail preview size in the approval prompt.
- Whether requests should survive a broker restart. In v1 they don't; the audit log is the record.
