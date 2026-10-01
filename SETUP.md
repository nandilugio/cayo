# priviledge — reference setup (draft)

Status: draft. This describes **one** way to deploy the AI workspace around priviledge: Docker
containers on macOS. priviledge itself does not depend on it; it only needs the deployment contract
in [SPEC.md §4](SPEC.md#4-deployment-contract); how priviledge reaches a guest is in
[DESIGN.md §3](DESIGN.md#3-channel-and-relay). Other setups are sketched in §14. Items marked
**(verify)** must be checked on the real machine. Every command here changes the machine's
configuration, so the human reviews and runs it.

Terms (guest, profile, privileged side, broker) are as defined in
[SPEC.md §3](SPEC.md#3-threat-model).

## 1. Overview

```
host: privileged side                         Docker VM
┌─────────────────────────────────────────┐   ┌──────────────────────────────────┐
│ terminal + tmux                         │   │ guest aiws-trusted-shop          │
│   panes: docker exec -it … aiws-…       │──▶│   nvim + LSP, claude, tests,     │
│   pane:  priviledge serve trusted shop  │──▶│   dev servers, priviledge relay  │
│ secrets, priviledge config              │   │   repos in a volume              │
│ clean clones (review, push, deploy)     │   │   dotfiles mounted read-only     │
│ docker CLI (runtime control)            │   ├──────────────────────────────────┤
│ browser                                 │   │ egress proxy, port forwarder     │
└─────────────────────────────────────────┘   │ dev services (project compose)   │
                                              └──────────────────────────────────┘
```

- A **guest** is a container created on demand from a **profile** (SPEC.md §3): the profile decides
  the image, what is mounted, and the egress policy. `aiws new trusted shop` creates
  `aiws-trusted-shop`; `priviledge serve trusted shop` brokers for it.
- One guest per project and profile, i.e. per trust domain. Many sessions (nvim, several agents,
  shells) run inside the same guest.
- On macOS, all containers run inside the runtime's Linux VM, so the host is behind a VM boundary.
  Guests are separated from each other by kernel namespaces inside that VM, which is weaker but
  adequate for project-vs-project trust. It is not adequate for `hostile-sample` guests, which run
  exploit material next to the trusted guests' kernel: run those in a separate VM (§14).
- The privileged side drives guests only through the runtime's CLI, and never runs code written in
  a guest except reviewed code at a pinned commit (§11, §12).

## 2. Container runtime

Any runtime with a Docker-compatible CLI works: Docker Desktop, colima, Podman. priviledge only
needs `exec -i`.

- **Licensing:** Docker Desktop's licence depends on your situation; colima and Podman are free.
- **File sharing:** restrict the runtime's shared host paths to what containers actually mount:
  the dotfiles and exchange directories (§4), and the clean-clone paths that project compose files
  bind-mount (§12). Not all of `/Users`. If a guest escaped into the runtime's VM, it would reach
  whatever the VM can see, including those clean clones. **(verify)** that Docker Desktop allows
  removing the default paths.
- **Never** give a guest the runtime's control socket (`/var/run/docker.sock` or equivalent),
  `privileged: true`, host networking, or the host PID namespace. Any of these hands the guest the
  privileged side.

## 3. Profiles

Each profile in priviledge's configuration (SPEC.md §8) is implemented here as a guest shape. The
reference set:

| Profile | Image | Mounted | Native tokens | Egress (§5) |
|---|---|---|---|---|
| `trusted` | `aiws-base` | home volume, dotfiles (ro), exchange | git read-only token | proxy, allow-list |
| `public` | `aiws-base` | same | none (public repos clone anonymously) | proxy, allow-list |
| `hostile-web` | `aiws-base` | fresh home volume, exchange only | none | proxy, public internet only |
| `hostile-sample` | `aiws-base` | fresh home volume, exchange only | none | none (`--network none`) |

`hostile-*` guests are meant to be disposable: created for the task, removed after (`aiws rm`).
No broker runs for them; results leave through the exchange directory, carried by the human.

Every guest that runs an agent also holds the agent's own login or key (§10), a known issue in
SPEC.md §3.

## 4. Guests

A guest is created by a small privileged-owned helper. Nothing about a guest's shape is decided
inside it.

```sh
#!/bin/sh
# ~/bin/aiws: aiws new <profile> <name> | aiws rm <profile> <name> | aiws <profile> <name> [cmd...]
set -e
cmd=$1; shift
case $cmd in
  new)
    p=$1; n=$2; g="aiws-$p-$n"
    case $n in                                 # this helper's naming needs it; priviledge doesn't
      ''|*-*) echo "guest names can't be empty or contain '-'" >&2; exit 64 ;;
    esac
    home="-v $g-home:/home/aiws -v $HOME/aiws-exchange/$g:/home/aiws/exchange"
    case $p in
      trusted|public) mounts="$home -v $HOME/.config/aiws/dotfiles:/home/aiws/.dotfiles:ro"
                      egress=allowlist ;;
      hostile-web)    mounts=$home; egress=public ;;
      hostile-sample) mounts=$home; egress=none ;;
      *) echo "unknown profile $p" >&2; exit 64 ;;
    esac
    docker volume create "$g-home" >/dev/null
    mkdir -p "$HOME/aiws-exchange/$g"
    if [ "$egress" = none ]; then
      net="--network none"
    else
      docker network create --internal "$g" >/dev/null
      aiws-egress "$g" "$egress"                          # proxy sidecar, §5
      px="http://$g-proxy:3128"; np="localhost,127.0.0.1${AIWS_NO_PROXY:+,$AIWS_NO_PROXY}"
      net="--network $g -e http_proxy=$px -e https_proxy=$px -e HTTP_PROXY=$px -e HTTPS_PROXY=$px
           -e no_proxy=$np -e NO_PROXY=$np"
    fi
    docker run -d --name "$g" --hostname "$g" --init \
      --cap-drop ALL --security-opt no-new-privileges:true \
      -e TERM=xterm-256color $net $mounts \
      aiws-base sleep infinity >/dev/null
    [ "$p" = hostile-sample ] || aiws-port "$g" "${AIWS_PORT:-8000}" ;;
  rm)
    p=$1; n=$2; g="aiws-$p-$n"
    docker rm -f "$g" "$g-proxy" "$g-port" >/dev/null 2>&1 || true
    docker network rm "$g" >/dev/null 2>&1 || true
    docker volume rm "$g-home" ;;
  *)
    p=$cmd; n=$1; shift; [ $# -gt 0 ] || set -- zsh
    exec docker exec -it -w /home/aiws/src "aiws-$p-$n" "$@" ;;
esac
```

- **Repos live in the guest's home volume**, not on the host filesystem. The privileged side can't
  accidentally run git or an editor against them; it reaches them only through the `ext::` remote
  (§11).
- **Dotfiles are mounted read-only**: nvim config, shell config, git config (no credentials), the
  global gitignore, Claude Code's global instructions. Change them once on the host and every guest
  sees it. Inside the guest, link them into place once (`ln -s ~/.dotfiles/nvim ~/.config/nvim`).
  They must never contain secrets. `hostile-*` guests get no dotfiles: less to configure, and
  nothing of the human's in them.
- **The exchange directory** is the one writable host path, for screenshots, CSVs and similar.
  It is per guest (`~/aiws-exchange/<guest>`), so guests of different profiles never share one.
  On the host, treat its contents like untrusted downloads. The guest can also create symlinks
  there that point at host paths: a host tool that follows one reads or overwrites the host file.
  Don't write into the directory over existing names, and check with `ls -l` before opening
  what's there.
- **Proxy variables** are set in both spellings, because tools disagree on which they read (curl,
  for one, ignores an uppercase `HTTP_PROXY`). `AIWS_NO_PROXY` adds the project's HTTP dev services
  (§12), which would otherwise be sent to the proxy and refused.
- **Published ports.** Docker does not publish ports for a container that is only on an internal
  network, so a small forwarder does it (`aiws-port`, below): the host port, on `127.0.0.1`, is
  chosen per guest (`AIWS_PORT`, default 8000) to avoid clashes, and always leads to port 8000 in
  the guest, Django's default. Dev servers must listen on `0.0.0.0` *inside* the guest for the
  forwarder to reach them (Django's, for one, defaults to `127.0.0.1`). Published ports are
  reachable from other guests' networks through the host (§13), so they should not expose anything
  that trusts its callers.

```sh
#!/bin/sh
# ~/bin/aiws-port: aiws-port <guest> <host-port>, forwarded to port 8000 in the guest.
# Created on the bridge so its port can be published, then attached to the guest's network.
g=$1; port=$2
docker run -d --name "$g-port" --network bridge -p "127.0.0.1:$port:8000" \
  alpine/socat "TCP-LISTEN:8000,fork,reuseaddr" "TCP:$g:8000" >/dev/null
docker network connect "$g" "$g-port"
```

## 5. Egress

Egress is part of a profile's C property (SPEC.md §3) and the deployment enforces it (SPEC.md §4,
item 5). The mechanism for every guest with a network: **the network denies, the proxy allows.**

- The guest is on an `--internal` Docker network, which has no route out. Non-HTTP TCP, UDP and
  external DNS simply have nowhere to go; the internal network blocks them, not the proxy. The
  guest resolves only local names; the proxy resolves the rest. **(verify)** that Docker's embedded
  DNS does not resolve external names for an internal network: if it did, DNS queries would be a
  way to carry data out.
- A proxy sidecar is on that network *and* a normal one, and is the guest's only way out. The
  guest's proxy variables point at it. Honouring them is voluntary, but a process that ignores them
  has no route at all.
- The proxy never connects to private, loopback or link-local addresses, which keeps the host,
  other containers and the local network out of reach, including through an allowed name that
  resolves to a private address.
- Two modes: `allowlist` (`trusted`, `public`) allows only listed hostnames; `public`
  (`hostile-web`) allows any public address. `hostile-sample` has no network at all.
- No TLS interception: the proxy sees hostnames, not contents, and the guest needs no extra CA.

```sh
#!/bin/sh
# ~/bin/aiws-egress: aiws-egress <guest> allowlist|public
g=$1; mode=$2; list=
if [ "$mode" = allowlist ]; then
  f=$HOME/.config/aiws/egress/$g.txt           # must exist: Docker would create a directory
  [ -f "$f" ] || { echo "missing allow-list $f" >&2; exit 1; }
  list="-v $f:/etc/squid/allow.txt:ro"
fi
docker run -d --name "$g-proxy" --network bridge $list \
  -v "$HOME/.config/aiws/egress/squid-$mode.conf:/etc/squid/squid.conf:ro" \
  ubuntu/squid >/dev/null
docker network connect --alias "$g-proxy" "$g" "$g-proxy"
```

```
# ~/.config/aiws/egress/squid-allowlist.conf (the relevant part)
acl private dst 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.0/8
acl private dst 169.254.0.0/16 ::1 fc00::/7 fe80::/10
acl allowed dstdomain "/etc/squid/allow.txt"
acl SSL_ports port 443
acl CONNECT method CONNECT
http_access deny private
http_access deny CONNECT !SSL_ports
http_access allow allowed
http_access deny all
http_port 3128

# ~/.config/aiws/egress/squid-public.conf: the same, without `allowed`, ending in
http_access deny private
http_access deny CONNECT !SSL_ports
http_access allow all
```

```
# ~/.config/aiws/egress/aiws-trusted-shop.txt
.anthropic.com
.githubusercontent.com
pypi.org
.pythonhosted.org
.npmjs.org
...
```

Notes:

- **(verify)** on Docker Desktop: that a container on an `--internal` network cannot reach
  `host.docker.internal`, that the proxy and the forwarder are reachable from it, and that the
  forwarder's published port reaches the guest.
- Squid is the boring choice. iron-proxy is the alternative when credential injection is wanted
  (the guest holds a placeholder token, the proxy swaps in the real one at egress, so git's native
  token, SPEC.md §5, never enters the guest), at the cost of terminating TLS: every client in the
  guest must trust its CA.
- Denied hosts are logged by the proxy; reviewing that log is how allow-lists grow. Approval of new
  hosts through priviledge is in the backlog (SPEC.md §10).
- An allowed host that stores data for any account can carry data out (SPEC.md §3), and in
  `trusted` the list also decides what strangers' text the agent reads. Keep such hosts off it
  where the work allows: `pypi.org` without the leading dot excludes `upload.pypi.org`, and pip
  downloads from `files.pythonhosted.org`. Where one host serves both, as npm's registry does, and
  for the agent's own model API, output review is the control.

## 6. Image

A base image with the shared tooling, running as a non-root user:

```dockerfile
# ~/.config/aiws/Dockerfile
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git less openssh-client ripgrep fd-find zsh \
      build-essential postgresql-client locales \
    && rm -rf /var/lib/apt/lists/*
# Also install system-wide (under /usr/local): a current nvim release, mise, and the priviledge
# client/relay.
RUN useradd -m -s /bin/zsh aiws && mkdir /home/aiws/src && chown aiws /home/aiws/src
USER aiws
WORKDIR /home/aiws
```

- **Install image-managed tools system-wide**, never into `/home/aiws`. The home is a volume:
  Docker copies the image's home into it only when the volume is first created, so later image
  updates to anything under the home would never reach the guest.
- **Per-user and self-updating tools live in the home volume** and are installed from inside the
  guest: Claude Code (it self-updates), mise-managed toolchains (Python, Node, Java, Go), nvim
  plugins and LSP servers. Baking toolchains into per-project images (`FROM aiws-base`)
  is the more reproducible option once they settle.
- No sudo in the guest; `cap_drop` and `no-new-privileges` would defeat it anyway. Installing
  system packages means rebuilding the image from the privileged side.
- The guest's copy of priviledge is only the client and relay, and must be on the default `PATH`
  (`guest_exec` runs it without a login shell). Its integrity doesn't matter; it only has
  to speak a protocol version the broker accepts (DESIGN.md §4).
- The broker's copy is what matters (SPEC.md §3): install it on the host from a privileged-owned
  clean clone at a reviewed tag, never from a guest.

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

A per-guest window:

```sh
#!/bin/sh
# ~/bin/aiws-window: aiws-window <profile> <name>
p=$1; n=$2
tmux new-window -n "$p/$n" "aiws $p $n nvim"
tmux split-window -h "aiws $p $n claude"
tmux split-window -v "aiws $p $n"
tmux split-window -v "priviledge serve $p $n"       # approvals for this guest
```

- `docker exec -it` allocates a terminal inside the guest. The privileged pane only relays bytes,
  so no terminal device is shared with the guest. What remains is escape sequences in guest
  output, which is why clipboard reads are denied and priviledge escapes agent text.
- The terminal's `TERM` (`xterm-ghostty`, say) needs its terminfo in the image. Either
  install it or use `xterm-256color`, as in §4.
- A privileged window holds a shell in the clean clones (§11) for review, push, deploy and project
  compose.

## 8. Review tools (privileged side)

The approval prompt shows escaped plain text; any richer view comes from the pager and editor the
human configures (SPEC.md §7). They run as the privileged user over agent-authored content, so the
choice matters:

- `$PRIVILEDGE_REVIEW_PAGER` and `$PRIVILEDGE_REVIEW_EDITOR` are argv strings, run without a shell.
- The default pager is `less -+r -+R --no-lessopen`. Shell setups often export `LESS=-R`, which
  would pass escape sequences to the terminal; `-+` resets those options whatever `LESS` says. Many
  systems set `LESSOPEN` to a lesspipe script that runs other programs over the file.
- The default editor, `vi`, is vim on many systems and loads the human's own vimrc and plugins,
  with modelines on. Set `$PRIVILEDGE_REVIEW_EDITOR` explicitly rather than relying on it.
- A minimal nvim serves as both, the pager in read-only mode:

  ```
  PRIVILEDGE_REVIEW_PAGER="env NVIM_APPNAME=priviledge-review nvim -R"
  PRIVILEDGE_REVIEW_EDITOR="env NVIM_APPNAME=priviledge-review nvim"
  ```

  `NVIM_APPNAME` gives it its own configuration and plugin directories
  (`~/.config/priviledge-review/`, privileged-owned). `-u <file>` alone is not enough: nvim still
  loads plugins from the normal configuration and data directories. In that configuration: syntax
  colouring (vim syntax or treesitter), `set nomodeline`, no plugins that execute anything, no LSP,
  and `set noswapfile noundofile shada=` so that no copy of the reviewed content (unredacted
  output, say) outlives the review.
- Human resources (SPEC.md §8) open the same editor on an empty file for the answer.
- Diff review before a push uses a git tool that does not run project code (§11).

## 9. Resources (privileged side)

Resource executables are the human's, written to the contract and the three properties in
SPEC.md §8. Two examples for the resources in SPEC.md's example configuration:

```sh
#!/bin/sh
# ~/.config/priviledge/resources/aws-readonly
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
AWS_CONFIG_FILE="$HOME/.config/priviledge/aws/readonly.config" \
AWS_SHARED_CREDENTIALS_FILE="$HOME/.config/priviledge/aws/readonly.credentials" \
  exec aws "$@"
```

```sh
#!/bin/sh
# ~/.config/priviledge/resources/prod-db-ro
# `sqlquery` is the human's driver-based script: one SQL statement in on stdin, sent with the
# extended query protocol (which refuses a second one, so a SET can't lift the timeout), CSV
# out, and the driver's own errors on stderr, for the human.
PGPASSWORD="$(security find-generic-password -s prod-db-ro -w)" \
  exec "$HOME/.config/priviledge/bin/sqlquery" \
  "host=... user=app_ro dbname=... options='-c statement_timeout=60s'"
```

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
- VS Code, optionally, with Dev Containers' "Attach to Running Container", which runs the VS Code
  server and its extensions inside the guest.
- Claude Code runs in the guest, logged in there, with its state in the home volume. That login is
  a credential in the guest (SPEC.md §3, known issue); for `public` and `hostile-*` guests, prefer
  an API key from a separate account or workspace with a spending limit. Its global
  `CLAUDE.md` is linked from the read-only dotfiles, so the source stays intact on the host. The
  agent could still replace the link in its own home; instructions are not a security control
  (SPEC.md §3). Its permission allow-list includes `Bash(priviledge list)`,
  `Bash(priviledge describe:*)`, `Bash(priviledge request:*)`, `Bash(priviledge wait:*)`,
  `Bash(priviledge retrieve:*)`, `Bash(priviledge pending)` and `Bash(priviledge cancel:*)`.
- Browser automation (Playwright and similar) runs inside the guest as well. Chromium's own
  sandbox may not start with all capabilities dropped; Playwright then needs Chromium's
  `--no-sandbox`, leaving the guest as the boundary **(verify)**.
- The git read-only token (SPEC.md §5) is the only native token, in a `trusted` guest's git
  credential store. Other read-only access (code host, error tracker, issue tracker) goes through
  priviledge resources.
- Per-path tool state (Claude Code's per-project memory, `mise trust`, `direnv allow`) initialises
  fresh in the guest. Existing checkouts are not migrated; clone fresh.

## 11. Git: clone, review, push, deploy

**In the guest:** a `trusted` guest clones with a **read-only** upstream token (HTTPS, stored in
the guest's git credential store); a `public` guest clones public repos anonymously. Fetch and pull
work; push is rejected by the server.

**On the privileged side:** a clean clone per repo, with the guest as a remote through git's
`ext::` transport, which runs git's protocol over the same command `guest_exec` uses:

```sh
git clone git@git.example.com:org/shop-app.git ~/src-clean/shop-app
cd ~/src-clean/shop-app
git remote add aiws 'ext::docker exec -i aiws-trusted-shop %S /home/aiws/src/shop-app'
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

**Two-pass review:**

1. *Comprehension pass* in the guest, with full nvim and LSP navigation. Comfortable, but not
   authoritative: the tooling there is agent-controlled (git diff drivers and textconv, pagers,
   editor plugins can render something other than the commit's content). Matching SHAs
   afterwards only proves which commit it was, not what was displayed.
2. *Authoritative pass* in the clean clone over the fetched objects, in a git tool that does not
   run project code: Sublime Merge (syntax-highlighted; a small parsing risk, like any
   highlighter), or `git` + `delta` + `less`. It is quick because the change is already
   understood: it checks that the change is what was reviewed and catches anything new.

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
- A privileged-owned override moves every service onto the guest's network only, and drops its
  published ports:

  ```yaml
  # ~/.config/aiws/overrides/shop-app.yml
  services:
    app-postgres:
      networks: !override [aiws]
      ports: !reset []
  networks:
    aiws:
      name: aiws-trusted-shop
      external: true
  ```

  `docker compose -f docker-compose.yml -f ~/.config/aiws/overrides/shop-app.yml up -d`
  (`!override` and `!reset` need a recent Compose **(verify)**). Create the guest first: it
  creates the network.
- **Why only the guest's network.** The guest can take over what it reaches: with the dev
  database's superuser, which dev setups usually hand out, `COPY ... TO PROGRAM` runs a program
  inside the service's container. A service that also had a normal network would give the guest
  a route around its egress proxy, to the internet, the host's loopback and the local network.
  On the internal network, services still reach each other by name and the daemon still pulls
  their images; one that needs the internet at run time gives its guest that route, which is
  never acceptable for `public`. The human reaches a dev database from the guest, or with
  `docker compose exec` from the clean clone.
- The guest reaches services by name (`psql -h app-postgres`). Projects that hard-code
  `localhost` need their host settings overridden in the guest's environment. HTTP services (a
  search engine on port 9200, say) also go in the guest's `AIWS_NO_PROXY` (§4), or clients send
  them to the egress proxy, which refuses them.
- **Dev servers run in the guest.** Services that call back into the dev server (a reverse proxy
  container, for example) must be attached to the guest's network in the override too, and point
  at the guest by name instead of `host.docker.internal`. The human opens them in the browser
  through the guest's forwarded port (§4), preferably in a separate browser profile from the one
  holding real sessions.
- Dev databases that matter get snapshots or credentials: the guest can reach them.

## 13. Host exposure and hygiene

- **Host loopback.** On Docker Desktop, containers on a normal network can reach services listening
  on the host's loopback through `host.docker.internal` **(verify)**. Guests in this setup are never
  on a normal network, nor are their dev services (§12), and their proxies refuse private addresses
  (§5), but the proxies and forwarders are. Anything the privileged side runs on localhost, and
  every published port, is reachable from those. Audit with `lsof -nP -iTCP -sTCP:LISTEN` and make
  sure nothing sensitive listens without authentication. priviledge itself listens on nothing.
- **No secrets in guests.** Nothing from the privileged home is mounted except the read-only
  dotfiles and the exchange directory.
- **Tracked secrets in repos** reach the guest with the clone. They are a team issue: rotate and
  remove.
- **The global gitignore** must reach guests through the dotfiles. Otherwise personal files
  ignored only by the host's global ignore become committable.

## 14. Other setups

The same priviledge configuration works with a different `guest_exec` template per profile:

| Setup | `guest_exec` | Notes |
|---|---|---|
| Docker / colima / Podman (this document) | `docker exec -i aiws-{profile}-{name}` | VM boundary to the host on macOS |
| Apple `container` (macOS 26) | `container exec -i aiws-{profile}-{name}` **(verify)** | One lightweight VM per container: a VM boundary between guests too. Same OCI images. A blocklist but no egress allow-list yet **(verify)**; the proxy sidecar of §5 still works |
| Lima VM | `limactl shell aiws-{profile}-{name}` or `ssh` **(verify)** | Full VM per guest; the agent can run its own Docker inside |
| Docker Sandboxes | its exec command, if it has one **(verify)** | microVM per sandbox with its own egress proxy; mounts the host project directory |
| Separate OS user | `ssh aiws-{profile}-{name}@127.0.0.1` or `sudo -u aiws-{profile}-{name}` | See below |

**On a Linux host,** containers share the host kernel directly, with no VM in between, and the
Docker daemon runs as root. A container escape is then a host compromise. Prefer rootless Docker
or Podman, a sandboxed runtime (gVisor, Kata), or VMs.

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

From inside a `trusted` or `public` guest:

- `/proc/self/mountinfo` shows no host paths besides the dotfiles and the exchange directory.
- `touch ~/.dotfiles/x` fails: dotfiles are read-only.
- There is no runtime socket: `find / -type s 2>/dev/null` lists nothing but the relay's.
- `git push` to upstream is rejected by the server.
- Other guests don't resolve (`getent hosts aiws-<other>` fails).
- `curl https://example.com` fails (not allow-listed); `curl https://<allowed host>` works;
  `curl http://host.docker.internal:<port>` fails, directly and through the proxy.
- `getent hosts example.com` fails: external names don't resolve in the guest.
- An HTTP dev service listed in `AIWS_NO_PROXY` answers by name.
- Once the core loop exists: `priviledge list` shows only this profile's resources, and stopping
  the guest's `priviledge serve` makes `request` fail fast.

From inside a `hostile-web` guest: `curl https://example.com` works;
`curl http://host.docker.internal` and an address on the local network both fail.

From inside a `hostile-sample` guest: no network at all (`ip route` shows nothing, and `curl` to
any address fails at once).

From the host:

- A dev server started in a guest answers on `http://127.0.0.1:<AIWS_PORT>`.
- The runtime's shared paths are only the dotfiles, exchange and clean-clone directories.
- Loopback listeners reachable via `host.docker.internal` are known and acceptable.
- The proxy's log shows only allow-listed hosts passing.
- Dev-service containers have no route out: from the clean clone, `docker compose exec` into one
  and try an external address and `host.docker.internal`.
