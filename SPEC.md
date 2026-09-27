# priviledge — product specification (draft)

Status: draft for discussion. Nothing here is implemented yet. Items marked **(verify)** are
assumptions that must be checked on a real machine before they are relied upon.

This document specifies **what** priviledge is and does: its purpose, security model, and the
interfaces the agent and the human use. Two other documents cover the rest:

- [DESIGN.md](DESIGN.md): **how** it is built. Processes, protocol, technology, first iterations.
  It can change without changing this document.
- [SETUP.md](SETUP.md): one reference deployment around it (container runtime, images, terminal,
  editor, review tools, git remotes, egress). priviledge depends only on the deployment contract
  in §4.

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
- **Dependable approvals**: the human can tell what they are approving. Whatever makes a risky
  request easier to spot, or blocks it outright, serves this goal before convenience does.
- Low-friction approvals: most requests are reads, arrive in bursts, and should cost one key.
- Output review before results reach the agent.
- Small, POSIX-style, composable; macOS and Linux; minimal and stable dependencies.
- Independent of how the AI workspace is hosted (container, VM, separate OS user).
- Single user, forever.

Non-goals:

- **Protecting production from malicious code that passes code review.** priviledge protects the
  developer's privileged context and mediates direct privileged actions. Code integrity is the job
  of review, CI, branch protection and deploy gates.
- Automating browser-only surfaces (cloud consoles, dashboards, admin UIs). priviledge can
  route such a task to the human instead (§8, human resources).
- Network egress control. It is part of a guest's risk profile (§3) and the deployment provides
  it (§4); priviledge may later act as its approval backend (§10).
- A team or multi-user product.

## 3. Threat model

### Parties

- **AI workspace** (untrusted): the agent **and all development tooling**, including the human's
  editor, LSP servers, tests, dev servers, package installs, git working copies and toolchains.
  The human does their coding *inside* it.
- **Guest**: the isolated environment the AI workspace runs in: a container, a VM, or a separate
  OS user. A guest is an instance of a **profile**, the named trust level that fixes what it may
  reach and how much confirmation its requests need (below, and §8).
- **Privileged side** (trusted): the human's own account on the host. It holds the secrets (cloud
  credentials, ssh keys, database credentials, OS keychain), runs the broker and its approval
  prompt, holds the credentials for pushing and deploying, and controls the guest runtime.
- **Broker**: the part of priviledge on the privileged side. It receives requests, asks the human,
  runs resources, and keeps the audit log. One broker serves one guest.
- **Client**: the part of priviledge inside the guest, the commands the agent runs (§6).

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
  have nothing to forge. (DESIGN.md §3 achieves this by having the broker open the connection into
  the guest itself.) A token scheme would not help anyway: whatever an honest client could present,
  another process in the same guest can obtain.
- **The client sends nothing about itself.** No working directory, pid or agent name: such labels
  could only be trusted if the guest were, and then they would not be needed. A request carries
  the resource, its inputs, and the agent's stated reason, which is judged, not trusted.
- What a guest may request, and with how much confirmation, is fixed by its profile (§8).
- **The client cannot authenticate the relay.** Another process in the guest can replace the
  relay's socket and answer clients itself: read their requests, feed them fabricated results.
  That is the guest lying to itself, and it is accepted like every other within-guest attack.
- **The broker treats every byte from the guest as hostile input**, and stays bounded: it accepts
  only messages that match its schema, limits the size of a request's payload and the number of
  requests a guest may have outstanding, and rejects the rest. Nothing a guest sends can name a
  path, choose a file, or select anything on the privileged side.
