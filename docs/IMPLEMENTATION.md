# Implementation Notes

This document describes the current `tmux-opencode` implementation in detail: process model, data model, control flow, and key design tradeoffs.

## 1. Runtime Topology

`tmux-opencode` is implemented as a small Bash runtime split into four executable surfaces:

1. `opencode.tmux`
   - TPM entrypoint
   - installs key binding
   - starts/repairs daemon
   - optionally appends status module into `status-right`

2. `scripts/daemon.sh`
   - single-instance polling daemon (Linux-oriented)
   - discovers active OpenCode panes (local + SSH)
   - resolves pane-to-session mappings
   - queries local/remote OpenCode metadata
   - writes normalized snapshots into state DB
   - publishes lightweight tmux signaling options

3. `scripts/_navigator_picker.sh`
   - renders Active/Recent views from state DB
   - hosts interactive `fzf` picker mode
   - routes selection actions (jump / local launch / remote launch)
   - writes exact remote pane bindings when user launches/reuses remote sessions

4. `scripts/status.sh`
   - tiny status renderer
   - reads daemon pill state and prints a Catppuccin-compatible segment
   - also calls daemon health gate (`start_daemon_if_needed`) to self-heal stale daemons


## 2. Storage and Signaling Model

The implementation intentionally separates **state transport** from **UI signaling**.

### 2.1 Canonical Runtime State (SQLite)

Primary runtime state lives in a plugin-owned SQLite DB:

- path: `$OPENCODE_STATE_DB_PATH`
- default: `$OPENCODE_STATE_DIR/state.db`
- default state dir: `/tmp/tmux-opencode-<uid>`

Schema (initialized by daemon):

- `panes`
  - `target TEXT PRIMARY KEY`
  - `cmd TEXT NOT NULL`
  - `state TEXT NOT NULL`
  - `host TEXT NOT NULL`
  - `sid TEXT`
  - `title TEXT`
  - `dir TEXT`
  - `updated INTEGER`

- `recent`
  - `host TEXT NOT NULL`
  - `sid TEXT NOT NULL`
  - `title TEXT`
  - `dir TEXT`
  - `updated INTEGER`
  - `tmux_session TEXT`
  - `PRIMARY KEY(host, sid)`

Write pattern:

- snapshot writes are transactional (`BEGIN IMMEDIATE` ... `COMMIT`)
- daemon rebuilds `panes` and `recent` snapshots and replaces table contents atomically
- fast tier may update only `panes` snapshot between metadata cycles


### 2.2 tmux Signaling Options

tmux options now carry signaling/status only (not full dataset transport):

- `@opencode-pill`
  - format: `state|count`
  - `state ∈ {permission, running, active, idle}`

- `@opencode-gen`
  - monotonic generation counter
  - incremented whenever pane/recent snapshots materially change
  - picker watcher reloads on generation changes

- `@opencode-daemon-ts`
  - unix epoch seconds heartbeat
  - used by launch paths to detect/restart stale daemon process


### 2.3 Auxiliary State Files

Under `$OPENCODE_STATE_DIR`:

- `daemon.pid`
  - active daemon process id

- `daemon.lock`
  - `flock` lock for single-instance enforcement

- `remote-bindings.tsv`
  - exact remote pane bindings persisted by picker
  - format: `<target>\t<host>\t<sid>`
  - daemon consumes this to map SSH panes with high confidence


## 3. Process Lifecycle and Health

## 3.1 Startup

On plugin load (`opencode.tmux`):

1. sources shared helpers
2. removes stale pre-v1 and pre-state-db options
3. installs popup key binding
4. runs `start_daemon_if_needed`

`start_daemon_if_needed` behavior:

- healthy daemon => no-op
- stale daemon (alive PID but stale heartbeat) => stop and restart
- missing daemon => start with `nohup`


## 3.2 Single-Instance Guard

Daemon startup sequence:

1. opens lock file descriptor (`exec 9>daemon.lock`)
2. acquires non-blocking lock (`flock -n 9`)
3. exits immediately if lock is held by another daemon
4. writes pid file and installs exit traps


