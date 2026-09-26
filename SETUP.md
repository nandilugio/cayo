# priviledge — reference setup (draft)

Status: draft. This describes **one** way to deploy the AI workspace around priviledge: Docker
containers on macOS. priviledge itself does not depend on it; it only needs the deployment contract
in [SPEC.md §4](SPEC.md#4-deployment-contract); how priviledge uses the channel is in
[DESIGN.md §2](DESIGN.md#2-channel-and-relay). Other setups are sketched in §10. Items marked
**(verify)** must be checked on the real machine. Every command here changes the machine's
configuration, so the human reviews and runs it.

Terms (guest, privileged side, broker) are as defined in [SPEC.md §3](SPEC.md#3-threat-model).

## 1. Overview

```
host: privileged side                            Docker VM
┌───────────────────────────────────────┐   ┌──────────────────────────────────┐
│ terminal + tmux                       │   │ guest aiws-shop (container)      │
│   panes: docker exec -it aiws-shop …  │──▶│   nvim + LSP, claude, tests,     │
│   pane:  priviledge serve aiws-shop    │──▶│   dev servers, priviledge relay   │
│ secrets, priviledge config             │   │   repos in a volume              │
│ clean clones (review, push, deploy)   │   │   dotfiles mounted read-only     │
│ docker CLI (runtime control)          │   ├──────────────────────────────────┤
│ browser                               │   │ dev services (project compose)   │
└───────────────────────────────────────┘   │ on the guest's network           │
                                            └──────────────────────────────────┘
```

- One guest (container) per project, i.e. per trust domain. Many sessions (nvim, several agents,
  shells) run inside the same guest.
- On macOS, all containers run inside the runtime's Linux VM, so the host is behind a VM boundary.
  Guests are separated from each other by kernel namespaces inside that VM, which is weaker but
  adequate for project-vs-project trust.
- The privileged side drives guests only through the runtime's CLI, and never runs code written in
  a guest except reviewed code at a pinned commit (§7, §8).

## 2. Container runtime

Any runtime with a Docker-compatible CLI works: Docker Desktop, colima, Podman. priviledge only needs
`exec -i`.

- **Licensing:** Docker Desktop is free for personal use and for companies with fewer than 250
  employees *and* less than $10M revenue; beyond that it needs a paid subscription. colima and
  Podman are free. OrbStack is paid for commercial use.
- **File sharing:** restrict the runtime's shared host paths to what containers actually mount:
  the dotfiles and exchange directories (§3), and the clean-clone paths that project compose files
  bind-mount (§8). Not all of `/Users`. If a guest escaped into the runtime's VM, it would reach
  whatever the VM can see, including those clean clones. **(verify)** that Docker Desktop allows
  removing the default paths.
- **Never** give a guest the runtime's control socket (`/var/run/docker.sock` or equivalent),
  `privileged: true`, host networking, or the host PID namespace. Any of these hands the guest the
  privileged side.

## 3. Guests

Guests are defined in a privileged-owned compose file, so their configuration is out of the
guests' reach.

```yaml
# ~/.config/aiws/compose.yml
name: aiws
services:
  shop:
    image: aiws-base
    container_name: aiws-shop
    hostname: aiws-shop
    init: true
    command: sleep infinity
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    environment:
      TERM: xterm-256color
    networks: [shop]
    ports:
      - "127.0.0.1:5000:5000"                             # dev servers opened in the browser
    volumes:
      - shop-home:/home/aiws                              # repos, caches, toolchains, agent state
      - ${HOME}/.config/aiws/dotfiles:/home/aiws/.dotfiles:ro
      - ${HOME}/aiws-exchange/shop:/home/aiws/exchange    # file exchange, data only

networks:
  shop:
    name: aiws-shop        # one network per project

volumes:
  shop-home:
```

- **Repos live in the guest's home volume**, not on the host filesystem. The privileged side can't
  accidentally run git or an editor against them; it reaches them only through the `ext::` remote
  (§7).
- **Dotfiles are mounted read-only**: nvim config, shell config, git config (no credentials), the
  global gitignore, Claude Code's global instructions. Change them once on the host and every guest
  sees it. Inside the guest, link them into place once (`ln -s ~/.dotfiles/nvim ~/.config/nvim`).
  They must never contain secrets.
- **The exchange directory** is the one writable host path, for screenshots, CSVs and similar.
  Create it before the first `up`. On the host, treat its contents like untrusted downloads. The
  guest can also create symlinks there that point at host paths: a host tool that follows one
  reads or overwrites the host file. Don't write into the directory over existing names, and
  check with `ls -l` before opening what's there.
- **Published ports** are bound to `127.0.0.1` and chosen per project to avoid clashes. Dev servers
  must listen on `0.0.0.0` *inside* the guest for the published port to reach them (Django's dev
  server, for one, defaults to `127.0.0.1`). Published ports are also reachable from other guests
  (§9), so the per-project network only isolates unpublished ports.
- Adding a project is a new service, network and volume in this file, plus a guest entry in
  priviledge's config (SPEC.md §8):

  ```toml
  [guests.aiws-shop]
  channel = ["docker", "exec", "-i", "aiws-shop"]
  resources = [...]
  ```

## 4. Image

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
RUN useradd -m -s /bin/zsh aiws
USER aiws
WORKDIR /home/aiws
```

- **Install image-managed tools system-wide**, never into `/home/aiws`. The home is a volume:
  Docker copies the image's home into it only when the volume is first created, so later image
  updates to anything under the home would never reach the guest.
- **Per-user and self-updating tools live in the home volume** and are installed from inside the
  guest: Claude Code (it self-updates), mise-managed toolchains (Python, Node, Java,
  Go), nvim plugins and LSP servers. Baking toolchains into per-project images (`FROM aiws-base`)
  is the more reproducible option once they settle.
- No sudo in the guest; `cap_drop` and `no-new-privileges` would defeat it anyway. Installing
  system packages means rebuilding the image from the privileged side.
- The guest's copy of priviledge is only the client and relay, and must be on the default `PATH`
  (the channel command runs it without a login shell). Its integrity doesn't matter; it only has
  to speak a protocol version the broker accepts (DESIGN.md §3).
- The broker's copy is what matters (SPEC.md §3): install it on the host from a privileged-owned
  clean clone at a reviewed tag, never from a guest.
- Create `~/src` in the guest once; the `aiws` helper (§5) starts there.

## 5. Terminal and tmux (privileged side)

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

A helper to enter a guest, and a per-project window:

```sh
#!/bin/sh
# ~/bin/aiws: aiws <project> [command...]
p=$1; shift
[ $# -gt 0 ] || set -- zsh
exec docker exec -it -w /home/aiws/src "aiws-$p" "$@"
```

```sh
#!/bin/sh
# ~/bin/aiws-window: aiws-window <project>
p=$1
tmux new-window -n "$p" "aiws $p nvim"
tmux split-window -h "aiws $p claude"
tmux split-window -v "aiws $p"
tmux split-window -v "priviledge serve aiws-$p"     # approvals for this project
```

- `docker exec -it` allocates a terminal inside the guest. The privileged pane only relays bytes,
  so no terminal device is shared with the guest. What remains is escape sequences in guest
  output, which is why clipboard reads are denied and priviledge escapes agent text.
- The terminal's `TERM` (`xterm-ghostty`, say) needs its terminfo in the image. Either
  install it or use `xterm-256color`, as in §3.
- A privileged window holds a shell in the clean clones (§7) for review, push, deploy and project
  compose.

## 6. Editor, LSP and agent (inside the guest)

- nvim, its plugins and every LSP server run in the guest: ruby-lsp, typescript-language-server,
  basedpyright/pyright, lua_ls, and so on. The plugin manager and mason.nvim install into the home
  volume.
- VS Code, optionally, with Dev Containers' "Attach to Running Container", which runs the VS Code
  server and its extensions inside the guest.
- Claude Code runs in the guest, logged in there, with its state in the home volume. Its global
  `CLAUDE.md` is linked from the read-only dotfiles, so the source stays intact on the host. The
  agent could still replace the link in its own home; instructions are not a security control
  (SPEC.md §3). Its permission allow-list includes `Bash(priviledge list)`,
  `Bash(priviledge describe:*)`, `Bash(priviledge run:*)` and `Bash(priviledge wait:*)`.
- Browser automation (Playwright and similar) runs inside the guest as well. Chromium's own
  sandbox may not start with all capabilities dropped; Playwright then needs Chromium's
  `--no-sandbox`, leaving the guest as the boundary **(verify)**.
- Native read-only tokens (SPEC.md §5) live in the guest's environment or config.
- Per-path tool state (Claude Code's per-project memory, `mise trust`, `direnv allow`) initialises
  fresh in the guest. Existing checkouts are not migrated; clone fresh.

## 7. Git: clone, review, push, deploy

**In the guest:** clone with a **read-only** upstream token (HTTPS, stored in the guest's git
credential store). Fetch and pull work; push is rejected by the server.

**On the privileged side:** a clean clone per repo, with the guest as a remote through git's
`ext::` transport, which runs git's protocol over the channel command:

```sh
git clone git@git.example.com:org/shop-app.git ~/src-clean/shop-app
cd ~/src-clean/shop-app
git remote add aiws 'ext::docker exec -i aiws-shop %S /home/aiws/src/shop-app'
git config protocol.ext.allow user
```

- `protocol.ext.allow user` allows `ext::` only for commands the human runs. git treats `ext::`
  as dangerous by default because a URL can run commands; `user` keeps it blocked for URLs coming
  from fetched content, such as submodules.
- `git fetch aiws <branch>` runs `git-upload-pack` inside the guest. On the host, git only
  receives and parses pack data, which is inert until checked out: the same trust model as
  fetching from any remote.

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
git worktree add ../shop-app-deploy <reviewed-sha>         # deploys and tofu run from here
```

Deploying runs code written in the guest with privileges. That is the reviewed-code exception of
SPEC.md §3: the guarantee is that what runs is exactly what was reviewed.

## 8. Dev services and dev servers

- The human runs each project's compose from the clean clone at a reviewed commit, so review
  covers its mounts, privileges and build contexts.
- A privileged-owned override attaches the services to the guest's network and keeps any
  published ports on loopback:

  ```yaml
  # ~/.config/aiws/overrides/shop-app.yml
  services:
    app-postgres:
      networks: [default, aiws]
      ports: !override ["127.0.0.1:5432:5432"]
  networks:
    aiws:
      name: aiws-shop
      external: true
  ```

  `docker compose -f docker-compose.yml -f ~/.config/aiws/overrides/shop-app.yml up -d`
  (`!override` needs a recent Compose **(verify)**). Start the guests first: they create the
  network.
- The guest reaches services by name (`psql -h app-postgres`). Projects that hard-code
  `localhost` need their host settings overridden in the guest's environment.
- **Dev servers run in the guest.** Services that call back into the dev server (a reverse proxy
  container, for example) must be attached to the guest's network in the override too, and point
  at the guest by name instead of `host.docker.internal`. The
  human opens them in the browser through the guest's published ports (§3), preferably in a
  separate browser profile from the one holding real sessions.
- Dev databases that matter get snapshots or credentials: the guest can reach them.

## 9. Host exposure and hygiene

- **Host loopback.** On Docker Desktop, containers can reach services listening on the host's
  loopback through `host.docker.internal` **(verify)**. That includes other guests' and dev
  services' published ports, and anything the privileged side runs on localhost. Audit with
  `lsof -nP -iTCP -sTCP:LISTEN` and make sure nothing sensitive listens without authentication.
  priviledge itself listens on nothing.
- **No secrets in guests.** Nothing from the privileged home is mounted except the read-only
  dotfiles and the exchange directory.
- **Tracked secrets in repos** reach the guest with the clone. They are a team issue: rotate and
  remove.
- **The global gitignore** must reach guests through the dotfiles. Otherwise personal files
  ignored only by the host's global ignore become committable.

## 10. Other setups

The same priviledge configuration works with a different `channel` per guest:

| Setup | Channel | Notes |
|---|---|---|
| Docker / colima / Podman (this document) | `docker exec -i aiws-<p>` | VM boundary to the host on macOS |
| Apple `container` (macOS 26) | `container exec -i aiws-<p>` **(verify)** | One lightweight VM per container: a VM boundary between guests too. Same OCI images |
| Lima VM | `limactl shell aiws-<p>` or `ssh` **(verify)** | Full VM per guest; the agent can run its own Docker inside |
| Docker Sandboxes | its exec command, if it has one **(verify)** | microVM per sandbox; mounts the host project directory |
| Separate OS user | `ssh aiws@127.0.0.1` or `sudo -u aiws` | See below |

**On a Linux host,** containers share the host kernel directly, with no VM in between, and the
Docker daemon runs as root. A container escape is then a host compromise. Prefer rootless Docker
or Podman, a sandboxed runtime (gVisor, Kata), or VMs.

**Separate OS user** (the lightest option, no runtime): create the user, close the privileged home
to it (`chmod o-rwx ~`; the user is not in the privileged user's group), and give it its own
toolchains. For interactive panes, prefer `ssh` to loopback over `sudo -u`/`su`: on macOS `su`
does not allocate a new terminal, so the guest shell shares the privileged pane's terminal device.
The channel has no terminal (the broker starts it detached, DESIGN.md §2), so `sudo -u aiws` is
fine there. For ssh: key-only
logins restricted to `AllowUsers aiws@127.0.0.1 aiws@::1`, no forwarding of any kind, and a
dedicated key installed with `restrict,pty` (on macOS, launchd starts sshd on all interfaces and
may ignore `ListenAddress` **(verify)**). Never give this user sudo to the privileged account,
including for Homebrew: sudo would authenticate the guest's own password, which other guest
processes can capture, and brew run as its owner with guest-influenced input is equivalent to a
shell as the owner.

## 11. Verification checklist

From inside a guest:

- `ls /Users` fails: no host paths.
- `touch ~/.dotfiles/x` fails: dotfiles are read-only.
- There is no runtime socket (`ls -l /var/run/docker.sock` fails) and `docker ps` fails.
- `git push` to upstream is rejected by the server.
- Other guests don't resolve (`getent hosts aiws-<other>` fails).
- `priviledge list` shows only this guest's resources. Stopping the project's `priviledge serve`
  makes `run` fail fast.

From the host:

- The runtime's shared paths are only the dotfiles, exchange and clean-clone directories.
- Loopback listeners reachable via `host.docker.internal` are known and acceptable.
