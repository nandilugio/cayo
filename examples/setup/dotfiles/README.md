# ~/.aiws/dotfiles

Mounted read-only at `~/.dotfiles` in `trusted` and `public` guests (SETUP.md §4): nvim, shell and git config (no credentials), the global gitignore, the agent's instructions. Link them into place once, inside the guest (`ln -s ~/.dotfiles/nvim ~/.config/nvim`).

Never put secrets here. File modes don't protect anything: a guest reads every file in the mount, whatever its permissions. This directory can also be a link to an existing dotfiles checkout: `aiws` mounts its real path, so that is the path the guests' VM must mount (SETUP.md §2).
