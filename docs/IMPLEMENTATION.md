# Implementation Notes

This document describes the internal data flow and major runtime behavior of `tmux-opencode`.

## Runtime Data Model

The daemon writes three tmux global options that drive UI/status rendering:

- `@opencode-pill`
  - format: `state|count`
  - `state` is one of `permission`, `running`, `active`, `idle`
- `@opencode-panes`
  - newline-separated records
  - record format: `target|cmd|state|host|sid|title|dir|updated`
  - `title` and `dir` are field-escaped
- `@opencode-recent`
  - newline-separated records
  - record format: `host|sid|title|dir|updated|tmux_session`
  - `title` and `dir` are field-escaped

Escaping rules are implemented in `scripts/daemon.sh` (`escape_field`) and reversed in `scripts/_navigator_picker.sh` (`decode_field`).

## Daemon Architecture

`scripts/daemon.sh` runs as a single-process polling loop with three tiers:

1. Discovery tier (`OPENCODE_POLL_DISCOVERY_S`, default 5s)
   - scans tmux panes
   - tracks local `opencode` panes and SSH panes that look like OpenCode TUI panes

2. Metadata tier (`OPENCODE_POLL_METADATA_S`, default 30s)
   - clears and rebuilds metadata maps each cycle
   - maps local pane -> session ID via cmdline `-s` extraction
   - for unmapped local panes, applies newest-in-directory fallback
   - queries local SQLite and remote host SQLite session metadata
   - builds `@opencode-panes` and `@opencode-recent`

3. Fast tier (100ms loop)
   - detects per-pane state by inspecting bottom lines of pane output
   - updates `@opencode-pill`
   - updates pane state payload if changed

Additional local fallback pass (`OPENCODE_POLL_LOCAL_MAP_S`, default 2s) refreshes local plain-`opencode` mappings between metadata cycles.

## Picker Behavior

`scripts/_navigator_picker.sh`:

- renders Active and Recent views from tmux options
- keeps full-width padded rows for consistent highlighting
- persists current mode (`active`/`recent`) while live-reloading
- watches both `@opencode-panes` and `@opencode-recent` for updates
- selection behavior:
  - Active -> jump to pane
  - Recent local -> if current pane is a matching local shell in saved directory, send `opencode -s <sid>` in-place; otherwise new window at saved directory
  - Recent remote -> if current pane is a matching SSH pane to the host, send in-place; otherwise ssh launch in mapped tmux session when available

## Dedupe Logic

Recent entries are filtered to avoid duplicate context when an equivalent active context already exists:

- context key: `host|directory|title`
- if a recent row matches an active context key, it is excluded from Recent view

This keeps Active and Recent views from showing conflicting duplicate rows for the same visible context.

## Status Rendering

`scripts/status.sh` reads `@opencode-pill` and emits a Catppuccin-compatible status fragment.

By default, plugin does not mutate `status-right`; users compose status manually unless `@opencode-auto-status-right` is enabled.

## Linux Assumptions

Current implementation assumes Linux features/tools, including:

- `/proc/<pid>/cmdline`
- `flock`
- process tree traversal via `pgrep`

Non-Linux behavior is not currently targeted.
