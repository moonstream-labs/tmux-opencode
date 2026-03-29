# tmux-opencode

`tmux-opencode` is a tmux plugin for navigating active and recent OpenCode sessions across local and remote panes.

It provides:

- a popup navigator (`prefix + o` by default)
- a status pill module for `status-right`
- background session/state tracking for local and SSH-hosted OpenCode sessions

## Features

- Active view: shows currently attached OpenCode panes, with live state (`running`, `permission`, `idle`)
- Recent view: shows recently updated sessions from local and remote OpenCode SQLite metadata
- One-keystroke navigation:
  - Enter on Active -> jump to the pane
  - Enter on Recent (local) -> open `opencode -s <id>` in a new window at the saved directory
  - Enter on Recent (remote) -> open via SSH in an appropriate tmux session
- Status module: compact state/count pill for Catppuccin-style status lines

## Requirements

| Dependency | Version | Purpose |
|---|---|---|
| `tmux` | >= 3.3 recommended | popup UI, modern option/render behavior |
| `bash` | >= 4 | plugin scripts |
| `fzf` | any | popup picker |
| `sqlite3` | any | OpenCode session metadata lookups |
| `ssh` | any | remote host metadata + remote session launch |
| `opencode` | any recent | OpenCode sessions and local DB |
| `curl` | any | fzf live reload channel |

Linux is currently required (`/proc`, `flock`, process tree inspection assumptions).

## Installation

### With TPM (recommended)

Add to your `tmux.conf`:

```tmux
set -g @plugin 'moonstream-labs/tmux-opencode'
```

Then press `prefix + I` to install.

### Manual

Clone into your tmux plugins directory:

```bash
git clone https://github.com/moonstream-labs/tmux-opencode.git \
  ~/.local/share/tmux/plugins/tmux-opencode
```

Add to your `tmux.conf`:

```tmux
run-shell ~/.local/share/tmux/plugins/tmux-opencode/opencode.tmux
```

Reload tmux config:

```bash
tmux source-file ~/.config/tmux/tmux.conf
```

## tmux.conf Configuration

Set options before TPM initialization.

```tmux
# Keybind (prefix + o)
set -g @opencode-popup-key 'o'

# Popup style
set -g @opencode-popup-width '70%'
set -g @opencode-popup-height '50%'
set -g @opencode-popup-border 'rounded'
set -g @opencode-popup-bg '#080909'
set -g @opencode-popup-fg '#dadada'

# Optional: plugin-managed status-right append (off by default)
set -g @opencode-auto-status-right 'off'
```

### Status Module (manual composition, recommended)

When `@opencode-auto-status-right` is `off`, compose the status module directly:

```tmux
set -ag status-right " #[fg=#dadada,bg=default]#($HOME/.local/share/tmux/plugins/tmux-opencode/scripts/status.sh)"
```

### Status Module (automatic append)

If preferred:

```tmux
set -g @opencode-auto-status-right 'on'
```

## Keybinding and Picker Usage

- Open picker: `prefix + o` (default)
- Toggle views: left/right arrows
  - left: Active
  - right: Recent
- Select row: Enter
- Abort: `Esc` or `Ctrl-c`

## Option Reference

| Option | Default | Description |
|---|---|---|
| `@opencode-popup-key` | `o` | Popup launcher key (with tmux prefix) |
| `@opencode-popup-width` | `70%` | Popup width |
| `@opencode-popup-height` | `50%` | Popup height |
| `@opencode-popup-border` | `rounded` | Popup border style |
| `@opencode-popup-bg` | `#080909` | Popup background |
| `@opencode-popup-fg` | `#dadada` | Popup foreground/border color |
| `@opencode-auto-status-right` | `off` | Auto-append status module to `status-right` |

Internal runtime options (managed by the plugin):

- `@opencode-pill`
- `@opencode-panes`
- `@opencode-recent`

## How It Works (High Level)

- `opencode.tmux`
  - registers keybinding
  - ensures daemon is running
  - optionally appends status module
- `scripts/daemon.sh`
  - discovers local/ssh OpenCode panes
  - maps pane -> OpenCode session IDs
  - reads local/remote OpenCode SQLite metadata
  - writes tmux runtime options (`pill`, `panes`, `recent`)
- `scripts/_navigator_picker.sh`
  - renders Active/Recent tables from tmux options
  - provides mode toggle, selection, and launch actions
- `scripts/status.sh`
  - renders the status pill from `@opencode-pill`

For implementation details, see `docs/IMPLEMENTATION.md`.

## Known Limitations

- Local sessions started as plain `opencode` (without `-s`) use newest-in-directory fallback mapping.
- Remote session-to-pane association can be ambiguous if multiple SSH panes target the same host alias.
- Linux-only assumptions are currently baked in.

## Troubleshooting

- Popup does not open:
  - verify keybind and plugin load (`tmux show-options -g | grep @opencode-popup-key`)
- No rows in picker:
  - verify OpenCode sessions are running
  - verify local DB exists at `~/.local/share/opencode/opencode.db`
- Status pill missing:
  - ensure status module is included in `status-right` (or enable auto-append)
- High-latency/freeze symptoms:
  - check host I/O pressure (`cat /proc/pressure/io`) and `vmstat`
  - this is often host/disk contention rather than plugin logic

## License

MIT (see `LICENSE`).
