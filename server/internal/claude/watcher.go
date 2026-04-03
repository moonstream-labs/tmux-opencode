package claude

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/fsnotify/fsnotify"
	"github.com/moonstream-labs/tmux-agents/internal/state"
)

// WatchTitles watches ~/.claude/projects/ for JSONL writes and
// detects custom-title changes. Runs until ctx is cancelled.
func WatchTitles(ctx context.Context, store *Store, reconciler *state.Reconciler) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}

	projectsDir := filepath.Join(home, ".claude", "projects")
	if _, err := os.Stat(projectsDir); os.IsNotExist(err) {
		log.Printf("claude: projects dir %s does not exist, title watcher disabled", projectsDir)
		return nil
	}

	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}

	// Watch the projects directory and all immediate subdirectories.
	if err := watcher.Add(projectsDir); err != nil {
		watcher.Close()
		return err
	}

	entries, err := os.ReadDir(projectsDir)
	if err == nil {
		for _, e := range entries {
			if e.IsDir() {
				subdir := filepath.Join(projectsDir, e.Name())
				watcher.Add(subdir)
			}
		}
	}

	go func() {
		defer watcher.Close()
		for {
			select {
			case <-ctx.Done():
				return
			case event, ok := <-watcher.Events:
				if !ok {
					return
				}
				if event.Op&(fsnotify.Write|fsnotify.Create) == 0 {
					continue
				}

				// New project subdirectory — start watching it.
				if event.Op&fsnotify.Create != 0 {
					if info, err := os.Stat(event.Name); err == nil && info.IsDir() {
						watcher.Add(event.Name)
						continue
					}
				}

				// Only care about .jsonl files.
				if !strings.HasSuffix(event.Name, ".jsonl") {
					continue
				}

				handleJSONLChange(event.Name, store, reconciler)

			case err, ok := <-watcher.Errors:
				if !ok {
					return
				}
				log.Printf("claude: watcher error: %v", err)
			}
		}
	}()

	return nil
}

func handleJSONLChange(path string, store *Store, reconciler *state.Reconciler) {
	// Extract session ID from filename: <sessionId>.jsonl
	base := filepath.Base(path)
	sessionID := strings.TrimSuffix(base, ".jsonl")
	if sessionID == "" {
		return
	}

	// Only process if we're tracking this session.
	if _, exists := store.Get(sessionID); !exists {
		return
	}

	// Read the last few lines looking for custom-title.
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}

	lines := splitLines(data)
	// Scan last 5 lines (title entries are appended).
	start := len(lines) - 5
	if start < 0 {
		start = 0
	}

	for i := len(lines) - 1; i >= start; i-- {
		var entry struct {
			Type        string `json:"type"`
			CustomTitle string `json:"customTitle"`
			SessionID   string `json:"sessionId"`
		}
		if err := json.Unmarshal(lines[i], &entry); err != nil {
			continue
		}
		if entry.Type == "custom-title" && entry.CustomTitle != "" {
			if store.UpdateName(sessionID, entry.CustomTitle) {
				log.Printf("claude: title updated session=%s name=%q", sessionID, entry.CustomTitle)
				reconciler.Reconcile()
			}
			return
		}
	}
}
