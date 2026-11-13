// Package audit records this app's own actions (never AWS's) to a local,
// append-only log, so the activity feed can show what the app did even
// before AWS's own event history catches up.
package audit

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/settings"
)

// Entry is one line of the local audit log.
type Entry struct {
	Time    string `json:"time"`
	Account string `json:"account"`
	Profile string `json:"profile"`
	ARN     string `json:"arn"`
	Action  string `json:"action"`
	Target  string `json:"target"`
	Result  string `json:"result"`
}

func logPath() (string, error) {
	dir, err := settings.Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "activity.jsonl"), nil
}

// Append writes one entry to the audit log. It never fails the caller's
// action: a logging failure is returned so the caller can decide, but the
// AWS call it describes has already happened by the time Append runs.
func Append(e Entry) error {
	p, err := logPath()
	if err != nil {
		return err
	}
	f, err := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("open audit log: %w", err)
	}
	defer f.Close()

	data, err := json.Marshal(e)
	if err != nil {
		return fmt.Errorf("encode audit entry: %w", err)
	}
	if _, err := f.Write(append(data, '\n')); err != nil {
		return fmt.Errorf("write audit entry: %w", err)
	}
	return nil
}

// ReadAll returns every locally recorded audit entry, oldest first. A
// missing log file is not an error: it just means nothing has happened yet.
func ReadAll() ([]Entry, error) {
	p, err := logPath()
	if err != nil {
		return nil, err
	}
	f, err := os.Open(p)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("open audit log: %w", err)
	}
	defer f.Close()

	var out []Entry
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var e Entry
		if err := json.Unmarshal(line, &e); err != nil {
			continue // skip a malformed line rather than failing the whole feed
		}
		out = append(out, e)
	}
	return out, scanner.Err()
}