## 3.3 Heartbeat and Staleness

Daemon writes `@opencode-daemon-ts` once per second.

Health check uses:

- pid validity (`kill -0` + `/proc/<pid>/cmdline` contains `daemon.sh`)
- heartbeat freshness threshold (`OPENCODE_DAEMON_STALE_S`, default 20s)


## 4. Core Daemon Loop

Main loop intervals (from `scripts/variables.sh`):

- discovery tier: `OPENCODE_POLL_DISCOVERY_S` (default 5s)
- metadata tier: `OPENCODE_POLL_METADATA_S` (default 30s)
- local-map tier: `OPENCODE_POLL_LOCAL_MAP_S` (default 2s)
- fast tier sleep: `0.1s`

Loop order:

1. heartbeat update
2. discovery (if due)
3. metadata fetch/rebuild (if due)
4. local fallback mapping refresh (if due)
5. fast state update (`update_pill`)


## 5. Pane Discovery and State Detection

### 5.1 Discovery Inputs

Daemon scans all panes with:

- `tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}\t#{pane_current_command}\t#{pane_pid}\t#{pane_title}'`

Tracked pane categories:

- local: `pane_current_command == opencode`
- remote: `pane_current_command == ssh` **and** output resembles OpenCode TUI


### 5.2 Remote TUI Validation

For SSH panes, daemon captures pane output and checks bottom non-blank lines against pattern set:

- `╹▀▀▀`
- `ctrl+p commands`
- `esc interrupt`
- `Allow once`

If capture fails or pattern does not match, pane is excluded from OpenCode inventory.


### 5.3 Per-Pane Runtime State

`detect_pane_state(target, cmd)` returns:

- `running` if last line contains `esc interrupt`
- `permission` if second-last or last line contains `Allow once`
- `idle` otherwise
- `unknown` when pane capture fails / invalid remote TUI

The function is intentionally failure-tolerant: capture errors map to `unknown` rather than terminating daemon.


## 6. Session Identity and Mapping

## 6.1 Composite Identity

Session metadata is keyed by composite `(host, sid)` identity internally.

Implementation detail:

- key format: `<host><US><sid>` where `US` is ASCII unit-separator (`0x1f`)

This avoids cross-host SID collision bugs and allows host-scoped recent/history behavior.


## 6.2 Local Pane -> Session Mapping

Exact mapping path:

1. walk process tree under pane pid (children + grandchildren)
2. locate `opencode` process
3. parse null-delimited `/proc/<pid>/cmdline`
4. extract `-s/--session` argument

Fallback path for plain `opencode` (without `-s`):

- choose newest session in same `pane_current_path` from local DB
- avoid reusing local SID already mapped to another pane in current cycle


## 6.3 Remote Pane -> Session Mapping

Default behavior: `unbound` unless exact binding exists.

Resolution order:

1. load exact mappings from `remote-bindings.tsv`
2. apply only when pane target still resolves to same remote host
3. if no exact mapping exists:
   - default `@opencode-remote-binding-mode=unbound`: leave SID empty
   - optional legacy `latest`: bind one unbound pane per host to newest remote row

This design prevents silent wrong-session assumptions by default.


## 7. Metadata Ingestion

## 7.1 Local Metadata Source

Local DB path:

- `$OPENCODE_DB_PATH`
- default: `~/.local/share/opencode/opencode.db`

Queries:

- active local session rows for mapped local SIDs
- recent local rows ordered by `time_updated DESC LIMIT 21`


## 7.2 Remote Metadata Source

Per unique host alias, daemon runs async ssh query:

- remote command: sqlite query against `~/.local/share/opencode/opencode.db`
- query result: newest 21 sessions by `time_updated`

SSH behavior:

- `BatchMode=yes`
- `ConnectTimeout=@opencode-ssh-connect-timeout` (default 3)
- `StrictHostKeyChecking=@opencode-ssh-strict-host-key-checking` (default `accept-new`)

