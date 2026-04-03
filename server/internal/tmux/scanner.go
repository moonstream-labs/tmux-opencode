package tmux

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// PaneInfo represents a tmux pane from list-panes.
type PaneInfo struct {
	Target  string // session:window.pane
	Command string // pane_current_command
	PID     int    // pane_pid
}

// ListPanes returns all panes in the tmux server.
func ListPanes() ([]PaneInfo, error) {
	out, err := exec.Command("tmux", "list-panes", "-a",
		"-F", "#{session_name}:#{window_index}.#{pane_index}\t#{pane_current_command}\t#{pane_pid}",
	).Output()
	if err != nil {
		return nil, err
	}

	var panes []PaneInfo
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) < 3 {
			continue
		}
		pid, _ := strconv.Atoi(parts[2])
		panes = append(panes, PaneInfo{
			Target:  parts[0],
			Command: parts[1],
			PID:     pid,
		})
	}
	return panes, nil
}

// PaneExists checks if a tmux pane target is still alive.
func PaneExists(target string) bool {
	err := exec.Command("tmux", "display-message", "-p", "-t", target, "#{pane_id}").Run()
	return err == nil
}

// ClaudeSessionFile is the structure of ~/.claude/sessions/<pid>.json.
type ClaudeSessionFile struct {
	PID       int    `json:"pid"`
	SessionID string `json:"sessionId"`
	CWD       string `json:"cwd"`
}

// FindClaudeSessionForPaneTree walks the process tree under panePID and
// tries to find a matching ~/.claude/sessions/<pid>.json file.
func FindClaudeSessionForPaneTree(panePID int) *ClaudeSessionFile {
	// Try the pane PID directly (when claude is the pane command).
	if sf, err := ReadClaudeSessionByPID(panePID); err == nil {
		return sf
	}
	// Walk children and grandchildren.
	for _, cpid := range findChildPIDs(panePID) {
		if sf, err := ReadClaudeSessionByPID(cpid); err == nil {
			return sf
		}
	}
	return nil
}

// ReadClaudeSessionByPID reads ~/.claude/sessions/<pid>.json.
func ReadClaudeSessionByPID(pid int) (*ClaudeSessionFile, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}

	path := filepath.Join(home, ".claude", "sessions", fmt.Sprintf("%d.json", pid))
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var sf ClaudeSessionFile
	if err := json.Unmarshal(data, &sf); err != nil {
		return nil, err
	}
	return &sf, nil
}

// DiscoverOpenCodePort attempts to find the --port flag from
// /proc/<pid>/cmdline for an opencode process.
func DiscoverOpenCodePort(panePID int) (int, bool) {
	// Walk child processes looking for opencode.
	children := findChildPIDs(panePID)
	children = append(children, panePID)

	for _, cpid := range children {
		cmdline, err := readCmdline(cpid)
		if err != nil {
			continue
		}

		// Check if this is an opencode process.
		isOpenCode := false
		for _, arg := range cmdline {
			if strings.Contains(arg, "opencode") {
				isOpenCode = true
				break
			}
		}
		if !isOpenCode {
			continue
		}

		// Extract --port value.
		for i, arg := range cmdline {
			if arg == "--port" && i+1 < len(cmdline) {
				if port, err := strconv.Atoi(cmdline[i+1]); err == nil {
					return port, true
				}
			}
			if strings.HasPrefix(arg, "--port=") {
				if port, err := strconv.Atoi(strings.TrimPrefix(arg, "--port=")); err == nil {
					return port, true
				}
			}
		}
	}

	return 0, false
}

func findChildPIDs(parentPID int) []int {
	out, err := exec.Command("pgrep", "-P", strconv.Itoa(parentPID)).Output()
	if err != nil {
		return nil
	}

	var pids []int
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if pid, err := strconv.Atoi(strings.TrimSpace(line)); err == nil {
			pids = append(pids, pid)
			// Also check grandchildren.
			pids = append(pids, findChildPIDs(pid)...)
		}
	}
	return pids
}

func readCmdline(pid int) ([]string, error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return nil, err
	}
	if len(data) == 0 {
		return nil, fmt.Errorf("empty cmdline")
	}

	// cmdline is null-delimited.
	var args []string
	for _, arg := range strings.Split(string(data), "\x00") {
		if arg != "" {
			args = append(args, arg)
		}
	}
	return args, nil
}

// ScannerCallbacks defines how the scanner notifies the main server
// about discovered and departed panes.
type ScannerCallbacks struct {
	// OnClaudeDiscovered is called when a claude pane is found that is
	// not yet tracked. Returns true if the session was registered.
	OnClaudeDiscovered func(target string, pid int) bool

	// OnOpenCodeDiscovered is called when an opencode pane with a known
	// port is found that is not yet tracked.
	OnOpenCodeDiscovered func(target string, port int) bool

	// IsClaudeTracked returns true if the given pane target is already
	// tracked as a Claude Code session.
	IsClaudeTracked func(target string) bool

	// IsOpenCodeTracked returns true if the given pane target is already
	// tracked as an OpenCode session.
	IsOpenCodeTracked func(target string) bool

	// OnPaneGone is called when a previously tracked pane no longer runs an agent.
	OnPaneGone func(target string)

	// GetTrackedTargets returns all pane targets currently tracked by any store.
	GetTrackedTargets func() []string
}

// RunScanner periodically scans tmux panes to discover untracked sessions
// and prune dead panes. Runs until ctx is cancelled.
func RunScanner(ctx context.Context, interval time.Duration, cb ScannerCallbacks) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			scanOnce(cb)
		}
	}
}

func scanOnce(cb ScannerCallbacks) {
	panes, err := ListPanes()
	if err != nil {
		return
	}

	// Build set of panes running claude or opencode.
	agentPanes := make(map[string]bool)

	for _, p := range panes {
		switch p.Command {
		case "claude":
			agentPanes[p.Target] = true
			if cb.IsClaudeTracked != nil && cb.IsClaudeTracked(p.Target) {
				continue
			}
			if cb.OnClaudeDiscovered != nil {
				cb.OnClaudeDiscovered(p.Target, p.PID)
			}

		case "opencode":
			agentPanes[p.Target] = true
			if cb.IsOpenCodeTracked != nil && cb.IsOpenCodeTracked(p.Target) {
				continue
			}
			port, found := DiscoverOpenCodePort(p.PID)
			if found && cb.OnOpenCodeDiscovered != nil {
				cb.OnOpenCodeDiscovered(p.Target, port)
			}
		}
	}

	// Prune tracked sessions whose pane no longer runs an agent process.
	if cb.OnPaneGone != nil {
		if cb.GetTrackedTargets != nil {
			for _, target := range cb.GetTrackedTargets() {
				if !agentPanes[target] {
					cb.OnPaneGone(target)
				}
			}
		}
	}
}
