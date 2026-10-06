# priviledge — reference setup (draft)

Status: draft. This describes **one** way to deploy the AI workspace around priviledge: Docker
containers in dedicated colima VMs on macOS. priviledge itself does not depend on it; it only
needs the deployment contract in [SPEC.md §4](SPEC.md#4-deployment-contract); how priviledge
reaches a guest is in [DESIGN.md §3](DESIGN.md#3-channel-and-relay). Other setups are sketched in
§14. Items marked **(verify)** must be checked on the real machine. Every command here changes
the machine's configuration, so the human reviews and runs it.

Terms (guest, profile, privileged side, broker) are as defined in
[SPEC.md §3](SPEC.md#3-threat-model).

## 1. Overview

```
host: privileged side                         colima VM aiws (trusted, public guests)
┌─────────────────────────────────────────┐   ┌──────────────────────────────────┐
│ terminal + tmux                         │   │ guest aiws-trusted-shop          │
│   panes: aiws exec … (docker exec -it)  │──▶│   nvim + LSP, agent, tests,      │
│   pane:  priviledge serve trusted shop  │──▶│   dev servers, priviledge relay  │
│ secrets, priviledge config              │   │   repos in a volume              │
│ the setup's files (~/.aiws)             │   │   dotfiles mounted read-only     │
│ clean clones (review, push, deploy)     │   ├──────────────────────────────────┤
│ docker CLI, colima (runtime control)    │   │ egress proxy, port forwarders    │
│ browser                                 │   │ dev services (project compose)   │
└─────────────────────────────────────────┘   └──────────────────────────────────┘
                                              colima VM aiws-hostile (hostile-* guests)
```

- A **guest** is a container created on demand from a **profile** (SPEC.md §3): the profile decides
  the VM it runs in, what is mounted, and the egress policy. `aiws new trusted shop` creates
  `aiws-trusted-shop`; `priviledge serve trusted shop` brokers for it.
- One guest per project and profile, i.e. per trust domain. Many sessions (nvim, several agents,
  shells) run inside the same guest.
- Guests run in **VMs of their own** (§2), not in the machine's general container runtime, so the
  host is behind a VM boundary whose exposure the setup decides: the VMs see only the few host
  paths they mount, read-only except the exchange directories. Inside a VM, guests are separated
  from each other by kernel namespaces, which is weaker but adequate for project-vs-project trust.
  It is not adequate next to hostile material, so `hostile-*` guests run in a second VM,
  `aiws-hostile`, apart from the `trusted` and `public` ones.
- The privileged side drives guests only through the runtime's CLI, and never runs code written in
  a guest except reviewed code at a pinned commit (§11, §12).

**Files.** The scripts and configuration of this setup are in the repository's
`examples/setup/`, tested as described in §15. They are an example, not part of priviledge: copy
the directory to `~/.aiws` and make it yours. From then on it doesn't follow the repository, and
nothing here is supported beyond being an example. priviledge's own files live in `~/.priviledge`
(SPEC.md §8), separate because only those matter to the broker; another deployment has no
`~/.aiws` at all. Copy from a checkout you trust; for priviledge's own development that means a
clean clone at a reviewed commit (§11), never a guest's working copy.

```
~/.aiws/
├── bin/          aiws (guests), aiws-verify (§15), aiws-window (§7): on PATH
├── Dockerfile    the guest image (§6)
├── egress/       squid-allowlist.conf, squid-public.conf, <guest>.txt allow-lists (§5)
├── dotfiles/     mounted read-only into trusted and public guests; may be a link (§4)
├── overrides/    compose overrides per project (§12)
└── run/          dtach sockets of the approval panes (§7)
~/aiws-exchange/<vm>/<guest>/   exchange directories: guest-written, so kept out of ~/.aiws
```

## 2. Runtime: dedicated colima VMs

[colima](https://github.com/abiosoft/colima) runs Docker Engine in a [Lima](https://lima-vm.io)
VM; both are open source. The setup gives guests two VMs of their own, `aiws` for `trusted` and
`public` guests and `aiws-hostile` for `hostile-*` ones. `aiws` holds their one definition:

```sh
aiws vm start aiws            # create it, or start it; then build the guest image if it lacks it
aiws vm start aiws-hostile    # when a hostile task needs it
```

`aiws vm start` runs `colima start` with the VM's full list of mounts: for `aiws`, its exchange
root (`~/aiws-exchange/aiws`, writable) and the dotfiles' real path; for `aiws-hostile`, only its
own exchange root. The proxies' configuration is copied into them instead (§5), so no VM mounts
it. Any other `aiws` command whose VM isn't running stops and names the command that starts it.

- **Why dedicated VMs.** A guest that escapes its container (a kernel or runtime flaw, SPEC.md §3)
  lands in the VM and reaches whatever the VM can see. A general-purpose runtime's VM usually
  sees the whole home directory (Docker Desktop shares `/Users` by default), and restricting it is
  a machine-wide setting other tools depend on. These VMs belong to the setup, which decides what
  they mount, independently of any other container work on the machine.
- **What a VM sees of the host:** exactly its `--mount`s, at the same paths, and nothing else
  (`/Users` in the VM holds only the path down to them). Mounts are read-only unless marked
  `:w`, and with colima's defaults on macOS (the `vz` VM type, virtiofs mounts) **the host
  enforces read-only**: checked on colima 0.10.3 (Lima 2.2.1), root inside the VM could neither
  write to a read-only mount, nor after remounting it read-write, nor after mounting the share
  again by its tag. So an escape reaches the exchange directories (writable by guests anyway),
  and in the `aiws` VM can read the dotfiles, which hold nothing secret.
- **`--activate=false`**, which `aiws vm start` passes and the VM's profile remembers, keeps
  colima from making the VM the Docker CLI's default context. The scripts select a VM explicitly
  (`docker --context colima-aiws`), and every other `docker` command on the machine keeps going
  where it went before.
- **Changing mounts** (adding the clean clones that a project's compose file bind-mounts, §12):
  edit the list in `aiws`, then `aiws vm stop aiws` and `aiws vm start aiws`. colima stores the
  list in the VM's profile, so a running VM keeps the one it started with.
- **Lifecycle.** VMs don't start by themselves after a reboot: `aiws vm start <vm>`. A VM's
  configuration is in `~/.colima/<vm>/`, its Docker data (images, and every guest's home volume:
  repos, the agent's login) in a sparse disk under `~/.colima/_lima/_disks/`, and the downloaded
  VM image in `~/Library/Caches/colima`. `aiws vm stop` frees the VM's memory and keeps
  everything; `aiws vm delete` removes it after two confirmations, with `--data`: a plain `colima
  delete` keeps the data disk, and a VM created later with the same name gets it back, guests'
  volumes included (checked on colima 0.10.3). `aiws-hostile` is meant to be disposable: start it
  for a hostile task, delete it when its guests are gone.
- Port forwarding: colima forwards ports the VM listens on to the host. Everything this setup
  publishes binds `127.0.0.1`, which lands on the host's loopback only (§13).
- **Never** give a guest the runtime's control socket (`/var/run/docker.sock` or equivalent),
  `privileged: true`, host networking, or the host PID namespace. Any of these hands the guest
  its VM, and with it everything the VM mounts.

## 3. Profiles

Each profile in priviledge's configuration (SPEC.md §8) is implemented here as a guest shape. The
reference set:

| Profile | VM | Mounted | Native tokens | Egress (§5) |
|---|---|---|---|---|
| `trusted` | `aiws` | home volume, dotfiles (ro), exchange | git read-only token | proxy, allow-list |
| `public` | `aiws` | same | none (public repos clone anonymously) | proxy, allow-list |
| `hostile-web` | `aiws-hostile` | fresh home volume, exchange only | none | proxy, public internet only |
| `hostile-sample` | `aiws-hostile` | fresh home volume, exchange only | none | none (`--network none`) |

All run the same image, `aiws-base` (§6). `hostile-*` guests are meant to be disposable: created
for the task, removed after (`aiws rm`). No broker runs for them; results leave through the
exchange directory, carried by the human.

Every guest that runs an agent also holds the agent's own login or key (§10), a known issue in
SPEC.md §3.

## 4. Guests

A guest is created by a small privileged-owned helper, `~/.aiws/bin/aiws`. Nothing about a
guest's shape is decided inside it.

```
aiws new    <profile> <name>                create the guest aiws-<profile>-<name>
aiws rm     <profile> <name>                remove it, with its network, sidecars and home volume
aiws recreate <profile> <name>              recreate it from the current images, keeping its
                                            home volume and forwarded ports
aiws exec   <profile> <name> [cmd...]       run a command in it (default: a shell)
aiws port   <profile> <name> <port>[:<guest-port>]
                                            forward 127.0.0.1:<port> on the host to the guest
aiws reload <profile> <name>                reload its proxy, after editing its allow-list
aiws denied <profile> <name>                the hosts its proxy refused, most frequent first
aiws allow  <profile> <name> <host>...      add hosts to its allow-list, and reload
aiws verify <profile> <name> [allowed-url]  check it against §15
aiws build                                  rebuild the guest image in each running VM, with
                                            updated base and sidecar images
aiws vm start|stop|delete <vm>              create or start a VM (aiws, aiws-hostile) with its
                                            mounts; stop it; delete it with all its data
```

`aiws new` picks the VM from the profile, creates the home volume and the exchange directory,
for a guest with a network an internal network and its proxy (§5), and runs the container with
no capabilities, no privilege escalation, and nothing but `sleep` until something execs into it.
Guest names can't contain `-`, although priviledge accepts it (DESIGN.md §2): the helper names a
guest's network, volume and sidecars by appending to the container's name, and a guest named
`shop-proxy` would collide with the proxy of a guest named `shop`.

The guest's home, as the guest sees it:

```
/home/aiws/                     the home volume: persists across container recreation
├── src/                        repos, cloned from inside
├── .dotfiles/                  bind mount, read-only  ◀─ ~/.aiws/dotfiles on the host
├── .config/nvim → .dotfiles/nvim   links made once, inside
└── exchange/                   bind mount, writable   ◀─ ~/aiws-exchange/<vm>/<guest> on the host
```

- **Repos live in the guest's home volume**, not on the host filesystem. The volume survives the
  container, so the guest can be recreated from a new image without losing anything; it lives
  inside the VM, so it is fast where mounts from the host are slow; and the privileged side can't
  accidentally run git or an editor against the repos, since it reaches them only through the
  `ext::` remote (§11).
- **Dotfiles are mounted read-only**: nvim config, shell config, git config (no credentials), the
  global gitignore, the agent's global instructions. Change them on the host and every guest sees
  it at once. Inside the guest, link them into place once (`ln -s ~/.dotfiles/nvim
  ~/.config/nvim`). `~/.aiws/dotfiles` may be a link to an existing dotfiles checkout: `aiws`
  mounts its real path, which is what the VM mounts too (§2). They must never contain secrets,
  and file modes don't help: a guest reads every file in a mount, whatever its permissions.
  `hostile-*` guests get no dotfiles: less to configure, and nothing of the human's in them.
- **The exchange directory** is the one writable host path, for screenshots, CSVs and similar.
  It is per guest, under its VM's exchange root, so guests of different profiles never share one
  and the hostile VM can't see the others' at all. On the host, treat its contents like untrusted
  downloads. The guest can also create symlinks there that point at host paths: a host tool that
  follows one reads or overwrites the host file. Don't write into the directory over existing
  names, and check with `ls -l` before opening what's there.
- **Proxy variables** are set in both spellings, because tools disagree on which they read (curl,
  for one, ignores an uppercase `HTTP_PROXY`). `AIWS_NO_PROXY` adds the project's HTTP dev services
  (§12), which would otherwise be sent to the proxy and refused.
- **Ports, when a guest needs them.** Docker does not publish ports for a container that is only
  on an internal network, so `aiws port` starts a small forwarder per port, on the bridge and
  attached to the guest's network: `aiws port trusted shop 8000` makes the guest's port 8000
  reachable at `127.0.0.1:8000` on the host, `aiws port trusted shop 18000:5173` maps a different
  host port. Each guest and service needs its own host port: a clash within a VM is refused, but
  one between the two VMs, or with a host process, goes unnoticed, and the host port then leads to
  whichever claimed it first. Dev servers must listen on `0.0.0.0` *inside* the guest for the
  forwarder to reach them (Django's, for one, defaults to `127.0.0.1`). Forwarded ports are
  reachable from other containers in the VM through the host (§13), so they should not expose
  anything that trusts its callers.

## 5. Egress

Egress is a profile's property C (SPEC.md §3) and the deployment enforces it (SPEC.md §4,
item 5). The mechanism for every guest with a network: **the network denies, the proxy allows.**

- The guest is on an `--internal` Docker network, which has no route out. Non-HTTP TCP, UDP and
  external DNS simply have nowhere to go; the internal network blocks them, not the proxy. The
  guest resolves only local names; the proxy resolves the rest, so DNS queries can't carry data
  out either.
- A proxy sidecar is on that network *and* the bridge, and is the guest's only way out. The
  guest's proxy variables point at it. Honouring them is voluntary, but a process that ignores them
  has no route at all.
- The proxy never connects to private, loopback or link-local addresses, which keeps the host,
  other containers and the local network out of reach, including through an allowed name that
  resolves to a private address.
- Two modes: `allowlist` (`trusted`, `public`) allows only listed hostnames; `public`
  (`hostile-web`) allows any public address. `hostile-sample` has no network at all.
- No TLS interception: the proxy sees hostnames, not contents, and the guest needs no extra CA.

The proxy is Squid, configured by `~/.aiws/egress/squid-allowlist.conf` or `squid-public.conf`,
and, in allow-list mode, by the guest's own list, `~/.aiws/egress/aiws-<profile>-<name>.txt`: one
hostname per line, a leading dot for subdomains too, `#` for comments. `aiws` copies both into
the proxy when it starts it, and again on `aiws reload` (`docker cp`, which reads them on the
host, links resolved), so no VM mounts them and nothing in a guest or a VM can change them. A
list may be empty: Squid warns about the empty ACL and refuses everything.
`allow-list.example.txt` is a commented starting point.

Allowing a host, with the guest running:

1. `aiws denied trusted shop` lists the hosts its proxy refused, from the proxy's log (`aiws
   verify`'s own probes show up there too).
2. Decide: the exact name rather than a whole domain, and whether the host stores data for any
   account (below).
3. `aiws allow trusted shop api.example.com` adds it and reloads the proxy; no restart of the
   guest or its sessions. Editing the file by hand and running `aiws reload` does the same, but
   `aiws allow` also checks that each entry is a hostname: Squid reads every word on a line as a
   separate name.

Notes:

- Checked on colima 0.10.3, with `aiws verify` (§15) and by hand: an internal network has no
  route to the internet or to the host; a guest's lookups of external names fail without leaving
  the VM (none showed up on any of its interfaces); the proxy refuses hosts off the list, the
  host, and private addresses with its own 403; a port forwarded with `aiws port` reaches the
  host's loopback.
- Squid is the boring choice. iron-proxy is the alternative when credential injection is wanted
  (the guest holds a placeholder token, the proxy swaps in the real one at egress, so git's native
  token, SPEC.md §5, never enters the guest), at the cost of terminating TLS: every client in the
  guest must trust its CA.
- Reviewing denied hosts is how allow-lists grow. Approval of new hosts through priviledge, as a
  prompt in the approval pane, is in the backlog (SPEC.md §10).
- Start lists as empty as the work allows. An allowed host that stores data for any account can
  carry data out (SPEC.md §3), and in `trusted` the list also decides what strangers' text the
  agent reads. Prefer exact names to whole domains: `github.com` rather than `.github.com`, which
  would also allow `gist.github.com`; `pypi.org` without the leading dot excludes
  `upload.pypi.org`, and pip downloads from `files.pythonhosted.org`. Where one host serves both,
  as npm's registry and GitHub do, and for the agent's own model API, output review is the
  control.

## 6. Image

`~/.aiws/Dockerfile` builds `aiws-base`: Debian stable with the shared tooling (git, curl, ripgrep,
fd, zsh, a compiler toolchain, the Postgres client), a UTF-8 locale, a pinned nvim release, and a
non-root user, `aiws`. `aiws vm start` builds it in a VM that lacks it, and `aiws build` rebuilds
it in each running VM after a change: VMs don't share images.
The build runs in the VM's Docker Engine, outside any guest and its proxy, so the downloads it
makes (Debian packages, the nvim release from GitHub) never need to be in a guest's allow-list.

- **What goes in the image and what goes in the home** follows from one fact: Docker copies the
  image's `/home/aiws` into the volume only once, when the volume is created, so anything the
  image installs under the home never updates afterwards. Tools that install system-wide (system
  packages, nvim, priviledge) therefore live in the image, rebuilt from the privileged side. Tools
  that install into the home (nvim's plugins, language toolchains, the agent and its self-updater)
  are installed from inside the guest, through its proxy. Baking a project's toolchain into a
  per-project image (`FROM aiws-base`) is the reproducible option once it settles.
- No sudo in the guest; `cap_drop` and `no-new-privileges` would defeat it anyway. Installing
  system packages means rebuilding the image from the privileged side.
- **Updating.** `aiws build` rebuilds on a freshly pulled Debian base, so security updates come
  in with every rebuild, pulls the proxy and forwarder images, and drops the images left unused.
  Guests keep the image they were created from until `aiws recreate`, which replaces the guest's
  containers and keeps its home volume and its forwarded ports (checked: a file in the home and
  two forwarded ports survived a recreate onto a rebuilt image). Whatever runs in the guest at
  that moment, agents and editors included, ends.
- priviledge is one program (DESIGN.md §1), installed the same way everywhere; in the guest only
  its client and relay subcommands are used. It must be on the default `PATH`, since `guest_exec`
  runs it without a login shell. Its integrity in the guest doesn't matter (SPEC.md §3): it only
  has to speak a protocol version the broker accepts (DESIGN.md §4). The broker's copy is what
  matters: install it on the host from a privileged-owned clean clone at a reviewed tag, never
  from a guest.

## 7. Terminal and tmux (privileged side)

A terminal that denies clipboard reads, Ghostty for example:

```
clipboard-read = deny
clipboard-write = allow
```

Guests set the clipboard through OSC 52 (this replaces `pbcopy`). Reads stay denied, because the
clipboard often holds secrets.

`~/.tmux.conf`:

```
set -g set-clipboard on
set -g monitor-bell on
set -g bell-action other
```

A per-guest window, `aiws-window <profile> <name>`: the editor, the agent and a shell in the guest
(`aiws exec`), and the guest's approval pane, `priviledge serve <profile> <name>` under `dtach`.

- **The approval pane in more than one window.** tmux can't show one pane in two windows, so the
  broker runs under `dtach`, which multiplexes its terminal: a second window attaches to the same
  socket (`dtach -a <sock> -r winch`), input from any attached window reaches the prompt, and
  output goes to all. The socket is privileged-owned and never visible to guests. One limit
  **(verify)**: the broker's terminal has one size, that of the window attached last, so the
  full-screen pager or editor renders correctly only in windows of that size; the line-oriented
  prompt is unaffected. `abduco` is the alternative with the same shape.

- `docker exec -it` allocates a terminal inside the guest. The privileged pane only relays bytes,
  so no terminal device is shared with the guest. What remains is escape sequences in guest
  output, which is why clipboard reads are denied and priviledge escapes agent text.
- The terminal's `TERM` (`xterm-ghostty`, say) needs its terminfo in the image. Either
  install it or use `xterm-256color`, which `aiws new` sets.
- A privileged window holds a shell in the clean clones (§11) for review, push, deploy and project
  compose.

## 8. Review tools (privileged side)

The approval prompt shows escaped plain text; any richer view comes from the pager and editor the
human configures (SPEC.md §7). They run as the privileged user over agent-authored content, so the
choice matters:

- They are the `[review]` argv lists in `~/.priviledge/config.toml`, run without a shell and with
  a fixed environment, so an exported `LESS=-R` (escape sequences passed to the terminal) or
  `LESSOPEN` (a lesspipe script running other programs over the file) never reaches them.
  Tool-specific settings go in the list itself, e.g. `["env", "LESSHISTFILE=-", "less", ...]`.
- The default pager is `less -+r -+R --no-lessopen`; the `-+` options reset raw control
  characters whatever a lesskey file says.
- The default editor, `vi -u NONE -i NONE -n -c "set nocompatible nomodeline"`, loads nothing:
  no vimrc, no plugins, no syntax colouring. `-u NONE` starts vim in compatible mode, where
  modelines are off when the file is read; `-c` then restores normal vim editing and keeps
  modelines off. Checked on Debian 13 and Ubuntu 24.04 (vim-tiny), Fedora 44 (vim-minimal) and
  macOS 15: a modeline that fires when forced on is ignored. On all three Linux systems the
  minimal package provides `vi` but no `vim`, hence the name.
- With full vim, colour comes from a privileged-owned vimrc that leaves the human's `~/.vim` out
  of the runtime path (`vim --clean` doesn't do: it leaves compatible mode after `--cmd` runs,
  which turns modelines back on). Checked on macOS's vim 9.1:

  ```toml
  [review]
  editor = ["vim", "-u", "~/.priviledge/review.vim", "-i", "NONE", "--noplugin"]
  ```

  ```vim
  " ~/.priviledge/review.vim
  set nocompatible
  set runtimepath=$VIMRUNTIME packpath=
  set nomodeline noswapfile noundofile viminfo=
  syntax on
  ```
- A minimal nvim serves as both, the pager in read-only mode:

  ```toml
  [review]
  pager = ["nvim", "--clean", "-u", "~/.priviledge/review.lua", "-R"]
  editor = ["nvim", "--clean", "-u", "~/.priviledge/review.lua"]
  ```

  ```lua
  -- ~/.priviledge/review.lua
  vim.o.modeline = false   -- the content must not set options
  vim.o.swapfile = false   -- no copy of the reviewed content (unredacted output, say)
  vim.o.undofile = false   --   outlives the review
  vim.cmd("syntax on")     -- colouring from nvim's bundled syntax files
  ```

  `--clean` starts nvim without the human's configuration, plugins or shada, and `-u` then loads
  only this file. Checked on nvim 0.12.5: the file is loaded, no script from the human's
  configuration or data directories is, a modeline in the content is ignored, and bundled syntax
  colouring works. No plugin, no LSP, no treesitter parser beyond the few nvim bundles.
- Answering a human resource (SPEC.md §8) is an edit of its output in the same editor.
- Diff review before a push (§11) is the human's own tooling, outside priviledge, under the same
  rule: no tool that runs project code.

## 9. Resources (privileged side)

Resource executables are the human's, written to the contract and the three properties in
SPEC.md §8. The repository will carry complete, tested examples under `examples/resources/`, to
copy into `~/.priviledge/resources/` and adapt; the two below are for the resources in
SPEC.md's example configuration.

```sh
#!/bin/sh
# ~/.priviledge/resources/aws-readonly
# Only allow-listed operations; global options go after them. No host files, no other endpoint.
case "$1 $2" in
  "logs filter-log-events"|"logs describe-log-groups"|"ecs describe-services") ;;
  *) echo "not allowed: aws $1 $2"; exit 1 ;;
esac
for a in "$@"; do
  case $a in
    *file://*|*fileb://*|--endpoint-url*) echo "not allowed: $a"; exit 1 ;;
  esac
done
# Only this profile's files. The broker's fixed environment (SPEC.md §8) keeps any AWS_* the
# human exported out of here.
AWS_CONFIG_FILE="$HOME/.priviledge/aws/readonly.config" \
AWS_SHARED_CREDENTIALS_FILE="$HOME/.priviledge/aws/readonly.credentials" \
  exec aws "$@"
```

```sh
#!/bin/sh
# ~/.priviledge/resources/prod-db-ro
# `sqlquery` is the human's driver-based script: one SQL statement in on stdin, sent with the
# extended query protocol (which refuses a second one, so a SET can't lift the timeout), CSV
# out, and the driver's own errors on stderr, for the human.
PGPASSWORD="$(security find-generic-password -s prod-db-ro -w)" \
  exec "$HOME/.priviledge/bin/sqlquery" \
  "host=... user=app_ro dbname=... options='-c statement_timeout=60s'"
```

- `sqlquery` is a single-file Python script run by uv, with its database driver pinned inline
  (`#!/usr/bin/env -S uv run --script`): the standard library has no Postgres driver, and the
  dependency belongs to this resource, not to priviledge. It reads one statement from stdin, sends
  it as a prepared statement (the extended query protocol, which refuses a second statement, so a
  `SET` can't lift the timeout), writes CSV to stdout, forwards the server's own error message to
  stdout (a syntax error or an unknown column is useful to the agent and names no host), and keeps
  connection errors on stderr. It is built and tested in the core-loop iteration (DESIGN.md §11).
- Both check the shape of their input, not its meaning: which operations, not which data. What the
  credential can read is still exposed (SPEC.md §5, condition 2).
- For tools with a large input surface, running them confined is the stronger option: a disposable
  container that holds only this resource's credential and mounts nothing from the host
  (SPEC.md §8).
- **(verify)** that the aws CLI accepts global options after the operation, and that a running
  Postgres statement can't change its own timeout.

## 10. Editor, LSP and agent (inside the guest)

- nvim, its plugins and every LSP server run in the guest: basedpyright/pyright,
  typescript-language-server, lua_ls, and so on. The plugin manager and mason.nvim install into the
  home volume.
- The example uses opencode, which is open source. Any agent that runs shell commands works the
  same way, since it reaches priviledge only through the client's commands (SPEC.md §6); several
  agents can share one guest.
- The agent runs in the guest, logged in there, with its state in the home volume. That login is
  a credential in the guest (SPEC.md §3, known issue); for `public` and `hostile-*` guests, prefer
  an API key from a separate account with a spending limit. Its global instructions file is linked
  from the read-only dotfiles, so the source stays intact on the host; the agent could still replace
  the link in its own home, and instructions are not a security control (SPEC.md §3). Its permission
  settings should let the `priviledge` commands (SPEC.md §6) run without asking: they are how the
  agent asks, and the human answers in the approval pane, not in the agent's.
- Browser automation (Playwright and similar) runs inside the guest as well. Chromium's own
  sandbox may not start with all capabilities dropped; Playwright then needs Chromium's
  `--no-sandbox`, leaving the guest as the boundary **(verify)**.
- **Helping the agent's browser by hand** (logging into a restricted test account, getting it to
  the right page) means seeing and driving a browser that lives in the guest. The browser must
  stay there: one on the privileged side driven from the guest over CDP or Playwright's server
  would execute guest commands on the host (`file://` URLs, downloads to host paths, any URL),
  the reverse of the rendering exception in §12, and a way around egress. So the guest's browser
  runs headed under Xvfb, a VNC server with noVNC serves its screen on a second forwarded port,
  and the human drives it from the host browser: what reaches the host is noVNC's page, the same
  exception as a dev server **(verify)**. A lighter variant to try first: Chromium's remote
  debugging port through the forwarder, with the host browser's inspector screencast for seeing
  and clicking **(verify)**. Self-signed dev certificates need no interaction
  (`ignoreHTTPSErrors`). What the human types into that browser, the test account's password,
  becomes a credential in the guest: a native grant under SPEC.md §5, acceptable because the
  account's rights are restricted server-side.
- The git read-only token (SPEC.md §5) is the only native token, in a `trusted` guest's git
  credential store. Other read-only access (code host, error tracker, issue tracker) goes through
  priviledge resources.
- Per-path tool state (the agent's per-project memory, `mise trust`, `direnv allow`) initialises
  fresh in the guest. Existing checkouts are not migrated; clone fresh.

## 11. Git: clone, review, push, deploy

**In the guest:** a `trusted` guest clones with a **read-only** upstream token (HTTPS, stored in
the guest's git credential store); a `public` guest clones public repos anonymously. Fetch and pull
work; push is rejected by the server.

**On the privileged side:** a clean clone per repo, with the guest as a remote through git's
`ext::` transport, which runs git's protocol over the same command `guest_exec` uses (§14):

```sh
git clone git@git.example.com:org/shop-app.git ~/src-clean/shop-app
cd ~/src-clean/shop-app
git remote add aiws 'ext::docker --context colima-aiws exec -i aiws-trusted-shop %S /home/aiws/src/shop-app'
git config protocol.ext.allow user
git config transfer.fsckObjects true
```

- `protocol.ext.allow user` allows `ext::` only for commands the human runs. git treats `ext::`
  as dangerous by default because a URL can run commands; `user` keeps it blocked for URLs coming
  from fetched content, such as submodules.
- `git fetch aiws <branch>` runs `git-upload-pack` inside the guest. On the host, git only
  receives and parses pack data, which is inert until checked out: the same trust model as
  fetching from any remote. `transfer.fsckObjects` makes git check every fetched object, and
  refuse malformed ones, before storing it.
- A `public` guest of the same project gets its own remote (`aiws-public`).

**Short-lived fetch tokens (optional).** Instead of a stored token, a git credential helper in the
guest asks priviledge for one on each use. A `git-token` resource mints a short-lived, read-only
token (for example a one-hour app installation token) and prints it in git's credential format;
auto-approved and released unreviewed in `trusted`. The token still enters the guest (SPEC.md
§5), but it expires, and every use is in the audit log. **(verify)**

```sh
#!/bin/sh
# ~/.local/bin/git-credential-priviledge, in the guest: git config credential.helper priviledge
[ "$1" = get ] || exit 0
id=$(priviledge request git-token -r "git credential for a fetch" </dev/null) &&
  priviledge wait "$id" && exec priviledge retrieve "$id"
```

**Two-pass review:**

1. *Comprehension pass* in the guest, with full nvim and LSP navigation. Comfortable, but not
   authoritative: the tooling there is agent-controlled (git diff drivers and textconv, pagers,
   editor plugins can render something other than the commit's content). Matching SHAs
   afterwards only proves which commit it was, not what was displayed.
2. *Authoritative pass* in the clean clone over the fetched objects, in a git tool that does not
   run project code: Sublime Merge (syntax-highlighted; a small parsing risk, like any
   highlighter), `git` + `delta` + `less`, or `git log -p` piped into the review nvim of §8. It is
   quick because the change is already understood: it checks that the change is what was
   reviewed and catches anything new.

**Push and deploy:**

```sh
git fetch aiws feature-x
git log -p origin/develop..aiws/feature-x                  # or Sublime Merge
git push origin aiws/feature-x:refs/heads/feature-x        # full destination ref: the source is a remote-tracking branch
git worktree add ../shop-app-deploy <reviewed-sha>         # deploys run from here
```

Deploying runs code written in the guest with privileges. That is the reviewed-code exception of
SPEC.md §3: the guarantee is that what runs is exactly what was reviewed.

## 12. Dev services and dev servers

- The human runs each project's compose from the clean clone at a reviewed commit, so review
  covers its mounts, privileges and build contexts.
- A privileged-owned override (`~/.aiws/overrides/example.yml` shows one) moves every service onto
  the guest's network only, and drops its published ports:

  ```sh
  docker --context colima-aiws compose -f docker-compose.yml -f ~/.aiws/overrides/shop-app.yml up -d
  ```

  Checked with Compose 5.5: a service defined with two networks and a published port came up on
  the guest's network only, with none published (`!override` and `!reset` need Compose 2.24 or
  later). Create the guest first: it creates the network. Build contexts are sent by the client,
  but files a compose file bind-mounts from the clean clone must be visible in the VM: add the
  clean clones to the VM's mounts, read-only (§2).
- **Why only the guest's network.** The guest can take over what it reaches: with the dev
  database's superuser, which dev setups usually hand out, `COPY ... TO PROGRAM` runs a program
  inside the service's container. A service that also had a normal network would give the guest
  a route around its egress proxy, to the internet, the host's loopback and the local network.
  On the internal network, services still reach each other by name and the daemon still pulls
  their images; one that needs the internet at run time gives its guest that route, which is
  never acceptable for `public`. The human reaches a dev database from the guest, or with
  `docker --context colima-aiws compose exec` from the clean clone.
- The guest reaches services by name (`psql -h app-postgres`). Projects that hard-code
  `localhost` need their host settings overridden in the guest's environment. HTTP services (a
  search engine on port 9200, say) also go in the guest's `AIWS_NO_PROXY` (§4), or clients send
  them to the egress proxy, which refuses them.
- **Dev servers run in the guest.** Services that call back into the dev server (a reverse proxy
  container, for example) must be attached to the guest's network in the override too, and point
  at the guest by name instead of the host. The human opens them in the browser through a port
  forwarded with `aiws port` (§4).
- **The browser is the one host program that runs guest-authored code**: the dev server's pages
  and scripts. It is accepted because rendering hostile pages in a sandbox is what a browser is
  for, and a dev server is at worst a malicious website. What the sandbox doesn't cover is handled
  around it: a separate browser profile with no extensions keeps real sessions and look-alike pages
  apart; the browser stays updated; and local services must not trust loopback callers (§13),
  since a page can send requests to any local port even though it can't read the answers.
- Dev databases that matter get snapshots or credentials: the guest can reach them.

## 13. Host exposure and hygiene

- **Host loopback.** In colima's VMs, containers on a normal network reach the host at
  `192.168.5.2` (`host.lima.internal`, also `host.docker.internal`), including services that
  listen only on the host's `127.0.0.1` (checked on colima 0.10.3). Guests in this setup are never
  on a normal network, nor are their dev services (§12), and their proxies refuse private
  addresses (§5), but the proxies and forwarders are. Anything the privileged side runs on
  localhost, and every forwarded port, is reachable from those, and from pages the browser renders
  from a guest (§12). Audit with `lsof -nP -iTCP -sTCP:LISTEN` and make sure nothing sensitive
  listens without authentication. priviledge itself listens on nothing.
- **What colima forwards to the host.** Ports the VM listens on are forwarded to the host: those on
  the VM's `127.0.0.1` to the host's loopback, those on `0.0.0.0` to all the host's interfaces,
  the local network included (colima's default, matching Docker's meaning of `-p 8000:8000`).
  Nothing this setup starts listens on `0.0.0.0` in the VM, and guests can't publish ports. A
  guest that escaped into its VM could, and would also have the VM's unfiltered outbound network;
  both are part of what an escape reaches. One quirk: the host shows colima listening on TCP port
  53 on all interfaces, for the VM's DNS forwarder; it accepts connections and resets them.
- **No secrets in guests.** Nothing from the privileged home is mounted into guests or their VMs
  except the read-only dotfiles and the exchange directories (§2).
- **Tracked secrets in repos** reach the guest with the clone. They are a team issue: rotate and
  remove.
- **The global gitignore** must reach guests through the dotfiles. Otherwise personal files
  ignored only by the host's global ignore become committable.

## 14. Other setups

The same priviledge configuration works with a different `guest_exec` template per profile:

| Setup | `guest_exec` | Notes |
|---|---|---|
| colima (this document) | `docker --context colima-aiws exec -i aiws-{profile}-{name}` | Dedicated VMs that see only their mounts; read-only enforced by the host |
| Docker Desktop, Podman machine | `docker exec -i aiws-{profile}-{name}` (or `podman`) | One VM shared with all the machine's containers: what an escape reaches is its file sharing, by default the whole home |
| Apple `container` (macOS 26) | `container exec -i aiws-{profile}-{name}` **(verify)** | One lightweight VM per container: a VM boundary between guests too. Same OCI images. A blocklist but no egress allow-list yet **(verify)**; the proxy sidecar of §5 still works |
| Lima VM | `limactl shell aiws-{profile}-{name}` or `ssh` **(verify)** | Full VM per guest; the agent can run its own Docker inside |
| Docker Sandboxes | its exec command, if it has one **(verify)** | microVM per sandbox with its own egress proxy; mounts the host project directory |
| Separate OS user | `ssh aiws-{profile}-{name}@127.0.0.1` or `sudo -u aiws-{profile}-{name}` | See below |

**On a Linux host,** containers share the host kernel directly, with no VM in between, and the
Docker daemon runs as root. A container escape is then a host compromise. colima runs on Linux too,
in a qemu VM, which keeps this setup's shape **(verify)**; otherwise prefer rootless Docker or
Podman, or a sandboxed runtime (gVisor, Kata).

**Separate OS user** (the only option with no runtime): one user per guest; close the privileged
home to them (`chmod o-rwx ~`; they are not in the privileged user's group), and give each its own
toolchains. For interactive panes, prefer `ssh` to loopback over `sudo -u`/`su`: on macOS `su` does
not allocate a new terminal, so the guest shell shares the privileged pane's terminal device. The
broker's connection has no terminal (it starts `guest_exec` detached, DESIGN.md §3), so `sudo -u` is
fine there; for the same reason sudo can't ask for a password, so it needs a `NOPASSWD` rule that
lets the privileged user run commands as the guest user (never the other way round). For ssh:
key-only logins restricted to `AllowUsers <user>@127.0.0.1 <user>@::1`, no forwarding of any kind,
and a dedicated key installed with `restrict,pty` (on macOS, launchd starts sshd on all interfaces
and may ignore `ListenAddress` **(verify)**). Never give such a user sudo to the privileged account,
including for Homebrew: sudo would authenticate the guest's own password, which other guest
processes can capture, and brew run as its owner with guest-influenced input is equivalent to a
shell as the owner. Its weak point is egress: restricting it per user needs packet-filter rules
keyed on uid (`pf` on macOS, nftables on Linux) **(verify)**, so until those exist it cannot make a
`public` profile real (SPEC.md §4, item 5).

## 15. Verification checklist

`aiws verify <profile> <name> [allowed-url]` runs the automatic part. It checks the container's
shape from the host (`docker inspect`), then pipes a script into the guest's shell and reads what
it prints, so nothing from the guest runs on the host. It exits non-zero if any check fails.

| Profile | Checks |
|---|---|
| all | not privileged; all capabilities dropped; `no-new-privileges`; own PID namespace; no runtime socket mounted; exactly the expected mounts |
| `trusted`, `public` | only on its internal network; dotfiles present, read-only, not writable; no Unix sockets besides the relay's; the proxy refuses a host off the allow-list with its own 403; `allowed-url`, if given, works |
| `trusted`, `public`, `hostile-web` | external names don't resolve; the proxy refuses the host and a private address; no route to the host or the internet around the proxy; other guests' containers don't resolve |
| `hostile-web` | the public internet works through the proxy |
| `hostile-sample` | no network, no routes, no connection to the internet |

Checked on colima 0.10.3 (Docker Engine in `vz` VMs) for all three profile shapes, including a
negative run: an `allowed-url` that is off the list fails. The rest is manual:

- What each VM sees of the host: `colima ssh -p aiws -- mount | grep virtiofs` lists exactly the
  configured mounts, writable only the exchange root (§2).
- `git push` to upstream from a guest is rejected by the server.
- An HTTP dev service listed in `AIWS_NO_PROXY` answers by name; a port forwarded with
  `aiws port` answers on `127.0.0.1` on the host.
- The proxy's log shows only allow-listed hosts passing (§5).
- Dev-service containers have no route out: `docker --context colima-aiws compose exec` into one
  and try an external address and `192.168.5.2`.
- Loopback listeners on the host (`lsof -nP -iTCP -sTCP:LISTEN`) are known and acceptable (§13).
- Once the core loop exists: `priviledge list` shows only this profile's resources, and stopping
  the guest's `priviledge serve` makes `request` fail fast.