Remote polling can be disabled via `@opencode-remote-polling`.


## 8. Snapshot Build Pipeline

Each metadata cycle produces two snapshots:

1. `panes` snapshot
   - includes every known pane target
   - enriches with `sid/title/dir/updated` when mapped
   - includes live `state`

2. `recent` snapshot
   - constructed from metadata map minus active session keys
   - sorted by `updated DESC`
   - top 20 retained
   - context dedupe excludes entries matching active `host|dir|title`

Change detection:

- daemon compares SQL snapshot payloads to previous payloads
- on change: writes DB snapshot and bumps `@opencode-gen`
- unchanged snapshots are skipped

Fast tier (`update_pill`) can also update pane snapshot and generation when only pane states changed.


## 9. Picker Rendering and Interaction

## 9.1 Render Sources

`_navigator_picker.sh` reads from state DB only:

- Active: select all from `panes`
- Recent: select top 20 from `recent` by `updated DESC`

Rows are rendered with fixed-width columns and ANSI colors derived from tmux theme options.


## 9.2 View Switching and Reload

Interactive picker uses `fzf --listen`.

- left/right keys toggle mode via mode file (`active` / `recent`)
- background watcher polls `@opencode-gen` every 100ms
- generation change triggers a reload for current mode


## 9.3 Selection Behavior

Active row:

- select corresponding tmux pane/session (`select-window`, `select-pane`, `switch-client`)

Recent local row:

- if current pane is local shell in same normalized dir: send `opencode -s <sid>` in place
- else open new window (prefer `-c <dir>` when directory exists)

Recent remote row:

- if current pane is SSH to same host: send command in place
- else open new SSH window (prefer tmux session previously associated with host)
- on in-place reuse or new-window launch, persist exact `<target, host, sid>` mapping

Selection key encoding:

- recent keys are `recent|base64(host)|base64(sid)|base64(tmux_session)`
- avoids delimiter breakage from `:` or `|` in host/session labels


## 10. Status Rendering

`scripts/status.sh`:

1. ensures daemon is running/healthy
2. reads `@opencode-pill`
3. emits a compact status segment

Color logic:

- no sessions (`count=0`) => plain white icon/count
- permission present => yellow pill
- running present => green pill
- otherwise => white pill


## 11. Safety and Failure Semantics

Key robustness mechanisms:

- non-fatal handling for pane capture failures (`unknown` state)
- stale daemon replacement using heartbeat + PID checks
- single-instance lock with `flock`
- transactional DB writes to avoid half-written snapshots
- default remote unbound mode to avoid wrong-session auto-binding
- host-key policy is explicit/configurable (no hardcoded `StrictHostKeyChecking=no`)

Known hard assumptions:

- Linux `/proc` for process introspection
- `flock` availability
- `sqlite3`, `tmux`, `ssh`, `fzf`, `bash`


## 12. Data Flow Summary (End-to-End)

1. User loads plugin or opens popup/status => daemon health check runs.
2. Daemon discovers panes and metadata on polling schedule.
3. Daemon writes canonical snapshots to state DB and bumps generation on change.
4. Picker watcher sees generation change and reloads view from DB.
5. User selects an entry:
   - active => pane navigation
   - recent => launch/reuse command
6. Remote launch/reuse writes exact pane binding file.
7. Next metadata cycle consumes binding and enriches pane rows with exact SID metadata.


## 13. Relevant Tunables

tmux user options:

- `@opencode-popup-key`
- `@opencode-popup-width`
- `@opencode-popup-height`
- `@opencode-popup-border`
- `@opencode-popup-bg`
- `@opencode-popup-fg`
- `@opencode-auto-status-right`
- `@opencode-remote-polling`
- `@opencode-remote-binding-mode` (`unbound` or `latest`)
- `@opencode-ssh-connect-timeout`
- `@opencode-ssh-strict-host-key-checking`

Environment variables:

- `OPENCODE_STATE_DIR`
- `OPENCODE_STATE_DB_PATH`
- `OPENCODE_DB_PATH`
