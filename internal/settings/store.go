// Package settings persists the user's configured AWS accounts and
// discovers local AWS CLI profiles for the account picker. It never stores
// credentials: only a profile name, display name, regions and a colour.
package settings

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/dinhdobathi/aws-db-backup-manager/internal/model"
)

// Settings is the persisted root document.
type Settings struct {
	Accounts []model.Account `json:"accounts"`
}

// Dir returns the app's settings directory, creating it if needed.
func Dir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home directory: %w", err)
	}
	dir := filepath.Join(home, "Library", "Application Support", "AWS DB Backup Manager")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("create settings directory: %w", err)
	}
	return dir, nil
}

func path() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "settings.json"), nil
}

// Load reads settings.json, returning an empty Settings if it does not
// exist yet.
func Load() (Settings, error) {
	p, err := path()
	if err != nil {
		return Settings{}, err
	}
	data, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return Settings{}, nil
		}
		return Settings{}, fmt.Errorf("read settings: %w", err)
	}
	var s Settings
	if err := json.Unmarshal(data, &s); err != nil {
		return Settings{}, fmt.Errorf("parse settings: %w", err)
	}
	return s, nil
}

// Save atomically writes settings.json with 0600 permissions: write to a
// temp file in the same directory, then rename over the target.
func Save(s Settings) error {
	p, err := path()
	if err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return fmt.Errorf("encode settings: %w", err)
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return fmt.Errorf("write settings: %w", err)
	}
	if err := os.Rename(tmp, p); err != nil {
		return fmt.Errorf("replace settings: %w", err)
	}
	return nil
}

var (
	configProfileHeader      = regexp.MustCompile(`^\[profile\s+(\S+)\]$`)
	configDefaultHeader      = regexp.MustCompile(`^\[default\]$`)
	credentialsProfileHeader = regexp.MustCompile(`^\[(\S+)\]$`)
)

// DiscoverProfiles reads ~/.aws/config and ~/.aws/credentials and returns
// the sorted, deduplicated set of profile names available for the account
// picker. It never reads secret values, only section headers.
func DiscoverProfiles() ([]string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("resolve home directory: %w", err)
	}

	seen := map[string]bool{}
	add := func(name string) {
		name = strings.TrimSpace(name)
		if name != "" {
			seen[name] = true
		}
	}

	if lines, err := readLines(filepath.Join(home, ".aws", "config")); err == nil {
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if m := configProfileHeader.FindStringSubmatch(line); m != nil {
				add(m[1])
			} else if configDefaultHeader.MatchString(line) {
				add("default")
			}
		}
	}

	if lines, err := readLines(filepath.Join(home, ".aws", "credentials")); err == nil {
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if m := credentialsProfileHeader.FindStringSubmatch(line); m != nil {
				add(m[1])
			}
		}
	}

	profiles := make([]string, 0, len(seen))
	for name := range seen {
		profiles = append(profiles, name)
	}
	sort.Strings(profiles)
	return profiles, nil
}

func readLines(p string) ([]string, error) {
	f, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var lines []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	return lines, scanner.Err()
}