- Anything configured inside the guest (the agent's permission settings, its instructions) is
  convenience, not a security control. The boundary is the guest itself.

### Task risk and profiles

Prompt injection is unsolved: an agent that reads text an attacker controls may follow
instructions in it, and no filter reliably prevents that. The more capable the agent, the more it
can do with one injected instruction. So the design assumes the agent *will* eventually act on
hostile input, and limits what that can reach. The framing is Meta's *Agents Rule of Two*, which
matches Willison's *lethal trifecta*: an agent has three risk properties, and holding all three at
once is unsafe unless a human supervises.

- **A. Can process untrustworthy inputs**: text or code an attacker may have written. Public
  issue trackers, pull requests, arbitrary web pages, dependency sources, hostile samples.
- **B. Can have access to sensitive systems or private data**: credentials in the guest,
  priviledge resources it may request, private source.
- **C. Can change state or communicate externally.** Meta defines C as one property. This
  document tags its two halves, because a deployment controls them with different means:
  - **C-state**: writes to anything outside the guest: pushes, PR comments, ticket edits, prod
    writes.
  - **C-egress**: sending data out of the guest at all. With unrestricted egress, any leak needs
    nothing but `curl`.

B and C meet at a credential: holding a write credential is B (access); using it is C-state.

**Rule:** a guest may hold at most two of A, B and C outright. When a task needs all three, the
third goes through a human step (priviledge approval for C-state, a human-carried transfer for
egress) or is removed. The guest's **profile** is the concrete choice of B and C for a given
kind of A. Profiles are named in the configuration (§8); a deployment implements each one as a
guest shape (image, mounted credentials, egress policy). The reference set:

| Profile | A: input | B: sensitive reach | C-state | C-egress |
|---|---|---|---|---|
| `trusted` | The human's own projects and vetted sources | Read-only resources may auto-approve; write resources ask | Through priviledge, asked | Allow-list |
| `public` | Open-source work: public issues, PRs, general web | No credentials in the guest; every request asks | Through priviledge, asked | Allow-list |
| `hostile-web` | Content that may target automated readers | **Nothing**: no credentials, no resources | None | Broad to the internet, needed by the task; no host or local network |
| `hostile-sample` | Samples, exploits, CTF material | Nothing | None | **None** |

Two consequences worth stating:

- **Open-source work is not the safe middle.** Reading strangers' text (A), holding credentials
  to one's own repos (B) and pushing or commenting (C) is the full set in one session by default;
  `public` breaks it by keeping every write behind approval and no write credential in the guest.
- **Hostile content is handled by removing B, not by trusting filters.** For `hostile-web` the
  task needs broad egress, so the guest holds nothing worth taking; the host and the local network
  stay out of reach, since services there are something worth taking too. For samples, egress
  goes too.

The same project may need guests of different profiles: developing it in `trusted`, triaging its
public tracker in `public`.

### priviledge's own code

- The broker is installed from a privileged-owned source (for example a clean clone at a reviewed
  tag). It must never run from a copy the AI workspace can write. This matters because priviledge
  itself will be developed in an AI workspace.
- The client is untrusted like everything else in the guest. Its version and integrity don't
  matter: whatever runs there speaks for that guest by definition.

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
  is a deployment choice. One class deserves naming, because priviledge triggers it: running a
  program inside a hostile guest (contract item 2) is what container-escape flaws such as
  CVE-2019-5736 in runc exploited. Keep the runtime patched, and prefer runtimes that put a VM
  around each guest (see SETUP.md).
- The human being misled by what the agent shows them. Mitigated by rendering request and output
  content safely (§7), by keeping approvals specific, and later by checkers (§10).

## 4. Deployment contract

priviledge assumes the deployment guarantees the following. Everything else about the setup is
free to change.

1. **Separation.** The AI workspace cannot read or write the privileged side's secrets, priviledge's
   configuration, or its state.
2. **A way to run a program inside a guest.** The privileged side has a command that starts a
   process inside a given guest with its stdin and stdout connected to the caller, for example
   `docker exec -i <name>`, `container exec -i <name>`, `ssh <host>`, or `sudo -u <user>`.
   priviledge uses it to reach the guest (`guest_exec`, §8; DESIGN.md §3).
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
  through the client. Each profile decides whether it asks or auto-approves, and whether the
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
it as well. Native grants remain for tools that cannot go through the client, such as git's
credential for `fetch` and `pull`.

Classifying requests by content ("this SQL is a read") is never the security boundary; it may only
drive auto-approval on resources whose credential is already limited.

Initial placement (to be confirmed per service):

| Capability | Placement | Notes |
|---|---|---|
| Git upstream read | Native, read-only token | git needs it non-interactively; a credential helper calling priviledge is in the backlog |
| Git push | Privileged side only | Feeds the deploy pipeline; never native, never a resource |
| PR/CI read (code host) | Resource, read-only token, auto-approve eligible | |
| Error tracker read | Resource, read-only token, auto-approve eligible | Errors may contain PII: condition 2 per profile |
| Issue tracker read | Resource, read-only token if one exists **(verify)** | |
| Issue tracker write | Resource, always ask | Low blast radius |
| Team chat (any) | Resource, always ask, or not at all | Even reads are high-impact |
| Prod DB, read-only role | Resource, auto-approve eligible | Role enforces read-only; bound query cost (§8) |
| Prod DB, read-write | Resource, always ask | |
| Cloud CLI | Resources per credential | e.g. a read-only policy vs an admin one |
| Consoles and shells on remote hosts | Session resources (backlog, §10), always ask | Full power once inside |
| Browser-only surfaces | Human resource (§8) | The human performs the step and returns the result |

Hosted OAuth connectors (e.g. claude.ai integrations) run outside the machine and request
whatever scopes the connector defines, often including write. They cannot be mediated from the
host at all; the only control is whether the account has them.

## 6. Agent interface

The client is one program, `priviledge`, used inside the guest. Every operation is asynchronous:
a request is submitted, waited for, and retrieved, in three separate commands. Each command does
one thing, so any of them can be composed with other tools without ambiguity.

- `priviledge list`: the resources this guest may request.
- `priviledge describe <resource>`: its description, what input it takes, its declared parameters,
  and whether it is auto-approved for this guest.
- `priviledge request <resource> -r <reason> [-p key=value]... [-- args...] [< payload]`: submit a
  request. Prints the request id on stdout and exits at once.
- `priviledge wait <id>... [--timeout <seconds>]`: block until every listed request is settled
  (done, failed, denied or dropped). Prints nothing on stdout. Without `--timeout` it waits
  indefinitely. It exits 0 once all are settled; `retrieve` then tells each outcome.
- `priviledge retrieve <id>`: write the result to stdout. Never blocks: if the request is not
  settled, it exits with a distinct status.
- `priviledge pending`: this guest's requests not yet retrieved, with resource and state.
- `priviledge cancel <id>`: withdraw a request that has not started. It is discarded.

```sh
id=$(priviledge request prod-db-ro -r "count overdue orders by region" <<'SQL'
SELECT region, count(*) FROM orders WHERE status = 'open' GROUP BY region
SQL
)
priviledge wait "$id" --timeout 100
priviledge retrieve "$id" > counts.csv

a=$(priviledge request aws-readonly -r "find restarts" -- logs filter-log-events ...)
b=$(priviledge request prod-db-ro -r "recent refunds" < refunds.sql)
priviledge wait "$a" "$b" && priviledge retrieve "$a" | jq ... && priviledge retrieve "$b"
```

- `-r <reason>` is required. It is shown to the human and written to the audit log.
- Inputs travel **by value**: the payload on stdin, extra arguments after `--`, named parameters
  as `-p key=value`, each only if the resource declares it (§8). A file the agent wants to use
  (a `.sql` or a Ruby script) is read by the *client* and sent as content. The broker never opens
  workspace paths, and never writes into them: the agent redirects `retrieve`'s stdout where it
  wants it.
- `wait` with a timeout exists because agent shell tools have hard timeouts (Claude Code's Bash
  tool: 2 min default, 10 min max). A timed-out `wait` changes nothing: the agent waits again.
- A client that exits does not cancel its request. `pending` recovers ids the agent lost.
- **A result is kept until it has been retrieved completely, then discarded.** Completely means
  the client wrote the last byte to its stdout without error and reported that to the broker; a
  broken pipe leaves the result in place for another `retrieve`. An agent that needs a result
  again keeps its own copy.
- If the human edited the request, `retrieve` says so on stderr, followed by the version that ran,
  so the agent does not reason from a query it did not actually get answered. If the human
  redacted the output, it says so on stderr, so the agent does not take withheld data for absent
  data. stdout carries only the result. The original request and the unredacted output are never
  sent; they exist only in the audit log.

**Exit status.** Resource executables never talk to the agent through exit codes (§8), so the
client's own codes cannot collide with theirs:

| Code | Meaning | Commands | The agent should |
|---|---|---|---|
| 0 | Success. For `retrieve`: the resource succeeded and its output is on stdout | all | |
| 1 | The resource failed. stdout carries whatever the resource chose to tell the agent | `retrieve` | Read stdout |
| 249 | Dropped: the broker connection was lost before the request ran; nothing happened | `retrieve` | Request again |
| 250 | Not settled (`retrieve`), or timed out (`wait`) | `wait`, `retrieve` | Wait again |
| 251 | Denied by the human, the request or the release of its output, with their message on stderr | `retrieve` | Not repeat it as is |
| 252 | Unknown id: never existed, already retrieved, or cancelled by the agent | `wait`, `retrieve`, `cancel` | Nothing to fetch |
| 253 | Invalid request: unknown resource, undeclared input, missing reason, or `cancel` on a request that already started | `request`, `describe`, `cancel` | Fix the call |
| 254 | Broker not connected | all | Retry once it is back |

Codes 249–254 are outside the ranges ordinary tools and shells use. Every non-zero exit comes
with a one-line `priviledge: ...` message on stderr.

**When the broker connection is lost** (guest restarted, broker stopped):

- Requests that have **not started** are dropped: nothing ran, and `retrieve` reports 249 once the
  connection is back, so the agent can request again.
- Requests that are **running, awaiting release, or settled but not retrieved** may already have
  had effects (a write on a write resource). They are kept, flagged to the human as "not
  retrieved", and the agent can still `retrieve` them once the connection is back.
- If the broker itself restarts, outstanding requests are lost. The audit log (§9) records how far
  each one got.

## 7. Approval

Each guest has its own approval prompt, on the terminal where the human runs
`priviledge serve <profile> <name>`. The prompt is line-oriented, like `git add -p`:

```
[12] trusted/shop · prod-db-ro
     reason: count overdue orders by region
     SELECT region, count(*) FROM orders WHERE status = 'open' GROUP BY region
run? [y]es [Y]es+release [n]o(+msg) [s]kip [e]dit [v]iew [?]
[12] exit 0 · 214 lines · 6.1 KB · 1.4 s
     region,count
     eu-west,412
     ... (first/last lines)
release? [y]es [n]o(+msg) [v]iew [e]dit/redact
```

- The guest (`profile/name`) is established by the broker and is authoritative. The reason is the
  agent's text and is shown as such.
- **Requests are handled one at a time, in arrival order**: a request runs only after the previous
  one is settled or skipped. `Y` approves and releases the output without a second prompt, for
  requests whose result the human does not need to see. `s` leaves a request pending and moves on;
  it comes back at the end of the queue. Concurrent execution is in the backlog (§10).
- Requests that need no confirmation still get a one-line entry in the pane, so the human sees
  everything that runs.
- The resource's stderr (§8) is shown in the pane and never sent to the guest.
- Notification of a new prompt is configurable per profile (`notify`, §8): a terminal bell, a
  command, or nothing.
- **All agent-supplied text is rendered with control characters escaped.** Requests and outputs
  must not be able to move the cursor, hide lines, restyle the prompt, or send queries to the
  terminal.
- The inline prompt shows escaped plain text with simple formatting (JSON pretty-printed, CSV
  aligned). Output is not size-limited on the way to the guest; the prompt shows size and a
  head/tail preview. Request payloads are capped (§3).
- `view` opens the content in `$PRIVILEDGE_REVIEW_PAGER`, from a privileged-owned temp file whose
  extension comes from the resource's `input_syntax` / `output_syntax` (§8). `edit` does the same
  with `$PRIVILEDGE_REVIEW_EDITOR`. Both are argv strings, run without a shell, with the file's path
  appended as the last argument; the defaults are
  `less` (without `-R`, and with its input preprocessor disabled) and `vi`. SETUP.md describes safe
  richer choices.

### Review surfaces run as privileged over hostile content

Whatever displays a request or output runs on the **privileged side** over **agent-authored**
text, exactly the content the core rule says privileged tools must not interpret. A painful
review is itself a risk, because that is where a sneaked-in change gets past a tired reviewer.
Comfortable review and small attack surface pull in opposite directions, and the rule that
settles it:

> priviledge itself renders untrusted content only as escaped plain text, with the standard
> library and no parser beyond JSON and CSV. Any richer view (syntax colour, diffing, folding) is
> delegated to an external tool the human chooses, which works on a privileged-owned *copy* of the
> content and must never execute anything from it. priviledge's own surface stays small and
> auditable; the richer tool's surface is the human's explicit choice.

For those external tools: no LSP, ever (LSP servers execute project code); syntax highlighting is
a small, accepted risk (in-process parsers of untrusted input, with a history of memory-safety
bugs, but no code execution) when the tool's configuration is privileged-owned and plugin-free.
The same rule applies to checkers (§10): external executables, not in-process parsers.

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
[resources.prod-db-ro]
description = "Production Postgres (read-only role). Bound queries on large tables by time."
run = "~/.config/priviledge/resources/prod-db-ro"
input = "stdin"            # takes a payload: the SQL
input_syntax = "sql"
output_syntax = "csv"

[resources.prod-db-rw]
description = "Production Postgres (read-write role)."
run = "~/.config/priviledge/resources/prod-db-rw"
input = "stdin"
input_syntax = "sql"
output_syntax = "csv"
write_credential = true

[resources.aws-readonly]
description = "AWS CLI with the read-only role. Pass the aws arguments after --."
run = "~/.config/priviledge/resources/aws-readonly"
args = true
output_syntax = "json"

[resources.dashboard-query]
kind = "human"
description = "A query for the human to run in the monitoring dashboard. Payload: the query."
input = "stdin"
input_syntax = "json"
output_syntax = "json"

[profiles.trusted]
guest_exec = ["docker", "exec", "-i", "aiws-{profile}-{name}"]
notify = "bell"
[profiles.trusted.resources]
prod-db-ro = { confirm_request = false, confirm_output = false }
prod-db-rw = {}
aws-readonly = { confirm_request = false }
dashboard-query = {}

[profiles.public]
guest_exec = ["docker", "exec", "-i", "aiws-{profile}-{name}"]
notify = "bell"
[profiles.public.resources]
prod-db-ro = {}            # every request and every output is confirmed
aws-readonly = {}

[profiles.hostile-web]     # no resources: no broker runs for such guests
[profiles.hostile-sample]
```

### Resolution

A resource is available to a guest if it appears in its profile's `resources` table; the value
holds that profile's settings for it. `confirm_request` and `confirm_output` default to `true`.
The broker validates at start:

- `confirm_request = false` is only allowed for resources without `write_credential`. Otherwise
  writes would run unapproved. Releasing output unreviewed is a confidentiality choice and is
  allowed for any resource.
- A profile entry for a resource that does not exist is an error.
- `guest_exec` must contain `{name}` (and may contain `{profile}`), so that two guests of one
  profile cannot resolve to the same command.

### Profile fields

| Field | Meaning |
|---|---|
| `guest_exec` | The command that runs a program inside a guest (§4, item 2), as an argv list with `{profile}` and `{name}` substituted; priviledge appends its own program name and arguments. Required for a profile with resources |
| `notify` | `"bell"`, `"none"`, or an argv list to run on each new prompt. Default `"bell"` |
| `resources.<resource>` | Makes the resource available to guests of this profile. Keys: `confirm_request` (approve before running), `confirm_output` (approve before releasing the output); both default `true` |

Whether to trust a resource unattended is a property of the profile, not of the resource, which
is why the confirmation settings live here.

### Resource fields

| Field | Meaning |
|---|---|
| `kind` | `"exec"` (default) or `"human"` |
| `description` | Shown to the agent by `list`/`describe` and to the human in the prompt |
| `run` | The privileged-owned executable (`exec` only) |
| `input` | `"stdin"` if the resource takes a payload. Omitted: no payload accepted |
| `args` | `true` if extra arguments after `--` are passed as argv (`exec` only). Default `false` |
| `params` | Table of named parameters and their descriptions. Undeclared parameters are rejected |
| `input_syntax`, `output_syntax` | Review hints: the file extension used for `view`/`edit` |
| `write_credential` | `true` if the resource's credential can change state. Default `false`. The human's declaration of what the credential enforces |

### The resource contract

A resource has one audience on each side, and the broker keeps them apart:

- **stdout is for the agent.** Whatever the resource writes there is the result, released to the
  guest after review (or at once, if the profile says so).
- **stderr is for the human.** Diagnostics, the wrapped tool's own errors, anything that mentions
  hosts, users or paths. It is shown in the approval pane and written to the audit log, and never
  sent to the guest.
- **Exit 0 is success; any other status is failure.** The status itself is not forwarded. A
  resource that wants the agent to know *why* it failed writes that to stdout before exiting
  ("syntax error at line 3"), and leaves out what the agent has no business knowing ("connection
  refused to prod-db-3.internal").

Resource executables are therefore wrappers written for this contract, not stock tools exposed
directly. They may be shared, and priviledge may ship some, but each one is the human's choice.

### Exec resources

An `exec` resource is an executable owned by the privileged user. It is executed directly (never
through `sh -c`). It receives the payload on stdin, declared parameters as `PRIVILEDGE_P_<NAME>`
environment variables, and, if `args = true`, the extra arguments as argv. The agent cannot set
any other part of its environment. It fetches its own secrets with whatever the OS provides (macOS
`security`, Linux `secret-tool`, `pass`, `op read`, ...).

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
  [ "$a" = configure ] && { echo "aws configure is not allowed"; exit 1; }
done
export AWS_CONFIG_FILE=~/.config/priviledge/aws/readonly.config
export AWS_SHARED_CREDENTIALS_FILE=~/.config/priviledge/aws/readonly.credentials
exec aws "$@"
```

```sh
#!/bin/sh
# prod-db-ro: `sqlquery` is the human's driver-based script: SQL in on stdin, CSV out,
# and the driver's own errors on stderr, for the human.
PGPASSWORD=$(security find-generic-password -s prod-db-ro -w) \
  exec ~/.config/priviledge/bin/sqlquery "host=... user=app_ro dbname=... options='-c statement_timeout=60s'"
```

**Read-only is not harmless on a primary database.** A read-only role can't write, but an
auto-approved query can still load production. Bound the cost with a role-level or connection
`statement_timeout`, as above.

An auto-approved resource with `args = true` exposes everything its credential can read (§5,
condition 2): a read-only cloud role can often read parameters, secrets stores and object storage.
Narrow the credential, or the subcommands the executable allows, before auto-approving it.

### Human resources

A `human` resource is a task only the human can do, fast, without ending the agent's turn:
running a query in a browser console, reading a value off a dashboard, answering a question.
The agent's alternative is to stop and ask, which tends to make it summarise, draw conclusions
and act as if the turn were over, when the missing information may change those conclusions.

The request is shown like any other, with the payload as the task. On `y` the broker opens
`$PRIVILEDGE_REVIEW_EDITOR` on an empty privileged-owned temp file; what the human saves is the
result (stdout, in the contract above). `n` denies. `confirm_output` applies as for any resource
and defaults to `true`, although the human wrote the output; setting it to `false` skips the second
look.

### Session resources (backlog)

Long-lived interactive processes: psql, a Django shell reached through a cloud exec
shell, a remote ssh shell. Essential in practice (slow start-up, loaded state,
interactive auth at start). Each approved snippet runs in the same live session and returns its
output. The same three properties apply: a local psql session would have to be
confined, while a remote console runs its input remotely. Until session resources exist, the same
work is done with repeated exec requests (each query is one request), which is slower but simple
and safe.

## 9. Audit log

Every request is recorded on the privileged side, one log per guest: request id, guest
(`profile/name`), reason, the request as submitted and as run (if edited), decisions,
timestamps, exit status, the resource's stderr, output size and a hash of the output, and the
unredacted output when the released one was redacted. Output bodies are not logged otherwise.
Each step of a request (received, decided, started, finished, released, retrieved) is recorded as
it happens, so a crash leaves a record of how far every request got.

## 10. Backlog

Development is iterative: after each item ships, the next one is chosen. The order below is the
current intent, not a plan. Releases use semantic versioning, `0.x` while the interfaces in this
document may still change, `1.0` when they stop.

1. **The core**: exec resources, profiles, the client (`list`, `describe`, `request`, `wait`,
   `retrieve`, `pending`, `cancel`), the sequential approval prompt with both confirmations and
   output review, the audit log.
2. **Human resources** (§8).
3. **Checkers**: privileged-owned executables that receive a request before the prompt and return
   *pass*, *flag* (with a note the prompt shows) or *block*. Pattern rules first; other kinds
   possible. They follow the review-surface rule (§7) and the resource input rules (§8).
4. **Concurrent execution**: several approved requests running at once, with their release
   prompts queued. Needs its own UX pass.
5. **Session resources** (§8).
6. **Egress approval**: the deployment's egress proxy asks priviledge before allowing a new host,
   so the human approves domains the way they approve requests.
7. **MCP servers on the privileged side.** Some integrations exist only as MCP servers. The broker
   runs them, with their credentials, and the client exposes them to the guest through a stdio
   adapter that forwards only `tools/list` and `tools/call`; each call is a request with the
   profile's confirmation settings, per tool. The server processes agent input with a credential,
   so it runs confined, like any resource that does.
8. **HTTP resources**: `kind = "http"` with a fixed base URL, allowed methods and paths, a
   credential injected on the privileged side, and JSON review hints. Most SaaS reads,
   declaratively; the fixed base URL satisfies the credential rules by construction.
9. **A git credential helper backed by priviledge**, removing the last native token (§5).
10. **Burst approvals**: "approve the rest from this resource for N minutes", read-only resources
    only.
11. **A privileged-only approval interface for scripting** (`queue`, `approve`, `deny`).
12. **An MCP adapter for the client's own commands** (`priviledge mcp`), only if a client needs
    it and it shows value over its cost. The CLI is POSIX-composable, works in every agent, and
    keeps the surface small and free of MCP spec churn.

## 11. Open questions

- Which SaaS tokens can actually be scoped read-only (trackers, code hosts, chat) **(verify)**.
- Cancelling a running request from the approval prompt, and whether resources need a timeout.
- Head/tail preview size in the approval prompt.
- Whether requests should survive a broker restart. For now they don't; the audit log is the
  record.
