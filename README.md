# Dotfiles

Personal macOS configuration files for MacBook Air M1.

## Quick Start

```bash
# Clone the repo
git clone <repo-url> ~/MyPlayground/dotfiles
cd ~/MyPlayground/dotfiles

# Install (creates symlinks)
./install.sh

# Or force overwrite existing
./install.sh --force
```

## What's Included

| Component                       | Description                                   |
| ------------------------------- | --------------------------------------------- |
| `zsh/.zshrc`                    | Zsh config with Oh My Zsh, Pure prompt, zplug |
| `git/.gitconfig`                | Git aliases and sensible defaults             |
| `git/.gitignore_global`         | Global ignores for OS/IDE files               |
| `hammerspoon/init.lua`          | Focus Follows Mouse for multi-monitor setup   |
| `scripts/mac_cleanup.sh`        | Safe macOS cleanup with dry-run mode          |
| `scripts/analyze_brew_deps.sh`  | Find unused Homebrew packages                 |
| `scripts/find_app_leftovers.sh` | Detect orphaned app data                      |
| `launchd/`                      | Scheduled cleanup automation                  |

## Cleanup Scripts

```bash
# Preview what would be cleaned (safe)
mac_cleanup

# Actually clean (moves to Trash)
mac_cleanup --apply

# Deep clean (Docker, npm, pip caches)
mac_cleanup --apply --aggressive
```

## Requirements

- macOS (tested on M1)
- [Homebrew](https://brew.sh)
- [Hammerspoon](https://www.hammerspoon.org/) - `brew install --cask hammerspoon`
- [Oh My Zsh](https://ohmyz.sh/)
- [Pure prompt](https://github.com/sindresorhus/pure) - `brew install pure`
