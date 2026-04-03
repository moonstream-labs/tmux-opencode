package state

import (
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite"
)

type DB struct {
	*sql.DB
	path string
}

func OpenDB(path string) (*DB, error) {
	dsn := fmt.Sprintf("file:%s?_journal_mode=WAL&_synchronous=NORMAL&_busy_timeout=1000", path)
	sqlDB, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}

	sqlDB.SetMaxOpenConns(1)

	if err := initSchema(sqlDB); err != nil {
		sqlDB.Close()
		return nil, fmt.Errorf("init schema: %w", err)
	}

	return &DB{DB: sqlDB, path: path}, nil
}

func initSchema(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS panes (
			target     TEXT PRIMARY KEY,
			tool       TEXT NOT NULL,
			state      TEXT NOT NULL,
			session_id TEXT,
			name       TEXT,
			dir        TEXT,
			updated    INTEGER,
			host       TEXT NOT NULL DEFAULT 'local'
		);

		CREATE TABLE IF NOT EXISTS recent (
			tool         TEXT NOT NULL,
			session_id   TEXT NOT NULL,
			name         TEXT,
			dir          TEXT,
			updated      INTEGER,
			host         TEXT NOT NULL DEFAULT 'local',
			tmux_session TEXT,
			PRIMARY KEY(tool, session_id, host)
		);
	`)
	return err
}

func (db *DB) WritePanesSnapshot(panes []PaneRow) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec("DELETE FROM panes"); err != nil {
		return err
	}

	stmt, err := tx.Prepare(`INSERT OR REPLACE INTO panes
		(target, tool, state, session_id, name, dir, updated, host)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, p := range panes {
		if _, err := stmt.Exec(p.Target, p.Tool, p.State, p.SessionID, p.Name, p.Dir, p.Updated, p.Host); err != nil {
			return err
		}
	}

	return tx.Commit()
}

func (db *DB) WriteRecentSnapshot(recent []RecentRow) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec("DELETE FROM recent"); err != nil {
		return err
	}

	stmt, err := tx.Prepare(`INSERT OR REPLACE INTO recent
		(tool, session_id, name, dir, updated, host, tmux_session)
		VALUES (?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, r := range recent {
		if _, err := stmt.Exec(r.Tool, r.SessionID, r.Name, r.Dir, r.Updated, r.Host, r.TmuxSession); err != nil {
			return err
		}
	}

	return tx.Commit()
}

func (db *DB) WriteSnapshot(panes []PaneRow, recent []RecentRow) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec("DELETE FROM panes"); err != nil {
		return err
	}
	if _, err := tx.Exec("DELETE FROM recent"); err != nil {
		return err
	}

	pStmt, err := tx.Prepare(`INSERT OR REPLACE INTO panes
		(target, tool, state, session_id, name, dir, updated, host)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return err
	}
	defer pStmt.Close()

	for _, p := range panes {
		if _, err := pStmt.Exec(p.Target, p.Tool, p.State, p.SessionID, p.Name, p.Dir, p.Updated, p.Host); err != nil {
			return err
		}
	}

	rStmt, err := tx.Prepare(`INSERT OR REPLACE INTO recent
		(tool, session_id, name, dir, updated, host, tmux_session)
		VALUES (?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return err
	}
	defer rStmt.Close()

	for _, r := range recent {
		if _, err := rStmt.Exec(r.Tool, r.SessionID, r.Name, r.Dir, r.Updated, r.Host, r.TmuxSession); err != nil {
			return err
		}
	}

	return tx.Commit()
}
