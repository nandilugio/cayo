# cayo

Isolated workspaces for AI agents, and for any other work you don't fully trust: each one a container in a VM of its own, seeing only what you give it and reaching the network only through an allow-list.

```
cayo vm start cayo                                  # the VM for trusted and public guests
cayo new trusted shop                               # a workspace for the "shop" project
cayo exec trusted shop                              # a shell in it: clone, code, run the agent
cayo allow trusted shop api.anthropic.com           # let it reach one more host
cayo verify trusted shop https://api.anthropic.com  # check its isolation
```

A *cayo* is a small island. **Status: early.** It runs on macOS with [colima](https://github.com/abiosoft/colima); Linux hosts should work the same way but are not checked yet. Nothing in a guest is special: it runs the editor, the agent and the project; you drive it from your terminal with `cayo exec`. It started as the reference deployment of [penyero](https://github.com/nandilugio/penyero), a broker that mediates agents' access to production, and stands on its own: penyero is optional.

## Why

AI coding agents work best with broad autonomy, and that autonomy is the risk. An agent that reads text an attacker wrote (an issue, a web page, a dependency) may follow instructions in it; no filter reliably prevents that. So cayo assumes the agent *will* eventually act on hostile input, and limits what that can reach:

- **The whole workspace is untrusted, not just the agent.** Your editor's language servers, tests, dev servers, installs and build scripts all run project code, which the agent may have written. They all live in the guest; you do your coding inside it too. The host never runs anything a guest can write, except reviewed code at a pinned commit (when you deploy it).
- **The guest is the unit of trust.** Processes inside one guest aren't isolated from each other, so isolation is per guest, never per session: one guest per project and trust level.
- **Secrets stay out.** Nothing from your home is mounted into a guest except a read-only directory you choose (your dotfiles, without secrets) and its exchange directory.
- **The network denies by default.** A guest reaches only the hosts on its allow-list, through a proxy, and never your host or local network.
- **Guests live in VMs that only see what cayo gives them.** An escape from a container lands in its VM, which sees the exchange directories and, read-only, your dotfiles: not your home.

### Trust profiles

The framing is Meta's *Agents Rule of Two*, with Simon Willison's *lethal trifecta*: [A] processing untrustworthy input, [B] reaching sensitive systems or private data, [C] sending data out. An agent with A and the ability to change sensitive state can do damage on its own; with A, private data and egress together, it can leak. A guest's **profile** fixes how much of each it gets:

| Profile | Meant for | VM | Gets | Egress |
|---|---|---|---|---|
| `trusted` | your own projects and vetted sources | `cayo` | your dotfiles, read-only | proxy, allow-list |
| `public` | open-source work: public issues, PRs, the web | `cayo` | your dotfiles, read-only (and you put no credentials in it) | proxy, allow-list |
| `hostile-web` | content that may target automated readers | `cayo-hostile` | nothing of yours | proxy, any public address; never the host or local network |
| `hostile-sample` | samples, exploits, CTF material | `cayo-hostile` | nothing of yours | none at all |

Hostile guests run in a VM of their own, so even an escape from one never meets a trusted guest. They are meant to be disposable: created for the task, removed after.

What cayo doesn't do: decide which credentials a guest may hold (keep write credentials out of guests that read untrusted input; [penyero](https://github.com/nandilugio/penyero) mediates privileged actions with human approval), protect production from malicious code that passes your review, or stop an escape from the VM itself (keep colima, Lima and macOS patched).

## Install

Requirements: macOS with [colima](https://github.com/abiosoft/colima) and the Docker CLI (`brew install colima docker`; `docker-compose`, as a CLI plugin, for dev services).

```sh
git clone https://github.com/nandilugio/cayo ~/.local/share/cayo
ln -s ~/.local/share/cayo/bin/cayo ~/.local/bin/
cayo vm start cayo
```

`cayo new` creates what it needs under `~/.cayo` (a guest's allow-list starts empty, so its proxy refuses everything until you allow hosts, unless `~/.cayo/egress/default.txt` gives new guests a starting list); the rest of the configuration is optional.

Install from a checkout you trust and don't let guests write to: the host runs these scripts with your privileges. If you develop cayo itself inside a guest, install from a clean clone at a reviewed commit, never from the guest's working copy.

## Configuration

The checkout holds the tool; `~/.cayo` holds yours. `examples/` has a template for each file.

```
~/.cayo/
├── config              settings: a shell file of CAYO_* variables (examples/config)
├── guest-init          run once in each new guest (examples/guest-init)
├── image/Dockerfile    your layer on the guest image, for every profile (examples/image.Dockerfile)
├── image/<profile>/Dockerfile   one profile's own layer
├── egress/<guest>.txt  each guest's allow-list (examples/allow-list.txt)
├── egress/default.txt  the hosts every new guest's list starts with, if you want any
└── overrides/          compose overrides per project (examples/override.yml)
~/cayo-exchange/<vm>/<guest>/   exchange directories: guest-written, so kept out of ~/.cayo
```

- **`config`**: `CAYO_DOTFILES` (a directory mounted read-only into `trusted` and `public` guests; default `~/.cayo/dotfiles`; may be a link to your dotfiles checkout; when it doesn't exist, guests get none and `cayo new` says so), `CAYO_DOTFILES_MOUNT` (where guests see it; default `/home/cayo/.dotfiles`), `CAYO_VM_MOUNTS` (more host paths for the `cayo` VM, read-only, space-separated), any `CAYO_INIT_*` variables for `guest-init`, and `CAYO_NO_PROXY` (hosts a guest reaches directly: its HTTP dev services; per project, so usually in the environment of `cayo new`).
- **`guest-init`**: `cayo new` pipes it into the new guest's shell, so it runs inside the guest as its user, with `CAYO_PROFILE`, `CAYO_NAME` and every `CAYO_INIT_*` variable (from `config` or the environment: `CAYO_INIT_GIT_EMAIL=you@example.com cayo new trusted shop`). Use it to link your dotfiles into place, set a git identity, install a shell framework. It never runs in hostile guests, which get nothing of yours, and `cayo recreate` doesn't run it again: the guest keeps its home.
- **`image/Dockerfile`** and **`image/<profile>/Dockerfile`**: your layers on the guest image (Image, below): the tools you want in every guest, and what one profile needs on top (or instead). Only what installs outside the home belongs in an image.
- **What to keep private.** The allow-lists, the overrides and the guest names all name your projects and the hosts you trust, so keep them local (they are in `~/.cayo`, not in the checkout). The rest (`config`, `guest-init`, `image/`) can live in a public dotfiles repository, as long as it holds no secrets.

## Commands

```
cayo new    <profile> <name>                create the guest cayo-<profile>-<name>
cayo rm     <profile> <name>                remove it, with its network, sidecars and home volume
cayo recreate <profile> <name>              recreate it from the current images, keeping its
                                            home volume and forwarded ports
cayo exec   <profile> <name> [cmd...]       run a command in it (default: a login shell)
cayo port   <profile> <name> <port>[:<guest-port>]
                                            forward 127.0.0.1:<port> on the host to the guest
cayo reload <profile> <name>                reload its proxy, after editing its allow-list
cayo denied <profile> <name>                the hosts its proxy refused, most frequent first
cayo allow  <profile> <name> <host>...      add hosts to its allow-list, and reload
cayo verify <profile> <name> [allowed-url]  check it against the checklist (Verification)
cayo build                                  rebuild the guest image in each running VM, with
                                            updated base and sidecar images
cayo vm start|stop|delete <vm>              create or start a VM (cayo, cayo-hostile) with its
                                            mounts; stop it; delete it with all its data
```

Guest names are letters, digits, `.` and `_`: no `-`, since cayo names a guest's network, volume and sidecars by appending to the container's name.

## How it works

```
host                                          colima VM cayo (trusted, public guests)
┌─────────────────────────────────────────┐   ┌──────────────────────────────────┐
│ terminal + tmux                         │   │ guest cayo-trusted-shop          │
│   panes: cayo exec … (docker exec -it)  │──▶│   editor + LSP, agent, tests,    │
│ your secrets and credentials            │   │   dev servers                    │
│ ~/.cayo (config, allow-lists)           │   │   repos in a volume              │
│ clean clones (review, push, deploy)     │   │   dotfiles mounted read-only     │
│ docker CLI, colima (runtime control)    │   ├──────────────────────────────────┤
│ browser                                 │   │ egress proxy, port forwarders    │
│                                         │   │ dev services (project compose)   │
└─────────────────────────────────────────┘   └──────────────────────────────────┘
                                              colima VM cayo-hostile (hostile-* guests)
```

### VMs

[colima](https://github.com/abiosoft/colima) runs Docker Engine in a [Lima](https://lima-vm.io) VM; both are open source. cayo gives guests two VMs of its own, `cayo` and `cayo-hostile`, and holds their one definition: `cayo vm start` runs `colima start` with each VM's full list of mounts. The `cayo` VM mounts its exchange root (`~/cayo-exchange/cayo`, writable), the dotfiles' real path and `CAYO_VM_MOUNTS`; `cayo-hostile` mounts only its own exchange root. Any other command whose VM isn't running stops and names the command that starts it.

- **Why VMs of its own.** A general-purpose runtime's VM usually sees your whole home (Docker Desktop shares `/Users` by default), and restricting it is a machine-wide setting other tools depend on. cayo's VMs see exactly their mounts, at the same paths, and nothing else. With colima's defaults on macOS (the `vz` VM type, virtiofs mounts), **the host enforces read-only**: checked on colima 0.10.3 (Lima 2.2.1), root inside the VM could neither write to a read-only mount, nor after remounting it read-write, nor after mounting the share again by its tag.
- **Your default Docker context stays yours.** `cayo vm start` passes `--activate=false`, which the VM's profile remembers; the commands select a VM explicitly (`docker --context colima-cayo`).
- **Changing mounts**: edit `config`, then `cayo vm stop cayo` and `cayo vm start cayo`. A running VM keeps the mounts it started with.
- **Lifecycle.** VMs don't start by themselves after a reboot: `cayo vm start <vm>`. A VM's configuration is in `~/.colima/<vm>/`, its Docker data (images, and every guest's home volume: repos, the agent's login) in a sparse disk under `~/.colima/_lima/_disks/`, the downloaded VM image in `~/Library/Caches/colima` (on macOS). `cayo vm stop` frees the VM's memory and keeps everything; `cayo vm delete` removes it after two confirmations, with `--data`: a plain `colima delete` keeps the data disk, and a VM created later with the same name gets it back, guests' volumes included. `cayo-hostile` is meant to be disposable: start it for a hostile task, delete it when its guests are gone.
- **Never** give a guest the runtime's control socket, `privileged: true`, host networking, or the host PID namespace: any of these hands it its VM, and everything the VM mounts.

### Guests

`cayo new` picks the VM from the profile, creates the home volume and the exchange directory, for a guest with a network an internal network and its proxy, and runs the container with no capabilities, no privilege escalation, and nothing but `sleep` until something execs into it. Then it runs your `guest-init`.

```
/home/cayo/                     the home volume: persists across container recreation
├── src/                        repos, cloned from inside
├── .dotfiles/                  CAYO_DOTFILES, read-only (trusted, public; CAYO_DOTFILES_MOUNT)
└── exchange/                   ~/cayo-exchange/<vm>/<guest> on the host, writable
```

- **Repos live in the home volume**, not on the host. The volume survives the container, so a guest can be recreated from a new image without losing anything; it lives inside the VM, so it is fast; and the host can't accidentally run git or an editor against the repos (it reaches them through the `ext::` remote, below).
- **The dotfiles are read-only**, and a change on the host reaches every guest at once. They must never contain secrets, and file modes don't help: a guest reads every file in a mount, whatever its permissions. Hostile guests get none.
- **The exchange directory** is the one writable host path, for screenshots, CSVs and similar, per guest under its VM's exchange root (the hostile VM can't see the others'). On the host, treat its contents like untrusted downloads: a guest can create symlinks there that point at host paths, and a host tool that follows one reads or overwrites the host file. Don't write into it over existing names, and check with `ls -l` before opening what's there.
- **Proxy variables** are set in both spellings, since tools disagree on which they read (curl ignores an uppercase `HTTP_PROXY`). `CAYO_NO_PROXY`, at `cayo new`, adds the hosts the guest reaches directly: its HTTP dev services, which would otherwise be sent to the proxy and refused.
- **Ports, when a guest needs them.** Docker publishes no ports for a container that is only on an internal network, so `cayo port` starts a small forwarder per port, on the bridge and attached to the guest's network: `cayo port trusted shop 8000` makes the guest's port 8000 reachable at `127.0.0.1:8000`, `cayo port trusted shop 18000:5173` maps another host port. A clash within a VM is refused; one between the two VMs, or with a host process, goes unnoticed, and the host port leads to whichever claimed it first. Dev servers must listen on `0.0.0.0` inside the guest (Django's, for one, defaults to `127.0.0.1`). Forwarded ports are reachable from other containers in the VM through the host, so they shouldn't expose anything that trusts its callers.
- **Updating.** `cayo build` rebuilds on a freshly pulled Debian base (security updates come with every rebuild), rebuilds your layer, pulls the proxy and forwarder images and drops unused images. Guests keep the image they were created from until `cayo recreate`, which replaces the guest's containers, keeps its home volume and its forwarded ports, and ends whatever runs in the guest at that moment.

### Egress

**The network denies, the proxy allows.**

- The guest is on an `--internal` Docker network, which has no route out: non-HTTP TCP, UDP and external DNS have nowhere to go. The guest resolves only local names; the proxy resolves the rest, so DNS can't carry data out either (checked: a guest's lookup of a unique name produced no packet on any of the VM's interfaces).
- A proxy sidecar is on that network and the bridge, and is the guest's only way out. Honouring the proxy variables is voluntary, but a process that ignores them has no route at all.
- The proxy never connects to private, loopback or link-local addresses, which keeps the host, other containers and the local network out of reach, including through an allowed name that resolves to a private address.
- Two modes: `allowlist` (`trusted`, `public`) allows only listed hostnames; `public` (`hostile-web`) allows any public address. `hostile-sample` has no network.
- No TLS interception: the proxy sees hostnames, not contents.

The proxy is Squid. cayo copies its configuration (`egress/` in the checkout) and the guest's allow-list (`~/.cayo/egress/cayo-<profile>-<name>.txt`: one hostname per line, a leading dot for subdomains too, `#` for comments) into it when it starts it, and again on `cayo reload`, so no VM mounts them and nothing in a guest or a VM can change them. A new guest's list is a copy of `~/.cayo/egress/default.txt` if you keep one (the hosts your `guest-init` needs, say), or else empty: Squid warns about the empty ACL and refuses everything.

Allowing a host, with the guest running:

1. `cayo denied trusted shop` lists the hosts its proxy refused (`cayo verify`'s own probes show up there too).
2. Decide: the exact name rather than a whole domain, and whether the host stores data for any account (below).
3. `cayo allow trusted shop api.example.com` adds it and reloads the proxy; nothing restarts. Editing the file and running `cayo reload` does the same, but `cayo allow` also checks each entry is a hostname: Squid reads every word on a line as a separate name.

Start lists as empty as the work allows. A host that stores data for whoever authenticates (a code host, a package registry, a model API used with someone else's key) can carry data out, and in `trusted` the list also decides what strangers' text the agent reads. Prefer exact names: `github.com` rather than `.github.com`, which would also allow `gist.github.com`; `pypi.org` without the dot excludes `upload.pypi.org`, and pip downloads from `files.pythonhosted.org`.

### Image

Three layers, each built `FROM` the one below; a guest runs the most specific one that exists:

| Image | From | Holds |
|---|---|---|
| `cayo-base` | the checkout's `Dockerfile` | Debian stable, a non-root user `cayo` (shell: bash), and only what cayo needs: `ca-certificates` and `curl` (HTTPS through the proxy, `cayo verify`'s probes), `git` (the review flow fetches from the guest) |
| `cayo-local` | `~/.cayo/image/Dockerfile` | your tools for every guest: a shell (and `usermod -s` to make it the one `cayo exec` opens), search tools, a toolchain, an editor (`examples/image.Dockerfile`) |
| `cayo-<profile>` | `~/.cayo/image/<profile>/Dockerfile` | one profile's own, `FROM cayo-local`, or `FROM cayo-base` when it should carry none of your tools: a browser for `hostile-web`, say |

`cayo build` builds all of them in each running VM, in the VM's Docker Engine, outside any guest and its proxy, so their downloads never need a guest's allow-list.

Docker copies the image's home into a guest's volume only once, when the volume is created, so whatever installs under the home never updates from the image. Tools that install system-wide belong in a layer; tools that install into the home (editor plugins, language toolchains, the agent and its self-updater) are installed from inside the guest, through its proxy. There is no sudo in guests; installing system packages means rebuilding from the host.

### Terminal

Use a terminal that denies clipboard reads (Ghostty: `clipboard-read = deny`, `clipboard-write = allow`): guests set the clipboard through OSC 52, and the clipboard often holds secrets. With tmux, `set -g set-clipboard on`; a window per guest with the editor, the agent and a shell is three `tmux split-window "cayo exec <profile> <name> …"` lines. `docker exec -it` allocates a terminal inside the guest; your pane only relays bytes, so no terminal device is shared with the guest. The terminal's `TERM` needs its terminfo in the image; `cayo new` sets `xterm-256color`.

### Editor, agent and browser

- The editor, its plugins and every language server run in the guest.
- The agent runs in the guest, logged in there, its state in the home volume. That login is a credential in the guest: for `public` and hostile guests, prefer an API key from a separate account with a spending limit. Anything configured inside the guest (the agent's permissions, its instructions) is convenience, not a security control: the boundary is the guest.
- Browser automation (Playwright and similar) runs in the guest too. Chromium's own sandbox may not start with all capabilities dropped; Playwright then needs `--no-sandbox`, leaving the guest as the boundary **(verify)**.
- To drive the agent's browser by hand (logging into a test account, say), keep the browser in the guest: one on the host driven from the guest would execute guest commands on the host (`file://` URLs, downloads to host paths) and bypass egress. Run it headed under Xvfb with noVNC on a forwarded port, and drive it from the host browser **(verify)**; or try Chromium's remote debugging port through a forwarder first **(verify)**. What you type into it becomes a credential in the guest: use an account whose rights are restricted server-side.
- Per-path tool state (`mise trust`, `direnv allow`, an agent's per-project memory) starts fresh in the guest. Clone fresh rather than migrating checkouts.

### Git: clone, review, push, deploy

**In the guest:** a `trusted` guest clones with a **read-only** upstream token (HTTPS, in the guest's git credential store); a `public` guest clones public repos anonymously. Fetch and pull work; push is refused by the server.

**On the host:** a clean clone per repo, with the guest as a remote through git's `ext::` transport:

```sh
git clone git@git.example.com:org/shop-app.git ~/src-clean/shop-app
cd ~/src-clean/shop-app
git remote add cayo 'ext::docker --context colima-cayo exec -i cayo-trusted-shop %S /home/cayo/src/shop-app'
git config protocol.ext.allow user
git config transfer.fsckObjects true
```

- `protocol.ext.allow user` allows `ext::` only for commands you run; git keeps it blocked for URLs coming from fetched content, such as submodules.
- `git fetch cayo <branch>` runs `git-upload-pack` inside the guest. On the host, git only receives pack data, inert until checked out; `transfer.fsckObjects` makes it check every object before storing it.

**Two-pass review.** First a comprehension pass in the guest, with your full editor: comfortable, but not authoritative, since the tooling there is agent-controlled (diff drivers, pagers and plugins can render something other than the commit). Then an authoritative pass in the clean clone, in a tool that doesn't run project code (`git log -p` with `delta` and `less`, Sublime Merge): quick, because the change is already understood.

```sh
git fetch cayo feature-x
git log -p origin/develop..cayo/feature-x
git push origin cayo/feature-x:refs/heads/feature-x        # full ref: the source is a remote-tracking branch
git worktree add ../shop-app-deploy <reviewed-sha>         # deploys run from here
```

Deploying runs guest-written code with your privileges; the guarantee is that what runs is exactly what you reviewed.

### Dev services and dev servers

- Run each project's compose from its clean clone at a reviewed commit, so review covers its mounts, privileges and build contexts, in the guest's VM and on the guest's network only, with an override (`examples/override.yml`) that also drops published ports:

  ```sh
  docker --context colima-cayo compose -f docker-compose.yml -f ~/.cayo/overrides/shop-app.yml up -d
  ```

  Checked with Compose 5.5: a service defined with two networks and a published port came up on the guest's network only, with none published. Create the guest first: it creates the network. Files the compose file bind-mounts from the clean clone must be visible in the VM: add the clean clones to `CAYO_VM_MOUNTS`.
- **Why only the guest's network.** The guest can take over what it reaches (with a dev database's superuser, `COPY ... TO PROGRAM` runs a program in the service's container). A service that also had a normal network would give the guest a route around its proxy. Services still reach each other by name; one that needs the internet at run time gives its guest that route, which is never acceptable for `public`.
- The guest reaches services by name (`psql -h app-postgres`); HTTP services also go in `CAYO_NO_PROXY`. Services that call back into a dev server must be on the guest's network too, and point at the guest by name.
- **The browser is the one host program that runs guest-written code**: the dev server's pages, through a forwarded port. That is what a browser's sandbox is for, and a dev server is at worst a malicious website. Use a separate browser profile without extensions, keep the browser updated, and make sure local services don't trust loopback callers: a page can send requests to any local port.

### Host exposure

- **Host loopback.** In colima's VMs, containers on a normal network reach the host at `192.168.5.2` (`host.lima.internal`, also `host.docker.internal`), including services that listen only on the host's `127.0.0.1`. Guests and their dev services are never on a normal network, and the proxies refuse private addresses, but the proxies and forwarders are. Anything you run on localhost is reachable from those, and from pages the browser renders from a guest: audit with `lsof -nP -iTCP -sTCP:LISTEN`.
- **What colima forwards to the host.** Ports the VM listens on are forwarded to the host: those on the VM's `127.0.0.1` to the host's loopback, those on `0.0.0.0` to all the host's interfaces. Nothing cayo starts listens on `0.0.0.0`, and guests can't publish ports; a guest that escaped into its VM could, and would also have the VM's unfiltered outbound network. One quirk: colima listens on TCP port 53 on all the host's interfaces, for the VM's DNS forwarder; it accepts connections and resets them.
- **Tracked secrets in repos** reach the guest with the clone: rotate and remove them.
- **A global gitignore** must reach guests through the dotfiles, or files ignored only by the host's global ignore become committable.

## Verification

`cayo verify <profile> <name> [allowed-url]` checks the container's shape from the host (`docker inspect`), then pipes a script into the guest's shell and reads what it prints, so nothing from the guest runs on the host. It exits non-zero if any check fails.

| Profile | Checks |
|---|---|
| all | not privileged; all capabilities dropped; `no-new-privileges`; own PID namespace; no runtime socket mounted or present; exactly the expected mounts |
| `trusted`, `public` | dotfiles (when mounted) present, read-only, not writable; the proxy refuses a host off the allow-list with its own 403; `allowed-url`, if given, gets through the proxy (whatever the site answers) |
| `trusted`, `public`, `hostile-web` | only on its internal network; external names don't resolve; the proxy refuses the host and a private address; no route to the host or the internet around the proxy; other guests' containers don't resolve |
| `hostile-web` | the public internet works through the proxy |
| `hostile-sample` | no network, no routes, no connection to the internet |

Checked on colima 0.10.3 for all three profile shapes across both VMs, including a negative run (an `allowed-url` off the list fails). The rest is manual:

- What each VM sees of the host: `colima ssh -p cayo -- mount | grep virtiofs` lists exactly the configured mounts, writable only the exchange root.
- `git push` to upstream from a guest is refused by the server.
- An HTTP dev service in `CAYO_NO_PROXY` answers by name; a port forwarded with `cayo port` answers on the host.
- Dev-service containers have no route out: `docker --context colima-cayo compose exec` into one and try an external address and `192.168.5.2`.
- Loopback listeners on the host are known and acceptable.

## Other platforms

On a Linux host, colima runs its VMs with QEMU, which should keep this shape **(verify)**. Without a VM, containers share the host's kernel and a container escape is a host compromise; cayo doesn't support that.

## License

[MIT](LICENSE).
